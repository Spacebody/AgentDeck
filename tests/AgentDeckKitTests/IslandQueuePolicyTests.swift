import XCTest
@testable import AgentDeckKit

final class IslandQueuePolicyTests: XCTestCase {
    private func event(
        _ index: Int, kind: String = "", key: String = "", title: String? = nil
    ) -> IslandEvent {
        IslandEvent(
            tool: "codex", title: title ?? "event-\(index)", project: "stress",
            session: "session-\(index)", cwd: "/work/stress", kind: kind,
            level: kind == "alert" ? "warn" : "", dedupeKey: key)
    }

    func testHundredCompletionBurstStaysFIFOAheadOfCoalescedAlerts() {
        var queue = IslandEventQueue()

        for index in 0..<100 {
            queue.enqueue(event(index))
            queue.enqueue(event(index, kind: "alert", key: "window-\(index % 4)"))
        }

        XCTAssertEqual(queue.count, 104)
        for index in 0..<100 {
            XCTAssertEqual(queue.popFirst()?.session, "session-\(index)")
        }
        let alerts = (0..<4).compactMap { _ in queue.popFirst() }
        XCTAssertEqual(Set(alerts.map(\.dedupeKey)), Set((0..<4).map { "window-\($0)" }))
        XCTAssertTrue(alerts.allSatisfy { $0.kind == "alert" })
        XCTAssertTrue(queue.isEmpty)
    }

    func testQueuedAlertKeepsLatestPayloadForItsWindow() {
        var queue = IslandEventQueue()
        queue.enqueue(event(1, kind: "alert", key: "weekly", title: "80%"))
        queue.enqueue(event(2, kind: "alert", key: "weekly", title: "95%"))

        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.popFirst()?.title, "95%")
    }

    func testCatchUpDeadlineUsesTwoSecondsEvenForLongConfiguredDwell() {
        let shownAt = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            IslandQueueTiming.deadline(
                shownAt: shownAt, configuredDwell: 30, hasPending: true),
            Date(timeIntervalSince1970: 102))
        XCTAssertEqual(
            IslandQueueTiming.deadline(
                shownAt: shownAt, configuredDwell: 30, hasPending: false),
            Date(timeIntervalSince1970: 130))
    }
}
