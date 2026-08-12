import XCTest
@testable import AgentDeckKit

final class QuotaCarouselTests: XCTestCase {
    private func decode(_ json: String) throws -> QuotaResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(QuotaResponse.self, from: Data(json.utf8))
    }

    func testFlatPagesUseAgentOrderAndDefaultAccountFirst() throws {
        let response = try decode("""
        {
          "agents": [
            {"id":"qoder","name":"Qoder","hidden":false,"accounts":[
              {"ok":true,"account_id":"work","account":"Work","is_default":false,"windows":[]},
              {"ok":true,"account_id":"default","account":"Default","is_default":true,"windows":[]}
            ]},
            {"id":"claude","name":"Claude","hidden":false,"accounts":[
              {"ok":true,"account_id":"default","account":"Default","is_default":true,"windows":[]}
            ]}
          ],
          "accounts":{"claude":[],"codex":[],"qoder":[]}
        }
        """)

        XCTAssertEqual(response.flatPages().map(\.id), [
            "qoder::default", "qoder::work", "claude::default",
        ])
    }

    func testLegacyQuotaResponseStillFlattens() throws {
        let response = try decode("""
        {
          "claude":{"ok":true,"account_id":"default","is_default":true,"windows":[]},
          "codex":{"ok":false,"hidden":true,"windows":[]},
          "accounts":{"claude":[],"codex":[]}
        }
        """)

        XCTAssertEqual(response.flatPages().map(\.id), ["claude::default"])
    }

    func testExplicitAgentErrorRemainsAPeerPage() throws {
        let response = try decode("""
        {
          "agents":[{"id":"qoder","name":"Qoder","hidden":false,"accounts":[
            {"ok":false,"account_id":"default","is_default":true,
             "no_quota":true,"error":"Qoder account not found"}
          ]}],
          "accounts":{"claude":[],"codex":[],"qoder":[]}
        }
        """)

        let pages = response.flatPages()
        XCTAssertEqual(pages.map(\.id), ["qoder::default"])
        XCTAssertEqual(pages.first?.account.noQuota, true)
    }

    func testSelectionIsStableAcrossRefreshAndFallsBackWhenRemoved() throws {
        let first = try decode("""
        {"agents":[{"id":"qoder","name":"Qoder","accounts":[
          {"ok":true,"account_id":"a","windows":[]},
          {"ok":true,"account_id":"b","windows":[]}
        ]}],"accounts":{"claude":[],"codex":[]}}
        """).flatPages()
        XCTAssertEqual(reconciledQuotaSelection(currentID: "qoder::b", pages: first), "qoder::b")

        let removed = Array(first.prefix(1))
        XCTAssertEqual(reconciledQuotaSelection(currentID: "qoder::b", pages: removed), "qoder::a")
    }

    func testRotationIntervalUsesApprovedValuesOnly() {
        XCTAssertEqual(normalizedQuotaRotationInterval(4), 4)
        XCTAssertEqual(normalizedQuotaRotationInterval(10), 10)
        XCTAssertEqual(normalizedQuotaRotationInterval(7), 6)
    }
}
