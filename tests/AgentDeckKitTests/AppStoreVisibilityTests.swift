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

    func testQuotaChangesResponseDecodesDaemonRestartCursor() throws {
        let data = Data("""
        {
          "boot_id": "boot-2",
          "revision": 17,
          "quota": {
            "claude": {"ok": false, "hidden": true},
            "codex": {
              "ok": true,
              "windows": [{
                "id": "seven_day",
                "label": "Weekly",
                "used_percent": 50,
                "resets_at": 1785258146
              }]
            },
            "accounts": {"claude": [], "codex": []},
            "ts": 1784819000
          }
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(QuotaChangesResponse.self, from: data)

        XCTAssertEqual(response.bootId, "boot-2")
        XCTAssertEqual(response.revision, 17)
        XCTAssertEqual(response.quota.codex?.displayWindows.first?.usedPercent, 50)
    }

    func testQuotaResponseDecodesSnapshotVersion() throws {
        let data = Data("""
        {
          "claude": {"ok": false},
          "codex": {"ok": false},
          "quota_revision": 12,
          "quota_boot_id": "boot-a"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(QuotaResponse.self, from: data)

        XCTAssertEqual(response.quotaRevision, 12)
        XCTAssertEqual(response.quotaBootId, "boot-a")
    }

    func testQuotaPushAllowsMatchingRevisionOrdinaryResponseToCompleteSnapshot() {
        var gate = QuotaSnapshotGate()
        let slowRequest = gate.beginRequest()

        XCTAssertTrue(gate.accept(bootId: "boot-a", revision: 2, request: nil))
        XCTAssertTrue(gate.accept(
            bootId: "boot-a", revision: 2, request: slowRequest))
        XCTAssertFalse(gate.accept(
            bootId: "boot-a", revision: 1, request: slowRequest))
        XCTAssertFalse(gate.canReportFailure(for: slowRequest))
    }

    func testQuotaGateRejectsOutOfOrderOrdinaryResponses() {
        var gate = QuotaSnapshotGate()
        let first = gate.beginRequest()
        let second = gate.beginRequest()

        XCTAssertTrue(gate.accept(bootId: "boot-a", revision: 4, request: second))
        XCTAssertFalse(gate.accept(bootId: "boot-a", revision: 3, request: first))
    }

    func testQuotaGateAcceptsHigherRevisionFromOlderRequest() {
        var gate = QuotaSnapshotGate()
        let forceRequest = gate.beginRequest()
        let ordinaryRequest = gate.beginRequest()

        XCTAssertTrue(gate.accept(
            bootId: "boot-a", revision: 4, request: ordinaryRequest))
        XCTAssertTrue(gate.accept(
            bootId: "boot-a", revision: 5, request: forceRequest))
        XCTAssertEqual(gate.revision, 5)
    }

    func testQuotaGateAcceptsNewDaemonBootAfterRestart() {
        var gate = QuotaSnapshotGate()

        XCTAssertTrue(gate.accept(bootId: "boot-a", revision: 19, request: nil))
        XCTAssertFalse(gate.accept(bootId: "boot-a", revision: 19, request: nil))
        XCTAssertTrue(gate.accept(bootId: "boot-b", revision: 1, request: nil))
        XCTAssertEqual(gate.bootId, "boot-b")
        XCTAssertEqual(gate.revision, 1)
    }

    @MainActor
    func testSessionPageCountUsesSelectedPageSize() {
        let store = AppStore()
        store.sessionsTotal = 95

        store.sessionPageSize = 20
        XCTAssertEqual(store.sessionPageCount, 5)

        store.sessionPageSize = 50
        XCTAssertEqual(store.sessionPageCount, 2)
    }

    func testNamedCodexWindowsRetainTheirKnownDuration() {
        let weekly = QuotaWindow(
            id: "seven_day_codex-bengalfox", label: "GPT-5.3-Codex-Spark",
            usedPercent: 5, resetsAt: nil)
        let fiveHour = QuotaWindow(
            id: "five_hour_codex-fast", label: "Fast",
            usedPercent: 7, resetsAt: nil)

        XCTAssertEqual(weekly.windowSeconds, 7 * 86400)
        XCTAssertEqual(fiveHour.windowSeconds, 5 * 3600)
    }

    func testQuotaHeaderUsesSampleTimeInsteadOfCreditsBalance() throws {
        let data = Data("""
        {
          "ok": true,
          "windows": [{
            "id": "seven_day",
            "used_percent": 12,
            "resets_at": 1785258146
          }],
          "sampled_at": "2026-07-24T15:00:00Z",
          "credits": {
            "hasCredits": true,
            "unlimited": false,
            "balance": "2500"
          }
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let node = try decoder.decode(QuotaNode.self, from: data)
        let now = try XCTUnwrap(Fmt.parseISO("2026-07-24T15:01:00Z"))

        let status = try XCTUnwrap(quotaStatusInfo(node: node, now: now))

        XCTAssertFalse(status.stale)
        XCTAssertFalse(status.text.contains("2500"))
        XCTAssertEqual(status.text, L("quota.sampledAt", ["time": L("time.minAgo", ["n": "1"])]))
    }
}
