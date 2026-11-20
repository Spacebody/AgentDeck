// AgentDeck v3 overview: daily usage, account quota, trend and project activity.
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
    @Environment(\.adShowInfo) private var showInfo
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
    var onViewUsage: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        AgentUsageDonut(summary: today)
                        Text(L("info.todayTerm")).font(.system(size: 12, weight: .semibold))
                        InfoButton { showInfo(.today) }.accessibilityLabel(L("info.title"))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(Fmt.tokens(today?.totalTokens ?? 0))
                            .font(.system(size: 34, weight: .semibold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("tokens").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    }
                    HStack(spacing: 10) {
                        Text(todayCost).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let delta = today?.deltaPercent {
                            Label("\(abs(delta))%", systemImage: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 10)).foregroundStyle(delta > 0 ? Theme.warn : DashboardStyle.accent)
                                .fixedSize()
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
                quotaSection.frame(maxWidth: .infinity, alignment: .top)
            }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    DashboardHeading(text: L("usage.tabCurve"))
                    Button(action: onViewUsage) {
                        Label(L("v3.viewUsage"), systemImage: "arrow.up.right")
                            .font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(DashboardStyle.accent).fixedSize()
                }
                if let usage {
                    DashboardTrend(hourly: usage.hourly, agents: visibleAgents).frame(height: 95)
                } else { Text(L("common.loading")).foregroundStyle(Theme.ink3) }
            }
            Divider().opacity(0.4)
            if showActive && !active.isEmpty {
                DashboardActiveList(sessions: active, onOpen: onFocusActive)
                Divider().opacity(0.4)
            }
            DashboardDoneList(events: done, onOpen: onFocusDone)
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

    private var visibleAgents: Set<String> {
        Set([showClaude ? "claude" : nil, showCodex ? "codex" : nil,
             showQoder ? "qoder" : nil, showQoderCN ? "qoder_cn" : nil].compactMap { $0 })
    }

    private var todayCost: String {
        guard let usage, let cost = UsageRangeSummary(usage: usage, span: 1, visible: visibleAgents).cost else {
            return L("v3.unavailable")
        }
        return String(format: "≈ $%.2f", cost)
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
                dashboard: true,
                autoRotate: quotaAutoRotate,
                interval: quotaRotateSecs,
                isActive: carouselActive,
                selectionID: quotaSelectionID,
                onSelectionChange: onSelectQuota,
                onRotationPauseChange: onQuotaRotationPauseChange)
                .frame(maxWidth: .infinity, alignment: .top)
        } else { Text(L("common.loading")).font(.system(size: 11)).foregroundStyle(Theme.ink3) }
    }
}

struct DashboardTrend: View {
    @ObservedObject private var palette = AgentColors.shared
    let hourly: [HourBucket]
    let agents: Set<String>
    var body: some View {
        Canvas { context, size in
            let now = Date().timeIntervalSince1970
            let end = floor(now / 3600) * 3600
            let totals = (0..<24).map { index -> Double in
                let start = end - Double(23 - index) * 3600
                return hourly.filter { $0.ts >= start && $0.ts < start + 3600 }.reduce(0) {
                    $0 + (agents.contains("claude") ? $1.c : 0) + (agents.contains("codex") ? $1.x : 0)
                        + (agents.contains("qoder") ? $1.q ?? 0 : 0)
                        + (agents.contains("qoder_cn") ? $1.qcn ?? 0 : 0)
                }
            }
            let maxValue = max(totals.max() ?? 0, 1)
            let height = max(0, size.height - 20)
            let points = totals.enumerated().map { i, value in
                CGPoint(x: size.width * Double(i) / 23, y: height - max(0, height - 3) * value / maxValue)
            }
            // Equal hourly spacing: limit tangents to the smaller adjacent change.
            // This keeps flat hours flat and makes the tangent horizontal at extrema.
            func tangent(_ i: Int) -> CGFloat {
                if i == 0 { return points[1].y - points[0].y }
                if i == points.count - 1 { return points[i].y - points[i - 1].y }
                let a = points[i].y - points[i - 1].y, b = points[i + 1].y - points[i].y
                return a * b > 0 ? (a > 0 ? min(a, b) : max(a, b)) : 0
            }
            var line = Path()
            line.move(to: points[0])
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                // Longer tangent handles broaden the shoulders at peaks and troughs.
                // Below 0.5 the controls stay ordered, even on steep hourly jumps.
                let reach: CGFloat = 0.48
                let dx = (b.x - a.x) * reach
                line.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y + tangent(i - 1) * reach),
                              control2: CGPoint(x: b.x - dx, y: b.y - tangent(i) * reach))
            }
            let ink = agents.count == 1 ? agents.first.flatMap(Brand.init(rawValue:))?.accent : nil
            context.stroke(line, with: .color(ink ?? DashboardStyle.accent),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: height)); baseline.addLine(to: CGPoint(x: size.width, y: height))
            context.stroke(baseline, with: .color(.white.opacity(0.1)), lineWidth: 1)
            let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
            for index in [0, 6, 12, 18, 23] {
                let date = Date(timeIntervalSince1970: end - Double(23 - index) * 3600)
                context.draw(Text(formatter.string(from: date)).font(.system(size: 10)).foregroundColor(Theme.ink2),
                             at: CGPoint(x: size.width * Double(index) / 23, y: height + 13),
                             anchor: index == 0 ? .leading : index == 23 ? .trailing : .center)
            }
        }.accessibilityLabel(L("usage.tabCurve"))
    }
}

// MARK: - 面板外壳预览容器（bg + aurora + 玻璃，模拟 420 宽主面板）
struct PanelChrome<Content: View>: View {
    var height: CGFloat = 780
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            DashboardStyle.background
            // 不用 ScrollView：ImageRenderer 渲染不了其内容；定高 VStack 顶对齐即可。
            VStack(spacing: 0) {
                content.padding(14)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 420, height: height)
        .foregroundStyle(Theme.ink)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
