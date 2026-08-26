// AgentDeck v2 — 概览页。里程碑阶段先实现额度卡区（核心质感）；
// 今日条 / 活跃会话 / 完成事件 / 用量图表在 #5、#6 接入。
import SwiftUI

/// 双 Agent 额度行：先以相同列宽测量两侧当前页，再把较高值作为共同高度。
/// 使用 Layout 避免 PreferenceKey 的首帧跳动，也能随 carousel 当前页即时重排。
struct EqualHeightQuotaRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                     cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let totalWidth: CGFloat
        if let proposedWidth = proposal.width {
            totalWidth = proposedWidth
        } else {
            let idealWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            totalWidth = idealWidth * CGFloat(subviews.count) + gaps
        }
        let columnWidth = max(0, (totalWidth - gaps) / CGFloat(subviews.count))
        let height = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }.max() ?? 0
        return CGSize(width: totalWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let gaps = spacing * CGFloat(max(0, subviews.count - 1))
        let columnWidth = max(0, (bounds.width - gaps) / CGFloat(subviews.count))
        var x = bounds.minX
        for subview in subviews {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: columnWidth, height: bounds.height))
            x += columnWidth + spacing
        }
    }
}

struct OverviewView: View {
    let quota: QuotaResponse?
    var usage: UsageResponse? = nil
    var today: TodaySummary? = nil
    var active: [ActiveSession] = []
    var done: [DoneEvent] = []
    var showActive: Bool = true
    /// nil 时回退 quota.hidden（仅预览/设置尚未加载）；真实根视图传入本地设置值。
    var showClaudeAgent: Bool? = nil
    var showCodexAgent: Bool? = nil
    var showQoderAgent: Bool? = nil
    var showQoderCNAgent: Bool? = nil
    var quotaAutoRotate: Bool = true
    var quotaRotateSecs: Int = 6
    var carouselActive: Bool = true
    var quotaSelectionID: String? = nil
    var onSelectQuota: (String) -> Void = { _ in }
    var onQuotaRotationPauseChange: (Bool) -> Void = { _ in }
    var onFocusActive: (ActiveSession) -> Void = { _ in }
    var onFocusDone: (DoneEvent) -> Void = { _ in }

    var body: some View {
        // 入场错峰淡入上滑，延时逐一对齐 v1 各卡 animation-delay。
        VStack(spacing: 10) {
            quotaSection.reveal(delay: 0.05)
            if let today { TodayBar(summary: today).reveal(delay: 0.06) }
            if showActive { ActiveCard(sessions: active, onTap: onFocusActive).reveal(delay: 0.09) }
            DoneCard(events: done, onTap: onFocusDone).reveal(delay: 0.10)
            UsageView(usage: usage, showClaude: showClaude,
                      showCodex: showCodex, showQoder: showQoder).reveal(delay: 0.12)
        }
        .animation(.easeInOut(duration: 0.18), value: showClaude)
        .animation(.easeInOut(duration: 0.18), value: showCodex)
        .animation(.easeInOut(duration: 0.18), value: showQoder)
        .animation(.easeInOut(duration: 0.18), value: showQoderCN)
    }

    private var showClaude: Bool {
        showClaudeAgent ?? !(quota?.claude?.hidden ?? false)
    }

    private var showCodex: Bool {
        showCodexAgent ?? !(quota?.codex?.hidden ?? false)
    }

    private var showQoder: Bool {
        showQoderAgent ?? !(quota?.qoder?.hidden ?? false)
    }

    private var showQoderCN: Bool {
        showQoderCNAgent ?? !(quota?.qoderCn?.hidden ?? true)
    }

    @ViewBuilder private var quotaSection: some View {
        if let quota {
            let visible = Set([
                showClaude ? "claude" : nil,
                showCodex ? "codex" : nil,
                showQoder ? "qoder" : nil,
                showQoderCN ? "qoder_cn" : nil,
            ].compactMap { $0 })
            FlatQuotaCarousel(
                pages: quota.flatPages(visibleAgents: visible),
                autoRotate: quotaAutoRotate,
                interval: quotaRotateSecs,
                isActive: carouselActive,
                selectionID: quotaSelectionID,
                onSelectionChange: onSelectQuota,
                onRotationPauseChange: onQuotaRotationPauseChange)
                .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

// MARK: - 面板外壳预览容器（bg + aurora + 玻璃，模拟 420 宽主面板）
struct PanelChrome<Content: View>: View {
    var height: CGFloat = 780
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg
            AuroraBackground(opacity: 0.72)
            // 不用 ScrollView：ImageRenderer 渲染不了其内容；定高 VStack 顶对齐即可。
            VStack(spacing: 0) {
                content.padding(14)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 420, height: height)
        .preferredColorScheme(.dark)
    }
}

// MARK: - 预览 mock 数据
enum PreviewSamples {
    static func win(_ id: String, _ label: String, _ pct: Double, resetIn: TimeInterval) -> QuotaWindow {
        QuotaWindow(id: id, label: label, usedPercent: pct,
                    resetsAt: FlexibleDate(Date().addingTimeInterval(resetIn)))
    }

    static let claude = QuotaNode(
        ok: true, hidden: false, accountId: nil, account: nil, isDefault: true, kind: "oauth",
        windows: [
            win("seven_day", "周限额", 62, resetIn: 3.5 * 86400),
            // 故意不按周期排序，预览可验证圆环按 windowSeconds 选择最短窗口。
            win("five_hour", "5 小时窗口", 35.2, resetIn: 2.4 * 3600),
            win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3.5 * 86400),
        ],
        error: nil, noQuota: nil, sampledAt: nil, stale: nil, credits: nil, raw: nil)

    static let codex = QuotaNode(
        ok: true, hidden: false, accountId: nil, account: nil, isDefault: true, kind: nil,
        windows: [
            win("seven_day", "周限额", 19, resetIn: 6 * 86400),
        ],
        error: nil, noQuota: nil, sampledAt: nil, stale: nil, credits: nil, raw: nil)

    static let qoder = QuotaNode(
        ok: true, hidden: false, accountId: nil, account: nil, isDefault: true,
        kind: "personal_standard",
        windows: [
            QuotaWindow(id: "total", label: "综合额度", usedPercent: 36,
                        resetsAt: nil, used: 360, total: 1000, remaining: 640,
                        unit: "credits", bucketKind: "total"),
            QuotaWindow(id: "plan", label: "套餐额度", usedPercent: 41,
                        resetsAt: nil, used: 410, total: 1000, remaining: 590,
                        unit: "credits", bucketKind: "plan"),
        ],
        error: nil, noQuota: nil, sampledAt: ISO8601DateFormatter().string(from: Date()),
        stale: nil, credits: nil, raw: nil)

    static let hiddenClaude = QuotaNode(
        ok: false, hidden: true, accountId: nil, account: nil, isDefault: true, kind: nil,
        windows: nil, error: nil, noQuota: nil, sampledAt: nil, stale: nil,
        credits: nil, raw: nil)

    static let response = QuotaResponse(
        claude: claude, codex: codex, qoder: qoder,
        agents: [
            AgentQuota(id: "claude", name: "Claude", hidden: false, accounts: [claude]),
            AgentQuota(id: "codex", name: "Codex", hidden: false, accounts: [codex]),
            AgentQuota(id: "qoder", name: "Qoder", hidden: false, accounts: [qoder]),
        ],
        accounts: QuotaAccounts(claude: [claude], codex: [codex], qoder: [qoder]),
        menubar: nil, ts: nil)

    static let readmeResponse = QuotaResponse(
        claude: claude, codex: codex, qoder: qoder,
        agents: [
            AgentQuota(id: "qoder", name: "Qoder", hidden: false, accounts: [qoder]),
            AgentQuota(id: "claude", name: "Claude", hidden: false, accounts: [claude]),
            AgentQuota(id: "codex", name: "Codex", hidden: false, accounts: [codex]),
        ],
        accounts: QuotaAccounts(claude: [claude], codex: [codex], qoder: [qoder]),
        menubar: nil, ts: nil)

    static let codexOnlyResponse = QuotaResponse(
        claude: hiddenClaude, codex: codex,
        accounts: QuotaAccounts(claude: [], codex: [codex]),
        menubar: nil, ts: nil)

    static let usageDays: [String] = (0..<7).reversed().map {
        DateFormatter.localDay.string(from: Date().addingTimeInterval(-Double($0) * 86400))
    }
    static var usage: UsageResponse {
        var cd: [String: [String: [Double]]] = [:]
        var xd: [String: Double] = [:], qd: [String: Double] = [:], costd: [String: Double] = [:]
        for (i, day) in usageDays.enumerated() {
            let s = Double(i + 1) / 7   // 由少到多，今日最高
            cd[day] = ["claude-opus-4-8": [1_200_000 * s, 300_000 * s], "claude-sonnet-4-6": [820_000 * s]]
            xd[day] = 460_000 * s
            qd[day] = 220_000 * s
            costd[day] = 37 * s
        }
        let nowH = floor(Date().timeIntervalSince1970 / 3600) * 3600   // 整点对齐（同 daemon）
        let hourly = (0..<48).map { HourBucket(ts: nowH - Double($0) * 3600,
                                               c: Double(max(0, 40000 - $0 * 300)),
                                               x: 8000, q: 4500) }
        return UsageResponse(
            days: usageDays, claudeDaily: cd, codexDaily: xd, qoderDaily: qd,
            costDaily: costd, hourly: hourly,
            projects7d: [
                ProjectUsage(name: "agentdeck", cwd: "/Users/demo/Projects/agentdeck",
                             tokens: 5_200_000, cost: 42, agents: ["claude": 5_200_000]),
                ProjectUsage(name: "api-service", cwd: "/Users/demo/Projects/api-service",
                             tokens: 2_100_000, cost: 18, agents: ["qoder": 2_100_000]),
                ProjectUsage(name: "cli", cwd: "/Users/demo/Projects/cli",
                             tokens: 900_000, cost: 6, agents: ["codex": 900_000]),
            ],
            cost7d: 66, cost30d: 210,
            claudeCost7d: 54, claudeCost30d: 170, codexCost7d: 12, codexCost30d: 40,
            coverage: UsageCoverage(codexFiles: 24, codexMissingUsageFiles: 0))
    }
    static var today: TodaySummary? { TodaySummary(from: usage) }

    static let active: [ActiveSession] = [
        ActiveSession(tool: "claude", cwd: "/Users/demo/Projects/agentdeck", project: "agentdeck",
                      host: "app", runtimeSecs: 4520, runtime: nil, status: "busy", id: "s1", pid: 123),
        ActiveSession(tool: "codex", cwd: "/Users/demo/Projects/api-service/backend", project: "api-service",
                      host: nil, runtimeSecs: 1200, runtime: nil, status: "idle", id: "s2", pid: 124),
        ActiveSession(tool: "qoder", cwd: "/Users/demo/Projects/design-system", project: "design-system",
                      host: "app", source: "qoder_app", runtimeSecs: 760, runtime: nil,
                      status: "busy", id: "s3", pid: 125),
    ]
    static var done: [DoneEvent] {
        let titles: (String, String, String)
        switch I18N.locale {
        case "en":
            titles = ("Refactor quota cards in SwiftUI", "Fix login callback timeout",
                      "Plan component library migration")
        case "ja":
            titles = ("クォータカードを SwiftUI 化", "ログインコールバックのタイムアウトを修正",
                      "コンポーネントライブラリ移行計画")
        default:
            titles = ("重构额度卡为 SwiftUI", "修复登录回调超时", "整理组件库迁移计划")
        }
        return [
        DoneEvent(tool: "claude", title: titles.0, project: "agentdeck",
                  ts: Date().timeIntervalSince1970 - 600, session: "x", cwd: "/Users/demo/Projects/agentdeck"),
        DoneEvent(tool: "codex", title: titles.1, project: "api-service",
                  ts: Date().timeIntervalSince1970 - 5400, session: "y", cwd: "/Users/demo/Projects/api-service"),
        DoneEvent(tool: "qoder", title: titles.2, project: "design-system",
                  ts: Date().timeIntervalSince1970 - 7200, session: "z", cwd: "/Users/demo/Projects/design-system"),
        ]
    }

    static let sessions: [SessionItem] = [
        SessionItem(tool: "claude", id: "a1", title: "重构额度卡为原生 SwiftUI", cwd: "/Users/demo/Projects/agentdeck",
                    project: "agentdeck", branch: "v2-native", mtime: Date().timeIntervalSince1970 - 30,
                    account: nil, accountId: nil, pinned: true),
        SessionItem(tool: "codex", id: "b2", title: "修复登录回调超时", cwd: "/Users/demo/Projects/api-service",
                    project: "api-service", branch: "main", mtime: Date().timeIntervalSince1970 - 3600,
                    account: nil, accountId: nil, pinned: false),
        SessionItem(tool: "claude", id: "c3", title: "撰写 v1.26 发布说明", cwd: "/Users/demo/Projects/agentdeck",
                    project: "agentdeck", branch: "HEAD", mtime: Date().timeIntervalSince1970 - 86400,
                    account: nil, accountId: nil, pinned: false),
        SessionItem(tool: "qoder", id: "d4", title: "整理组件库迁移计划", cwd: "/Users/demo/Projects/design-system",
                    project: "design-system", branch: "main", mtime: Date().timeIntervalSince1970 - 5400,
                    account: nil, accountId: nil, source: "qoder_app", pinned: false),
    ]
    static let previewMsgs: [PreviewMsg] = [
        PreviewMsg(role: "user", text: "把额度卡的进度环改成原生 SwiftUI，要和网页版一模一样"),
        PreviewMsg(role: "assistant", text: "好的，用 Circle().trim 实现进度环，阈值 ≥80 橙、≥95 红，中心显示百分比，渐变跟随品牌色。"),
    ]

    static let settingsValues: [String: SettingValue] = [
        "language": .string("auto"), "font_scale": .int(120), "glass_dim": .int(68),
        "color_claude": .string("#ff9d7a"), "color_codex": .string("#4fd1c5"),
        "color_qoder": .string("#a78bfa"),
        "minimal_mode": .bool(false), "show_active": .bool(true),
        "show_claude": .bool(true), "show_codex": .bool(true), "show_qoder": .bool(true),
        "quota_auto_rotate": .bool(true), "quota_rotate_secs": .int(6),
        "sessions_limit": .int(20), "refresh_interval": .int(30),
        "sample_interval": .int(180), "quota_interval": .int(600),
        "menubar_claude": .bool(true), "menubar_codex": .bool(false), "menubar_qoder": .bool(true),
        "menubar_value_dim": .string("shortest"), "menubar_alert_color": .bool(true),
        "menubar_color_dim": .string("shortest"), "menubar_rotate_secs": .int(6),
        "notify_enabled": .bool(true), "notify_warn": .int(80), "notify_crit": .int(95),
        "notify_reset": .bool(true), "notify_session_done": .bool(true), "notify_done_min_secs": .int(30),
        "island_dwell_secs": .int(5), "notify_sound": .bool(false),
        "terminal": .string("auto"), "auto_paste_resume": .bool(false),
        "keep_awake": .bool(true), "update_check": .bool(true),
    ]
}

#Preview("概览 · 额度卡") {
    PanelChrome {
        OverviewView(quota: PreviewSamples.response, usage: PreviewSamples.usage,
                     today: PreviewSamples.today, active: PreviewSamples.active, done: PreviewSamples.done)
    }
}

#Preview("单卡 · Claude") {
    PanelChrome { QuotaCardView(brand: .claude, node: PreviewSamples.claude) }
}
