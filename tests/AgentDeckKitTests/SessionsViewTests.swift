import XCTest
@testable import AgentDeckKit

final class SessionsViewTests: XCTestCase {
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
