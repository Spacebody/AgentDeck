// AgentDeck v2 — 设计系统。把 static/index.html 的 :root CSS 变量与玻璃/aurora
// 视觉语言译成原生 SwiftUI。颜色/圆角/字体 token 与 v1 对齐，便于逐屏比对。
import SwiftUI

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
    var accent: Color { self == .claude ? Color(hex: 0xff9d7a) : Color(hex: 0x8be9e2) }
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

// MARK: - 玻璃卡（对应 .card：白渐变高光 + 模糊背板 + 描边 + 投影 + 内嵌镜面线）
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.rLg
    /// 精简模式：去渐变高光与内嵌镜面线，降视觉噪声（body.minimal .card）
    var minimal: Bool = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)   // 模糊背板（≈ backdrop-filter blur）
                    .overlay {
                        if !minimal {
                            // 顶亮底暗白渐变（linear-gradient(180deg, .085 → .04)）
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .fill(LinearGradient(
                                    colors: [Color.white.opacity(0.085), Color.white.opacity(0.04)],
                                    startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .overlay {   // 描边（rgba(255,255,255,.13) / minimal .09）
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(minimal ? 0.09 : 0.13), lineWidth: 1)
                    }
            }
            .shadow(color: .black.opacity(minimal ? 0.28 : 0.35),
                    radius: minimal ? 11 : 16, x: 0, y: minimal ? 8 : 12)
    }
}

extension View {
    /// 玻璃卡样式（.card）。radius 默认 24；minimal 对应精简模式降噪。
    func glassCard(radius: CGFloat = Theme.rLg, minimal: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, minimal: minimal))
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
                        .fill(RadialGradient(colors: [b.color, b.color.opacity(0)],
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
            .opacity(opacity)
        }
        .ignoresSafeArea()
        .onAppear { drift = true }
        .allowsHitTesting(false)
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
