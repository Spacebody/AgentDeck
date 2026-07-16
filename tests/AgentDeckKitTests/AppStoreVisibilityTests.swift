import XCTest
@testable import AgentDeckKit

final class AppStoreVisibilityTests: XCTestCase {
    @MainActor
    func testConfiguredVisibilityOverridesQuotaHiddenFallback() {
        let store = AppStore()

        XCTAssertFalse(store.agentOn("claude", fallbackHidden: true))
        XCTAssertTrue(store.agentOn("codex", fallbackHidden: false))

        store.settings["show_claude"] = .bool(true)
        store.settings["show_codex"] = .bool(false)

        XCTAssertTrue(store.agentOn("claude", fallbackHidden: true))
        XCTAssertFalse(store.agentOn("codex", fallbackHidden: false))
    }

    @MainActor
    func testSessionListsUseQuotaHiddenBeforeSettingsLoad() {
        let store = AppStore()
        let hiddenClaude = QuotaNode(
            ok: false, hidden: true, accountId: nil, account: nil, isDefault: true,
            kind: nil, windows: nil, error: nil, noQuota: nil, sampledAt: nil,
            stale: nil, credits: nil, raw: nil)
        let visibleCodex = QuotaNode(
            ok: true, hidden: false, accountId: nil, account: nil, isDefault: true,
            kind: nil, windows: [], error: nil, noQuota: nil, sampledAt: nil,
            stale: nil, credits: nil, raw: nil)
        store.quota = QuotaResponse(
            claude: hiddenClaude, codex: visibleCodex,
            accounts: nil, menubar: nil, ts: nil)
        store.sessions = [
            SessionItem(tool: "Claude", id: "c", title: nil, cwd: nil, project: nil,
                        branch: nil, mtime: 1, account: nil, accountId: nil, pinned: nil),
            SessionItem(tool: "Codex", id: "x", title: nil, cwd: nil, project: nil,
                        branch: nil, mtime: 1, account: nil, accountId: nil, pinned: nil),
        ]

        XCTAssertEqual(store.sessionsShown.map(\.tool), ["Codex"])
    }

    func testUnacknowledgedLocalMutationWinsOverStaleSettingsResponse() {
        let merged = mergeLoadedSettings(
            remote: ["show_claude": .bool(true)],
            current: ["show_claude": .bool(false)],
            pending: [:],
            mutationVersions: ["show_claude": 4],
            acknowledgedVersionsAtRequest: ["show_claude": 3])

        XCTAssertEqual(merged["show_claude"], .bool(false))
    }

    func testPendingValueWinsEvenWhenMutationWasAlreadyAcknowledged() {
        let merged = mergeLoadedSettings(
            remote: ["show_codex": .bool(true)],
            current: ["show_codex": .bool(false)],
            pending: ["show_codex": .bool(false)],
            mutationVersions: ["show_codex": 8],
            acknowledgedVersionsAtRequest: ["show_codex": 8])

        XCTAssertEqual(merged["show_codex"], .bool(false))
    }

    func testAcknowledgedSettingAcceptsFreshRemoteValue() {
        let merged = mergeLoadedSettings(
            remote: ["show_claude": .bool(true)],
            current: ["show_claude": .bool(false)],
            pending: [:],
            mutationVersions: ["show_claude": 5],
            acknowledgedVersionsAtRequest: ["show_claude": 5])

        XCTAssertEqual(merged["show_claude"], .bool(true))
    }

    func testFailedSaveRetriesOnlyChangesNotIncludedInFailedBatch() {
        XCTAssertFalse(hasUnattemptedSettingChanges(
            pending: ["show_claude": .bool(false)],
            mutationVersions: ["show_claude": 3],
            attemptedVersions: ["show_claude": 3]))

        XCTAssertTrue(hasUnattemptedSettingChanges(
            pending: ["show_claude": .bool(true)],
            mutationVersions: ["show_claude": 4],
            attemptedVersions: ["show_claude": 3]))

        XCTAssertTrue(hasUnattemptedSettingChanges(
            pending: ["show_codex": .bool(false)],
            mutationVersions: ["show_codex": 5],
            attemptedVersions: [:]))
    }
}
