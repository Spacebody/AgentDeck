// 生成 DMG 安装窗口背景图（540x360 @2x，深色玻璃风 + 安装指引箭头）
// 用法: swift scripts/makedmgbg.swift <输出 png 路径>
import Cocoa

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "bg.png"
let W: CGFloat = 540, H: CGFloat = 360, SCALE: CGFloat = 2

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(W * SCALE), pixelsHigh: Int(H * SCALE),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
rep.size = NSSize(width: W, height: H)   // 点尺寸 540x360 → Retina 2x

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: W, height: H)

// 深色底 + 弥散渐变（与 App 同色系）
NSColor(calibratedRed: 0.028, green: 0.028, blue: 0.055, alpha: 1).setFill()
rect.fill()
let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
    (0.12, 0.95, 0.65, NSColor(red: 0.69, green: 0.23, blue: 0.36, alpha: 0.55)),
    (0.95, 0.75, 0.60, NSColor(red: 0.19, green: 0.24, blue: 0.58, alpha: 0.50)),
    (0.55, 0.05, 0.55, NSColor(red: 0.56, green: 0.36, blue: 0.18, alpha: 0.35)),
    (0.05, 0.15, 0.45, NSColor(red: 0.12, green: 0.45, blue: 0.40, alpha: 0.40)),
]
for (cx, cy, rad, color) in blobs {
    let c = NSPoint(x: W * cx, y: H * cy)
    NSGradient(starting: color, ending: color.withAlphaComponent(0))?
        .draw(fromCenter: c, radius: 0, toCenter: c, radius: W * rad,
              options: .drawsAfterEndingLocation)
}

// 标题（注意 AppKit 坐标 y 从下往上；图标行约在窗口上半部）
func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight,
              color: NSColor, centerX: CGFloat, y: CGFloat) {
    let attr: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ]
    let t = NSAttributedString(string: s, attributes: attr)
    t.draw(at: NSPoint(x: centerX - t.size().width / 2, y: y))
}
drawText("AgentDeck", size: 22, weight: .bold,
         color: NSColor(white: 1, alpha: 0.92), centerX: W / 2, y: H - 56)
drawText("拖动到 Applications 完成安装", size: 12, weight: .regular,
         color: NSColor(white: 1, alpha: 0.45), centerX: W / 2, y: H - 78)

// 指引箭头：图标行（Finder y≈185 → AppKit y≈H-185）两图标之间
let ay = H - 185
let path = NSBezierPath()
path.move(to: NSPoint(x: 215, y: ay))
path.line(to: NSPoint(x: 305, y: ay))
path.lineWidth = 5
path.lineCapStyle = .round
NSColor(white: 1, alpha: 0.30).setStroke()
path.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 300, y: ay + 12))
head.line(to: NSPoint(x: 322, y: ay))
head.line(to: NSPoint(x: 300, y: ay - 12))
head.lineWidth = 5
head.lineCapStyle = .round
head.lineJoinStyle = .round
NSColor(white: 1, alpha: 0.30).setStroke()
head.stroke()

NSGraphicsContext.restoreGraphicsState()
try? rep.representation(using: .png, properties: [:])?
    .write(to: URL(fileURLWithPath: out))
print("dmg background written to \(out)")
