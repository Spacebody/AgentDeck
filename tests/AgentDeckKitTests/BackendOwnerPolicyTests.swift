import XCTest
@testable import AgentDeckKit

final class BackendOwnerPolicyTests: XCTestCase {
    private let installed = "/Applications/AgentDeck.app/Contents/Resources/agentdeckd.py"
    private let checkout = "/Users/test/AgentDeck.app/Contents/Resources/agentdeckd.py"

    func testTransientHealthMissWaitsOnlyForRunningOwnedBackend() {
        XCTAssertTrue(BackendOwnerPolicy.shouldWaitForOwnedBackend(
            forceRestart: false, healthAlive: false, ownedProcessRunning: true))
        XCTAssertFalse(BackendOwnerPolicy.shouldWaitForOwnedBackend(
            forceRestart: true, healthAlive: false, ownedProcessRunning: true))
        XCTAssertFalse(BackendOwnerPolicy.shouldWaitForOwnedBackend(
            forceRestart: false, healthAlive: true, ownedProcessRunning: true))
        XCTAssertFalse(BackendOwnerPolicy.shouldWaitForOwnedBackend(
            forceRestart: false, healthAlive: false, ownedProcessRunning: false))
    }

    func testBackendIdentityRequiresPIDVersionAndOwnerToken() {
        XCTAssertTrue(BackendOwnerPolicy.belongsToCurrentApp(
            alive: true, remoteVersion: "2.8.0", remoteParentPID: 123,
            remoteUpdateTransaction: nil, remoteOwnerToken: "owner",
            currentPID: 123, currentVersion: "2.8.0",
            expectedUpdateTransaction: nil, expectedOwnerToken: "owner"))
        XCTAssertFalse(BackendOwnerPolicy.belongsToCurrentApp(
            alive: true, remoteVersion: "2.8.0", remoteParentPID: 123,
            remoteUpdateTransaction: nil, remoteOwnerToken: "old-owner",
            currentPID: 123, currentVersion: "2.8.0",
            expectedUpdateTransaction: nil, expectedOwnerToken: "owner"))
    }

    func testUpdateIdentityAlsoRequiresTransactionToken() {
        XCTAssertFalse(BackendOwnerPolicy.belongsToCurrentApp(
            alive: true, remoteVersion: "2.8.0", remoteParentPID: 123,
            remoteUpdateTransaction: "old", remoteOwnerToken: "owner",
            currentPID: 123, currentVersion: "2.8.0",
            expectedUpdateTransaction: "new", expectedOwnerToken: "owner"))
        XCTAssertTrue(BackendOwnerPolicy.belongsToCurrentApp(
            alive: true, remoteVersion: "2.8.0", remoteParentPID: 123,
            remoteUpdateTransaction: "new", remoteOwnerToken: "owner",
            currentPID: 123, currentVersion: "2.8.0",
            expectedUpdateTransaction: "new", expectedOwnerToken: "owner"))
    }

    func testSameVersionAndScriptSharesLiveOwner() {
        XCTAssertTrue(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: "2.6.2", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testNewAppReplacesOlderDaemonEvenAtSameScriptPath() {
        XCTAssertFalse(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: "2.6.1", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testOldAppSharesNewerDaemonInsteadOfTakingItBack() {
        XCTAssertTrue(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.1", currentScript: installed,
            remoteVersion: "2.6.2", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testReleaseVersionWinsOverPrerelease() {
        XCTAssertFalse(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: "2.6.2-beta.10", remoteScript: installed,
            remoteOwnerIsAlive: true))
        XCTAssertTrue(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2-beta.2", currentScript: installed,
            remoteVersion: "2.6.2", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testBuildMetadataDoesNotChangeVersionPrecedence() {
        XCTAssertTrue(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2+local", currentScript: checkout,
            remoteVersion: "2.6.2+release", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testInstalledBundleWinsSameVersionCrossBundleRace() {
        XCTAssertFalse(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: "2.6.2", remoteScript: checkout,
            remoteOwnerIsAlive: true))
        XCTAssertTrue(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: checkout,
            remoteVersion: "2.6.2", remoteScript: installed,
            remoteOwnerIsAlive: true))
    }

    func testDeadOrUnidentifiedOwnerIsNeverShared() {
        XCTAssertFalse(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: "2.6.2", remoteScript: installed,
            remoteOwnerIsAlive: false))
        XCTAssertFalse(BackendOwnerPolicy.shouldShare(
            currentVersion: "2.6.2", currentScript: installed,
            remoteVersion: nil, remoteScript: installed,
            remoteOwnerIsAlive: true))
    }
}
