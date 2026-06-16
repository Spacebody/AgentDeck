// AgentDeck v2 — 桌面小组件紧凑视图（?widget=1）。复刻 body.wgt：只留额度卡(紧凑) +
// 今日条 + 活跃会话头部，隐藏 tabbar/用量/会话/完成/设置/更新横幅，顶部 grip 提示。
import SwiftUI

struct WidgetView: View {
    let quota: QuotaResponse?
    var today: TodaySummary? = nil
    var active: [ActiveSession] = []
    var onTapPanel: () -> Void = {}
    var onFocusActive: (ActiveSession) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                if !(quota?.claude?.hidden ?? false) {
                    QuotaCardView(brand: .claude, node: quota?.claude, compact: true)
                }
                if !(quota?.codex?.hidden ?? false) {
                    QuotaCardView(brand: .codex, node: quota?.codex, compact: true)
                }
            }
            if let today { TodayBar(summary: today) }
            ActiveCard(sessions: active, onTap: onFocusActive)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTapPanel)   // 点击小组件 → 打开主面板（body.wgt #quota/#active cursor:pointer）
    }
}

// 小组件外壳（驻桌面的窄玻璃窗：顶部 grip + 暗化 aurora）
struct WidgetChrome<Content: View>: View {
    var width: CGFloat = 340
    var height: CGFloat = 320
    @ViewBuilder var content: Content
    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg
            AuroraBackground(opacity: 0.14)
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.28)).frame(width: 36, height: 4).padding(.top, 7)
                content.padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .preferredColorScheme(.dark)
    }
}
