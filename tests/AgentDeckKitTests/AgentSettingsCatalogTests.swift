import XCTest
@testable import AgentDeckKit

final class AgentSettingsCatalogTests: XCTestCase {
    func testMenuWindowsAreSelectableWithoutSamples() {
        for agent in AgentSettingsCatalog.ids {
            let choices = AgentSettingsCatalog.windowChoices(agent: agent, quota: nil, selected: "")
            XCTAssertEqual(choices.first?.id, "")
            XCTAssertGreaterThan(choices.count, 1, agent)
            XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
            XCTAssertFalse(choices.contains { $0.title.hasPrefix("win.") })
        }
        let saved = "amount:future-bucket"
        let ids = AgentSettingsCatalog.windowChoices(agent: "antigravity", quota: nil, selected: saved).map(\.id)
        XCTAssertTrue(ids.contains("pct:gemini-weekly"))
        XCTAssertTrue(ids.contains(saved))
        XCTAssertFalse(ids.contains("pct:seven_day_sonnet"))
    }
    func testAgentCatalogOwnsUniqueIDsAndSettingKeys() {
        let agents = AgentSettingsCatalog.all
        XCTAssertEqual(Set(agents.map(\.id)).count, agents.count)

        let keys = agents.flatMap { [$0.showKey, $0.menubarKey, $0.colorKey] }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testAgentCatalogKeysAreIncludedInSettingsValueKinds() {
        for agent in AgentSettingsCatalog.all {
            assertKind(.bool, for: agent.showKey)
            assertKind(.bool, for: agent.menubarKey)
            assertKind(.string, for: agent.colorKey)
        }
    }

    func testEnabledCountUsesPanelVisibilityOnly() {
        let values: [String: SettingValue] = [
            "show_claude": .bool(true),
            "show_codex": .bool(false),
            "show_qoder": .bool(true),
            "show_qoder_cn": .bool(false),
            "show_antigravity": .bool(false),
            "menubar_codex": .bool(true),
        ]

        XCTAssertEqual(AgentSettingsCatalog.enabledCount(in: values), 2)
    }

    func testQoderCNIsRegisteredAsIndependentAgent() {
        let qoderCN = AgentSettingsCatalog.all.first { $0.id == "qoder_cn" }
        XCTAssertEqual(qoderCN?.name, "Qoder CN")
        XCTAssertEqual(qoderCN?.showKey, "show_qoder_cn")
        XCTAssertEqual(qoderCN?.menubarKey, "menubar_qoder_cn")
        XCTAssertEqual(qoderCN?.colorKey, "color_qoder_cn")
        XCTAssertEqual(qoderCN?.brand, .qoderCn)
        XCTAssertEqual(qoderCN?.defaultShow, false)
        XCTAssertEqual(qoderCN?.defaultMenubar, false)
    }

    private func assertKind(_ expected: SettingValueKind, for key: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = SettingsSchema.valueKinds[key] else {
            XCTFail("Missing value kind for \(key)", file: file, line: line)
            return
        }
        switch (expected, actual) {
        case (.bool, .bool), (.int, .int), (.string, .string): break
        default: XCTFail("Unexpected value kind for \(key)", file: file, line: line)
        }
    }
}
