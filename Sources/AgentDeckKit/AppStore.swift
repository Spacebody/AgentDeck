// AgentDeck v2 — 应用状态 store。轮询后端、持有各屏数据、暴露动作。#10 在 main.swift 接它。
import SwiftUI

struct UpdateInfo: Decodable {
    let current: String?
    let latest: String?
    let available: Bool?
    let url: String?
    let dmg: String?
    let notesUrl: String?
}

@MainActor
public final class AppStore: ObservableObject {
    // 仅初始化默认值，无需主线程隔离 → nonisolated，便于主壳在属性声明处直接构造。
    public nonisolated init() {}

    /// 设置变更后回调（主壳据此即时重绘菜单栏图标，等价 v1 的 "sync" 桥消息）。
    public var onSettingsChanged: (() -> Void)?

    @Published var quota: QuotaResponse?
    @Published var usage: UsageResponse?
    @Published var sessions: [SessionItem] = []
    @Published var active: [ActiveSession] = []
    @Published var done: [DoneEvent] = []
    @Published var settings: [String: SettingValue] = [:]
    @Published var update: UpdateInfo?
    @Published var searchResults: [SessionItem]?   // 搜索态（nil=用周期列表）
    @Published var online = true                   // 后端健康（驱动顶栏 live 点）

    @Published var terminals: [TerminalOption] = []   // /api/terminals 已安装终端（恢复方式选项）

    var today: TodaySummary? { usage.flatMap { TodaySummary(from: $0) } }
    var updateAvailable: Bool { update?.available == true }

    /// 该 agent 是否展示（设置 show_claude/show_codex；默认 true，对应 v1 agentOn）。
    func agentOn(_ tool: String) -> Bool { settings["show_\(tool)"]?.boolVal ?? true }
    var showActive: Bool { settings["show_active"]?.boolVal ?? true }

    // 列表按 show_claude/show_codex 过滤（daemon 不过滤这几个，对齐 v1 客户端 agentOn）。
    var sessionsShown: [SessionItem] { (searchResults ?? sessions).filter { agentOn($0.tool) } }
    var activeShown: [ActiveSession] { active.filter { agentOn($0.tool) } }
    var doneShown: [DoneEvent] { done.filter { agentOn($0.tool) } }

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    /// 上次「成功强刷额度」的时刻——开面板智能强刷据此节流。
    private var lastForceAt: Date?
    /// 开面板强刷的过期阈值：超过该时长才真去打 Anthropic，否则用缓存。
    /// 把开面板看到的额度滞后从 quota_interval（可至 30 分钟）压到 ~3 分钟内，
    /// 又不至于每次开关都出站（频繁强刷易触发 429）。
    private let openForceStaleSecs: Double = 180

    private var refreshInterval: Double { Double(max(5, settings["refresh_interval"]?.intVal ?? 30)) }

    // MARK: 轮询
    public func start() {
        Task { await loadSettings() }
        Task { await loadTerminals() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let secs = self?.refreshInterval ?? 30
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
        }
    }
    public func stop() { pollTask?.cancel(); pollTask = nil }

    /// 开面板时调用：数据「够旧」才强刷额度（绕缓存打一次 Anthropic），否则走缓存即可。
    /// 强刷失败（daemon 出站异常）时 daemon 已回退到 last_good 陈旧数据、不会把卡片刷成
    /// 「获取失败」；只有真拿到新鲜数据才记 lastForceAt，失败则下次开面板照常再试。
    public func refreshOnOpen() async {
        let due = lastForceAt.map { Date().timeIntervalSince($0) > openForceStaleSecs } ?? true
        await refresh(force: due)
        if due && online { lastForceAt = Date() }
    }

    /// force=true 时给 /api/quota 带 ?force=1 绕过后端额度缓存、强制重采（对应 v1 手动刷新 refreshAll(true)）；
    /// 周期轮询用 false 走缓存，避免每轮都出站打 Anthropic。
    public func refresh(force: Bool = false) async {
        // 6 个接口并发拉取（旧实现串行 → 启动/手动刷新要等全部之和；quota 还出站打 Anthropic 最慢，
        // 串行时它把整屏都拖住）。APIClient 是 actor，并发 get 在各自 await 网络处挂起、互不阻塞。
        let needSessions = searchResults == nil
        async let quotaR:    QuotaResponse?    = try? await api.get("/api/quota", query: force ? ["force": "1"] : [:])
        async let usageR:    UsageResponse?    = try? await api.get("/api/usage")
        async let activeR:   ActiveResponse?   = try? await api.get("/api/active")
        async let eventsR:   EventsResponse?   = try? await api.get("/api/events", query: ["recent": "4"])
        async let sessionsR: SessionsResponse? = needSessions ? (try? await api.get("/api/sessions")) : nil
        async let updateR:   UpdateInfo?       = try? await api.get("/api/update")

        // 本地快接口先落地渲染（概览卡/会话即时出来），出站慢接口(quota/update)随后补上。
        if let u = await usageR { usage = u }
        if let a = await activeR { active = a.active }
        if let e = await eventsR {
            let cutoff = Date().timeIntervalSince1970 - 86400
            done = e.events.filter { $0.ts > cutoff }
        }
        if needSessions, let s = await sessionsR { sessions = s.sessions }
        if let q = await quotaR { quota = q; online = true } else { online = false }
        if let up = await updateR { update = up }
    }

    // MARK: 设置
    func loadSettings() async {
        // GET /api/settings 直接返回扁平设置字典（无 settings 包裹，与 v1 一致）；
        // POST 的应答才是 {ok, settings:{…}}。兼容两种形态，否则设置永远读不回 → 看似「开关不保存」。
        guard let raw = try? await api.getJSON("/api/settings") else { return }
        let dict = (raw["settings"] as? [String: Any]) ?? raw
        let kinds = SettingsSchema.valueKinds
        var out: [String: SettingValue] = [:]
        for (k, v) in dict {
            switch kinds[k] {
            case .bool:   out[k] = .bool((v as? NSNumber)?.boolValue ?? (v as? Bool ?? false))
            case .int:    out[k] = .int((v as? NSNumber)?.intValue ?? (v as? Int ?? 0))
            case .string: out[k] = .string(v as? String ?? "")
            case .none:
                if let s = v as? String { out[k] = .string(s) }
                else if let n = v as? NSNumber { out[k] = .int(n.intValue) }
            }
        }
        settings = out
        applyCustomColors()
        I18N.locale = I18N.resolve(settings["language"]?.stringVal ?? "auto")
    }

    func loadTerminals() async {
        if let r: TerminalsResponse = try? await api.get("/api/terminals") { terminals = r.terminals }
    }

    func setSetting(_ key: String, _ value: SettingValue) {
        settings[key] = value
        applyCustomColors()
        if key == "language" { I18N.locale = I18N.resolve(value.stringVal) }
        onSettingsChanged?()   // 即时刷新菜单栏（语言/常显用量/告警阈值等）
        Task {
            var body: [String: Any] = [:]
            switch value {
            case .bool(let b): body[key] = b
            case .int(let i): body[key] = i
            case .double(let d): body[key] = d
            case .string(let s): body[key] = s
            }
            _ = try? await api.postJSON("/api/settings", body: body)
        }
    }

    /// 恢复默认配色：单请求清两色（避免两次 setSetting 竞态），后端回填空串=用默认。
    func resetColors() {
        settings["color_claude"] = .string("")
        settings["color_codex"] = .string("")
        applyCustomColors()
        Task {
            _ = try? await api.postJSON("/api/settings", body: ["color_claude": "", "color_codex": ""])
            await loadSettings()
        }
    }

    /// 数据管理动作（打开目录 / 导出 CSV / 清空完成记录），对应 POST /api/data。
    @discardableResult
    func dataAction(_ action: String) async -> (ok: Bool, error: String?) {
        let r = try? await api.postJSON("/api/data", body: ["action": action])
        return ((r?["ok"] as? Bool) ?? false, r?["error"] as? String)
    }

    /// 自定义主色 → Brand 全局覆盖（额度环/进度条/用量图同步）。
    private func applyCustomColors() {
        Brand.customAccents[.claude] = Color(hexString: settings["color_claude"]?.stringVal ?? "")
        Brand.customAccents[.codex] = Color(hexString: settings["color_codex"]?.stringVal ?? "")
    }

    // MARK: 动作
    @discardableResult
    func resume(_ s: SessionItem) async -> ResumeResult? {
        try? await api.post("/api/resume", body: ["tool": s.tool, "id": s.id, "cwd": s.cwd ?? ""])
    }

    func pin(_ s: SessionItem) async {
        let session: [String: Any] = [
            "tool": s.tool, "id": s.id, "title": s.title ?? "", "cwd": s.cwd ?? "",
            "project": s.project ?? "", "branch": s.branch ?? "", "mtime": s.mtime,
            "account": s.account ?? "", "account_id": s.accountId ?? "",
        ]
        _ = try? await api.postJSON("/api/pin", body: ["pinned": !(s.pinned ?? false), "session": session])
        if let r: SessionsResponse = try? await api.get("/api/sessions") { sessions = r.sessions }
    }

    @discardableResult
    func focus(tool: String, id: String, cwd: String, pid: Int) async -> Bool {
        let r = try? await api.postJSON("/api/focus", body: ["tool": tool, "session": id, "cwd": cwd, "pid": pid])
        return (r?["ok"] as? Bool) ?? false
    }

    func preview(_ s: SessionItem) async -> [PreviewMsg] {
        let r: PreviewResponse? = try? await api.get("/api/preview", query: ["tool": s.tool, "id": s.id])
        return r?.messages ?? []
    }

    // MARK: 搜索（250ms debounce；服务端全量匹配）
    func search(_ q: String) {
        searchTask?.cancel()
        let query = q.trimmingCharacters(in: .whitespaces)
        if query.isEmpty { searchResults = nil; return }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            if let r: SessionsResponse = try? await self?.api.get("/api/sessions", query: ["q": query]) {
                self?.searchResults = r.sessions
            }
        }
    }

    func checkUpdate() async {
        update = try? await api.get("/api/update", query: ["force": "1"])
    }
}
