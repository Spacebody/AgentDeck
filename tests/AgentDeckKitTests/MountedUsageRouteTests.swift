import AppKit
import SwiftUI
import XCTest
@testable import AgentDeckKit


// Install a passive test probe in the Root's real Label hierarchy. This exercises
// the destination environment action without requiring assistive-access privileges.
private final class RouteTrace {
    var action: ((UsageDestination, AnalyticsSnapshot?) -> Void)?
    var appeared: [UUID] = []
    var disappeared: [UUID] = []
    var anchors: [UUID: NSView] = [:]
}

private struct RouteLabelStyle: LabelStyle {
    let trace: RouteTrace
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.icon; configuration.title }
            .background(RouteProbe(trace: trace))
    }
}

private struct RouteProbe: View {
    let trace: RouteTrace
    @Environment(\.openAnalytics) var open
    @State private var id = UUID()
    var body: some View {
        ProbeAnchor(id: id, trace: trace).allowsHitTesting(false).onAppear {
            trace.appeared.append(id)
            trace.action = open
        }.onDisappear { trace.disappeared.append(id) }
    }
}

private struct ProbeAnchor: NSViewRepresentable {
    let id: UUID
    let trace: RouteTrace
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { trace.anchors[id] = view }
}

final class MountedUsageRouteTests: XCTestCase {
    @MainActor func testMountedRootConsumesScopedActionAndKeepsOriginMounted() throws {
        _ = NSApplication.shared
        let trace = RouteTrace()
        let store = PreviewRender.mockStore()
        store.update = nil
        let root = AgentDeckRootView(previewStore: store, version: "fixture", initialTab: "projects")
            .labelStyle(RouteLabelStyle(trace: trace))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 1100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        settle()
        let action = try XCTUnwrap(trace.action)
        let origin = Set(trace.appeared).subtracting(trace.disappeared)
        XCTAssertFalse(origin.isEmpty)
        func clickTopLabel(_ ids: Set<UUID>) throws {
            let point = try XCTUnwrap(ids.compactMap { trace.anchors[$0] }.filter { $0.window === window }
            .map { $0.convert(NSPoint(x: $0.bounds.midX, y: $0.bounds.midY), to: nil) }
            .max(by: { $0.y < $1.y }))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
            }
        }
        let session = try XCTUnwrap(store.sessions.first)
        for sessionScope in [false, true] {
            let prior = Set(trace.appeared)
            if sessionScope {
                action(.init(scope: AnalyticsScope(session), title: session.id, agents: [session.tool]), .preview)
            } else {
                // The expanded preview project's Usage link is the first Label on Projects.
                try clickTopLabel(origin)
            }
            settle()
            let destination = Set(trace.appeared).subtracting(prior).subtracting(trace.disappeared)
            XCTAssertFalse(destination.isEmpty, "Root did not mount scoped Usage")
            XCTAssertTrue(origin.isDisjoint(with: trace.disappeared))
            try clickTopLabel(destination) // Back is the first Label on scoped Usage.
            settle()
            XCTAssertTrue(destination.isSubset(of: Set(trace.disappeared)), "Back did not dismiss scoped Usage")
            XCTAssertTrue(origin.isDisjoint(with: trace.disappeared), "Origin was reconstructed")
        }
    }
}
