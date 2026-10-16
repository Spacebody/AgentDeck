import XCTest
@testable import AgentDeckKit

final class SessionPerformanceTests: XCTestCase {
    func testOnlyExplicitAverageCanDisplayRate() {
        XCTAssertNil(SessionPerformance(state: "active", tokensPerSecond: 50).rate)
        XCTAssertNil(SessionPerformance(state: "stale", mode: "turn_average", tokensPerSecond: 50).rate)
        XCTAssertNil(SessionPerformance(state: "active", mode: "turn_average", tokensPerSecond: .infinity).rate)
        XCTAssertNil(SessionPerformance(state: "completed", mode: "turn_average", tokensPerSecond: -1).rate)
        XCTAssertEqual(SessionPerformance(state: "completed", mode: "turn_average", tokensPerSecond: 12).rate, 12)
    }

    func testIdentitySeparatesAgentsAccountsAndSources() {
        let base = SessionPerformanceRequest(tool: "codex", account: "default", source: "transcript", id: "same")
        XCTAssertNotEqual(base.key, SessionPerformanceRequest(tool: "claude", account: "default", source: "transcript", id: "same").key)
        XCTAssertNotEqual(base.key, SessionPerformanceRequest(tool: "codex", account: "other", source: "transcript", id: "same").key)
        XCTAssertNotEqual(base.key, SessionPerformanceRequest(tool: "codex", account: "default", source: "qoder_app", id: "same").key)
    }

    @MainActor func testLocalizationLabelsAndUnsupportedState() {
        let previous = I18N.locale
        defer { I18N.locale = previous }
        for locale in ["zh-CN", "en", "ja"] {
            I18N.locale = locale
            let label = SessionPerformance(state: "active", mode: "turn_average", tokensPerSecond: 12.3).label
            XCTAssertTrue(label?.contains("12.3") == true)
            XCTAssertFalse(label?.contains("{rate}") == true)
            XCTAssertNil(SessionPerformance(state: "unavailable").label)
        }
    }
}
