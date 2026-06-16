// AgentDeck v2 — 概览页。里程碑阶段先实现额度卡区（核心质感）；
// 今日条 / 活跃会话 / 完成事件 / 用量图表在 #5、#6 接入。
import SwiftUI

struct OverviewView: View {
    let quota: QuotaResponse?
    var usage: UsageResponse? = nil
    var today: TodaySummary? = nil
    var active: [ActiveSession] = []
    var done: [DoneEvent] = []
    var onFocusActive: (ActiveSession) -> Void = { _ in }
    var onFocusDone: (DoneEvent) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            quotaSection
            if let today { TodayBar(summary: today) }
            ActiveCard(sessions: active, onTap: onFocusActive)
            DoneCard(events: done, onTap: onFocusDone)
            UsageView(usage: usage)   // 用量趋势（24h / 近7天 / 项目 Top）
        }
    }

    @ViewBuilder private var quotaSection: some View {
        let claude = quota?.claude
        let codex = quota?.codex
        let showClaude = !(claude?.hidden ?? false)
        let showCodex = !(codex?.hidden ?? false)
        HStack(alignment: .top, spacing: 10) {
            if showClaude { QuotaCardView(brand: .claude, node: claude) }
            if showCodex { QuotaCardView(brand: .codex, node: codex) }
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
            win("five_hour", "5 小时窗口", 35.2, resetIn: 2.4 * 3600),
            win("seven_day", "周限额", 62, resetIn: 3.5 * 86400),
            win("seven_day_opus", "周限额 · Opus", 88, resetIn: 3.5 * 86400),
        ],
        error: nil, noQuota: nil, sampledAt: nil)

    static let codex = QuotaNode(
        ok: true, hidden: false, accountId: nil, account: nil, isDefault: true, kind: nil,
        windows: [
            win("five_hour", "5 小时窗口", 12, resetIn: 1.2 * 3600),
            win("seven_day", "周限额", 96, resetIn: 5 * 86400),
        ],
        error: nil, noQuota: nil, sampledAt: nil)

    static let response = QuotaResponse(
        claude: claude, codex: codex,
        accounts: QuotaAccounts(claude: [claude], codex: [codex]),
        menubar: nil, ts: nil)

    static let usageDays: [String] = (0..<7).reversed().map {
        DateFormatter.localDay.string(from: Date().addingTimeInterval(-Double($0) * 86400))
    }
    static var usage: UsageResponse {
        var cd: [String: [String: [Double]]] = [:], xd: [String: Double] = [:], costd: [String: Double] = [:]
        for (i, day) in usageDays.enumerated() {
            let s = Double(i + 1) / 7   // 由少到多，今日最高
            cd[day] = ["claude-opus-4-8": [1_200_000 * s, 300_000 * s], "claude-sonnet-4-6": [820_000 * s]]
            xd[day] = 460_000 * s
            costd[day] = 37 * s
        }
        let nowH = floor(Date().timeIntervalSince1970 / 3600) * 3600   // 整点对齐（同 daemon）
        let hourly = (0..<48).map { HourBucket(ts: nowH - Double($0) * 3600,
                                               c: Double(max(0, 40000 - $0 * 300)), x: 8000) }
        return UsageResponse(
            days: usageDays, claudeDaily: cd, codexDaily: xd, costDaily: costd, hourly: hourly,
            projects7d: [
                ProjectUsage(name: "agentdeck", cwd: "/Users/jerry/Downloads/agentdeck", tokens: 5_200_000, cost: 42),
                ProjectUsage(name: "api-service", cwd: "/Users/jerry/work/api-service", tokens: 2_100_000, cost: 18),
                ProjectUsage(name: "Codex/cli", cwd: "/Users/jerry/Codex/cli", tokens: 900_000, cost: 6),
            ],
            cost7d: 66, cost30d: 210,
            claudeCost7d: 54, claudeCost30d: 170, codexCost7d: 12, codexCost30d: 40)
    }
    static var today: TodaySummary? { TodaySummary(from: usage) }

    static let active: [ActiveSession] = [
        ActiveSession(tool: "claude", cwd: "/Users/jerry/Downloads/agentdeck", project: "agentdeck",
                      host: "app", runtimeSecs: 4520, runtime: nil, status: "busy", id: "s1", pid: 123),
        ActiveSession(tool: "codex", cwd: "/Users/jerry/work/api-service/backend", project: "api-service",
                      host: nil, runtimeSecs: 1200, runtime: nil, status: "idle", id: "s2", pid: 124),
    ]
    static let done: [DoneEvent] = [
        DoneEvent(tool: "claude", title: "重构额度卡为 SwiftUI", project: "agentdeck",
                  ts: Date().timeIntervalSince1970 - 600, session: "x", cwd: "/Users/jerry/Downloads/agentdeck"),
        DoneEvent(tool: "codex", title: "修复登录回调超时", project: "api-service",
                  ts: Date().timeIntervalSince1970 - 5400, session: "y", cwd: "/Users/jerry/work/api-service"),
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
