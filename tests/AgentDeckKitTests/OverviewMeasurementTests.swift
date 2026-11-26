import Foundation
import XCTest
@testable import AgentDeckKit

final class OverviewMeasurementTests: XCTestCase {
    func testTodayMatchesGlobalRecordedTrendIncludingQoderCN() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z"))
        let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for agents: Set<String> in [["qoder_cn"], ["claude", "qoder_cn", "antigravity"], []] {
            let global = AnalyticsQuery(days: 1, agents: agents, dimension: "agent", basis: "recorded",
                                        scope: .all, now: now, timezone: zone)
            let overview = OverviewMeasurement.query(agents: agents, now: now, timezone: zone)
            XCTAssertEqual(overview.parameters(), global.parameters())
            XCTAssertEqual(overview.end - overview.start, 25 * 3600)
        }
    }

    func testPartialRecordedReadingDoesNotUseSampledOrHiddenRowsAsTotal() {
        func slice(_ basis: String, _ agent: String, _ n: Double) -> AnalyticsSlice {
            AnalyticsSlice(basis: basis, metrics: ["tokens_total": n], quality: ["tokens_total": "complete"],
                           knownSubtotals: nil, agent: agent)
        }
        let recorded = AnalyticsSlice(basis: "recorded", metrics: ["tokens_total": nil],
                                     quality: ["tokens_total": "partial"], knownSubtotals: ["tokens_total": 15])
        let sample = slice("sampled", "antigravity", 900)
        let snapshot = AnalyticsSnapshot(generation: "g", status: "ready", summary: [sample, recorded], series: [],
                                         rows: [sample, slice("recorded", "qoder_cn", 15), slice("recorded", "qoder", 200)])
        let reading = OverviewMeasurement(snapshot: snapshot, query: OverviewMeasurement.query(agents: ["qoder_cn"]))
        XCTAssertNil(reading.summary?.value("tokens_total"))
        XCTAssertEqual(reading.summary?.subtotal("tokens_total"), 15)
        XCTAssertEqual(reading.parts.map { $0.0.rawValue }, ["qoder_cn"])
        XCTAssertNil(OverviewMeasurement(snapshot: snapshot, query: OverviewMeasurement.query(agents: [])).summary)
    }

    func testTodayPreviewMatchesLastTrendDayNotWeekTotal() {
        let reading = OverviewMeasurement(snapshot: .todayPreview, query: OverviewMeasurement.query(agents: ["claude", "codex", "qoder"]))
        let headline = reading.summary?.value("tokens_total")
        XCTAssertNotNil(headline)
        XCTAssertEqual(headline, AnalyticsSnapshot.preview.series.last?.value("tokens_total"))
        XCTAssertNotEqual(headline, AnalyticsSnapshot.preview.summary.first?.value("tokens_total"))
    }
}
