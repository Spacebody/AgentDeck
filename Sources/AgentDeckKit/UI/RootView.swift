// AgentDeck v3: shared four-page shell, native actions, settings and update overlay.
import AppKit
import SwiftUI

// MARK: - 统计口径弹层种类（today 摘要 / usage 当前视图）
enum InfoKind: Equatable { case today; case usage(UsageMode); case range(Int) }

// MARK: - 主内容自然高度（驱动面板高度自适应，消除底部空隙）
private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

// MARK: - 统计口径环境闭包（TodayBar / UsageView 深层触发，根视图实现）
private struct ShowInfoKey: EnvironmentKey { static let defaultValue: (InfoKind) -> Void = { _ in } }
extension EnvironmentValues {
    var adShowInfo: (InfoKind) -> Void {
        get { self[ShowInfoKey.self] }
        set { self[ShowInfoKey.self] = newValue }
    }
}

// MARK: - 字体缩放容器：内容在「基准尺寸」(容器/scale)布局后整体放大，
// 等价 index.html 的 zoom（窗口尺寸由主壳按同一 scale 同步扩大）。
struct ScaledContainer<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder var content: Content
    var body: some View {
        if abs(scale - 1) < 0.001 {
            content
        } else {
            GeometryReader { geo in
                content
                    .frame(width: geo.size.width / scale, height: geo.size.height / scale)
                    .scaleEffect(scale, anchor: .topLeading)
            }
        }
    }
}

// MARK: - 刷新图标（照搬 v1 Feather refresh-cw 的两段 SVG path，24×24 viewBox）
// path1 箭头角 M23 4 v6 h-6；path2 大圆弧 M20.49 15 a9 9 …→(18.37,5.64) L23 10
// SVG 椭圆弧换算：圆心(12,12) r9，起点角 19.45°、绕大弧(顺时针/增角)到 315°。
struct RefreshCWShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var p = Path()
        p.move(to: P(23, 4)); p.addLine(to: P(23, 10)); p.addLine(to: P(17, 10))   // 箭头角
        p.move(to: P(20.49, 15))                                                    // 大圆弧 + 尾线
        p.addArc(center: P(12, 12), radius: 9 * s,
                 startAngle: .degrees(19.45), endAngle: .degrees(315), clockwise: false)
        p.addLine(to: P(23, 10))
        return p
    }
}

// MARK: - 圆形玻璃图标按钮（.iconbtn）
struct IconButton: View {
    let system: String
    var weight: Font.Weight = .semibold
    var fontSize: CGFloat = 15
    var size: CGFloat = 32
    var danger = false
    var spinning = false
    /// 用 v1 原样刷新字形（RefreshCWShape）替代 SF Symbol。
    var customRefresh = false
    let action: () -> Void
    @State private var hover = false

    // 颜色/底/描边随 hover 计算（对应 v1 .iconbtn:hover 与 #quit:hover 的三处变化）
    private var fg: Color { danger && hover ? Theme.danger : (hover ? Theme.ink : Theme.ink2) }
    private var bg: Color { hover ? (danger ? Theme.danger.opacity(0.10) : Theme.glassHi) : Theme.glass }
    private var border: Color { danger && hover ? Theme.danger.opacity(0.45) : Theme.edge }

    var body: some View {
        Button(action: action) {
            // 自旋用 TimelineView 按时钟算角度：转时每帧重算、停时直接渲染静态。
            // 不依赖任何「动画对象」的起/停——隐式 .repeatForever 会被轮询重绘取消（点了不转），
            // 显式 withAnimation(.repeatForever) 又取消不掉（一直转）；按时间算两个坑都绕开。
            if spinning {
                TimelineView(.animation) { ctx in
                    let secs = ctx.date.timeIntervalSinceReferenceDate
                    glyph(angle: secs.truncatingRemainder(dividingBy: 0.7) / 0.7 * 360)  // 0.7s 一圈，顺时针
                }
            } else {
                glyph(angle: 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        // v1 transition:.18s 作用于 background/color/transform/border 全属性，CSS 默认 ease ≈ easeInOut。
        .animation(.easeInOut(duration: 0.18), value: hover)
    }

    @ViewBuilder private func glyph(angle: Double) -> some View {
        Group {
            if customRefresh {
                RefreshCWShape()
                    .stroke(fg, style: StrokeStyle(lineWidth: 2.2 * 16 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)          // 同 v1 svg 16px
            } else {
                Image(systemName: system)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(fg)
            }
        }
            .frame(width: size, height: size)              // 先定方框，再绕方框中心旋转 → 同心转，不晃
            .rotationEffect(.degrees(angle), anchor: .center)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? bg : .clear))
    }
}

struct HeaderHintPlacement<Hint: View>: View {
    @ViewBuilder let hint: () -> Hint

    var body: some View {
        GeometryReader { button in
            hint()
                .fixedSize()
                .frame(width: button.size.width, alignment: .trailing)
                .offset(y: button.size.height + 8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct HeaderHint: ViewModifier {
    let text: String
    var wraps = false
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onDisappear { hovered = false }
            .overlay {
                if hovered {
                    HeaderHintPlacement {
                    Text(verbatim: text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: !wraps, vertical: true)
                        .frame(width: wraps ? 190 : nil, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: 0x222529)))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.edgeHi))
                    }
                }
            }
    }
}

// MARK: - 应用根视图（主面板）
public struct AgentDeckRootView: View {
    @ObservedObject var store: AppStore
    var version: String
    var onQuit: () -> Void
    var onRestartBackend: () -> Void = {}
    var onOpenExternal: (String) -> Void
    var onPasteEnter: (String, Int) -> Void
    var onHidePanel: () -> Void
    /// 字体大小变更（驱动主壳同步缩放窗口，保持有效布局宽度）。
    var onScale: (CGFloat) -> Void
    /// 内容自然高度变化（驱动主壳把面板高度自适应到内容，去掉底部空隙）。
    var onContentHeight: (CGFloat) -> Void
    /// 预览模式：用 VStack 取代 ScrollView（ImageRenderer 渲不了滚动内容）。
    var previewMode: Bool

    public init(store: AppStore, version: String = "dev",
                onQuit: @escaping () -> Void = {},
                onRestartBackend: @escaping () -> Void = {},
                onOpenExternal: @escaping (String) -> Void = { _ in },
                onPasteEnter: @escaping (String, Int) -> Void = { _, _ in },
                onHidePanel: @escaping () -> Void = {},
                onScale: @escaping (CGFloat) -> Void = { _ in },
                onContentHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.store = store; self.version = version
        self.onQuit = onQuit; self.onOpenExternal = onOpenExternal
        self.onRestartBackend = onRestartBackend
        self.onPasteEnter = onPasteEnter; self.onHidePanel = onHidePanel
        self.onScale = onScale; self.onContentHeight = onContentHeight
        self.previewMode = false
    }

    // 内部预览构造（PreviewRender 用，非 public）。
    init(previewStore: AppStore, version: String, initialTab: String = "overview",
         settingsOpen: Bool = false, liveLayout: Bool = false) {
        self.store = previewStore; self.version = version
        self.onQuit = {}; self.onOpenExternal = { _ in }; self.onPasteEnter = { _, _ in }; self.onHidePanel = {}
        self.onScale = { _ in }; self.onContentHeight = { _ in }
        self.previewMode = !liveLayout
        _showSettings = State(initialValue: settingsOpen)
        _navigation = State(initialValue: UsageNavigation(tab: initialTab))
    }

    @State private var navigation = UsageNavigation()
    private var tab: String { navigation.tab }
    @State private var scopedDays = 30
    @State private var scopedFixture: AnalyticsSnapshot?
    @State private var originViewport: CGFloat?
    @State private var analyticsDays = 7
    @State private var analyticsRefresh = 0
    @State private var showSettings = false
    @State private var settingsPage: SettingsPage = .main
    @State private var info: InfoKind?
    @State private var infoResponder: NSResponder?
    @FocusState private var infoCloseFocused: Bool
    @State private var dismissedUpdateVersion: String?
    @State private var spinning = false
    @State private var toastMsg: String?
    @State private var toastSeq = 0

    private var minimal: Bool { store.settings["minimal_mode"]?.boolVal ?? false }
    private var gatewayOnline: Bool { store.gatewayOnline || previewMode }
    private var gatewayIndicatorKey: String { gatewayOnline ? "header.gatewayOnline" : "header.gatewayOffline" }
    private var dim: Double { Double(store.settings["glass_dim"]?.intVal ?? 68) / 100 }
    private var showUpdate: Bool { store.updateAvailable && store.update?.latest != dismissedUpdateVersion }
    private var fontScale: CGFloat {
        min(max(CGFloat(store.settings["font_scale"]?.intVal ?? 100) / 100, 0.8), 1.6)
    }

    public var body: some View {
        // 字体缩放：内容在「基准宽度」(窗口/scale)布局后整体放大，等价 v1 的 zoom；窗口由主壳同步扩大。
        ScaledContainer(scale: fontScale) {
            ZStack(alignment: .top) {
                background
                mainScroll
                    .opacity(showSettings ? 0 : 1)
                    .disabled(info != nil || showSettings)
                    .accessibilityHidden(info != nil || showSettings)

                // 设置右滑浮层
                if showSettings { settingsOverlay.transition(.move(edge: .trailing)) }
                // 统计口径弹层
                if let info { infoPopup(info) }
                // toast
                if let msg = toastMsg { toastView(msg) }
            }
            .environment(\.minimalMode, minimal)
            .environment(\.samplingStore, previewMode ? nil : store)
            .environment(\.openAnalytics, { destination, fixture in
                scopedDays = 30
                scopedFixture = fixture
                navigation.open(destination)
            })
            .environment(\.adShowInfo, { kind in
                infoResponder = NSApp.keyWindow?.firstResponder
                info = kind
            })
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showSettings)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: info)   // ipin 轻微过冲
            .animation(.easeOut(duration: 0.2), value: toastMsg)
        }
        .preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .foregroundStyle(Theme.ink)
        .onChange(of: store.gatewayRestart) { status in
            if status != .idle { showToast(L(restartLabel)) }
        }
        .onExitCommand {
            if info != nil { info = nil }
            else if showSettings && settingsPage == .agents { settingsPage = .main }
            else if showSettings { showSettings = false }
            else if navigation.destination != nil { navigation.back() }
            else { onHidePanel() }
        }
        .onChange(of: info) { value in
            if value == nil {
                if let view = infoResponder as? NSView, let window = view.window {
                    window.makeFirstResponder(view)
                }
                infoResponder = nil
            }
        }
        .onChange(of: fontScale) { onScale($0) }
        .onChange(of: navigation.selectedTab) { store.performanceShowsSessions = $0 == "sessions" && !showSettings }
        .onChange(of: showSettings) { store.performanceShowsSessions = !$0 && navigation.selectedTab == "sessions" }
        .environment(\.sessionPerformanceStore, previewMode ? nil : store.performance)
        .environment(\.analyticsFixture, previewMode ? .preview : nil)
        .environment(\.analyticsLive, store.panelVisible && !showSettings && !previewMode)
        .environment(\.analyticsRefresh, analyticsRefresh)
    }

    // MARK: 背景（native：系统玻璃之上叠暗化 scrim + 弱 aurora；精简模式去 aurora）
    @ViewBuilder private var background: some View {
        DashboardStyle.background.opacity(min(1, max(0, dim))).ignoresSafeArea()
    }

    // MARK: 顶栏
    private var header: some View {
        HStack(spacing: 8) {
            // Same arcs as scripts/makeicon.swift, without the launcher's tile or tracks.
            ZStack {
                Circle().trim(from: 0, to: 250.0 / 360)
                    .stroke(DashboardStyle.accent.opacity(0.82), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 23, height: 23)
                Circle().trim(from: 0, to: 198.0 / 360)
                    .stroke(DashboardStyle.accent.opacity(0.66), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(150)).frame(width: 13.6, height: 13.6)
            }.frame(width: 32, height: 32).accessibilityHidden(true)
            Text("AgentDeck").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.5)
            Circle()
                .fill(gatewayOnline ? Theme.ok : Theme.danger)
                .frame(width: 7, height: 7)
                .help(L(gatewayIndicatorKey))
                .accessibilityLabel(L(gatewayIndicatorKey))
            Spacer()
            IconButton(system: "gearshape", fontSize: 16) {
                settingsPage = .main
                showSettings = true
            }
            .modifier(HeaderHint(text: L("header.settings")))
            .accessibilityLabel(L("header.settings"))
            IconButton(system: "arrow.clockwise", weight: .semibold, fontSize: 15, spinning: spinning, customRefresh: true) { manualRefresh() }
                .modifier(HeaderHint(text: L("header.refresh")))
                .accessibilityLabel(L("header.refresh"))
            IconButton(system: store.gatewayRestart == .failed || store.gatewayRestart == .foreign
                       ? "exclamationmark.triangle" : "arrow.triangle.2.circlepath",
                       spinning: store.gatewayRestart == .restarting, action: onRestartBackend)
                .disabled(!store.canRestartGateway)
                .modifier(HeaderHint(text: L(restartButtonLabel), wraps: restartButtonLabel != "header.restartGateway"))
                .accessibilityLabel(L(restartButtonLabel))
            IconButton(system: "power", danger: true, action: onQuit)
                .modifier(HeaderHint(text: L("header.quit")))
                .accessibilityLabel(L("header.quit"))
        }
    }

    private func manualRefresh() {
        guard !spinning else { return }
        analyticsRefresh += 1
        spinning = true
        Task {
            if await store.refreshManually() == false {
                showToast(L("header.quotaRefreshFailed"))
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            spinning = false
        }
    }

    // MARK: 更新横幅
    private var updateBar: some View {
        let install = store.updateInstall
        let installing = install?.running == true
        let progress = min(max(install?.progress ?? 0, 0), 1)
        let stageKey: String = {
            switch install?.stage {
            case "downloading": return "update.downloading"
            case "mounting": return "update.preparing"
            case "staging": return "update.preparing"
            case "installing": return "update.installing"
            default: return "update.installing"
            }
        }()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("✨ " + L("update.available", ["v": "v\(store.update?.latest ?? "")"]))
                    .font(.system(size: 12)).foregroundStyle(Theme.ink)
                if installing {
                    HStack(spacing: 7) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.13))
                                Capsule().fill(LinearGradient(colors: [Brand.codex.deep, Brand.codex.accent],
                                                              startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(width: 120, height: 4)
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.ink2)
                            .monospacedDigit()
                    }
                } else if install?.stage == "error" {
                    Text(install?.error.flatMap { $0.isEmpty ? nil : $0 } ?? L("update.installFail"))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0xff7a8a))
                        .help(install?.error ?? L("update.installFail"))
                }
            }
            Spacer(minLength: 6)
            Button {
                Task { await store.startUpdateInstall() }
            } label: {
                Text(installing ? L(stageKey) : L("update.go"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.edge))
            }.buttonStyle(.plain).hoverLift().disabled(!store.canInstallUpdate)
            Button { dismissedUpdateVersion = store.update?.latest } label: {
                Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xe8744f).opacity(0.16), Color(hex: 0x3aa79c).opacity(0.12)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16)))
        }
    }

    // MARK: Tab 栏
    private var tabbar: some View {
        ViewThatFits(in: .horizontal) {
            navigationTabs(spacing: 24)
            navigationTabs(spacing: 10)
        }.padding(.top, 14).padding(.bottom, 10)
    }

    private func navigationTabs(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            tabButton("overview", icon: "chart.bar.fill", label: L("tab.overview"))
            tabButton("sessions", icon: "bubble.left.fill", label: L("tab.sessions"))
            tabButton("projects", icon: "folder", label: L("tab.projects"))
            tabButton("usage", icon: "chart.bar", label: L("tab.usage"))
            Spacer(minLength: 0)
        }
    }

    private func tabButton(_ id: String, icon: String, label: String) -> some View {
        let on = navigation.selectedTab == id
        return Button { navigation.select(id) } label: {
            Text(label).font(.system(size: 13, weight: on ? .semibold : .regular))
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(on ? Theme.ink : Theme.ink3)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                if on { Rectangle().fill(DashboardStyle.accent).frame(height: 2) }
            }
            .contentShape(Rectangle())   // 整块可点：off tab 背景透明，否则只有图标/文字命中 → 切不回去
        }.buttonStyle(.plain).accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: 主内容滚动容器（量自然高 → 上报主壳做高度自适应；超屏才滚动）
    private var mainScroll: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                header.zIndex(1)
                if showUpdate { updateBar }
                tabbar
                Rectangle().fill(Theme.ink.opacity(0.07)).frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            })
            ZStack(alignment: .top) {
                let covered = navigation.destination != nil
                pageScroll(visible: !covered) { tabContent.id(tab) }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: OriginViewportKey.self, value: covered ? nil : geo.size.height)
                    })
                    .onPreferenceChange(OriginViewportKey.self) { if let height = $0, height > 0 { originViewport = height } }
                    .frame(height: covered ? originViewport : nil, alignment: .top)
                    .frame(height: covered ? 0 : nil, alignment: .top)
                    .opacity(covered ? 0 : 1)
                    .disabled(covered).allowsHitTesting(!covered).accessibilityHidden(covered)
                    .environment(\.analyticsLive, !covered && store.panelVisible && !showSettings && !previewMode)
                if let destination = navigation.destination {
                    pageScroll(visible: true) {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { navigation.back() } label: {
                                Label(L("common.back"), systemImage: "chevron.left")
                            }.buttonStyle(.plain)
                            Text(destination.scopeLabel + " · " + destination.title)
                                .font(.headline).lineLimit(2).textSelection(.enabled)
                            AnalyticsDashboard(agents: destination.visibleAgents(in: usageAgents), scope: destination.scope,
                                               fixture: scopedFixture, days: $scopedDays)
                        }
                    }.id(destination)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { onContentHeight($0) }
    }

    @ViewBuilder private func pageScroll<Content: View>(visible: Bool, @ViewBuilder _ page: () -> Content) -> some View {
        let content = page().padding(.horizontal, 22).padding(.vertical, 12)
            .background(GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: visible ? geo.size.height : 0)
            })
        if previewMode { content }
        else {
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
                    .background(PanelInputRegion(.scrollBody, active: visible))
            }.scrollIndicators(.hidden)
        }
    }

    // MARK: Tab 内容（自然高；超屏由外层 ScrollView 滚动）
    @ViewBuilder private var tabContent: some View {
        if tab == "overview" {
            let showClaude = store.agentOn("claude", fallbackHidden: store.quota?.claude?.hidden)
            let showCodex = store.agentOn("codex", fallbackHidden: store.quota?.codex?.hidden)
            let showQoder = store.agentOn("qoder", fallbackHidden: store.quota?.qoder?.hidden)
            let showQoderCN = store.agentOn(
                "qoder_cn", fallbackHidden: store.quota?.qoderCn?.hidden)
            OverviewView(
                quota: store.quota, usage: store.usage, today: store.today,
                active: store.activeShown, done: store.doneShown, showActive: store.showActive,
                showClaudeAgent: showClaude, showCodexAgent: showCodex,
                showQoderAgent: showQoder, showQoderCNAgent: showQoderCN,
                showAntigravityAgent: store.agentOn("antigravity"),
                analyticsAgents: usageAgents,
                quotaAutoRotate: (store.settings["quota_auto_rotate"]?.boolVal ?? true)
                    && !store.menubarRotationActive,
                quotaRotateSecs: store.settings["quota_rotate_secs"]?.intVal ?? 6,
                carouselActive: tab == "overview" && !showSettings,
                analyticsActive: store.panelVisible && !showSettings && !previewMode,
                quotaSelectionID: store.quotaSelectionID,
                onSelectQuota: { store.selectQuotaPage($0, notifyMenubar: true) },
                onQuotaRotationPauseChange: { store.setQuotaRotationPaused($0) },
                onFocusActive: focusActive, onFocusDone: focusDone,
                onViewUsage: { analyticsDays = 1; navigation.select("usage") })
        } else if tab == "sessions" {
            sessionsCard
        } else if tab == "projects" {
            ProjectsView(agents: dashboardAgents, analyticsAgents: usageAgents,
                         isActive: store.panelVisible && !showSettings && navigation.destination == nil,
                         showActive: store.showActive, refreshSeconds: store.settings["refresh_interval"]?.intVal ?? 30,
                         previewProjects: previewMode ? PreviewRender.dashboardProjects : nil,
                         previewSessions: previewMode ? store.sessions : nil,
                         onOpen: focusActive, onResume: resume)
        } else if tab == "usage" {
            AnalyticsDashboard(agents: usageAgents, fixture: previewMode ? (analyticsDays == 1 ? .todayPreview : .preview) : nil,
                               days: $analyticsDays, initialBasis: "recorded", initialMode: .trend)
        }
    }

    private var dashboardAgents: Set<String> {
        Set([store.agentOn("claude", fallbackHidden: store.quota?.claude?.hidden) ? "claude" : nil,
             store.agentOn("codex", fallbackHidden: store.quota?.codex?.hidden) ? "codex" : nil,
             store.agentOn("qoder", fallbackHidden: store.quota?.qoder?.hidden) ? "qoder" : nil,
             store.agentOn("antigravity") ? "antigravity" : nil].compactMap { $0 })
    }

    private var usageAgents: Set<String> {
        dashboardAgents.union(store.agentOn("qoder_cn", fallbackHidden: store.quota?.qoderCn?.hidden) ? ["qoder_cn"] : [])
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            // scrollable:false → 会话列表按自然高展开，由外层 ScrollView 统一滚动（避免嵌套滚动）
            SessionsView(
                sessions: store.sessionsShown, active: store.showActive ? store.activeShown : [],
                onOpenActive: focusActive, scrollable: false,
                query: store.sessionQuery, filter: store.sessionFilter,
                showAntigravity: store.agentOn("antigravity"), total: store.sessionsTotal, hasMore: store.sessionsHasMore,
                page: store.sessionPage, pageCount: store.sessionPageCount,
                pageSize: store.sessionPageSize,
                loading: store.sessionsLoading, indexing: store.sessionsIndexing,
                loadFailed: store.sessionsLoadFailed,
                onResume: resume, onCopy: copyCommand, onPin: pin,
                onRelocate: relocate, onForgetPath: forgetPathMapping,
                loadPreview: { await store.preview($0) },
                onSearch: { store.search($0) },
                onFilter: { store.setSessionFilter($0) },
                onPreviousPage: { store.previousSessionPage() },
                onNextPage: { store.nextSessionPage() },
                onPageSize: { store.setSessionPageSize($0) })
        }
        .task(id: store.panelVisible && !showSettings) {
            if store.panelVisible && !showSettings && navigation.destination == nil && !previewMode {
                store.visitSessionList()
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .reveal(delay: 0.05)
    }

    // MARK: 设置浮层
    private var settingsOverlay: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    IconButton(system: "chevron.left", weight: .semibold, fontSize: 15) {
                        if settingsPage == .agents { settingsPage = .main }
                        else { showSettings = false }
                    }
                    Text(L(settingsPage.titleKey)).font(.rounded(17, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                SettingsView(
                    values: store.settings, scrollable: !previewMode,
                    page: settingsPage,
                    terminals: store.terminals.map { ($0.mode, $0.name) },
                    onSet: { store.setSetting($0, $1) },
                    onAction: settingsAction,
                    onOpenAgentManager: { settingsPage = .agents },
                    onResetColors: { store.resetColors(); showToast(L("set.colorsReset")) },
                    version: version)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
        }
    }

    // MARK: 统计口径弹层
    private func infoPopup(_ kind: InfoKind) -> some View {
        ZStack {
            Rectangle().fill(Color(hex: 0x040409).opacity(0.46)).ignoresSafeArea()
                .background(.ultraThinMaterial)
                .onTapGesture { info = nil }
                .transition(.opacity)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(L("info.title")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    IconButton(system: "xmark", weight: .semibold, fontSize: 11, size: 22) { info = nil }
                        .accessibilityLabel(L("common.close"))
                        .focused($infoCloseFocused)
                        .onAppear { infoCloseFocused = true }
                }
                .padding(.bottom, 9)
                ForEach(Array(infoRows(kind).enumerated()), id: \.offset) { idx, row in
                    if idx > 0 { Divider().overlay(Color.white.opacity(0.07)) }
                    HStack(alignment: .top, spacing: 9) {
                        Text(row.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 40, alignment: .leading)
                        Text(row.1).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineSpacing(2)
                    }
                    .padding(.vertical, 5)
                }
                Text(infoNote).font(.system(size: 9.5)).foregroundStyle(Theme.ink3).lineSpacing(1.5)
                    .padding(.top, 8)
            }
            .padding(16)
            .frame(width: 322)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(DashboardStyle.background)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.edge))
                    .shadow(color: .black.opacity(0.55), radius: 32, y: 14)
            }
            .transition(.scale(scale: 0.93).combined(with: .opacity))   // ipin：缩放弹入（.93→1）
        }
    }

    private var infoNote: String { L("info.note") }

    private func infoRows(_ kind: InfoKind) -> [(String, String)] {
        switch kind {
        case .today:
            var rows: [(String, String)] = [
                (L("info.todayTerm"), L("info.todayText")),
                (L("info.eqTerm"), L("info.eqText")),
                (L("info.momTerm"), L("info.momText")),
            ]
            if let fams = todayFamsText { rows.append((L("info.detailTerm"), fams)) }
            return rows
        case .range(let span):
            guard let usage = store.usage else { return [] }
            let summary = UsageRangeSummary(usage: usage, span: span, visible: usageAgents)
            var rows = [(L("v3.range", ["n": "\(span)"]), summary.tokenText),
                        (L("v3.cost"), summary.cost.map { String(format: "$%.2f", $0) } ?? L("v3.unavailable"))]
            rows += summary.agents.map { (Brand(rawValue: $0.0)?.name ?? $0.0, Fmt.tokens($0.1)) }
            if dashboardAgents.contains("codex"), let missing = usage.coverage?.codexMissingUsageFiles, missing > 0 {
                rows.append(("Codex", L("usage.incomplete", ["count": "\(missing)"])))
            }
            return rows
        case .usage(let mode):
            let first: (String, String) = {
                switch mode {
                case .curve: return (L("info.curveTerm"), L("info.curveText"))
                case .proj:  return (L("info.projTerm"), L("info.projText"))
                case .usage: return (L("info.barTerm"), L("info.barText"))
                }
            }()
            var rows = [first, (L("info.priceTerm"), L("info.priceText"))]
            if let split = costSplitText { rows.append((L("info.splitTerm"), split)) }
            return rows
        }
    }

    private var todayFamsText: String? {
        guard let t = store.today else { return nil }
        let parts = Brand.allCases.compactMap { brand -> String? in
            let v = t.byAgent[brand] ?? 0
            return v > 0 ? "\(brand.name) \(Fmt.tokens(v))" : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var costSplitText: String? {
        guard let u = store.usage else { return nil }
        func r(_ v: Double?) -> String { "\(Int((v ?? 0).rounded()))" }
        return L("usage.costSplit", ["c7": r(u.claudeCost7d), "c30": r(u.claudeCost30d),
                                     "x7": r(u.codexCost7d), "x30": r(u.codexCost30d)])
    }

    // MARK: toast
    private func toastView(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg).font(.system(size: 10.5)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(Color(hex: 0x181820).opacity(0.92))
                    .overlay(Capsule().strokeBorder(Theme.edgeHi)))
                .shadow(color: .black.opacity(0.5), radius: 10, y: 6)
                .padding(.bottom, 18)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var restartLabel: String {
        switch store.gatewayRestart {
        case .idle: return "header.restartGateway"
        case .restarting: return "gateway.restarting"
        case .failed: return "gateway.failed"
        case .foreign: return "gateway.foreign"
        case .restarted: return "gateway.restarted"
        case .recovered: return "gateway.recovered"
        }
    }
    private var restartButtonLabel: String {
        switch store.gatewayRestart {
        case .failed, .foreign, .restarting: return restartLabel
        default: return "header.restartGateway"
        }
    }

    private func showToast(_ msg: String) {
        toastMsg = msg
        toastSeq += 1
        let seq = toastSeq
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if seq == toastSeq { toastMsg = nil }
        }
    }

    // MARK: 动作接线
    private func focusActive(_ a: ActiveSession) {
        Task {
            let ok = await store.focus(tool: a.tool, id: a.id ?? "", cwd: a.cwd ?? "",
                                       pid: a.pid ?? 0, source: a.source)
            if ok { onHidePanel() } else { showToast(L("active.termNotFound", ["err": ""])) }
        }
    }
    private func focusDone(_ e: DoneEvent) {
        Task {
            let ok = await store.focus(tool: e.tool, id: e.session ?? "", cwd: e.cwd ?? "", pid: 0)
            if ok { onHidePanel() } else { showToast(L("active.termNotFound", ["err": ""])) }
        }
    }
    private func resume(_ s: SessionItem) {
        performResume(s, copyOnly: false)
    }
    private func copyCommand(_ s: SessionItem) {
        performResume(s, copyOnly: true)
    }
    private func performResume(_ s: SessionItem, copyOnly: Bool) {
        Task {
            var result = await store.resume(s, copyOnly: copyOnly)
            if result?.needsPath == true {
                let opensQoderApp = s.source == "qoder_app"
                if !opensQoderApp, result?.command == nil {
                    showToast(L(copyOnly ? "session.copyFailed" : "session.resumeFailed"))
                    return
                }
                guard let replacement = chooseReplacementDirectory(
                    originalPath: result?.originalCwd ?? s.cwd ?? "",
                    expectedProject: s.project ?? "") else {
                    if let fallbackCommand = result?.command {
                        showToast(L(copyText(fallbackCommand) != nil
                                    ? "session.pathFallbackCopied" : "session.copyFailed"))
                    }
                    return
                }
                result = await store.resume(
                    s, copyOnly: copyOnly, replacementCwd: replacement)
            }

            if copyOnly {
                guard result?.ok == true, let command = result?.command else {
                    showToast(L("session.copyFailed"))
                    return
                }
                showToast(L(copyText(command) != nil ? "session.cmdCopied" : "session.copyFailed"))
            } else if result?.ok == true, result?.copy == true {
                guard let command = result?.command else {
                    showToast(L("session.resumeFailed"))
                    return
                }
                guard let clipboardGeneration = copyText(command) else {
                    showToast(L("session.copyFailed"))
                    return
                }
                showToast(result?.paste == true
                          ? L("session.openedPaste", ["app": result?.app ?? ""])
                          : L("session.cmdCopied"))
                if result?.paste == true, result?.autoPaste == true {
                    onHidePanel()
                    onPasteEnter(result?.terminal ?? "", clipboardGeneration)
                }
            } else {
                showToast(result?.opened == true ? L("session.openedApp", ["app": result?.app ?? "Qoder"])
                          : result?.ok == true ? L("session.resumed")
                          : L("session.resumeFailedReason", ["err": result?.error ?? ""]))
            }
        }
    }
    private func relocate(_ s: SessionItem) {
        guard let originalPath = s.cwd, !originalPath.isEmpty,
              let replacement = chooseReplacementDirectory(
                originalPath: originalPath, expectedProject: s.project ?? "") else { return }
        Task {
            let ok = await store.setPathMapping(
                originalCwd: originalPath, replacementCwd: replacement)
            showToast(L(ok ? "session.pathMapped" : "session.pathMappingFailed"))
        }
    }
    private func forgetPathMapping(_ s: SessionItem) {
        guard let originalPath = s.cwd, !originalPath.isEmpty else { return }
        Task {
            let ok = await store.removePathMapping(originalCwd: originalPath)
            showToast(L(ok ? "session.pathForgotten" : "session.pathMappingFailed"))
        }
    }
    private func chooseReplacementDirectory(
        originalPath: String, expectedProject: String
    ) -> String? {
        let panel = NSOpenPanel()
        panel.title = L("session.pathMovedTitle")
        panel.message = L("session.pathMovedMessage", ["path": originalPath])
        panel.prompt = L("session.chooseFolder")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = nearestExistingParent(of: originalPath)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        if !expectedProject.isEmpty, selected.lastPathComponent != expectedProject {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L("session.pathMismatchTitle")
            alert.informativeText = L("session.pathMismatchMessage", [
                "expected": expectedProject, "selected": selected.lastPathComponent,
            ])
            alert.addButton(withTitle: L("session.useFolder"))
            alert.addButton(withTitle: L("session.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }
        return selected.path
    }
    private func nearestExistingParent(of path: String) -> URL {
        var candidate = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    private func pin(_ s: SessionItem) {
        let wasPinned = s.pinned == true
        Task { await store.pin(s); showToast(L(wasPinned ? "session.unpinned" : "session.pinned")) }
    }
    private func copyText(_ s: String) -> Int? {
        AutoPastePolicy.copyCommand(s)
    }

    private func settingsAction(_ act: String) {
        switch act {
        case "check_update":
            Task {
                await store.checkUpdate()
                if store.updateAvailable {
                    dismissedUpdateVersion = nil
                    showSettings = false
                    showToast(L("update.available", ["v": "v\(store.update?.latest ?? "")"]))
                } else {
                    showToast(L(store.update == nil || store.update?.error == true
                                ? "update.checkFail" : "update.latest"))
                }
            }
        case "feedback_github", "feedback_email":
            // 仅预填版本号；不带任何账号/路径，用户自填正文。
            func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "" }
            let subject = enc(L("feedback.subject", ["v": version]))
            let body = enc(L("feedback.body", ["v": version]))
            onOpenExternal(act == "feedback_github"
                ? "https://github.com/Spacebody/AgentDeck/issues/new?title=\(subject)&body=\(body)"
                : "mailto:jerry_zyl@hotmail.com?subject=\(subject)&body=\(body)")
        default:   // open / export / clear_events → POST /api/data
            Task {
                let (ok, err) = await store.dataAction(act)
                let keys = ["open": "set.openedData", "export": "set.csvExported", "clear_events": "set.eventsCleared"]
                showToast(ok ? L(keys[act] ?? "common.opFailed")
                          : L("common.opFailed") + (err.map { "：\($0)" } ?? ""))
            }
        }
    }
}

// MARK: - 桌面小组件根视图
public struct AgentDeckWidgetRootView: View {
    @ObservedObject var store: AppStore
    var onTapPanel: () -> Void
    var onHidePanel: () -> Void

    public init(store: AppStore, onTapPanel: @escaping () -> Void = {},
                onHidePanel: @escaping () -> Void = {}) {
        self.store = store; self.onTapPanel = onTapPanel; self.onHidePanel = onHidePanel
    }

    private var minimal: Bool { store.settings["minimal_mode"]?.boolVal ?? false }
    private var fontScale: CGFloat {
        min(max(CGFloat(store.settings["font_scale"]?.intVal ?? 100) / 100, 0.8), 1.6)
    }

    public var body: some View {
        ScaledContainer(scale: fontScale) {
            ZStack(alignment: .top) {
                DashboardStyle.background.opacity(0.93).ignoresSafeArea()
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 28, height: 3.5)
                    .padding(.top, 7).frame(maxWidth: .infinity, alignment: .center)
                WidgetView(
                    quota: store.quota, today: store.today, active: store.activeShown,
                    showActive: store.showActive,
                    showClaudeAgent: store.agentOn("claude", fallbackHidden: store.quota?.claude?.hidden),
                    showCodexAgent: store.agentOn("codex", fallbackHidden: store.quota?.codex?.hidden),
                    showQoderAgent: store.agentOn("qoder", fallbackHidden: store.quota?.qoder?.hidden),
                    showQoderCNAgent: store.agentOn(
                        "qoder_cn", fallbackHidden: store.quota?.qoderCn?.hidden),
                    showAntigravityAgent: store.agentOn("antigravity"),
                    onTapPanel: onTapPanel,
                    onFocusActive: { a in
                        // 小组件常驻桌面：跳转成功不收起自身
                        Task { _ = await store.focus(tool: a.tool, id: a.id ?? "", cwd: a.cwd ?? "", pid: a.pid ?? 0) }
                    })
                .padding(EdgeInsets(top: 18, leading: 10, bottom: 8, trailing: 10))
                .environment(\.sessionPerformanceStore, store.performance)
                .environment(\.samplingStore, store)
            }
            .environment(\.minimalMode, minimal)
        }
        .preferredColorScheme(.dark)
    }
}
