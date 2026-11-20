import AppKit
import SwiftUI

/// Observe panel events without putting a hit-testable view over SwiftUI controls.
struct PanelInputRegion: NSViewRepresentable {
    enum Role { case scrollBody, focusedSearch }
    let role: Role
    var active = true
    var dismiss: () -> Void = {}
    @Environment(\.isEnabled) private var enabled

    init(_ role: Role, active: Bool = true, dismiss: @escaping () -> Void = {}) {
        self.role = role
        self.active = active
        self.dismiss = dismiss
    }

    final class Anchor: NSView {
        var monitor: Any?
        var role = Role.scrollBody
        var active = false
        var dismiss: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configure()
        }
        func configure() {
            guard window != nil, active else { stop(); return }
            guard monitor == nil else { return }
            let mask: NSEvent.EventTypeMask = role == .scrollBody ? .scrollWheel : [.leftMouseDown, .rightMouseDown]
            monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                return self.route(event, at: event.locationInWindow, in: window)
            }
        }
        func route(_ event: NSEvent, at location: CGPoint, in window: NSWindow) -> NSEvent? {
                if self.role == .focusedSearch {
                    if !self.bounds.contains(self.convert(location, from: nil)) { self.dismiss() }
                    return event
                }
                guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
                      let scroll = self.enclosingScrollView, let document = scroll.documentView,
                      document.bounds.height > scroll.documentVisibleRect.height + 1,
                      let root = window.contentView else { return event }
                let hit = root.hitTest(root.convert(location, from: nil))
                if let nested = hit?.enclosingScrollView, nested !== scroll,
                   nested.isDescendant(of: scroll) { return event }
                scroll.scrollWheel(with: event)
                return nil
        }
    }
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.role = role
        view.active = active && enabled
        view.dismiss = dismiss
        view.configure()
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.stop() }
}
