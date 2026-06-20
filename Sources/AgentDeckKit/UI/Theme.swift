// AgentDeck v2 — 设计系统。把 static/index.html 的 :root CSS 变量与玻璃/aurora
// 视觉语言译成原生 SwiftUI。颜色/圆角/字体 token 与 v1 对齐，便于逐屏比对。
import SwiftUI
import AppKit

// 玻璃渲染开关：真机用原生 NSVisualEffectView；无头 PreviewGen（ImageRenderer 渲不出 NSView，
// 会出红色禁止符占位）切到 SwiftUI 材质，保留 PNG 自检能力。
enum GlassRender { static var useNativeEffect = true }

// MARK: - 原生玻璃背板（NSVisualEffectView）。SwiftUI 的 .ultraThin/.thinMaterial 只近似，
// 要复刻 v1 的 backdrop-filter blur(36) saturate(190) 真磨砂，得用 AppKit 的视觉效果视图。
// withinWindow 混合：采样卡片在窗内身后的内容（面板玻璃 + scrim + aurora），= v1 卡片观感。
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

// MARK: - 颜色 token（对应 index.html :root，白底叠加用 opacity 表达 rgba(255,255,255,a)）
enum Theme {
    static let bg      = Color(red: 0x07/255, green: 0x07/255, blue: 0x0c/255)  // --bg #07070c

    // 文字三级灰（--ink / --ink-2 / --ink-3）
    static let ink     = Color.white.opacity(0.96)
    static let ink2    = Color.white.opacity(0.78)
    static let ink3    = Color.white.opacity(0.58)

    // 玻璃面/描边（--glass / --glass-hi / --edge / --edge-hi）
    static let glass   = Color.white.opacity(0.055)
    static let glassHi = Color.white.opacity(0.09)
    static let edge    = Color.white.opacity(0.10)
    static let edgeHi  = Color.white.opacity(0.16)

    // 状态色（--ok / --warn / --danger）
    static let ok      = Color(hex: 0x7ee2a8)
    static let warn    = Color(hex: 0xffc46b)
    static let danger  = Color(hex: 0xff7a8a)

    // 圆角（--r-lg / --r-md / --r-sm；同心圆角：卡片 24 − 内边距 12 = 12）
    static let rLg: CGFloat = 24
    static let rMd: CGFloat = 12
    static let rSm: CGFloat = 11
}

// MARK: - 品牌（Claude / Codex）配色。accent 为用户可在设置中自定义的主色（--claude/--codex），
// 此处给默认值；接入 store 后由设置覆盖。deep 为渐变深端，tint 为卡片辉光底色。
enum Brand: String, CaseIterable {
    case claude, codex

    // 默认主色（--claude #ff9d7a / --codex #8be9e2）
    /// 用户自定义主色覆盖（设置 color_claude/color_codex；AppStore.applyCustomColors 写入）。
    static var customAccents: [Brand: Color?] = [:]
    var accent: Color {
        if let c = Brand.customAccents[self] ?? nil { return c }
        return self == .claude ? Color(hex: 0xff9d7a) : Color(hex: 0x8be9e2)
    }
    // 渐变深端（--claude-deep #e8744f / --codex-deep #4fd1c5）
    var deep: Color   { self == .claude ? Color(hex: 0xe8744f) : Color(hex: 0x4fd1c5) }
    // 卡片右上角辉光（qcard::before：claude .22 / codex .18 透明度）
    var tint: Color   { self == .claude ? Color(hex: 0xe8744f).opacity(0.22)
                                        : Color(hex: 0x4fd1c5).opacity(0.18) }
    // 进度环/进度条渐变（90deg/对角：deep → accent）
    var gradient: LinearGradient {
        LinearGradient(colors: [deep, accent], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - 告警/危险渐变（对应 SVG grad-warn / grad-danger 与 .wbar i.warn/.danger）
extension Theme {
    static let warnGradient = LinearGradient(
        colors: [Color(hex: 0xffd28a), Color(hex: 0xe8a04f)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let dangerGradient = LinearGradient(
        colors: [Color(hex: 0xff9aa8), Color(hex: 0xe84f68)], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 按窗口阈值挑渐变：危险 → danger，告警 → warn，否则品牌色。
    static func gradient(for level: QuotaWindow.Level, brand: Brand) -> LinearGradient {
        switch level {
        case .danger: return dangerGradient
        case .warn:   return warnGradient
        case .normal: return brand.gradient
        }
    }
}

// MARK: - 精简模式环境键（body.minimal）。在根视图按设置注入，玻璃卡/控件据此降噪。
private struct MinimalModeKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var minimalMode: Bool {
        get { self[MinimalModeKey.self] }
        set { self[MinimalModeKey.self] = newValue }
    }
}

// MARK: - 玻璃卡（对应 .card：白渐变高光 + 模糊背板 + 描边 + 投影 + 内嵌镜面线）
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.rLg
    /// 精简模式：去渐变高光与内嵌镜面线，降视觉噪声（body.minimal .card）。
    /// 默认跟随环境 minimalMode（根视图按设置注入），整树一致切换。
    @Environment(\.minimalMode) private var minimal

    func body(content: Content) -> some View {
        content
            .background {
                if minimal {
                    // 精简模式：平面浅白底，无磨砂（对应 body.minimal .card）
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                } else {
                    ZStack {
                        // 真磨砂：NSVisualEffectView（withinWindow）采样身后玻璃+scrim+aurora（≈ v1 backdrop-filter）。
                        // 无头预览回退 thinMaterial（ImageRenderer 渲不出 NSView）。
                        if GlassRender.useNativeEffect {
                            VisualEffectBackground()
                        } else {
                            Rectangle().fill(.thinMaterial)
                        }
                        // 顶亮底暗白渐变（linear-gradient(180deg, .085 → .04)），给文字一层可读性底
                        LinearGradient(colors: [Color.white.opacity(0.085), Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                }
            }
            .overlay {
                // 描边：顶亮→底暗的渐变环，复刻 v1 .card 的 inset 0 1px rgba(255,255,255,.22) 镜面高光，
                // 给玻璃「液态」质感（精简模式收敛为近匀色）。
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: minimal
                                ? [Color.white.opacity(0.12), Color.white.opacity(0.06)]
                                : [Color.white.opacity(0.30), Color.white.opacity(0.12), Color.black.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
            }
            .shadow(color: .black.opacity(minimal ? 0.28 : 0.35),
                    radius: minimal ? 11 : 16, x: 0, y: minimal ? 8 : 12)
    }
}

extension View {
    /// 玻璃卡样式（.card）。radius 默认 24；精简模式由环境 minimalMode 驱动。
    func glassCard(radius: CGFloat = Theme.rLg) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

// MARK: - aurora 弥散流动背景（#aurora：四团径向渐变 + 缓慢漂移）
struct AuroraBackground: View {
    /// 整体透明度：主面板 .72；native .18；minimal 隐藏；widget .14（对应各 body 态）
    var opacity: Double = 0.72
    @State private var drift = false

    private struct Blob: Identifiable {
        let id = UUID()
        let color: Color
        let size: CGFloat        // 占较短边比例
        let x: CGFloat; let y: CGFloat   // 锚点（0~1）
        let dx: CGFloat; let dy: CGFloat // 漂移目标位移比例
        let period: Double
    }

    // b1 红 / b2 蓝 / b3 棕 / b4 绿，与 CSS 的 4 团对应（位置/尺寸近似）
    private let blobs: [Blob] = [
        .init(color: Color(hex: 0xb03a5b), size: 0.56, x: -0.08, y: -0.12, dx: 0.09, dy: 0.07, period: 26),
        .init(color: Color(hex: 0x2d3a8c), size: 0.48, x: 0.90, y: 0.16, dx: -0.07, dy: 0.09, period: 32),
        .init(color: Color(hex: 0x8c5a2d), size: 0.44, x: 0.12, y: 1.10, dx: 0.06, dy: -0.08, period: 38),
        .init(color: Color(hex: 0x1f6e63), size: 0.30, x: 0.82, y: 0.96, dx: 0.07, dy: 0.05, period: 44),
    ]

    var body: some View {
        GeometryReader { geo in
            let minSide = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(blobs) { b in
                    let d = max(geo.size.width, geo.size.height) * b.size
                    Circle()
                        // v1 每团 opacity .72（容器再 .18），核心实色到 ~55% 再淡出（透明 65%）。
                        // 之前用满透明度 → aurora 比 v1 浓约 40%，背景发糊压低文字对比。对齐 v1。
                        .fill(RadialGradient(
                            stops: [.init(color: b.color.opacity(0.72), location: 0),
                                    .init(color: b.color.opacity(0.72), location: 0.5),
                                    .init(color: b.color.opacity(0), location: 1)],
                            center: .center, startRadius: 0, endRadius: d * 0.5))
                        .frame(width: d, height: d)
                        .position(x: geo.size.width * b.x + (drift ? minSide * b.dx : 0),
                                  y: geo.size.height * b.y + (drift ? minSide * b.dy : 0))
                        .animation(.easeInOut(duration: b.period).repeatForever(autoreverses: true), value: drift)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .blur(radius: 70)
            .saturation(1.5)
            .drawingGroup()   // Metal 离屏合成：blur/saturation 走 GPU，drift 不再每帧 CPU 重算（消抖）
            .opacity(opacity)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
        .allowsHitTesting(false)
    }
}

// MARK: - 入场动画（.reveal：淡入 + 上滑 10px，错峰延时）
// v1: animation: in .55s cubic-bezier(.2,.7,.2,1) backwards; @keyframes in { from { opacity:0; translateY(10px) } }
// 各元素 animation-delay 错峰（header 0 / tabbar .03 / quota .05 / today .06 / active .09 / done .1 / usage·sess .12）。
// 精简模式（body.minimal .reveal）禁用；无头渲染（PreviewGen，onAppear 不触发）直接呈现，避免 PNG 全透明。
struct Reveal: ViewModifier {
    var delay: Double = 0
    var distance: CGFloat = 10
    var duration: Double = 0.55
    @Environment(\.minimalMode) private var minimal
    @State private var shown = false

    // 无头渲染时（ImageRenderer）onAppear 不跑，直接当作已呈现。
    private var skip: Bool { minimal || !GlassRender.useNativeEffect }

    func body(content: Content) -> some View {
        content
            .opacity(skip || shown ? 1 : 0)
            .offset(y: skip || shown ? 0 : distance)
            .onAppear {
                guard !skip else { return }
                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: duration).delay(delay)) { shown = true }
            }
    }
}

// MARK: - 悬浮微交互（.iconbtn / .ubgo 等 :hover { transform: translateY(-1px) }，transition .18s）
struct HoverLift: ViewModifier {
    var lift: CGFloat = 1
    @Environment(\.minimalMode) private var minimal
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .offset(y: (hovering && !minimal) ? -lift : 0)
            .animation(.easeOut(duration: 0.18), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 入场动画：淡入 + 上滑（对应 v1 .reveal）。delay 做错峰；精简/无头自动跳过。
    func reveal(delay: Double = 0, distance: CGFloat = 10, duration: Double = 0.55) -> some View {
        modifier(Reveal(delay: delay, distance: distance, duration: duration))
    }
    /// 悬浮上移 1px（对应 v1 :hover translateY(-1px)）；精简模式禁用。
    func hoverLift(_ lift: CGFloat = 1) -> some View {
        modifier(HoverLift(lift: lift))
    }
}

// MARK: - 工具：16 进制 → Color
extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue:  Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

// MARK: - 字体助手（数字用 SF Pro Rounded，对应 ui-rounded）
extension Font {
    /// 圆体（百分比/数值），对应 CSS 的 "SF Pro Rounded", ui-rounded
    static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
