import AppKit

package struct IslandPalette {
    let background: NSColor
    package let ink: NSColor
    package var fill: CGColor { background.cgColor }
    package static let subtitle = NSColor(srgbRed: 0.79, green: 0.79, blue: 0.79, alpha: 1)

    init(accent: NSColor) {
        let color = accent.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
        background = NSColor(srgbRed: 0.054 + 0.1 * r, green: 0.0675 + 0.1 * g,
                             blue: 0.072 + 0.1 * b, alpha: 1)
        let required = 7 * (Self.luminance(background) + 0.05) - 0.05
        func tinted(_ t: CGFloat) -> NSColor {
            NSColor(srgbRed: r + (1-r)*t, green: g + (1-g)*t, blue: b + (1-b)*t, alpha: 1)
        }
        if Self.luminance(color) >= required {
            ink = color
        } else {
            // Find the smallest white tint that meets the contrast target.
            var low: CGFloat = 0, high: CGFloat = 1
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if Self.luminance(tinted(mid)) >= required { high = mid } else { low = mid }
            }
            ink = tinted(high)
        }
    }

    package init(tool: String) { self.init(accent: agentAccentInk(tool)) }

    static func luminance(_ c: NSColor) -> CGFloat {
        func linear(_ x: CGFloat) -> CGFloat {
            x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
}
