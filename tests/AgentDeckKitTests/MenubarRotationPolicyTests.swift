import XCTest
@testable import AgentDeckKit

final class MenubarRotationPolicyTests: XCTestCase {
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

    func testAnimationProgressIsClampedAndEased() {
        XCTAssertEqual(MenubarRotationPolicy.easedProgress(elapsed: -1, duration: 0.25), 0)
        XCTAssertGreaterThan(MenubarRotationPolicy.easedProgress(elapsed: 0.125, duration: 0.25), 0.5)
        XCTAssertEqual(MenubarRotationPolicy.easedProgress(elapsed: 1, duration: 0.25), 1)
    }
}
