import XCTest
@testable import AgentDeckKit

final class LoopbackSessionPolicyTests: XCTestCase {
    func testAppKitSessionUsesSameRedirectDelegateAsAPIClient() throws {
        let session = LoopbackSessionPolicy.makeSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(session.delegate as? APIRequestDelegate)
        let original = URL(string: "http://127.0.0.1:7777/api/shutdown")!
        let destination = URL(string: "https://example.com/collect")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 307, httpVersion: nil,
                                       headerFields: ["Location": destination.absoluteString])!
        var called = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: destination)) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
    }
}
