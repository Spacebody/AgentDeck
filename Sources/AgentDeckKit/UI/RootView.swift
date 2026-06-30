// AgentDeck v2 — 应用外壳（#4+#10）。复刻 index.html 的 body 结构：
// 顶栏(logo/live/设置/刷新) + 更新横幅 + 双 tab(概览/会话) + 设置右滑浮层 + 统计口径弹层 + toast。
// 把 store 数据与动作闭包接入各视图；主壳(main.swift)以 NSHostingView 承载本视图，退役 WebView。
import SwiftUI

// MARK: - 统计口径弹层种类（today 摘要 / usage 当前视图）
enum InfoKind: Equatable { case today; case usage(UsageMode) }

// MARK: - 主内容自然高度（驱动面板高度自适应，消除底部空隙）
private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
            .background(Circle().fill(bg))
            .overlay(Circle().strokeBorder(border))
            .offset(y: hover ? -1 : 0)                      // :hover translateY(-1px)
    }
}

// MARK: - 应用根视图（主面板）
public struct AgentDeckRootView: View {
    @ObservedObject var store: AppStore
    var version: String
    var onQuit: () -> Void
    var onOpenExternal: (String) -> Void
    var onPasteEnter: () -> Void
    var onHidePanel: () -> Void
    /// 字体大小变更（驱动主壳同步缩放窗口，保持有效布局宽度）。
    var onScale: (CGFloat) -> Void
    /// 内容自然高度变化（驱动主壳把面板高度自适应到内容，去掉底部空隙）。
    var onContentHeight: (CGFloat) -> Void
    /// 预览模式：用 VStack 取代 ScrollView（ImageRenderer 渲不了滚动内容）。
    var previewMode: Bool

    public init(store: AppStore, version: String = "dev",
                onQuit: @escaping () -> Void = {},
                onOpenExternal: @escaping (String) -> Void = { _ in },
                onPasteEnter: @escaping () -> Void = {},
                onHidePanel: @escaping () -> Void = {},
                onScale: @escaping (CGFloat) -> Void = { _ in },
                onContentHeight: @escaping (CGFloat) -> Void = { _ in }) {
        self.store = store; self.version = version
        self.onQuit = onQuit; self.onOpenExternal = onOpenExternal
        self.onPasteEnter = onPasteEnter; self.onHidePanel = onHidePanel
        self.onScale = onScale; self.onContentHeight = onContentHeight
        self.previewMode = false
    }

    // 内部预览构造（PreviewRender 用，非 public）。
    init(previewStore: AppStore, version: String) {
        self.store = previewStore; self.version = version
        self.onQuit = {}; self.onOpenExternal = { _ in }; self.onPasteEnter = {}; self.onHidePanel = {}
        self.onScale = { _ in }; self.onContentHeight = { _ in }
        self.previewMode = true
    }

    @State private var tab = "overview"
    @State private var showSettings = false
    @State private var info: InfoKind?
    @State private var updateDismissed = false
    @State private var spinning = false
    @State private var toastMsg: String?
    @State private var toastSeq = 0

    private var minimal: Bool { store.settings["minimal_mode"]?.boolVal ?? false }
    private var dim: Double { Double(store.settings["glass_dim"]?.intVal ?? 68) / 100 }
    private var showUpdate: Bool { store.updateAvailable && !updateDismissed }
    private var fontScale: CGFloat {
        min(max(CGFloat(store.settings["font_scale"]?.intVal ?? 100) / 100, 0.8), 1.6)
    }

    public var body: some View {
        // 字体缩放：内容在「基准宽度」(窗口/scale)布局后整体放大，等价 v1 的 zoom；窗口由主壳同步扩大。
        ScaledContainer(scale: fontScale) {
            ZStack(alignment: .top) {
                background
                mainScroll   // 内容自然高 + 量高上报（主壳据此把面板高度自适应到内容）

                // 设置右滑浮层
                if showSettings { settingsOverlay.transition(.move(edge: .trailing)) }
                // 统计口径弹层
                if let info { infoPopup(info) }
                // toast
                if let msg = toastMsg { toastView(msg) }
            }
            .environment(\.minimalMode, minimal)
            .environment(\.adShowInfo, { info = $0 })
            .animation(.spring(response: 0.32, dampingFraction: 0.85), value: showSettings)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: info)   // ipin 轻微过冲
            .animation(.easeOut(duration: 0.2), value: toastMsg)
        }
        .preferredColorScheme(.dark)
        .onChange(of: fontScale) { onScale($0) }
    }

    // MARK: 背景（native：系统玻璃之上叠暗化 scrim + 弱 aurora；精简模式去 aurora）
    @ViewBuilder private var background: some View {
        if previewMode { Theme.bg }   // 预览无 NSVisualEffectView，垫底色
        LinearGradient(colors: [Color(hex: 0x08080e).opacity(max(0, dim - 0.13)),
                                Color(hex: 0x08080e).opacity(dim)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        if !minimal { AuroraBackground(opacity: 0.18) }
    }

    // MARK: 顶栏
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                Text("Agent").foregroundStyle(Theme.ink)
                Text("Deck").foregroundStyle(
                    LinearGradient(colors: [Brand.claude.accent, Brand.codex.accent],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .font(.rounded(17, weight: .bold))
            Circle()
                .fill(store.online ? Theme.ok : Theme.danger)
                .frame(width: 7, height: 7)
                .shadow(color: store.online ? Theme.ok : Theme.danger, radius: 4)
                .pulse(store.online ? 2.4 : .infinity)   // .live 呼吸 2.4s；离线(err) 不闪
            Spacer()
            IconButton(system: "gearshape", fontSize: 16) { showSettings = true }
            IconButton(system: "arrow.clockwise", weight: .semibold, fontSize: 15, spinning: spinning, customRefresh: true) { manualRefresh() }
            // 原生壳里显示退出按钮（对应 v1：bridge 存在时 #quit 显示）。
            IconButton(system: "power", weight: .semibold, fontSize: 15, danger: true) { onQuit() }
        }
    }

    private func manualRefresh() {
        spinning = true
        Task {
            await store.refresh(force: true)   // 手动刷新强制重采额度（绕过缓存，对应 v1 force=1）
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
                    Text(L("update.installFail"))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0xff7a8a))
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
            }.buttonStyle(.plain).hoverLift().disabled(installing)
            Button { updateDismissed = true } label: {
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
        HStack(spacing: 3) {
            tabButton("overview", icon: "chart.bar.fill", label: L("tab.overview"))
            tabButton("sessions", icon: "bubble.left.fill", label: L("tab.sessions"))
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.glass)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.edge))
        }
    }

    private func tabButton(_ id: String, icon: String, label: String) -> some View {
        let on = tab == id
        return Button { tab = id } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.3)
            }
            .foregroundStyle(on ? Theme.ink : Theme.ink3)
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.12))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
            }
            .contentShape(Rectangle())   // 整块可点：off tab 背景透明，否则只有图标/文字命中 → 切不回去
        }.buttonStyle(.plain)
    }

    // MARK: 主内容滚动容器（量自然高 → 上报主壳做高度自适应；超屏才滚动）
    private var mainScroll: some View {
        let content = VStack(spacing: 10) {
            header.reveal(delay: 0)
            if showUpdate { updateBar }
            tabbar.reveal(delay: 0.03)
            tabContent
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(GeometryReader { g in
            Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
        })

        return Group {
            if previewMode { content }
            else { ScrollView { content }.scrollIndicators(.hidden) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { onContentHeight($0) }
    }

    // MARK: Tab 内容（自然高；超屏由外层 ScrollView 滚动）
    @ViewBuilder private var tabContent: some View {
        if tab == "overview" {
            OverviewView(
                quota: store.quota, usage: store.usage, today: store.today,
                active: store.activeShown, done: store.doneShown, showActive: store.showActive,
                onFocusActive: focusActive, onFocusDone: focusDone)
        } else {
            sessionsCard
        }
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            // scrollable:false → 会话列表按自然高展开，由外层 ScrollView 统一滚动（避免嵌套滚动）
            SessionsView(
                sessions: store.sessionsShown, scrollable: false,
                onResume: resume, onCopy: copyCommand, onPin: pin,
                loadPreview: { await store.preview($0) },
                onSearch: { store.search($0) })
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .glassCard()
        .reveal(delay: 0.05)
    }

    // MARK: 设置浮层
    private var settingsOverlay: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(Color(hex: 0x07070c).opacity(0.66)).ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    IconButton(system: "chevron.left", weight: .semibold, fontSize: 15) { showSettings = false }
                    Text(L("header.settings")).font(.rounded(17, weight: .bold)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                SettingsView(
                    values: store.settings, scrollable: !previewMode,
                    terminals: store.terminals.map { ($0.mode, $0.name) },
                    onSet: { store.setSetting($0, $1) },
                    onAction: settingsAction,
                    onResetColors: { store.resetColors(); showToast(L("set.colorsReset")) },
                    version: version)
            }
            .padding(14)
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
            .padding(EdgeInsets(top: 15, leading: 17, bottom: 13, trailing: 17))
            .frame(width: 322)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0x2c2c3a).opacity(0.94), Color(hex: 0x1a1a24).opacity(0.96)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15)))
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
        let parts = TodaySummary.Family.allCases.compactMap { f -> String? in
            let v = t.byFamily[f] ?? 0
            return v > 0 ? "\(f.rawValue) \(Fmt.tokens(v))" : nil
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
            let ok = await store.focus(tool: a.tool, id: a.id ?? "", cwd: a.cwd ?? "", pid: a.pid ?? 0)
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
        Task {
            let r = await store.resume(s)
            if r?.ok == true, r?.copy == true {
                copyText(r?.command ?? s.resumeCommand)
                showToast(r?.paste == true ? L("session.openedPaste", ["app": r?.app ?? ""]) : L("session.cmdCopied"))
                if r?.paste == true, r?.autoPaste == true { onHidePanel(); onPasteEnter() }
            } else {
                showToast(r?.ok == true ? L("session.resumed")
                          : L("session.resumeFailedReason", ["err": r?.error ?? ""]))
            }
        }
    }
    private func copyCommand(_ s: SessionItem) { copyText(s.resumeCommand); showToast(L("session.cmdCopied")) }
    private func pin(_ s: SessionItem) {
        let wasPinned = s.pinned == true
        Task { await store.pin(s); showToast(L(wasPinned ? "session.unpinned" : "session.pinned")) }
    }
    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func settingsAction(_ act: String) {
        switch act {
        case "check_update":
            Task {
                await store.checkUpdate()
                if store.updateAvailable {
                    updateDismissed = false
                    showToast(L("update.available", ["v": "v\(store.update?.latest ?? "")"]))
                } else {
                    showToast(L(store.update?.available == nil ? "update.checkFail" : "update.latest"))
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
                // 小组件顶部 grip 提示（弱化，更接近原生小组件的干净表面）
                Capsule().fill(Color.white.opacity(0.16)).frame(width: 28, height: 3.5)
                    .padding(.top, 7).frame(maxWidth: .infinity, alignment: .center)
                WidgetView(
                    quota: store.quota, today: store.today, active: store.activeShown,
                    showActive: store.showActive,
                    onTapPanel: onTapPanel,
                    onFocusActive: { a in
                        // 小组件常驻桌面：跳转成功不收起自身
                        Task { _ = await store.focus(tool: a.tool, id: a.id ?? "", cwd: a.cwd ?? "", pid: a.pid ?? 0) }
                    })
                .padding(EdgeInsets(top: 18, leading: 10, bottom: 8, trailing: 10))
            }
            .environment(\.minimalMode, minimal)
        }
        .preferredColorScheme(.dark)
    }
}
