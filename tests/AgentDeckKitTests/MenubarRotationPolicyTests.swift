import AppKit
import XCTest
@testable import AgentDeckKit

final class MenubarRotationPolicyTests: XCTestCase {
    func testDrumFramesMoveTemplateFacesOfDifferentWidthsAndPreserveAlertColor() throws {
        func face(_ width: CGFloat, ink: NSColor, template: Bool) -> NSImage {
            let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { rect in
                ink.setFill()
                rect.insetBy(dx: 2, dy: 7).fill()
                return true
            }
            image.isTemplate = template
            return image
        }
        let a = face(22, ink: .black, template: true), b = face(64, ink: .black, template: true)
        let start = MenubarDrumRenderer.frame(from: a, to: b, progress: 0)
        let middle = MenubarDrumRenderer.frame(from: a, to: b, progress: 0.5)
        XCTAssertEqual(middle.size, b.size)
        XCTAssertTrue(middle.isTemplate)
        func centerAlpha(_ image: NSImage) throws -> CGFloat {
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)).alphaComponent
        }
        XCTAssertGreaterThan(try centerAlpha(start), 0.9)
        XCTAssertLessThan(try centerAlpha(middle), 0.1)
        let alert = face(64, ink: .red, template: false)
        XCTAssertFalse(MenubarDrumRenderer.frame(from: a, to: alert, progress: 0.5).isTemplate)
    }

    func testOnlySuccessfulHTTPStatusCanApplyMenubarSnapshot() {
        XCTAssertTrue(MenubarRotationPolicy.isSuccessfulHTTPStatus(200))
        XCTAssertTrue(MenubarRotationPolicy.isSuccessfulHTTPStatus(299))
        XCTAssertFalse(MenubarRotationPolicy.isSuccessfulHTTPStatus(500))
        XCTAssertFalse(MenubarRotationPolicy.isSuccessfulHTTPStatus(304))
    }

    func testSelectionSurvivesQuotaRefreshByStableID() {
        let ids = ["claude::default", "codex::default", "qoder::work"]
        XCTAssertEqual(
            MenubarRotationPolicy.reconciledIndex(currentID: "qoder::work", itemIDs: ids),
            2)
        XCTAssertEqual(
            MenubarRotationPolicy.reconciledIndex(currentID: "missing", itemIDs: ids),
            0)
    }

    func testMissingAccountFallsBackButOverviewOnlyAgentPausesMenubar() {
        let ids = ["claude::default", "codex::default"]
        XCTAssertFalse(MenubarRotationPolicy.selectionIsOutsideMenubar(
            sharedID: "codex::removed", sharedToolEnabled: true,
            itemIDs: ids, panelVisible: true))
        XCTAssertTrue(MenubarRotationPolicy.selectionIsOutsideMenubar(
            sharedID: "qoder::default", sharedToolEnabled: false,
            itemIDs: ids, panelVisible: true))
        XCTAssertFalse(MenubarRotationPolicy.selectionIsOutsideMenubar(
            sharedID: "qoder::default", sharedToolEnabled: false,
            itemIDs: ids, panelVisible: false))
    }

    func testNextIndexWrapsAndEmptyListIsSafe() {
        XCTAssertEqual(MenubarRotationPolicy.nextIndex(current: 0, itemCount: 3), 1)
        XCTAssertEqual(MenubarRotationPolicy.nextIndex(current: 2, itemCount: 3), 0)
        XCTAssertEqual(MenubarRotationPolicy.nextIndex(current: 5, itemCount: 0), 0)
    }

    func testRotationRequiresMultipleItemsAndPositiveInterval() {
        XCTAssertNil(MenubarRotationPolicy.interval(configuredSeconds: 6, itemCount: 1))
        XCTAssertNil(MenubarRotationPolicy.interval(configuredSeconds: 0, itemCount: 3))
        XCTAssertEqual(MenubarRotationPolicy.interval(configuredSeconds: 6, itemCount: 3), 6)
    }

    func testPassiveRefreshWaitsForAnimationAndCompletionUsesLatestItem() {
        XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: "same", nextID: "same",
                       isAnimating: true, reduceMotion: false), .finishCurrentRoll)
        XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: "same", nextID: "same",
                       isAnimating: false, reduceMotion: false), .replace)

        var items = ["codex 10%", "qoder 20%"]
        items[1] = "qoder 21%"
        XCTAssertEqual(MenubarRotationPolicy.currentItem(items: items, currentIndex: 1),
                       "qoder 21%")
    }

    func testAllAgentAndAccountChangesRollEvenWhenInterruptingAnotherRoll() {
        let ids = AgentSettingsCatalog.ids.map { $0 + "::default" } + ["codex::work"]
        for from in ids {
            for to in ids where from != to {
                for active in [true, false] {
                    XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: from, nextID: to,
                                   isAnimating: active, reduceMotion: false), .roll)
                    XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: from, nextID: to,
                                   isAnimating: active, reduceMotion: true), .replace)
                }
            }
        }
    }

    func testStartupFallbackAndEnablingReduceMotionAreImmediate() {
        for (from, to) in [(nil, "codex"), ("codex", nil), ("codex", "codex")] as [(String?, String?)] {
            XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: from, nextID: to,
                           isAnimating: true, reduceMotion: true), .replace)
        }
        XCTAssertEqual(MenubarRotationPolicy.presentation(targetID: nil, nextID: "codex",
                       isAnimating: false, reduceMotion: false), .replace)
    }

    func testAnimationCompletionHandlesRemovedOrEmptyItemList() {
        XCTAssertEqual(MenubarRotationPolicy.currentItem(items: ["codex"], currentIndex: 1),
                       "codex")
        XCTAssertNil(MenubarRotationPolicy.currentItem(items: [String](), currentIndex: 1))
    }

    func testOlderMenubarResponseCannotOverwriteNewerSnapshot() {
        XCTAssertTrue(MenubarRotationPolicy.shouldAcceptResponse(
            requestID: 8, lastAppliedRequestID: 7))
        XCTAssertFalse(MenubarRotationPolicy.shouldAcceptResponse(
            requestID: 7, lastAppliedRequestID: 8))
        // A later request may fail before decoding. The older valid response is
        // still newer than the last applied snapshot and must not be discarded.
        XCTAssertTrue(MenubarRotationPolicy.shouldAcceptResponse(
            requestID: 8, lastAppliedRequestID: 6))
    }
}
