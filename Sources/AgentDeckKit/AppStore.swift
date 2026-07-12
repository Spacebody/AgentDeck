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

struct UpdateInstallStatus: Decodable {
    let ok: Bool?
    let running: Bool?
    let id: String?
    let stage: String?
    let progress: Double?
    let version: String?
    let error: String?
    let message: String?
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
    @Published var updateInstall: UpdateInstallStatus?
    @Published var sessionQuery = ""
    @Published var sessionFilter = "all"
    @Published var sessionsTotal = 0
    @Published var sessionsHasMore = false
    @Published var sessionsLoading = false
    @Published var sessionsIndexing = false
    @Published var sessionsLoadFailed = false
    @Published var online = true                   // 后端健康（驱动顶栏 live 点）

    @Published var terminals: [TerminalOption] = []   // /api/terminals 已安装终端（恢复方式选项）

    var today: TodaySummary? { usage.flatMap { TodaySummary(from: $0) } }
    var updateAvailable: Bool { update?.available == true }

    /// 该 agent 是否展示（设置 show_claude/show_codex；默认 true，对应 v1 agentOn）。
    func agentOn(_ tool: String) -> Bool { settings["show_\(tool)"]?.boolVal ?? true }
    var showActive: Bool { settings["show_active"]?.boolVal ?? true }

    // 列表按 show_claude/show_codex 过滤（daemon 不过滤这几个，对齐 v1 客户端 agentOn）。
    var sessionsShown: [SessionItem] { sessions.filter { agentOn($0.tool) } }
    var activeShown: [ActiveSession] { active.filter { agentOn($0.tool) } }
    var doneShown: [DoneEvent] { done.filter { agentOn($0.tool) } }

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionIndexRetryTask: Task<Void, Never>?
    private var sessionCursor: String?
    private var sessionRequestGeneration = 0
    private var sessionPageCount = 0
    private var pendingSettingValues: [String: SettingValue] = [:]
    private var settingsSaveTask: Task<Void, Never>?

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
    public func stop() {
        pollTask?.cancel(); pollTask = nil
        searchTask?.cancel(); searchTask = nil
        sessionIndexRetryTask?.cancel(); sessionIndexRetryTask = nil
    }

    /// 开面板时调用：只走缓存做一次「即时同步」，不强刷。
    /// 关键——菜单栏图标(main.swift)与面板读的是 daemon 同一份额度缓存（key=claude_quota/codex_quota，
    /// TTL=quota_interval）。面板若在开窗时强刷(force)，会去打 Anthropic：①期间面板仍显示上一轮旧值、
    /// 要等数秒出站返回才更新（"打开面板还没更新"）；②强刷拿到的新鲜值会高于菜单栏的缓存值，两者数字对不上
    /// （"没保持一致节奏"）；③还会吃掉 daemon 的 10s 防连点闸，紧接着点🔄手动刷新被去重而"刷了没反应"。
    /// 故开窗只做本地快刷（<50ms 读缓存）即与菜单栏对齐；要拿实时最新值由用户点🔄(force)显式触发。
    public func refreshOnOpen() async { await refresh() }

    /// force=true 时给 /api/quota 带 ?force=1 绕过后端额度缓存、强制重采（对应 v1 手动刷新 refreshAll(true)）；
    /// 周期轮询用 false 走缓存，避免每轮都出站打 Anthropic。
    public func refresh(force: Bool = false) async {
        // 6 个接口并发拉取（旧实现串行 → 启动/手动刷新要等全部之和；quota 还出站打 Anthropic 最慢，
        // 串行时它把整屏都拖住）。APIClient 是 actor，并发 get 在各自 await 网络处挂起、互不阻塞。
        // 只在默认列表仍处于第一页时参与周期刷新；用户已加载更多时不把长列表
        // 突然替换回第一页。搜索由独立 generation 管理，轮询绝不覆盖搜索结果。
        let sessionGeneration = sessionRequestGeneration
        let needSessions = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sessionPageCount <= 1 && !sessionsLoading
        let sessionParams = sessionRequestParams(cursor: nil)
        async let quotaR:    QuotaResponse?    = try? await api.get("/api/quota", query: force ? ["force": "1"] : [:])
        async let usageR:    UsageResponse?    = try? await api.get("/api/usage")
        async let activeR:   ActiveResponse?   = try? await api.get("/api/active")
        async let eventsR:   EventsResponse?   = try? await api.get("/api/events", query: ["recent": "4"])
        async let sessionsR: SessionsResponse? = needSessions
            ? (try? await api.get("/api/sessions", query: sessionParams)) : nil
        async let updateR:   UpdateInfo?       = try? await api.get("/api/update")

        // 本地快接口合成一批后同步落地，ObservableObjectPublisher 可在同一主线程周期
        // 合并视图失效；出站较慢的 quota/update 再作为第二批补上。
        let (u, a, e, s) = await (usageR, activeR, eventsR, sessionsR)
        if let u { usage = u }
        if let a { active = a.active }
        if let e {
            let cutoff = Date().timeIntervalSince1970 - 86400
            done = e.events.filter { $0.ts > cutoff }
        }
        if needSessions, let s,
           sessionGeneration == sessionRequestGeneration,
           sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           sessionPageCount <= 1, !sessionsLoading {
            applySessionPage(s, reset: true, generation: sessionGeneration)
        }
        let (q, up) = await (quotaR, updateR)
        if let q { quota = q; online = true } else { online = false }
        if let up { update = up }
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
        pendingSettingValues[key] = value
        normalizeNotificationThresholds(changed: key)
        applyCustomColors()
        if key == "language" { I18N.locale = I18N.resolve(value.stringVal) }
        onSettingsChanged?()   // 即时刷新菜单栏（语言/常显用量/告警阈值等）
        scheduleSettingsSave()
        if key == "show_claude" || key == "show_codex" || key == "sessions_limit" {
            sessionRequestGeneration += 1
            let generation = sessionRequestGeneration
            searchTask?.cancel()
            sessionIndexRetryTask?.cancel()
            searchTask = Task { [weak self] in
                await self?.loadSessionPage(reset: true, generation: generation)
            }
        }
    }

    /// 恢复默认配色：单请求清两色（避免两次 setSetting 竞态），后端回填空串=用默认。
    func resetColors() {
        settings["color_claude"] = .string("")
        settings["color_codex"] = .string("")
        pendingSettingValues["color_claude"] = .string("")
        pendingSettingValues["color_codex"] = .string("")
        applyCustomColors()
        onSettingsChanged?()
        scheduleSettingsSave()
    }

    private func normalizeNotificationThresholds(changed key: String) {
        guard key == "notify_warn" || key == "notify_crit" else { return }
        var warn = min(max(settings["notify_warn"]?.intVal ?? 80, 50), 99)
        var crit = min(max(settings["notify_crit"]?.intVal ?? 95, 60), 100)
        if warn >= crit {
            if key == "notify_crit" { warn = max(50, crit - 1) }
            else { crit = min(100, warn + 1) }
        }
        for (settingKey, normalized) in [("notify_warn", warn), ("notify_crit", crit)] {
            let value = SettingValue.int(normalized)
            if settings[settingKey] != value {
                settings[settingKey] = value
                pendingSettingValues[settingKey] = value
            }
        }
    }

    private func scheduleSettingsSave() {
        guard settingsSaveTask == nil else { return }
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            if Task.isCancelled {
                self.settingsSaveTask = nil
                return
            }
            var consecutiveFailures = 0
            while !self.pendingSettingValues.isEmpty {
                let snapshot = self.pendingSettingValues
                self.pendingSettingValues.removeAll()
                var body: [String: Any] = [:]
                for (key, value) in snapshot {
                    switch value {
                    case .bool(let b): body[key] = b
                    case .int(let i): body[key] = i
                    case .double(let d): body[key] = d
                    case .string(let s): body[key] = s
                    }
                }
                do {
                    _ = try await self.api.postJSON("/api/settings", body: body)
                    consecutiveFailures = 0
                } catch {
                    // 不覆盖失败期间产生的更新值；旧批次只补回仍无更新的键。
                    for (key, value) in snapshot where self.pendingSettingValues[key] == nil {
                        self.pendingSettingValues[key] = value
                    }
                    consecutiveFailures += 1
                    if consecutiveFailures < 3 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    let stillPending = self.pendingSettingValues
                    await self.loadSettings()
                    for (key, value) in stillPending { self.settings[key] = value }
                    self.applyCustomColors()
                    if let language = stillPending["language"]?.stringVal {
                        I18N.locale = I18N.resolve(language)
                    }
                    self.onSettingsChanged?()
                    self.settingsSaveTask = nil
                    return
                }
            }
            self.settingsSaveTask = nil
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
    func resume(_ s: SessionItem, copyOnly: Bool = false) async -> ResumeResult? {
        let request = SessionResumeRequest(
            tool: s.tool, id: s.id, cwd: s.cwd ?? "",
            accountId: s.accountId, copyOnly: copyOnly)
        return try? await api.post("/api/resume", body: request)
    }

    func pin(_ s: SessionItem) async {
        let session: [String: Any] = [
            "tool": s.tool, "id": s.id, "title": s.title ?? "", "cwd": s.cwd ?? "",
            "project": s.project ?? "", "branch": s.branch ?? "", "mtime": s.mtime,
            "account": s.account ?? "", "account_id": s.accountId ?? "",
        ]
        _ = try? await api.postJSON("/api/pin", body: ["pinned": !(s.pinned ?? false), "session": session])
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        searchTask?.cancel()
        await loadSessionPage(reset: true, generation: generation)
    }

    @discardableResult
    func focus(tool: String, id: String, cwd: String, pid: Int) async -> Bool {
        let r = try? await api.postJSON("/api/focus", body: ["tool": tool, "session": id, "cwd": cwd, "pid": pid])
        return (r?["ok"] as? Bool) ?? false
    }

    func preview(_ s: SessionItem) async -> [PreviewMsg] {
        var query = ["tool": s.tool, "id": s.id]
        if let accountId = s.accountId, !accountId.isEmpty { query["account_id"] = accountId }
        let r: PreviewResponse? = try? await api.get("/api/preview", query: query)
        return r?.messages ?? []
    }

    // MARK: 会话索引 / 搜索 / 分页
    func search(_ q: String) {
        sessionQuery = q
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        searchTask?.cancel()
        sessionIndexRetryTask?.cancel()
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchTask = Task { [weak self] in
                await self?.loadSessionPage(reset: true, generation: generation)
            }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await self?.loadSessionPage(reset: true, generation: generation)
        }
    }

    func setSessionFilter(_ filter: String) {
        let normalized = ["all", "claude", "codex"].contains(filter) ? filter : "all"
        guard normalized != sessionFilter else { return }
        sessionFilter = normalized
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        searchTask?.cancel()
        sessionIndexRetryTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.loadSessionPage(reset: true, generation: generation)
        }
    }

    func loadMoreSessions() {
        guard sessionsHasMore, !sessionsLoading, sessionCursor != nil else { return }
        sessionsLoading = true
        let generation = sessionRequestGeneration
        Task { [weak self] in
            await self?.loadSessionPage(reset: false, generation: generation)
        }
    }

    private func sessionRequestParams(cursor: String?) -> [String: String] {
        var params: [String: String] = [:]
        let query = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { params["q"] = query }
        var effectiveTool = "all"
        if sessionFilter != "all" {
            effectiveTool = sessionFilter
        } else {
            let claude = agentOn("claude"), codex = agentOn("codex")
            if claude != codex { effectiveTool = claude ? "claude" : "codex" }
        }
        if effectiveTool != "all" { params["tool"] = effectiveTool }
        let perTool = min(100, max(5, settings["sessions_limit"]?.intVal ?? 15))
        params["limit"] = String(perTool * (effectiveTool == "all" ? 2 : 1))
        if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
        return params
    }

    private func loadSessionPage(reset: Bool, generation: Int) async {
        guard generation == sessionRequestGeneration else { return }
        if sessionFilter == "all" && !agentOn("claude") && !agentOn("codex") {
            sessions = []; sessionsTotal = 0; sessionsHasMore = false
            sessionsLoading = false; sessionsIndexing = false; sessionsLoadFailed = false
            sessionCursor = nil; sessionPageCount = 1
            return
        }
        sessionsLoading = true
        sessionsLoadFailed = false
        let cursor = reset ? nil : sessionCursor
        do {
            let response: SessionsResponse = try await api.get(
                "/api/sessions", query: sessionRequestParams(cursor: cursor))
            guard generation == sessionRequestGeneration, !Task.isCancelled else { return }
            applySessionPage(response, reset: reset, generation: generation)
        } catch {
            guard generation == sessionRequestGeneration, !Task.isCancelled else { return }
            sessionsLoading = false
            sessionsLoadFailed = true
        }
    }

    private func applySessionPage(_ response: SessionsResponse, reset: Bool, generation: Int) {
        guard generation == sessionRequestGeneration else { return }
        if reset {
            sessions = response.sessions
            sessionPageCount = 1
        } else {
            var seen = Set(sessions.map(\.rowKey))
            for session in response.sessions where seen.insert(session.rowKey).inserted {
                sessions.append(session)
            }
            sessionPageCount += 1
        }
        sessionsTotal = response.total ?? sessions.count
        sessionsHasMore = response.hasMore ?? false
        sessionCursor = response.nextCursor
        sessionsIndexing = response.indexing ?? false
        sessionsLoading = false
        sessionsLoadFailed = response.indexError != nil
        scheduleSessionIndexRetry(generation: generation)
    }

    private func scheduleSessionIndexRetry(generation: Int) {
        sessionIndexRetryTask?.cancel()
        guard sessionsIndexing else { sessionIndexRetryTask = nil; return }
        sessionIndexRetryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self,
                  generation == self.sessionRequestGeneration else { return }
            await self.loadSessionPage(reset: true, generation: generation)
        }
    }

    func checkUpdate() async {
        update = try? await api.get("/api/update", query: ["force": "1"])
    }

    func startUpdateInstall() async {
        guard let up = update else { return }
        let body: [String: Any] = [
            "version": up.latest ?? "",
        ]
        do {
            let raw = try await api.postJSON("/api/update/install", body: body)
            updateInstall = Self.updateInstallStatus(raw)
        } catch {
            updateInstall = UpdateInstallStatus(ok: false, running: false, id: nil, stage: "error",
                                                progress: 0, version: up.latest, error: "\(error)",
                                                message: "error")
            return
        }
        await pollUpdateInstall()
    }

    func pollUpdateInstall() async {
        var transientFailures = 0
        for _ in 0..<1200 {
            guard let raw = try? await api.getJSON("/api/update/install") else {
                transientFailures += 1
                if transientFailures >= 10 {
                    let current = updateInstall
                    updateInstall = UpdateInstallStatus(
                        ok: false, running: false, id: current?.id, stage: "error",
                        progress: current?.progress, version: current?.version,
                        error: "Lost connection to update service", message: "error")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            transientFailures = 0
            let st = Self.updateInstallStatus(raw)
            updateInstall = st
            if st.running != true { return }
            if st.stage == "installing" { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let current = updateInstall
        updateInstall = UpdateInstallStatus(
            ok: false, running: false, id: current?.id, stage: "error",
            progress: current?.progress, version: current?.version,
            error: "Update timed out", message: "error")
    }

    private static func updateInstallStatus(_ raw: [String: Any]) -> UpdateInstallStatus {
        UpdateInstallStatus(
            ok: raw["ok"] as? Bool,
            running: raw["running"] as? Bool,
            id: raw["id"] as? String,
            stage: raw["stage"] as? String,
            progress: (raw["progress"] as? NSNumber)?.doubleValue ?? raw["progress"] as? Double,
            version: raw["version"] as? String,
            error: raw["error"] as? String,
            message: raw["message"] as? String)
    }
}
