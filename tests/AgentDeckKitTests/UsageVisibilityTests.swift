import XCTest
@testable import AgentDeckKit

final class UsageVisibilityTests: XCTestCase {
    private func usage(_ fields: [String: Any]) throws -> UsageResponse {
        var json: [String: Any] = ["days": [], "claudeDaily": [:], "codexDaily": [:],
                                   "costDaily": [:], "hourly": []]
        json.merge(fields) { _, new in new }
        return try JSONDecoder().decode(UsageResponse.self,
            from: JSONSerialization.data(withJSONObject: json))
    }

    private func project(_ name: String, agents: [String: Double]?, cost: Double = 50,
                         costs: [String: Double]? = nil) -> [String: Any] {
        var json: [String: Any] = ["name": name, "cwd": "/work/\(name)",
                                   "tokens": agents?.values.reduce(0, +) ?? 100, "cost": cost]
        if let agents { json["agents"] = agents }
        if let costs { json["costsByAgent"] = costs }
        return json
    }

    func testFullCandidatesAreFilteredBeforeRankingAndLimit() throws {
        let hidden = (0..<6).map { project("hidden\($0)", agents: ["claude": 10_000]) }
        let visible = (1...7).map { project("visible\($0)", agents: ["codex": Double($0)]) }
        let snapshot = try usage(["projects7d": hidden, "projectsAll7d": hidden + visible])

        let rows = UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"])
        XCTAssertEqual(rows.map(\.name), ["visible7", "visible6", "visible5", "visible4", "visible3", "visible2"])
        XCTAssertEqual(rows.map(\.tokens), [7, 6, 5, 4, 3, 2])
    }

    func testMixedProjectReaggregatesTokensAndCostsOnSameSnapshot() throws {
        let snapshot = try usage(["projectsAll7d": [
            project("mixed", agents: ["claude": 900, "codex": 100, "qoder": 50],
                    cost: 102, costs: ["claude": 2, "codex": 100, "qoder": 0])]])

        let codex = try XCTUnwrap(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"]).first)
        XCTAssertEqual(codex.tokens, 100)
        XCTAssertEqual(codex.cost, 100)
        XCTAssertEqual(codex.agents, ["codex": 100])
        let claude = try XCTUnwrap(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["claude"]).first)
        XCTAssertEqual(claude.tokens, 900)
        XCTAssertEqual(claude.cost, 2)
        let qoder = try XCTUnwrap(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["qoder"]).first)
        XCTAssertEqual(qoder.tokens, 50)
        XCTAssertEqual(qoder.cost, 0)
        XCTAssertTrue(UsageVisibilityPolicy.projects(snapshot, visibleAgents: []).isEmpty)
    }

    func testLegacyMixedCostIsOmittedRatherThanEstimated() throws {
        let snapshot = try usage(["projects7d": [
            project("mixed", agents: ["claude": 900, "codex": 100], cost: 102),
            project("single", agents: ["codex": 20], cost: 4)]])

        let filtered = UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"])
        XCTAssertEqual(filtered.map(\.tokens), [100, 20])
        XCTAssertNil(filtered[0].cost)
        XCTAssertEqual(filtered[1].cost, 4)
        let all = UsageVisibilityPolicy.projects(snapshot, visibleAgents: UsageVisibilityPolicy.allAgents)
        XCTAssertEqual(all[0].tokens, 1000)
        XCTAssertEqual(all[0].cost, 102)
    }

    func testLegacyUnattributedProjectRequiresAllAgentsVisible() throws {
        let snapshot = try usage(["projects7d": [project("unattributed", agents: nil)]])
        XCTAssertTrue(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"]).isEmpty)
        let all = UsageVisibilityPolicy.projects(snapshot, visibleAgents: UsageVisibilityPolicy.allAgents)
        XCTAssertEqual(all.first?.tokens, 100)
        XCTAssertEqual(all.first?.cost, 50)
    }

    func testEmptyFullCandidateListDoesNotFallBackToStaleTopSix() throws {
        let snapshot = try usage(["projectsAll7d": [], "projects7d": [
            project("stale", agents: ["codex": 100])]])
        XCTAssertTrue(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"]).isEmpty)
    }

    func testEqualTokenRankingIsDeterministicAndZeroRowsAreExcluded() throws {
        let snapshot = try usage(["projectsAll7d": [
            project("b", agents: ["codex": 10]), project("a", agents: ["codex": 10]),
            project("zero", agents: ["codex": 0])]])
        XCTAssertEqual(UsageVisibilityPolicy.projects(snapshot, visibleAgents: ["codex"]).map(\.name), ["a", "b"])
    }

    func testHeaderSumsOnlyVisibleAgentCosts() throws {
        let snapshot = try usage(["cost7d": 999, "cost30d": 999,
                                  "claudeCost7d": 2.5, "claudeCost30d": 5,
                                  "codexCost7d": 10, "codexCost30d": 20])
        let codex = UsageVisibilityPolicy.costs(snapshot, visibleAgents: ["codex"])
        XCTAssertEqual(codex.sevenDay, 10)
        XCTAssertEqual(codex.thirtyDay, 20)
        let claude = UsageVisibilityPolicy.costs(snapshot, visibleAgents: ["claude"])
        XCTAssertEqual(claude.sevenDay, 2.5)
        XCTAssertEqual(claude.thirtyDay, 5)
        let all = UsageVisibilityPolicy.costs(snapshot, visibleAgents: UsageVisibilityPolicy.allAgents)
        XCTAssertEqual(all.sevenDay, 12.5)
        XCTAssertEqual(all.thirtyDay, 25)
        let selections: [Set<String>] = [[], ["qoder"]]
        for visible in selections {
            let costs = UsageVisibilityPolicy.costs(snapshot, visibleAgents: visible)
            XCTAssertEqual(costs.sevenDay, 0)
            XCTAssertEqual(costs.thirtyDay, 0)
        }
    }
}
