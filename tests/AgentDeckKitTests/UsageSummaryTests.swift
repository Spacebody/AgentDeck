import Foundation
import Testing
@testable import AgentDeckKit

@Test func todaySummaryIncludesQoderTokensAndHourlyTrend() throws {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let usage = UsageResponse(
        days: ["2026-08-12"],
        claudeDaily: ["2026-08-12": ["sonnet": [10, 0, 0, 0, 0]]],
        codexDaily: ["2026-08-12": 20],
        qoderDaily: ["2026-08-12": 30],
        costDaily: ["2026-08-12": 1.5],
        hourly: [
            HourBucket(ts: now.timeIntervalSince1970 - 3_600, c: 10, x: 20, q: 30),
            HourBucket(ts: now.timeIntervalSince1970 - 90_000, c: 5, x: 10, q: 15),
        ],
        projects7d: nil,
        cost7d: 1.5, cost30d: 1.5,
        claudeCost7d: 0.5, claudeCost30d: 0.5,
        codexCost7d: 1, codexCost30d: 1,
        coverage: nil)

    let summary = try #require(TodaySummary(from: usage, now: now))

    #expect(summary.totalTokens == 60)
    #expect(summary.byFamily[.qoder] == 30)
    #expect(summary.deltaPercent == 100)
}

@Test func todaySummaryHonorsVisibleAgents() throws {
    let usage = UsageResponse(
        days: ["2026-08-12"], claudeDaily: ["2026-08-12": [:]],
        codexDaily: ["2026-08-12": 20], qoderDaily: ["2026-08-12": 30],
        costDaily: ["2026-08-12": 1], hourly: [], projects7d: nil,
        cost7d: nil, cost30d: nil, claudeCost7d: nil, claudeCost30d: nil,
        codexCost7d: nil, codexCost30d: nil, coverage: nil)

    let summary = try #require(TodaySummary(
        from: usage, visibleAgents: ["qoder"]))

    #expect(summary.totalTokens == 30)
    #expect(summary.byFamily[.qoder] == 30)
    #expect(summary.byFamily[.codex] == nil)
}

@Test func usageResponseStillDecodesWithoutQoderFields() throws {
    let json = """
    {
      "days": ["2026-08-12"],
      "claude_daily": {"2026-08-12": {}},
      "codex_daily": {"2026-08-12": 0},
      "cost_daily": {"2026-08-12": 0},
      "hourly": [{"ts": 1, "c": 0, "x": 0}]
    }
    """
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let usage = try decoder.decode(UsageResponse.self, from: Data(json.utf8))

    #expect(usage.qoderDaily == nil)
    #expect(usage.hourly.first?.q == nil)
}
