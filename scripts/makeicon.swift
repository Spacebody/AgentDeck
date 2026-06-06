// 生成 AgentDeck.icns：深色圆角方块 + 品牌双色弥散 + 双 agent 活动环
// 设计语言与面板一致：外环 Claude 珊瑚橙 / 内环 Codex 青，呼应额度环 UI
// 用法: swift scripts/makeicon.swift <输出目录>
import Cocoa

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets"
let fm = FileManager.default
let iconset = "\(outDir)/AgentDeck.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func renderBase(_ size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        // Big Sur 规范：留边 + 大圆角
        let margin = size * 0.097
        let box = rect.insetBy(dx: margin, dy: margin)
        let path = NSBezierPath(roundedRect: box,
                                xRadius: size * 0.2256, yRadius: size * 0.2256)
        path.addClip()
        NSColor(calibratedRed: 0.027, green: 0.027, blue: 0.055, alpha: 1).setFill()
        rect.fill()
        // 品牌双色弥散：左上珊瑚橙 / 右下青，少量蓝紫过渡（收敛配色，避免浑浊）
        let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
            (0.15, 0.90, 0.70, NSColor(red: 0.91, green: 0.42, blue: 0.30, alpha: 0.60)),
            (0.88, 0.08, 0.66, NSColor(red: 0.26, green: 0.76, blue: 0.72, alpha: 0.48)),
            (0.88, 0.88, 0.55, NSColor(red: 0.32, green: 0.32, blue: 0.70, alpha: 0.55)),
        ]
        for (cx, cy, rad, color) in blobs {
            let center = NSPoint(x: box.minX + box.width * cx,
                                 y: box.minY + box.height * cy)
            NSGradient(starting: color, ending: color.withAlphaComponent(0))?
                .draw(fromCenter: center, radius: 0,
                      toCenter: center, radius: size * rad,
                      options: .drawsAfterEndingLocation)
        }

        // 双 agent 活动环（与面板额度环同构）
        let c = NSPoint(x: rect.midX, y: rect.midY)
        let lw = size * 0.072
        func ring(_ radius: CGFloat, _ color: NSColor,
                  from start: CGFloat, to end: CGFloat) {
            // 暗色轨道垫底
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius,
                            startAngle: 0, endAngle: 360)
            track.lineWidth = lw
            NSColor(white: 1, alpha: 0.10).setStroke()
            track.stroke()
            // 进度弧（圆头）
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: radius,
                          startAngle: start, endAngle: end, clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            color.setStroke()
            arc.stroke()
        }
        // 外环 Claude（珊瑚橙，70% 弧，缺口左下）；内环 Codex（青，55% 弧，缺口错位朝右上）
        ring(size * 0.300, NSColor(red: 1.00, green: 0.62, blue: 0.48, alpha: 1),
             from: 90, to: -160)
        ring(size * 0.178, NSColor(red: 0.55, green: 0.91, blue: 0.89, alpha: 1),
             from: -150, to: 12)
        return true
    }
}

let base = renderBase(1024)

func savePNG(px: Int, name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    base.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero,
              operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}

for (pt, scales) in [16: [1, 2], 32: [1, 2], 128: [1, 2], 256: [1, 2], 512: [1, 2]] {
    for s in scales {
        savePNG(px: pt * s, name: s == 1 ? "icon_\(pt)x\(pt).png"
                                         : "icon_\(pt)x\(pt)@2x.png")
    }
}
print("iconset written to \(iconset)")
