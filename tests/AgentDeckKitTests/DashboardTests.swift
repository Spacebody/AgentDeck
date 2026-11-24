import XCTest
import SwiftUI
@testable import AgentDeckKit

final class DashboardTests: XCTestCase {
    @MainActor func testOverviewTrendSeparatesVisibleAgentsOnSameTimeAxis() {
        let end = 23.0 * 3600
        let hourly = [-1.0, 0, 60, end, end + 3600].map {
            HourBucket(ts: $0, c: 1, x: 2, q: 3, qcn: 4, ag: 5)
        }
        let series = DashboardTrend.series(hourly: hourly, agents: Set(Brand.allCases.map(\.rawValue)), end: end)
        XCTAssertEqual(series.map(\.brand), [.claude, .codex, .qoder, .qoderCn, .antigravity])
        XCTAssertEqual(series.map { $0.values[0] }, [2, 4, 6, 8, 10])
        XCTAssertEqual(series.map { $0.values[23] }, [1, 2, 3, 4, 5])
        XCTAssertTrue(series.allSatisfy { $0.values.count == 24 && $0.values[1] == ($0.brand == .antigravity ? nil : 0) })
        XCTAssertEqual(DashboardTrend.series(hourly: hourly, agents: ["codex"], end: end).map(\.brand), [.codex])
        XCTAssertTrue(DashboardTrend.series(hourly: hourly, agents: [], end: end).isEmpty)
    }

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
                                               .qoder: .pink, .qoderCn: .indigo, .antigravity: .green], [:]] {
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

    func testAntigravityRangeAndTodayUseObservedTokensOnly() throws {
        let usage = try fixture(["antigravityDaily": ["2026-11-30": 35]])
        let result = UsageRangeSummary(usage: usage, span: 7, visible: ["antigravity"])
        XCTAssertEqual(result.total, 35)
        XCTAssertNil(result.cost)
        XCTAssertEqual(TodaySummary(from: usage, visibleAgents: ["antigravity"])?.byAgent[.antigravity], 35)
        let missing = try fixture()
        XCTAssertNil(TodaySummary(from: missing, visibleAgents: ["antigravity"]))
        XCTAssertEqual(UsageRangeSummary(usage: missing, span: 7, visible: ["antigravity"]).tokenText, "—")
        let noTokens = try fixture(["codexDaily": [:]])
        for snapshot in [missing, noTokens] {
            XCTAssertNil(UsageRangeSummary(usage: snapshot, span: 7, visible: ["antigravity", "codex"]).cost)
        }
        XCTAssertEqual(UsageRangeSummary(usage: missing, span: 7, visible: ["codex"]).cost, 3)
    }

    @MainActor func testAntigravitySettingsAndQuotaContract() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let quota = try decoder.decode(QuotaResponse.self, from: Data(#"{"antigravity":{"ok":true,"remaining_amounts":[{"id":"credits","label":"Credits","remaining":42}]},"menubar":{"antigravity":false}}"#.utf8))
        let page = try XCTUnwrap(quota.flatPages().first)
        XCTAssertEqual(page.brand, .antigravity)
        XCTAssertEqual(page.account.remainingAmounts?.first?.remaining, 42)
        XCTAssertTrue(page.account.displayWindows.isEmpty)
        XCTAssertTrue(quota.flatPages(visibleAgents: []).isEmpty)
        XCTAssertEqual(quota.menubar?.antigravity, false)
        let store = AppStore()
        XCTAssertFalse(store.agentOn("antigravity"))
        XCTAssertFalse(store.menubarAgentEnabled("antigravity"))
        store.quota = quota
        XCTAssertTrue(store.agentOn("antigravity"))
        store.settings["show_antigravity"] = .bool(false)
        XCTAssertFalse(store.agentOn("antigravity"))
    }

    @MainActor func testAllFiveLegendItemsFitNarrowPanel() {
        let sizes = Brand.allCases.map { brand -> CGSize in
            let label = NSHostingView(rootView: HStack(spacing: 4) {
                Circle().frame(width: 7, height: 7)
                Text(brand.name).font(.caption)
            })
            return label.fittingSize
        }
        XCTAssertEqual(sizes.count, 5)
        for width: CGFloat in [180, 300, 380] {
            let frames = TrendLegendLayout.frames(sizes, width: width)
            XCTAssertTrue(frames.allSatisfy { $0.width > 0 && $0.maxX <= width })
            for (i, frame) in frames.enumerated() {
                XCTAssertFalse(frames.dropFirst(i + 1).contains { $0.intersects(frame) })
            }
            if width == 180 { XCTAssertGreaterThan(frames.last!.minY, 0) }
        }
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
