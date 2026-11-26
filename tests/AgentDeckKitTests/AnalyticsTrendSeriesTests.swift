import XCTest
@testable import AgentDeckKit

final class AnalyticsTrendSeriesTests: XCTestCase {
    private func query(_ days: Int) -> AnalyticsQuery {
        AnalyticsQuery(days: days, agents: ["claude"], dimension: "agent", basis: "recorded", scope: .all,
                       now: ISO8601DateFormatter().date(from: "2026-03-11T03:00:00Z")!,
                       timezone: TimeZone(identifier: "America/New_York")!)
    }

    private func slice(_ day: String, _ quality: String, _ value: Double?, basis: String = "recorded") -> AnalyticsSlice {
        AnalyticsSlice(basis: basis, metrics: ["tokens_total": value], quality: ["tokens_total": quality],
                       knownSubtotals: ["tokens_total": value], day: day)
    }

    func testLocalDatesAcrossDSTAndEndpoints() {
        let series = AnalyticsTrendSeries(samples: [], query: query(5))
        XCTAssertEqual(series.days.map(\.date), ["2026-03-06", "2026-03-07", "2026-03-08", "2026-03-09", "2026-03-10"])
        XCTAssertEqual(series.days.map(\.sample), Array(repeating: .missing, count: 5))
        XCTAssertEqual(series.days.indices.map(series.position), [0, 0.25, 0.5, 0.75, 1])
        XCTAssertEqual(series.missingRanges, ["03-06–03-10"])
        XCTAssertEqual(AnalyticsTrendSeries(samples: [], query: query(1)).position(0), 0.5)
    }

    func testOnlyAdjacentCompleteDaysConnectAndZeroIsPlotted() {
        let series = AnalyticsTrendSeries(samples: [
            slice("2026-03-03", "complete", 0), slice("2026-03-04", "complete", 2),
            slice("2026-03-05", "complete", 100, basis: "sampled"), slice("2026-03-06", "complete", 3),
            slice("2026-03-07", "partial", 0), slice("2026-03-08", "complete", 4),
            slice("2026-03-09", "unknown", 99), slice("2026-03-10", "partial", nil)
        ], query: query(8))
        XCTAssertEqual(series.days.map(\.sample), [.complete(0), .complete(2), .missing, .complete(3),
                                                .partial(0), .complete(4), .unknown, .partial(nil)])
        XCTAssertEqual(series.days.map(\.sample.value), [0, 2, nil, 3, 0, 4, nil, nil])
        XCTAssertEqual(series.days.indices.filter(series.joinsPrevious), [1])
        XCTAssertEqual(series.missingRanges, ["03-05"])
    }

    func testMissingRangesSplitByObservedDaysEvenWhenTotalsAreUnknown() {
        let series = AnalyticsTrendSeries(samples: [slice("2026-03-07", "unknown", nil),
                                                   slice("2026-03-09", "partial", nil)], query: query(6))
        XCTAssertEqual(series.missingRanges, ["03-05–03-06", "03-08", "03-10"])
        let unknown = AnalyticsTrendSeries(samples: [slice("2026-03-10", "unknown", nil)], query: query(1))
        XCTAssertTrue(unknown.missingRanges.isEmpty)
    }
}
