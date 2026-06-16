// AgentDeck v2 — 概览页。里程碑阶段先实现额度卡区（核心质感）；
// 今日条 / 活跃会话 / 完成事件 / 用量图表在 #5、#6 接入。
import SwiftUI

struct OverviewView: View {
    let quota: QuotaResponse?

    var body: some View {
        VStack(spacing: 10) {
            quotaSection
            // TODO #5: 今日摘要条 · 活跃会话 · 最近完成
            // TODO #6: 用量趋势（24h / 近7天 / 项目 Top）
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
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Theme.bg
            AuroraBackground(opacity: 0.72)
            ScrollView { content.padding(14) }
        }
        .frame(width: 420, height: 780)
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
}

#Preview("概览 · 额度卡") {
    PanelChrome { OverviewView(quota: PreviewSamples.response) }
}

#Preview("单卡 · Claude") {
    PanelChrome { QuotaCardView(brand: .claude, node: PreviewSamples.claude) }
}
