import XCTest
@testable import AgentDeckKit

final class MenubarRotationPolicyTests: XCTestCase {
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
        XCTAssertTrue(MenubarRotationPolicy.shouldDeferPassiveRefresh(isAnimating: true))
        XCTAssertFalse(MenubarRotationPolicy.shouldDeferPassiveRefresh(isAnimating: false))

        var items = ["codex 10%", "qoder 20%"]
        items[1] = "qoder 21%"
        XCTAssertEqual(MenubarRotationPolicy.currentItem(items: items, currentIndex: 1),
                       "qoder 21%")
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
