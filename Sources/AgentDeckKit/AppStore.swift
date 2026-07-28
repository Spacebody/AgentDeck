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

/// 合并一次设置 GET 的结果。GET 发起时仍未获 daemon 确认的本地修改必须保留，
/// 否则较慢的旧响应会让刚切换的 Agent 在界面上短暂反弹。
func mergeLoadedSettings(
    remote: [String: SettingValue],
    current: [String: SettingValue],
    pending: [String: SettingValue],
    mutationVersions: [String: Int],
    acknowledgedVersionsAtRequest: [String: Int]
) -> [String: SettingValue] {
    var merged = remote
    for (key, version) in mutationVersions
    where version > (acknowledgedVersionsAtRequest[key] ?? 0) {
        if let value = current[key] { merged[key] = value }
    }
    for (key, value) in pending { merged[key] = value }
    return merged
}

/// 连续保存失败后，只为失败批次之外的新修改重新启动保存任务；原批次保留到下次
/// 用户操作再重试，避免网络持续异常时形成无界重试循环。
func hasUnattemptedSettingChanges(
    pending: [String: SettingValue],
    mutationVersions: [String: Int],
    attemptedVersions: [String: Int]
) -> Bool {
    pending.keys.contains { key in
        guard let attempted = attemptedVersions[key] else { return true }
        return (mutationVersions[key] ?? 0) > attempted
    }
}

/// Serializes quota snapshots arriving from ordinary requests and the daemon's push channel.
/// Push snapshots cover failures from requests already in flight, but a matching-revision
/// ordinary response may still be more complete (for example, freshly fetched Claude quota).
struct QuotaSnapshotGate {
    private(set) var bootId = ""
    private(set) var revision = 0
    private var nextRequest = 0
    private var pushCoveredThroughRequest = 0
    private var lastAppliedRequest = 0

    mutating func beginRequest() -> Int {
        nextRequest += 1
        return nextRequest
    }

    func canReportFailure(for request: Int) -> Bool {
        request > pushCoveredThroughRequest
            && request >= lastAppliedRequest
            && request == nextRequest
    }

    mutating func accept(
        bootId incomingBoot: String?,
        revision incomingRevision: Int?,
        request: Int?
    ) -> Bool {
        let incomingBoot = incomingBoot ?? ""
        let incomingRevision = incomingRevision ?? 0

        let sameBoot = !incomingBoot.isEmpty && incomingBoot == bootId
        if sameBoot {
            if incomingRevision < revision { return false }
            if request == nil, incomingRevision == revision { return false }
        }
        if let request, request < lastAppliedRequest {
            // A slower request may still carry a newer daemon snapshot. Request order
            // only breaks ties; revision order remains authoritative within one boot.
            guard sameBoot && incomingRevision > revision else { return false }
        }

        if let request {
            lastAppliedRequest = max(lastAppliedRequest, request)
        } else {
            pushCoveredThroughRequest = nextRequest
        }
        if !incomingBoot.isEmpty {
            if incomingBoot != bootId {
                bootId = incomingBoot
                revision = incomingRevision
            } else {
                revision = max(revision, incomingRevision)
            }
        }
        return true
    }
}

@MainActor
public final class AppStore: ObservableObject {
    // 仅初始化默认值，无需主线程隔离 → nonisolated，便于主壳在属性声明处直接构造。
    public nonisolated init() {}

    /// 设置变更后回调（主壳据此即时重绘菜单栏图标，等价 v1 的 "sync" 桥消息）。
    public var onSettingsChanged: (() -> Void)?
    /// daemon 额度 revision 变化后回调；主壳据此即时重绘菜单栏，不等 20s 兜底轮询。
    public var onQuotaChanged: (() -> Void)?

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
    @Published var sessionPage = 1
    @Published var sessionPageSize = 20
    @Published var sessionsLoading = false
    @Published var sessionsIndexing = false
    @Published var sessionsLoadFailed = false
    @Published var online = true                   // 后端健康（驱动顶栏 live 点）

    @Published var terminals: [TerminalOption] = []   // /api/terminals 已安装终端（恢复方式选项）

    var today: TodaySummary? { usage.flatMap { TodaySummary(from: $0) } }
    var updateAvailable: Bool { update?.available == true }

    /// 该 agent 是否展示。设置一旦到达客户端便是前端唯一真值；设置尚未加载时才回退
    /// `/api/quota.hidden`，避免启动瞬间闪出用户已隐藏的 Agent。
    func agentOn(_ tool: String, fallbackHidden: Bool? = nil) -> Bool {
        if let configured = settings["show_\(tool.lowercased())"] { return configured.boolVal }
        return !(fallbackHidden ?? false)
    }
    var showActive: Bool { settings["show_active"]?.boolVal ?? true }

    // 列表按 show_claude/show_codex 过滤（daemon 不过滤这几个，对齐 v1 客户端 agentOn）。
    var sessionsShown: [SessionItem] { sessions.filter { agentOnWithQuotaFallback($0.tool) } }
    var activeShown: [ActiveSession] { active.filter { agentOnWithQuotaFallback($0.tool) } }
    var doneShown: [DoneEvent] { done.filter { agentOnWithQuotaFallback($0.tool) } }

    private let api = APIClient.shared
    private var pollTask: Task<Void, Never>?
    private var quotaWatchTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var sessionIndexRetryTask: Task<Void, Never>?
    private var sessionNextCursor: String?
    private var sessionPageCursors: [String?] = [nil]
    private var sessionRequestGeneration = 0
    private var pendingSettingValues: [String: SettingValue] = [:]
    private var settingsSaveTask: Task<Void, Never>?
    private var agentVisibilityRefreshTask: Task<Void, Never>?
    private var settingsMutationVersion = 0
    private var settingMutationVersions: [String: Int] = [:]
    private var acknowledgedSettingVersions: [String: Int] = [:]
    private var quotaGate = QuotaSnapshotGate()

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
        quotaWatchTask?.cancel()
        quotaWatchTask = Task { [weak self] in
            await self?.watchQuotaChanges()
        }
    }
    public func stop() {
        pollTask?.cancel(); pollTask = nil
        quotaWatchTask?.cancel(); quotaWatchTask = nil
        searchTask?.cancel(); searchTask = nil
        sessionIndexRetryTask?.cancel(); sessionIndexRetryTask = nil
        agentVisibilityRefreshTask?.cancel(); agentVisibilityRefreshTask = nil
    }

    /// 开面板立即读取 daemon 快照；Codex 超过 30s 未经官方校准时只在后台发起校准，
    /// 返回路径不等待出站。Claude 仍走原缓存，避免开窗动作消耗其限流严格的 usage 接口。
    public func refreshOnOpen() async { await refresh(freshCodex: true) }

    /// force=true 时给 /api/quota 带 ?force=1 绕过后端额度缓存、强制重采（对应 v1 手动刷新 refreshAll(true)）；
    /// 周期轮询用 false 走缓存，避免每轮都出站打 Anthropic。
    public func refresh(force: Bool = false, freshCodex: Bool = false) async {
        // 6 个接口并发拉取（旧实现串行 → 启动/手动刷新要等全部之和；quota 还出站打 Anthropic 最慢，
        // 串行时它把整屏都拖住）。APIClient 是 actor，并发 get 在各自 await 网络处挂起、互不阻塞。
        // 只在默认列表仍处于第一页时参与周期刷新；用户翻到后页时不把当前页
        // 突然替换回第一页。搜索由独立 generation 管理，轮询绝不覆盖搜索结果。
        let sessionGeneration = sessionRequestGeneration
        let needSessions = sessionQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && sessionPage == 1 && !sessionsLoading
        let sessionParams = sessionRequestParams(cursor: nil)
        let quotaQuery: [String: String] = {
            var query: [String: String] = [:]
            if force { query["force"] = "1" }
            if freshCodex { query["fresh_codex"] = "1" }
            return query
        }()
        let quotaRequest = quotaGate.beginRequest()
        async let quotaR:    QuotaResponse?    = try? await api.get("/api/quota", query: quotaQuery)
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
           sessionPage == 1, !sessionsLoading {
            applySessionPage(
                s, targetPage: 1, requestedCursor: nil,
                resetHistory: true, generation: sessionGeneration)
        }
        let (q, up) = await (quotaR, updateR)
        if let q {
            applyQuota(q, request: quotaRequest)
        } else if quotaGate.canReportFailure(for: quotaRequest) {
            online = false
        }
        if let up { update = up }
    }

    /// 单一长轮询连接接收额度 revision。服务端 25s 心跳、客户端 35s 超时；
    /// 无变化时不发布 ObservableObject 更新，daemon 重启则用 bootId 立即重建游标。
    private func watchQuotaChanges() async {
        var retryNanos: UInt64 = 500_000_000
        while !Task.isCancelled {
            do {
                let response: QuotaChangesResponse = try await api.get(
                    "/api/quota/changes",
                    query: [
                        "after": String(quotaGate.revision),
                        "boot": quotaGate.bootId,
                        "timeout": "25",
                    ])
                guard !Task.isCancelled else { return }
                online = true
                _ = applyQuota(
                    response.quota,
                    bootId: response.bootId,
                    revision: response.revision,
                    request: nil)
                retryNanos = 500_000_000
            } catch {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: retryNanos)
                retryNanos = min(retryNanos * 2, 5_000_000_000)
            }
        }
    }

    @discardableResult
    private func applyQuota(
        _ response: QuotaResponse,
        bootId: String? = nil,
        revision: Int? = nil,
        request: Int?
    ) -> Bool {
        guard quotaGate.accept(
            bootId: bootId ?? response.quotaBootId,
            revision: revision ?? response.quotaRevision,
            request: request) else { return false }
        quota = response
        online = true
        onQuotaChanged?()
        return true
    }

    // MARK: 设置
    func loadSettings() async {
        let acknowledgementsAtRequest = acknowledgedSettingVersions
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
        settings = mergeLoadedSettings(
            remote: out,
            current: settings,
            pending: pendingSettingValues,
            mutationVersions: settingMutationVersions,
            acknowledgedVersionsAtRequest: acknowledgementsAtRequest)
        applyCustomColors()
        I18N.locale = I18N.resolve(settings["language"]?.stringVal ?? "auto")
        let loadedPageSize = min(100, max(5, settings["sessions_limit"]?.intVal ?? 20))
        if loadedPageSize != sessionPageSize {
            sessionPageSize = loadedPageSize
            sessionRequestGeneration += 1
            let generation = sessionRequestGeneration
            searchTask?.cancel()
            sessionIndexRetryTask?.cancel()
            invalidateSessionNavigation()
            searchTask = Task { [weak self] in
                await self?.loadSessionPage(reset: true, generation: generation)
            }
        }
    }

    func loadTerminals() async {
        if let r: TerminalsResponse = try? await api.get("/api/terminals") { terminals = r.terminals }
    }

    func setSetting(_ key: String, _ value: SettingValue) {
        stageSetting(key, value)
        if key == "sessions_limit" {
            sessionPageSize = min(100, max(5, value.intVal))
        }
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
            invalidateSessionNavigation()
            searchTask = Task { [weak self] in
                await self?.loadSessionPage(reset: true, generation: generation)
            }
        }
    }

    /// 恢复默认配色：单请求清两色（避免两次 setSetting 竞态），后端回填空串=用默认。
    func resetColors() {
        stageSetting("color_claude", .string(""))
        stageSetting("color_codex", .string(""))
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
                stageSetting(settingKey, value)
            }
        }
    }

    private func stageSetting(_ key: String, _ value: SettingValue) {
        settingsMutationVersion += 1
        settingMutationVersions[key] = settingsMutationVersion
        settings[key] = value
        pendingSettingValues[key] = value
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
                let snapshotVersions = snapshot.reduce(into: [String: Int]()) { versions, item in
                    versions[item.key] = self.settingMutationVersions[item.key] ?? 0
                }
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
                    for (key, value) in snapshot {
                        let version = snapshotVersions[key] ?? 0
                        self.acknowledgedSettingVersions[key] = max(
                            self.acknowledgedSettingVersions[key] ?? 0, version)
                        if self.pendingSettingValues[key] == value,
                           self.settingMutationVersions[key] == version {
                            self.pendingSettingValues.removeValue(forKey: key)
                        }
                    }
                    self.refreshQuotaAfterAgentVisibilityChange(in: snapshot)
                } catch {
                    consecutiveFailures += 1
                    if consecutiveFailures < 3 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    await self.loadSettings()
                    self.onSettingsChanged?()
                    let shouldRetryNewChanges = hasUnattemptedSettingChanges(
                        pending: self.pendingSettingValues,
                        mutationVersions: self.settingMutationVersions,
                        attemptedVersions: snapshotVersions)
                    self.settingsSaveTask = nil
                    if shouldRetryNewChanges { self.scheduleSettingsSave() }
                    return
                }
            }
            self.settingsSaveTask = nil
        }
    }

    /// Agent 可见性已被 daemon 接收后重读一次额度缓存。后到的切换覆盖前一次刷新，
    /// 但刷新始终覆盖当前所有可见 Agent，不会因另一个 Agent 的开关而漏掉刚启用的数据。
    private func refreshQuotaAfterAgentVisibilityChange(in saved: [String: SettingValue]) {
        guard saved.keys.contains(where: { $0 == "show_claude" || $0 == "show_codex" }) else { return }
        agentVisibilityRefreshTask?.cancel()
        agentVisibilityRefreshTask = nil
        guard agentOn("claude") || agentOn("codex") else { return }
        agentVisibilityRefreshTask = Task { [weak self] in
            guard let self else { return }
            let quotaRequest = self.quotaGate.beginRequest()
            let refreshed: QuotaResponse? = try? await self.api.get("/api/quota")
            guard !Task.isCancelled else { return }
            if let refreshed {
                self.applyQuota(refreshed, request: quotaRequest)
            }
            self.agentVisibilityRefreshTask = nil
        }
    }

    private func agentOnWithQuotaFallback(_ tool: String) -> Bool {
        let hidden: Bool?
        switch tool.lowercased() {
        case "claude": hidden = quota?.claude?.hidden
        case "codex": hidden = quota?.codex?.hidden
        default: hidden = nil
        }
        return agentOn(tool, fallbackHidden: hidden)
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
    func resume(_ s: SessionItem, copyOnly: Bool = false,
                replacementCwd: String? = nil) async -> ResumeResult? {
        let request = SessionResumeRequest(
            tool: s.tool, id: s.id, cwd: s.cwd ?? "",
            accountId: s.accountId, copyOnly: copyOnly,
            replacementCwd: replacementCwd)
        return try? await api.post("/api/resume", body: request)
    }

    func setPathMapping(originalCwd: String, replacementCwd: String) async -> Bool {
        let response = try? await api.postJSON("/api/path-mapping", body: [
            "action": "set", "original_cwd": originalCwd,
            "replacement_cwd": replacementCwd,
        ])
        return response?["ok"] as? Bool == true
    }

    func removePathMapping(originalCwd: String) async -> Bool {
        let response = try? await api.postJSON("/api/path-mapping", body: [
            "action": "remove", "original_cwd": originalCwd,
        ])
        return response?["ok"] as? Bool == true
    }

    func pin(_ s: SessionItem) async {
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        searchTask?.cancel()
        sessionIndexRetryTask?.cancel()
        invalidateSessionNavigation()
        let session: [String: Any] = [
            "tool": s.tool, "id": s.id, "title": s.title ?? "", "cwd": s.cwd ?? "",
            "project": s.project ?? "", "branch": s.branch ?? "", "mtime": s.mtime,
            "account": s.account ?? "", "account_id": s.accountId ?? "",
        ]
        _ = try? await api.postJSON("/api/pin", body: ["pinned": !(s.pinned ?? false), "session": session])
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
        invalidateSessionNavigation()
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
        invalidateSessionNavigation()
        searchTask = Task { [weak self] in
            await self?.loadSessionPage(reset: true, generation: generation)
        }
    }

    func nextSessionPage() {
        guard sessionsHasMore, !sessionsLoading, let cursor = sessionNextCursor else { return }
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        let targetPage = sessionPage + 1
        Task { [weak self] in
            await self?.loadSessionPage(
                cursor: cursor, targetPage: targetPage,
                resetHistory: false, generation: generation)
        }
    }

    func previousSessionPage() {
        guard sessionPage > 1, !sessionsLoading,
              sessionPage - 2 < sessionPageCursors.count else { return }
        sessionRequestGeneration += 1
        let generation = sessionRequestGeneration
        let targetPage = sessionPage - 1
        let cursor = sessionPageCursors[targetPage - 1]
        Task { [weak self] in
            await self?.loadSessionPage(
                cursor: cursor, targetPage: targetPage,
                resetHistory: false, generation: generation)
        }
    }

    func setSessionPageSize(_ size: Int) {
        let normalized = min(100, max(5, size))
        guard normalized != sessionPageSize else { return }
        setSetting("sessions_limit", .int(normalized))
    }

    var sessionPageCount: Int {
        max(1, Int(ceil(Double(sessionsTotal) / Double(max(1, sessionPageSize)))))
    }

    private func invalidateSessionNavigation() {
        sessionPage = 1
        sessionsHasMore = false
        sessionNextCursor = nil
        sessionPageCursors = [nil]
        sessionsLoading = true
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
        params["limit"] = String(sessionPageSize)
        if let cursor, !cursor.isEmpty { params["cursor"] = cursor }
        return params
    }

    private func loadSessionPage(reset: Bool, generation: Int) async {
        await loadSessionPage(
            cursor: nil, targetPage: 1,
            resetHistory: reset, generation: generation)
    }

    private func loadSessionPage(
        cursor: String?, targetPage: Int,
        resetHistory: Bool, generation: Int
    ) async {
        guard generation == sessionRequestGeneration else { return }
        if sessionFilter == "all" && !agentOn("claude") && !agentOn("codex") {
            sessions = []; sessionsTotal = 0; sessionsHasMore = false
            sessionsLoading = false; sessionsIndexing = false; sessionsLoadFailed = false
            sessionNextCursor = nil; sessionPageCursors = [nil]; sessionPage = 1
            return
        }
        sessionsLoading = true
        sessionsLoadFailed = false
        do {
            let response: SessionsResponse = try await api.get(
                "/api/sessions", query: sessionRequestParams(cursor: cursor))
            guard generation == sessionRequestGeneration, !Task.isCancelled else { return }
            let cursorStale = response.cursorStale ?? false
            applySessionPage(
                response, targetPage: cursorStale ? 1 : targetPage,
                requestedCursor: cursorStale ? nil : cursor,
                resetHistory: resetHistory || cursorStale, generation: generation)
        } catch {
            guard generation == sessionRequestGeneration, !Task.isCancelled else { return }
            sessionsLoading = false
            sessionsLoadFailed = true
        }
    }

    private func applySessionPage(
        _ response: SessionsResponse, targetPage: Int,
        requestedCursor: String?, resetHistory: Bool, generation: Int
    ) {
        guard generation == sessionRequestGeneration else { return }
        sessions = response.sessions
        if resetHistory {
            sessionPageCursors = [nil]
        } else if targetPage > sessionPage {
            sessionPageCursors = Array(sessionPageCursors.prefix(targetPage - 1))
            sessionPageCursors.append(requestedCursor)
        }
        sessionPage = targetPage
        sessionsTotal = response.total ?? sessions.count
        sessionsHasMore = response.hasMore ?? false
        sessionNextCursor = response.nextCursor
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
