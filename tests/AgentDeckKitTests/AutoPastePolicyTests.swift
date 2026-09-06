import XCTest
@testable import AgentDeckKit

final class AutoPastePolicyTests: XCTestCase {
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
