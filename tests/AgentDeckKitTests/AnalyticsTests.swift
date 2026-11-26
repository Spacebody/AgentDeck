import Foundation
import XCTest
@testable import AgentDeckKit

private final class AnalyticsFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!
        let args = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        let csv = url.path == "/api/analytics/export"
        let valid = args["agents"] == "claude,codex" && args["basis"] == "recorded" && args["project"] == "/work/a & b"
            && args["dimension"] == "model" && (!csv || (args["generation"] == "uuid:1" && args["cursor"] == nil))
        let payload = #"{"generation":"uuid:1","status":"partial","summary":[{"basis":"recorded","metrics":{"tokens_total":null,"reasoning_output_tokens":4,"input_uncached_tokens":5,"output_tokens":10},"quality":{"tokens_total":"partial","input_uncached_tokens":"complete","output_tokens":"complete","reasoning_output_tokens":"complete"},"known_subtotals":{"tokens_total":15}}],"series":[],"rows":[],"next_cursor":null}"#
        let response = HTTPURLResponse(url: url, statusCode: valid ? 200 : 409, httpVersion: nil,
                                       headerFields: ["Content-Type": csv ? "text/csv; charset=utf-8" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((csv ? "model,tokens_total\nunknown,\n" : payload).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class AnalyticsTests: XCTestCase {
    func testPerformanceShowsMeasuredZeroAndPartialButNotSampleCounters() {
        let slice = AnalyticsSlice(basis: "recorded", metrics: ["calls": 0, "ttft_samples": 0],
                                   quality: ["calls": "complete", "latency_ms": "partial", "ttft_samples": "complete"],
                                   knownSubtotals: ["latency_ms": 42])
        XCTAssertEqual(slice.measuredPerformanceKeys, ["calls", "latency_ms"])
        let empty = AnalyticsSlice(basis: "recorded", metrics: ["ttft_samples": 0],
                                   quality: ["ttft_samples": "complete"], knownSubtotals: nil)
        XCTAssertTrue(empty.measuredPerformanceKeys.isEmpty)
    }

    func testPartialComponentIsNotCountedAgainInRemainder() {
        let slice = AnalyticsSlice(basis: "recorded", metrics: ["tokens_total": 200, "output_tokens": 40],
                                   quality: ["tokens_total": "complete", "output_tokens": "complete",
                                             "input_uncached_tokens": "partial"],
                                   knownSubtotals: ["input_uncached_tokens": 80])
        XCTAssertEqual(slice.subtotal("input_uncached_tokens"), 80)
        XCTAssertNil(slice.unclassifiedTokens)
    }

    func testRankedDetailKeepsExactQueryAndUsesRawGroupIdentity() throws {
        let row = try JSONDecoder().decode(AnalyticsSlice.self, from: Data(#"{"basis":"recorded","metrics":{},"quality":{},"label":"repo","project":"/work/team/repo","model":"model:actual","agent":"codex"}"#.utf8))
        let scope = AnalyticsScope.session(agent: "codex", account: "dev", source: "transcript", id: "s1")
        let q = AnalyticsQuery(days: 7, agents: ["claude","codex"], dimension: "model", basis: "recorded",
                               scope: scope, now: Date(timeIntervalSince1970: 123456))
        let project = try XCTUnwrap(AnalyticsGroupFilter(dimension: "project", row: row))
        let model = try XCTUnwrap(AnalyticsGroupFilter(dimension: "model", row: row))
        XCTAssertEqual(project.value, "/work/team/repo")
        XCTAssertEqual(model.value, "model:actual")
        XCTAssertNil(AnalyticsGroupFilter(dimension: "session", row: row))
        var params = q.filtered(by: project).filtered(by: model).parameters()
        let encoded = try XCTUnwrap(params.removeValue(forKey: "group_filters"))
        XCTAssertEqual(try JSONDecoder().decode([[String?]].self, from: Data(encoded.utf8)),
                       [["project", "/work/team/repo"], ["model", "model:actual"]])
        XCTAssertEqual(params, q.parameters())
    }

    func testUnknownGroupAndDisabledSessionAgentNeverWidenSelection() throws {
        let row = try JSONDecoder().decode(AnalyticsSlice.self, from: Data(#"{"basis":"recorded","metrics":{},"quality":{},"model":null,"label":"Unknown"}"#.utf8))
        let filter = try XCTUnwrap(AnalyticsGroupFilter(dimension: "model", row: row))
        let q = AnalyticsQuery(days: 1, agents: ["claude"], dimension: "agent", basis: "recorded",
                               scope: .session(agent: "codex", account: "work", source: "transcript", id: "sid"),
                               groupFilter: filter)
        let params = q.parameters()
        XCTAssertEqual(params["agents"], "")
        XCTAssertEqual(params["account_id"], "work")
        let encoded = try XCTUnwrap(params["group_filters"])
        XCTAssertEqual(try JSONDecoder().decode([[String?]].self, from: Data(encoded.utf8)), [["model", nil]])
    }

    func testCalendarDaysUseLocalMidnightAcrossDST() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-03-09T20:00:00Z"))
        let q = AnalyticsQuery(days: 1, agents: ["codex"], dimension: "agent", basis: "recorded",
                               scope: .all, now: date, timezone: zone)
        XCTAssertEqual(q.end - q.start, 23 * 3600)
        XCTAssertEqual(q.timezone, zone.identifier)
    }

    func testSessionIdentitiesMatchAdaptersNotIndexAliases() {
        for (tool, account, indexSource, adapter, expectedAccount) in [
            ("antigravity", "app", "antigravity_app", "antigravity_app_db", nil),
            ("antigravity", "cli", "antigravity_cli", "antigravity_cli_db", nil),
            ("qoder", "default", "qoder_app", "qoder_desktop", "default"),
            ("qoder", "work", "", "qoder_cli", "work"),
            ("qoder_cn", "cn", "", "qoder_cn_cli", "cn"),
            ("claude", "work", "", "transcript", "work"), ("codex", "dev", "", "transcript", "dev"),
        ] {
            let item = SessionItem(tool: tool, id: "shared", title: nil, cwd: nil, project: nil, branch: nil,
                                   mtime: 0, account: nil, accountId: account, source: indexSource.isEmpty ? nil : indexSource)
            let params = AnalyticsQuery(days: 30, agents: [tool], dimension: "model", basis: "recorded",
                                        scope: .init(item)).parameters()
            XCTAssertEqual(params["account_id"], expectedAccount)
            XCTAssertEqual(params["source_kind"], adapter)
            XCTAssertEqual(params["session_id"], "shared")
            XCTAssertEqual(params["agents"], tool)
        }
    }

    func testSameQueryRawCSVPartialAndConflict() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnalyticsFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let api = APIClient(session: session)
        let q = AnalyticsQuery(days: 7, agents: ["codex", "claude"], dimension: "model", basis: "recorded",
                               scope: .project("/work/a & b"))
        let page: AnalyticsSnapshot = try await api.get("/api/analytics", query: q.parameters())
        let slice = try XCTUnwrap(page.summary.first)
        XCTAssertNil(slice.value("tokens_total"))
        XCTAssertEqual(slice.subtotal("tokens_total"), 15)
        XCTAssertEqual(slice.composition.map(\.1).reduce(0, +), 15, "Reasoning is already included in output")
        XCTAssertNil(slice.value("cost_usd"))
        let data = try await api.analyticsCSV(query: q.parameters(generation: page.generation))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "model,tokens_total\nunknown,\n")
        do { _ = try await api.analyticsCSV(query: q.parameters(generation: "expired")); XCTFail("Expected 409") }
        catch APIError.http(409) {}
        var first = page
        let next = AnalyticsSnapshot(generation: "uuid:2", status: "ready", summary: [], series: [], rows: [], nextCursor: nil)
        XCTAssertThrowsError(try first.append(next))
    }

    func testAllAnalyticsKeysExistInEveryLocale() throws {
        let keys = try XCTUnwrap(I18N.table["en"]).keys.filter { $0.hasPrefix("analytics.") }
        for locale in ["zh-CN", "ja"] {
            XCTAssertEqual(Set(keys), Set(try XCTUnwrap(I18N.table[locale]).keys.filter { $0.hasPrefix("analytics.") }))
        }
    }
}
