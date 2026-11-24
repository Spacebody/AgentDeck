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
    var showAntigravityAgent: Bool? = nil
    var onTapPanel: () -> Void = {}
    var onFocusActive: (ActiveSession) -> Void = { _ in }

    var body: some View {
        let showClaude = showClaudeAgent ?? !(quota?.claude?.hidden ?? false)
        let showCodex = showCodexAgent ?? !(quota?.codex?.hidden ?? false)
        let showQoder = showQoderAgent ?? !(quota?.qoder?.hidden ?? false)
        let showQoderCN = showQoderCNAgent ?? !(quota?.qoderCn?.hidden ?? true)
        let visible = Set([showClaude ? "claude" : nil, showCodex ? "codex" : nil,
                           showQoder ? "qoder" : nil,
                           showQoderCN ? "qoder_cn" : nil,
                           (showAntigravityAgent ?? !(quota?.antigravityPanelHidden ?? true)) ? "antigravity" : nil].compactMap { $0 })
        let pages = quota?.flatPages(visibleAgents: visible) ?? []
        let widgetPages = Array(pages.prefix(2))
        let maxWindows = widgetPages.map { $0.account.displayWindows.count }.max() ?? 0
        let activeLimit = maxWindows >= 4 ? 1 : 2
        let activeRows = Array(active.prefix(activeLimit))
        return VStack(spacing: 7) {
            if widgetPages.isEmpty {
                Text(L(visible.isEmpty ? "usage.noVisibleAgents" : quota == nil ? "quota.loading" : "quota.noQuota"))
                    .foregroundStyle(Theme.ink2).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 7) {
                ForEach(widgetPages) { page in
                    DashboardQuota(brand: page.brand, node: page.account, compact: true)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .layoutPriority(1)
                }
            }
            if let today {
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(L("info.todayTerm")).foregroundStyle(Theme.ink2)
                    Text(Fmt.tokens(today.totalTokens)).font(.system(size: 19, weight: .semibold))
                    Text("tokens").foregroundStyle(Theme.ink3)
                    Spacer(minLength: 2)
                    Text(today.costUSD.map { String(format: "≈ $%.2f", $0) } ?? L("v3.unavailable")).foregroundStyle(Theme.ink2)
                }.font(.system(size: 11)).monospacedDigit()
            }
            if showActive && !activeRows.isEmpty {
                HStack {
                    Text(L("active.running", ["n": "\(active.count)"])).fontWeight(.semibold)
                    Spacer()
                }
                ForEach(Array(activeRows.enumerated()), id: \.offset) { _, session in
                    Button { onFocusActive(session) } label: {
                        HStack {
                            Text(session.project ?? session.cwd ?? session.tool)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            SessionSpeedView(request: session.performanceRequest)
                            if let status = session.status, ["busy", "idle"].contains(status) {
                                SessionActivityLabel(status: status, tool: session.tool)
                                    .environment(\.flatCard, true)
                            }
                            if SessionTools.canFocus(session.tool) {
                                Image(systemName: "chevron.right").foregroundStyle(Theme.ink3)
                            }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!SessionTools.canFocus(session.tool))
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
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
            DashboardStyle.background
            VStack(spacing: 0) {
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 28, height: 3.5).padding(.top, 7)
                content.padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                Spacer(minLength: 0)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .preferredColorScheme(.dark)
    }
}
