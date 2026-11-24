import Foundation

enum AnalyticsScope: Hashable {
    case all
    case project(String)
    case session(agent: String, account: String?, source: String?, id: String)

    init(_ item: SessionItem) {
        let source: String?
        switch item.tool {
        case "claude", "codex": source = "transcript"
        case "qoder": source = item.source == "qoder_app" ? "qoder_desktop" : "qoder_cli"
        case "qoder_cn": source = "qoder_cn_cli"
        case "antigravity":
            switch item.source {
            case "antigravity_app": source = "antigravity_app_db"
            case "antigravity_cli": source = "antigravity_cli_db"
            default: source = item.accountId == "app" ? "antigravity_app_db" : item.accountId == "cli" ? "antigravity_cli_db" : nil
            }
        default: source = nil
        }
        self = .session(agent: item.tool, account: item.tool == "antigravity" ? nil : item.accountId ?? "default",
                        source: source, id: item.id)
    }
}

struct AnalyticsQuery: Hashable {
    let start: Int
    let end: Int
    let timezone: String
    let agents: [String]
    let dimension: String
    let basis: String
    let scope: AnalyticsScope

    init(days: Int, agents: Set<String>, dimension: String, basis: String, scope: AnalyticsScope,
         now: Date = Date(), timezone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        self.start = Int(calendar.date(byAdding: .day, value: 1 - days, to: today)!.timeIntervalSince1970)
        self.end = Int(calendar.date(byAdding: .day, value: 1, to: today)!.timeIntervalSince1970)
        self.timezone = timezone.identifier
        self.agents = agents.sorted()
        self.dimension = dimension
        self.basis = basis
        self.scope = scope
    }

    func parameters(generation: String? = nil, cursor: String? = nil) -> [String: String] {
        var result = ["start": String(start), "end": String(end), "timezone": timezone,
                      "agents": agents.joined(separator: ","), "dimension": dimension, "basis": basis]
        result["generation"] = generation
        result["cursor"] = cursor
        switch scope {
        case .all: break
        case let .project(key): result["project"] = key
        case let .session(agent, account, source, id):
            result["agents"] = agent
            result["account_id"] = account
            result["source_kind"] = source
            result["session_id"] = id
        }
        return result
    }
}

struct AnalyticsSlice: Decodable {
    let basis: String
    let metrics: [String: Double?]
    let quality: [String: String]
    let knownSubtotals: [String: Double?]?
    var day: String?
    var key: String?
    var label: String?
    var agent: String?

    func value(_ metric: String) -> Double? {
        guard quality[metric] == "complete" else { return nil }
        return metrics[metric] ?? nil
    }

    func subtotal(_ metric: String) -> Double? {
        guard quality[metric] == "partial" else { return nil }
        return knownSubtotals?[metric] ?? nil
    }

    static let components = ["input_uncached_tokens", "cache_read_tokens", "cache_write_tokens", "output_tokens"]
    var composition: [(String, Double)] {
        Self.components.compactMap { key in value(key).map { (key, $0) } }
    }
}

struct AnalyticsSnapshot: Decodable {
    let generation: String
    let status: String
    let summary: [AnalyticsSlice]
    let series: [AnalyticsSlice]
    var rows: [AnalyticsSlice]
    var nextCursor: String?

    mutating func append(_ page: Self) throws {
        guard generation == page.generation else { throw APIError.http(409) }
        rows += page.rows
        nextCursor = page.nextCursor
    }
}
