import XCTest
@testable import AgentDeckKit

final class GatewayRestartTests: XCTestCase {
    func testAutomaticHandoffKeepsOriginalDeadlineAndCannotBePreempted() {
        let start = DispatchTime.now()
        var transition = GatewayTransition()
        XCTAssertTrue(transition.begin(manual: false, now: start))
        let epoch = transition.epoch
        transition.prepareHandoff()
        transition.prepareHandoff() // a different instance takes over the port
        XCTAssertFalse(transition.begin(manual: true))
        XCTAssertFalse(transition.begin(manual: false))
        XCTAssertEqual(transition.callback(for: epoch, now: start + .seconds(44)), .current)
        XCTAssertEqual(transition.callback(for: epoch, now: start + .seconds(45)), .expired)
        transition.end()
        XCTAssertTrue(transition.begin(manual: false))
        XCTAssertEqual(transition.callback(for: epoch), .stale)
    }

    func testManualSupersedesOnlyTheReadOnlyProbe() {
        var transition = GatewayTransition()
        XCTAssertTrue(transition.begin(manual: false))
        let probe = transition.epoch
        XCTAssertTrue(transition.begin(manual: true))
        XCTAssertEqual(transition.callback(for: probe), .stale)
        XCTAssertFalse(transition.begin(manual: false))
        XCTAssertFalse(transition.begin(manual: true))
    }

    func testRecoveryAfterFailureRequiresVacantPortExitedChildAndNoInstall() {
        var transition = GatewayTransition()
        XCTAssertTrue(transition.begin(manual: true))
        let manual = transition.epoch
        transition.end()
        XCTAssertFalse(transition.beginRecovery(refused: false, childRunning: false, installing: false))
        XCTAssertFalse(transition.beginRecovery(refused: true, childRunning: true, installing: false))
        XCTAssertFalse(transition.beginRecovery(refused: true, childRunning: false, installing: true))
        XCTAssertTrue(transition.beginRecovery(refused: true, childRunning: false, installing: false))
        XCTAssertEqual(transition.callback(for: manual), .stale)
        transition.prepareHandoff()
        XCTAssertEqual(transition.phase, .recovery)
        XCTAssertFalse(transition.begin(manual: true))
        XCTAssertFalse(transition.beginRecovery(refused: true, childRunning: false, installing: false))
    }

    func testStopWaitLaunchAndVerifyOwnership() {
        var attempt = GatewayRestartAttempt()
        XCTAssertEqual(attempt.next(running: true, ownedHealth: true, foreignHealth: false), .stopOwned)
        XCTAssertEqual(attempt.next(running: true, ownedHealth: false, foreignHealth: false), .wait)
        XCTAssertEqual(attempt.next(running: false, ownedHealth: true, foreignHealth: false), .wait)
        XCTAssertEqual(attempt.next(running: false, ownedHealth: false, foreignHealth: false), .launch)
        XCTAssertEqual(attempt.next(running: false, ownedHealth: false, foreignHealth: false), .wait)
        XCTAssertEqual(attempt.next(running: true, ownedHealth: false, foreignHealth: false), .wait)
        XCTAssertEqual(attempt.next(running: true, ownedHealth: true, foreignHealth: false), .ready)
    }

    func testForeignHealthNeverAuthorizesStopOrLaunch() {
        for running in [false, true] {
            var attempt = GatewayRestartAttempt()
            XCTAssertEqual(attempt.next(running: running, ownedHealth: false, foreignHealth: true), .foreign)
        }
    }

    func testTimeoutDoesNotSignalOrSpawnAndRetryGetsFreshBudget() {
        let start = DispatchTime.now()
        var attempt = GatewayRestartAttempt(start: start)
        XCTAssertEqual(attempt.next(running: true, ownedHealth: false, foreignHealth: false, now: start), .stopOwned)
        let expired = start + .seconds(20)
        for running in [false, true] {
            XCTAssertEqual(attempt.next(running: running, ownedHealth: false, foreignHealth: false, now: expired), .timedOut)
        }
        var retry = GatewayRestartAttempt(start: expired)
        XCTAssertEqual(retry.next(running: false, ownedHealth: false, foreignHealth: false, now: expired), .launch)
    }
}
