import XCTest
import AppKit
import SwiftUI
@testable import AgentDeckKit

final class SessionsViewTests: XCTestCase {
    func testAntigravitySourcesShareFilterButNotIdentityOrResume() {
        func row(_ source: String?, _ account: String) -> SessionItem {
            SessionItem(tool: "antigravity", id: "same", title: nil, cwd: nil,
                        project: nil, branch: nil, mtime: 0, account: nil, accountId: account, source: source)
        }
        let app = row("antigravity_app", "app"), cli = row("antigravity_cli", "cli")
        XCTAssertNotEqual(app.rowKey, cli.rowKey)
        XCTAssertEqual(cli.sourceLabel, "Antigravity CLI")
        XCTAssertNotEqual(app.sourceLabel, cli.sourceLabel)
        XCTAssertTrue(cli.canResume && cli.canCopyCommand)
        for unsupported in [app, row(nil, "cli"), row("antigravity_cli", "app")] {
            XCTAssertFalse(unsupported.canResume)
            XCTAssertFalse(unsupported.canCopyCommand)
        }
        XCTAssertFalse(SessionTools.canFocus(cli.tool))
        XCTAssertTrue(SessionTools.indexed.contains(cli.tool))
        XCTAssertEqual(Brand(rawValue: cli.tool), .antigravity)
        for item in [app, cli] {
            XCTAssertNil(SessionPreviewRequest.expanded(item.rowKey, in: [item]))
        }
    }

    @MainActor
    func testAntigravityVisibilityAndLocalizedLabels() {
        let store = AppStore()
        XCTAssertFalse(store.agentOn("antigravity"))
        store.settings["show_antigravity"] = .bool(true)
        XCTAssertTrue(store.agentOn("antigravity"))
        store.settings["show_antigravity"] = .bool(false)
        XCTAssertFalse(store.agentOn("antigravity"))
        for locale in ["en", "ja", "zh-CN"] {
            for key in ["session.antigravityImport", "session.antigravityDesktop"] {
                XCTAssertNotNil(I18N.table[locale]?[key])
            }
        }
    }

    private func session(mtime: Double) -> SessionItem {
        SessionItem(tool: "codex", id: "preview", title: "Preview", cwd: nil,
                    project: nil, branch: nil, mtime: mtime,
                    account: nil, accountId: nil, pinned: nil)
    }

    func testExpandedPreviewIdentityTracksFileChangesAndRemoval() {
        let first = session(mtime: 1)
        let updated = session(mtime: 2)
        let request = SessionPreviewRequest.expanded(first.rowKey, in: [first])
        XCTAssertNotNil(request)
        XCTAssertNotEqual(request, SessionPreviewRequest.expanded(first.rowKey, in: [updated]))
        XCTAssertEqual(request, SessionPreviewRequest.expanded(first.rowKey, in: [first]))
        XCTAssertNil(SessionPreviewRequest.expanded(nil, in: [first]))
        XCTAssertNil(SessionPreviewRequest.expanded(first.rowKey, in: []))
    }

    func testPulseRejectsOfflineSentinelAndInvalidDurations() {
        XCTAssertTrue(Pulse.validPeriod(1.6))
        XCTAssertFalse(Pulse.validPeriod(.infinity))
        XCTAssertFalse(Pulse.validPeriod(.nan))
        XCTAssertFalse(Pulse.validPeriod(0))
        XCTAssertFalse(Pulse.validPeriod(-1))
    }

    @MainActor
    func testExpandedPreviewReloadsWhenFileChanges() async {
        let firstLoaded = expectation(description: "Initial preview")
        let updatedLoaded = expectation(description: "Updated preview")
        let first = session(mtime: 1)
        let loader: (SessionItem) async -> [PreviewMsg] = { session in
            if session.mtime == 1 { firstLoaded.fulfill() }
            if session.mtime == 2 { updatedLoaded.fulfill() }
            return [PreviewMsg(role: "user", text: "Version \(session.mtime)")]
        }
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SessionsView(
            sessions: [first], loadPreview: loader, initialExpanded: first.rowKey))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await fulfillment(of: [firstLoaded], timeout: 3)
        host.rootView = SessionsView(sessions: [session(mtime: 2)], loadPreview: loader)
        await fulfillment(of: [updatedLoaded], timeout: 3)
    }

    @MainActor
    func testRemovingExpandedSessionCancelsPreviewLoad() async {
        let started = expectation(description: "Preview started")
        let cancelled = expectation(description: "Preview cancelled")
        let first = session(mtime: 1)
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SessionsView(
            sessions: [first], loadPreview: { _ in
                started.fulfill()
                do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                catch { cancelled.fulfill() }
                return []
            }, initialExpanded: first.rowKey))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        await fulfillment(of: [started], timeout: 3)
        host.rootView = SessionsView(sessions: [])
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testQoderAppSessionSourceDecodes() throws {
        let json = """
        {"tool":"qoder","id":"00000000-0000-0000-0000-000000000123",
         "title":"Desktop session","cwd":"/work/qoder","project":"qoder",
         "branch":"main","mtime":42,"source":"qoder_app"}
        """.data(using: .utf8)!

        let session = try JSONDecoder().decode(SessionItem.self, from: json)
        XCTAssertEqual(session.source, "qoder_app")
    }

    func testCustomPageSizeAcceptsIntegersWithinRange() {
        XCTAssertEqual(SessionsView.parseCustomPageSize("5"), 5)
        XCTAssertEqual(SessionsView.parseCustomPageSize("37"), 37)
        XCTAssertEqual(SessionsView.parseCustomPageSize(" 100 "), 100)
    }

    func testCustomPageSizeRejectsInvalidOrOutOfRangeInput() {
        XCTAssertNil(SessionsView.parseCustomPageSize(""))
        XCTAssertNil(SessionsView.parseCustomPageSize("4"))
        XCTAssertNil(SessionsView.parseCustomPageSize("101"))
        XCTAssertNil(SessionsView.parseCustomPageSize("12.5"))
        XCTAssertNil(SessionsView.parseCustomPageSize("abc"))
    }
}
