import XCTest
@testable import AgentDeckKit

final class UsageNavigationTests: XCTestCase {
    private let project = UsageDestination(scope: .project("/repo"), title: "Repo", agents: ["codex"])

    func testScopedPushRetainsOriginAndSelectsUsageIndicator() {
        var nav = UsageNavigation(tab: "projects")
        nav.open(project)
        XCTAssertEqual(nav.tab, "projects")
        XCTAssertEqual(nav.selectedTab, "usage")
        XCTAssertEqual(nav.destination, project)
        nav.back()
        XCTAssertEqual(nav.selectedTab, "projects")
        XCTAssertNil(nav.destination)
    }

    func testProjectTracksVisibilityChangesButSessionNeverWidens() {
        XCTAssertEqual(project.visibleAgents(in: ["claude", "codex"]), ["claude", "codex"])
        let session = UsageDestination(scope: .session(agent: "codex", account: nil, source: nil, id: "s"),
                                       title: "S", agents: ["codex"])
        XCTAssertEqual(session.visibleAgents(in: ["claude", "codex"]), ["codex"])
        XCTAssertTrue(session.visibleAgents(in: ["claude"]).isEmpty)
    }

    func testTabSelectionFromScopedUsageAlwaysDropsTheScope() {
        for target in ["usage", "overview", "sessions", "projects"] {
            var nav = UsageNavigation(tab: "sessions")
            nav.open(project)
            nav.select(target)
            XCTAssertNil(nav.destination)
            XCTAssertEqual(nav.tab, target)
            XCTAssertEqual(nav.selectedTab, target)
        }
    }

    func testSingleDayTrendDetectionIncludesBothDSTTransitions() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for stamp in ["2025-03-09T20:00:00Z", "2025-11-02T20:00:00Z"] {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: stamp))
            for days in [1, 7, 30] {
                let query = AnalyticsQuery(days: days, agents: ["codex"], dimension: "model",
                                           basis: "recorded", scope: .all, now: date, timezone: zone)
                XCTAssertEqual(query.isSingleCalendarDay, days == 1)
            }
        }
    }
}
