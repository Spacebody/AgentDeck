// AgentDeck v2 — 桌面小组件紧凑视图（?widget=1）。复刻 body.wgt：只留额度卡(紧凑) +
// 今日条 + 活跃会话头部，隐藏 tabbar/用量/会话/完成/设置/更新横幅，顶部 grip 提示。
import SwiftUI

struct WidgetView: View {
    let quota: QuotaResponse?
    var today: TodaySummary? = nil
    var active: [ActiveSession] = []
    var showActive: Bool = true
    /// nil 仅用于预览/启动兜底；真实根视图传入本地设置，切换后下一帧生效。
    var showClaudeAgent: Bool? = nil
    var showCodexAgent: Bool? = nil
    var showQoderAgent: Bool? = nil
    var showQoderCNAgent: Bool? = nil
    var onTapPanel: () -> Void = {}
    var onFocusActive: (ActiveSession) -> Void = { _ in }

    var body: some View {
        let showClaude = showClaudeAgent ?? !(quota?.claude?.hidden ?? false)
        let showCodex = showCodexAgent ?? !(quota?.codex?.hidden ?? false)
        let showQoder = showQoderAgent ?? !(quota?.qoder?.hidden ?? false)
        let showQoderCN = showQoderCNAgent ?? !(quota?.qoderCn?.hidden ?? true)
        let visible = Set([showClaude ? "claude" : nil, showCodex ? "codex" : nil,
                           showQoder ? "qoder" : nil,
                           showQoderCN ? "qoder_cn" : nil].compactMap { $0 })
        let pages = quota?.flatPages(visibleAgents: visible) ?? []
        let widgetPages = Array(pages.prefix(2))
        let maxWindows = widgetPages.map { $0.account.displayWindows.count }.max() ?? 0
        let activeLimit = maxWindows >= 4 ? 1 : 2
        let activeRows = Array(active.prefix(activeLimit))
        return VStack(spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                ForEach(widgetPages) { page in
                    QuotaCardView(brand: page.brand, node: page.account,
                                  accountLabel: page.account.account,
                                  presentation: .widget)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .layoutPriority(1)
                }
            }
            if let today { TodayBar(summary: today) }
            if showActive {
                ActiveCard(sessions: activeRows, totalCount: active.count,
                           onTap: onFocusActive)
            }
        }
        .environment(\.flatCard, true)   // 小组件内卡片走扁平轻磨砂（原生小组件观感）
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapPanel)   // 点击小组件 → 打开主面板（body.wgt #quota/#active cursor:pointer）
        .animation(.easeInOut(duration: 0.18), value: showClaude)
        .animation(.easeInOut(duration: 0.18), value: showCodex)
        .animation(.easeInOut(duration: 0.18), value: showQoder)
        .animation(.easeInOut(duration: 0.18), value: showQoderCN)
    }
}

// 小组件外壳（驻桌面的窄玻璃窗：顶部 grip + 暗化 aurora）
struct WidgetChrome<Content: View>: View {
    var width: CGFloat = 360
    var height: CGFloat = 300
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg
            AuroraBackground(opacity: 0.14)
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 28, height: 3.5).padding(.top, 7)
                content.padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .preferredColorScheme(.dark)
    }
}
