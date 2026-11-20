import AppKit
import SwiftUI
import XCTest
@testable import AgentDeckKit

final class PanelInputTests: XCTestCase {
    @MainActor func testSettingsDimmingChangesTheVisibleBackdrop() throws {
        let store = AppStore()
        let root = AgentDeckRootView(previewStore: store, version: "test", settingsOpen: true, liveLayout: true)
        let host = NSHostingView(rootView: root.background(Color.white))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: 540),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func red(_ level: Int) throws -> CGFloat {
            store.settings["glass_dim"] = .int(level)
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            host.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            return try XCTUnwrap(image.colorAt(x: 4, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB)).redComponent
        }
        let low = try red(20), high = try red(90)
        XCTAssertGreaterThan(low - high, 0.35)
        XCTAssertEqual(ChipFmt.minutesFromSecs.text(90), "90s")
    }

    @MainActor func testActivityLampFrames() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "System requests static indicators")
        let view = HStack(spacing: 20) {
            SessionActivityLabel(status: "busy", tool: "codex")
            SessionActivityLabel(status: "idle", tool: "claude")
        }.padding().background(DashboardStyle.background)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 180, height: 44),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let output = ProcessInfo.processInfo.environment["AD_ACTIVITY_FRAMES"]
        var colors: [Double] = []
        for frame in 0..<9 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // Isolate the teal lamp from the neutral text and background.
            var intensity = 0.0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<(bitmap.pixelsWide / 2) {
                    guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    intensity = max(intensity, Double(c.greenComponent - c.redComponent))
                }
            }
            colors.append(intensity)
            if let output {
                let path = URL(fileURLWithPath: output).appendingPathComponent("lamp-\(frame).png")
                try bitmap.representation(using: .png, properties: [:])?.write(to: path)
            }
        }
        XCTAssertGreaterThan((colors.max() ?? 0) - (colors.min() ?? 0), 0.05, "\(colors)")
    }

    @MainActor func testOutsideClickPassesThroughAfterBlur() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let anchor = PanelInputRegion.Anchor(frame: CGRect(x: 10, y: 10, width: 120, height: 40))
        window.contentView?.addSubview(anchor)
        anchor.role = .focusedSearch
        var blurs = 0
        anchor.dismiss = { blurs += 1 }
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            XCTAssertIdentical(anchor.route(event, at: CGPoint(x: 25, y: 25), in: window), event)
            XCTAssertIdentical(anchor.route(event, at: CGPoint(x: 200, y: 25), in: window), event)
        }
        XCTAssertEqual(blurs, 2)
    }

    @MainActor func testPaletteCanonicalizesOnlyCompleteRGBValues() {
        XCTAssertEqual(AgentPalette.parse(" #00aAfF ").map(AgentPalette.hex), "#00aaff")
        XCTAssertEqual(AgentPalette.parse("336699"), 0x336699)
        for invalid in ["", "#abc", "##00aaff", "#ff000000", "+12345", "zzffff"] {
            XCTAssertNil(AgentPalette.parse(invalid))
        }
    }

    @MainActor func testContinuousRGBReadoutAndHexStayInSync() throws {
        let host = NSHostingView(rootView: AgentPalette(initial: "#abcdef", apply: { _ in
            XCTFail("Dragging must not save the draft")
        }, cancel: {}).padding().preferredColorScheme(.dark))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 210),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        layout()
        let sliders = descendants(host).compactMap { $0 as? NSSlider }
        XCTAssertEqual(sliders.count, 3)
        let red = try XCTUnwrap(sliders.first { $0.accessibilityLabel() == "R" })
        let stack = try XCTUnwrap(red.superview as? NSStackView)
        let readout = try XCTUnwrap(stack.arrangedSubviews.last as? NSTextField)
        for value in [0, 7, 128, 255] {
            XCTAssertTrue(red.isContinuous)
            red.doubleValue = Double(value)
            XCTAssertTrue(red.sendAction(red.action, to: red.target))
            XCTAssertEqual(readout.stringValue, String(value))
            layout()
            let fields = descendants(host).compactMap { $0 as? NSTextField }
            XCTAssertTrue(fields.contains { $0.stringValue.lowercased() == String(format: "#%02xcdef", value) })
        }
        if let path = ProcessInfo.processInfo.environment["AD_PALETTE_SCREENSHOT"],
           let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @MainActor func testAgentSwatchOpensAndAppliesOnlyItsOwnColor() throws {
        _ = NSApplication.shared
        var writes: [(String, SettingValue)] = []
        let host = NSHostingView(rootView: AgentManagerView(values: [:], onSet: { writes.append(($0, $1)) },
                                                            onResetColors: {}))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 680),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        try XCTSkipIf((host.accessibilityChildren() ?? []).isEmpty,
                      "This test host does not expose a SwiftUI accessibility tree")
        func press(_ match: (NSAccessibilityProtocol) -> Bool) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            func find(_ node: NSAccessibilityProtocol) -> NSAccessibilityProtocol? {
                if match(node) { return node }
                for case let child as NSAccessibilityProtocol in node.accessibilityChildren() ?? [] {
                    if let result = find(child) { return result }
                }
                return nil
            }
            let control = try XCTUnwrap(find(window))
            XCTAssertTrue(control.accessibilityPerformPress())
        }
        try press { $0.accessibilityIdentifier() == "agent-color-codex" }
        try press { $0.accessibilityLabel() == "#a78bfa" }
        XCTAssertTrue(writes.isEmpty)
        try press { $0.accessibilityLabel() == L("set.applyColor") }
        XCTAssertEqual(writes.map(\.0), ["color_codex"])
        XCTAssertEqual(writes.first?.1, .string("#a78bfa"))
    }

    @MainActor func testScrollableBodyFindsNativeViewport() throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ScrollView {
            Color.clear.frame(height: 900).background(PanelInputRegion(.scrollBody))
        })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> PanelInputRegion.Anchor? {
            if let anchor = view as? PanelInputRegion.Anchor { return anchor }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let anchor = try XCTUnwrap(find(host))
        let scroll = try XCTUnwrap(anchor.enclosingScrollView)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, scroll.documentVisibleRect.height)
        XCTAssertNotNil(anchor.monitor)
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                         wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
        let location = CGPoint(x: 50, y: 50)
        XCTAssertNil(anchor.route(event, at: location, in: window))
        wheel.flags = .maskCommand
        let modified = try XCTUnwrap(NSEvent(cgEvent: wheel))
        XCTAssertIdentical(anchor.route(modified, at: location, in: window), modified)
        window.contentView = nil
        XCTAssertNil(anchor.monitor)
    }
}
