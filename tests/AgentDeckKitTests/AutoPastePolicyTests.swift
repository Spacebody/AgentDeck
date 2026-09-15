import XCTest
import AppKit
@testable import AgentDeckKit

final class AutoPastePolicyTests: XCTestCase {
    func testCopyRejectsFailureAndConcurrentReplacement() {
        XCTAssertNil(AutoPastePolicy.verifiedCopy("command", clear: { 10 },
                                                 write: { _ in false }, generation: { 10 }))
        XCTAssertNil(AutoPastePolicy.verifiedCopy("command", clear: { 10 },
                                                 write: { _ in true }, generation: { 11 }))
        XCTAssertEqual(AutoPastePolicy.verifiedCopy("command", clear: { 10 },
                                                    write: { _ in true }, generation: { 10 }), 10)
        XCTAssertNil(AutoPastePolicy.verifiedCopy("", clear: { XCTFail(); return 10 },
                                                 write: { _ in XCTFail(); return true }, generation: { 10 }))
    }

    @MainActor func testCopyGenerationSurvivesHandoffAndRejectsReplacement() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let generation = AutoPastePolicy.copyCommand("codex resume test", to: board)
        XCTAssertNotNil(generation)
        XCTAssertEqual(board.string(forType: .string), "codex resume test")
        guard let generation else { return }
        XCTAssertTrue(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: 42,
                                                 originalClipboard: generation,
                                                 currentClipboard: board.changeCount))
        board.clearContents()
        board.setString("replacement", forType: .string)
        XCTAssertFalse(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: 42,
                                                  originalClipboard: generation,
                                                  currentClipboard: board.changeCount))
    }

    func testOnlyKnownPasteTerminalsResolve() {
        // Keep aligned with agentdeckd.py _PASTE_TERMS, using app names, not display labels.
        let expected = ["warp": "Warp", "vscode": "Visual Studio Code", "cursor": "Cursor",
                        "windsurf": "Windsurf", "hyper": "Hyper", "tabby": "Tabby",
                        "rio": "Rio", "wave": "Wave"]
        for (mode, name) in expected {
            XCTAssertEqual(AutoPastePolicy.applicationName(for: mode), name)
        }
        XCTAssertNil(AutoPastePolicy.applicationName(for: ""))
        XCTAssertNil(AutoPastePolicy.applicationName(for: "Other"))
        XCTAssertNil(AutoPastePolicy.applicationName(for: "/Applications/Other.app"))
    }

    func testSendingRequiresUnchangedTargetAndClipboard() {
        XCTAssertTrue(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: 42,
                                                 originalClipboard: 3, currentClipboard: 3))
        XCTAssertFalse(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: 43,
                                                  originalClipboard: 3, currentClipboard: 3))
        XCTAssertFalse(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: nil,
                                                  originalClipboard: 3, currentClipboard: 3))
        XCTAssertFalse(AutoPastePolicy.shouldSend(expectedPID: 42, frontmostPID: 42,
                                                  originalClipboard: 3, currentClipboard: 4))
        XCTAssertFalse(AutoPastePolicy.shouldSend(expectedPID: 0, frontmostPID: 0,
                                                  originalClipboard: 3, currentClipboard: 3))
    }
}
