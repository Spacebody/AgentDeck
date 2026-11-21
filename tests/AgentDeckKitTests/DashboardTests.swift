import XCTest
import SwiftUI
@testable import AgentDeckKit

final class DashboardTests: XCTestCase {
    @MainActor func testIslandTextMeetsContrastForAgentColors() {
        let colors = Brand.allCases.map { agentAccentInk($0.rawValue) } +
            [NSColor.black, .darkGray, .gray, .blue, .red, .white]
        for accent in colors {
            let palette = IslandPalette(accent: accent)
            let base = IslandPalette.luminance(palette.background) + 0.05
            XCTAssertGreaterThanOrEqual((IslandPalette.luminance(palette.ink) + 0.05) / base, 7)
            XCTAssertGreaterThanOrEqual((IslandPalette.luminance(IslandPalette.subtitle) + 0.05) / base, 4.5)
            let original = accent.usingColorSpace(.sRGB)!
            if (IslandPalette.luminance(original) + 0.05) / base >= 7 {
                XCTAssertEqual(palette.ink, original)
            }
        }
    }

    @MainActor func testIslandAccentTracksPanelIncludingResetForEveryAgent() {
        let palette = AgentColors.shared
        let saved = palette.overrides
        defer { palette.replace(saved) }
        for overrides: [Brand: Color] in [[:], [.claude: .green, .codex: .orange,
                                               .qoder: .pink, .qoderCn: .indigo], [:]] {
            palette.replace(overrides)
            for brand in Brand.allCases {
                let actual = IslandPalette(tool: brand.rawValue.uppercased())
                let expected = IslandPalette(accent: NSColor(brand.accent))
                XCTAssertEqual(actual.ink, expected.ink)
                XCTAssertEqual(actual.background, expected.background)
            }
        }
    }

    @MainActor func testImportedFolderSurvivesRefreshAndForgetKeepsFiles() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("file")
        try Data().write(to: file)
        let cwd = folder.standardizedFileURL.resolvingSymlinksInPath().path
        let existing = ProjectItem(cwd: cwd, name: suite, mtime: 1, count: 3, active: [])
        let store = ProjectStore(projects: [existing], defaults: defaults)
        store.importDirectories([folder, file, folder])
        XCTAssertEqual(store.imported, [cwd])
        XCTAssertEqual(store.projects.map(\.count), [3])
        await store.refresh(agents: [])
        XCTAssertEqual(store.projects.map(\.cwd), [cwd])
        let reopened = ProjectStore(defaults: defaults)
        XCTAssertEqual(reopened.projects.map(\.cwd), [cwd])
        reopened.forgetDirectory(cwd)
        XCTAssertTrue(ProjectStore(defaults: defaults).projects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func fixture(_ override: [String: Any] = [:]) throws -> UsageResponse {
        var fields: [String: Any] = [
            "days": (1...30).map { String(format: "2026-11-%02d", $0) },
            "claudeDaily": ["2026-11-30": ["sonnet": [100.0, 20.0]]],
            "codexDaily": ["2026-11-01": 1000.0, "2026-11-30": 200.0],
            "qoderDaily": ["2026-11-30": 500.0], "costDaily": [:], "hourly": [],
            "costsByAgentDaily": ["claude": ["2026-11-30": 1.0],
                                  "codex": ["2026-11-01": 2.0, "2026-11-30": 3.0],
                                  "qoder": ["2026-11-30": NSNull()]]
        ]
        fields.merge(override) { _, new in new }
        return try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testRangeControlsEveryTotalAndRespectsVisibility() throws {
        let usage = try fixture()
        let seven = UsageRangeSummary(usage: usage, span: 7, visible: ["codex"])
        XCTAssertEqual(seven.days.count, 7)
        XCTAssertEqual(seven.total, 200)
        XCTAssertEqual(seven.cost, 3)
        XCTAssertEqual(seven.agents.map(\.0), ["codex"])
        let thirty = UsageRangeSummary(usage: usage, span: 30, visible: ["codex", "claude"])
        XCTAssertEqual(thirty.total, 1320)
        XCTAssertEqual(thirty.cost, 6)
    }

    func testUnknownCostsRemainUnavailableAndZeroUsageIsSafe() throws {
        let usage = try fixture()
        XCTAssertNil(UsageRangeSummary(usage: usage, span: 7, visible: ["qoder"]).cost)
        let none = UsageRangeSummary(usage: usage, span: 30, visible: [])
        XCTAssertEqual(none.total, 0)
        XCTAssertEqual(none.cost, 0)
        XCTAssertTrue(none.agents.isEmpty)
        XCTAssertTrue(none.projects.isEmpty)
    }

    func testProjectRankingUsesSelectedRangeBeforeFiltering() throws {
        let project: (String, Double) -> [String: Any] = { name, tokens in
            ["name": name, "cwd": "/work/" + name, "tokens": tokens, "cost": 0,
             "agents": ["codex": tokens]]
        }
        let usage = try fixture(["projectsAll7d": [project("recent", 10)],
                                 "projectsAll30d": [project("old", 100), project("recent", 10)]])
        XCTAssertEqual(UsageRangeSummary(usage: usage, span: 7, visible: ["codex"]).projects.map { $0.0.name }, ["recent"])
        XCTAssertEqual(UsageRangeSummary(usage: usage, span: 30, visible: ["codex"]).projects.map { $0.0.name }, ["old", "recent"])
        XCTAssertTrue(UsageRangeSummary(usage: usage, span: 30, visible: ["claude"]).projects.isEmpty)
    }

    func testDashboardKeysExistInAllLanguages() {
        let keys = I18N.table["zh-CN"]!.keys.filter { $0.hasPrefix("v3.") || $0 == "tab.projects" || $0 == "tab.usage" }
        for locale in ["zh-CN", "en", "ja"] {
            for key in keys { XCTAssertNotNil(I18N.table[locale]?[key], "\(locale):\(key)") }
        }
    }
}
