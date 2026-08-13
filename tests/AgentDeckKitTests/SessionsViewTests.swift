import XCTest
@testable import AgentDeckKit

final class SessionsViewTests: XCTestCase {
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
