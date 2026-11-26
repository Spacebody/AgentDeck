import AppKit

public enum MenubarDrumRenderer {
    public static func frame(from outgoing: NSImage, to incoming: NSImage,
                          progress: CGFloat) -> NSImage {
        let size = NSSize(width: max(outgoing.size.width, incoming.size.width),
                          height: max(outgoing.size.height, incoming.size.height))
        let angle = progress * .pi / 2
        let incomingAngle = (.pi / 2) - angle
        let image = NSImage(size: size, flipped: false) { bounds in
            NSGraphicsContext.current?.cgContext.clip(to: bounds)
            func drawFace(_ source: NSImage, angle: CGFloat, direction: CGFloat) {
                let scale = max(0.02, cos(angle))
                let height = max(0.5, source.size.height * scale)
                let center = bounds.midY + direction * sin(angle) * bounds.height / 2
                let rect = NSRect(x: (bounds.width - source.size.width) / 2,
                                  y: center - height / 2,
                                  width: source.size.width, height: height)
                source.draw(in: rect, from: .zero, operation: .sourceOver,
                            fraction: 0.32 + 0.68 * scale)
            }
            drawFace(outgoing, angle: angle, direction: 1)
            drawFace(incoming, angle: incomingAngle, direction: -1)
            return true
        }
        image.isTemplate = outgoing.isTemplate && incoming.isTemplate
        return image
    }
}
