// AgentDeck v2 — 后端 API 客户端。直连本机 daemon（127.0.0.1:7777），async/await。
// 与 v1 一致地绕过系统代理（某些企业 PAC 会把回环改道 SOCKS → 连不上本机后端）。
import Foundation

enum APIError: Error {
    case badURL
    case http(Int)
    case noData
}

actor APIClient {
    static let shared = APIClient()

    static let port = 7777
    static let base = "http://127.0.0.1:\(port)"

    // 禁代理直连回环（镜像 main.swift 的 kDirectSession 配置）。
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // 自定义 snake_case → camelCase：Foundation 自带的 .convertFromSnakeCase 对「下划线后接数字」
    // 的键（cost_7d / cost_30d / claude_cost_7d / projects_7d）转换错误 → 解不出、字段静默为 nil
    // （表现：API 等值金额全 0、项目 Top 空、成本拆分缺失）。这里自己实现，数字段也正确映射。
    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue; intValue = Int(stringValue) }
        init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            guard key.contains("_") else { return path.last! }
            let parts = key.split(separator: "_", omittingEmptySubsequences: false)
            var out = String(parts.first ?? "")
            for p in parts.dropFirst() { out += p.prefix(1).uppercased() + p.dropFirst() }
            return AnyKey(stringValue: out)   // cost_7d→cost7d, used_percent→usedPercent, five_hour→fiveHour
        }
        return d
    }()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    // MARK: GET
    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        var comps = URLComponents(string: APIClient.base + path)
        if !query.isEmpty {
            comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps?.url else { throw APIError.badURL }
        var request = URLRequest(url: url)
        // A cache-version upgrade may require one full 30-day JSONL rebuild.
        // Keep the stricter default for every other loopback endpoint.
        if path == "/api/usage" { request.timeoutInterval = 45 }
        // 手动额度刷新可能等待正在执行的 Codex 校准，再查询多个账号。
        // 普通缓存读取仍保留 20s，只有明确 force 时放宽。
        if path == "/api/quota", query["force"] == "1" {
            request.timeoutInterval = 120
        }
        // 额度变化端点由 daemon 最多挂起 30s；客户端超时须略长于服务端，
        // 否则正常心跳会被误判为断线并形成重连循环。
        if path == "/api/quota/changes" { request.timeoutInterval = 35 }
        let (data, resp) = try await session.data(for: request)
        try Self.check(resp)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: POST（保持 daemon 的 CSRF 屏障：Content-Type 主类型须为 application/json；
    // URLSession 自动设 Host=127.0.0.1，且不发 Origin → 通过本机同源校验）。
    @discardableResult
    func post<Body: Encodable, T: Decodable>(_ path: String, body: Body) async throws -> T {
        guard let url = URL(string: APIClient.base + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return try decoder.decode(T.self, from: data)
    }

    /// 原始 JSON 取数（设置值混合类型，绕 Codable）。
    func getJSON(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(string: APIClient.base + path)
        if !query.isEmpty { comps?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps?.url else { throw APIError.badURL }
        let (data, resp) = try await session.data(for: URLRequest(url: url))
        try Self.check(resp)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// POST 原始字典 body，返回原始 JSON（设置保存等）。
    @discardableResult
    func postJSON(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: APIClient.base + path) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
    }
}

// MARK: - 通用 {ok:true,...} 应答
struct OKResponse: Decodable { let ok: Bool }

/// resets_at 等时间字段可能是 epoch 秒（Codex）或 ISO 串（Claude usage API）——两者皆容。
struct FlexibleDate: Decodable, Hashable {
    let date: Date?
    init(_ date: Date?) { self.date = date }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { date = nil; return }
        if let secs = try? c.decode(Double.self) {
            date = Date(timeIntervalSince1970: secs); return
        }
        if let s = try? c.decode(String.self) {
            date = ISO8601DateFormatter().date(from: s)
                ?? ISO8601DateFormatter.withFractional.date(from: s)
            return
        }
        date = nil
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
