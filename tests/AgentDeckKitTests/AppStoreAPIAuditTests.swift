import XCTest
@testable import AgentDeckKit

private final class AuditURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handlers: [String: (AuditURLProtocol) -> Void] = [:]

    static func register(_ id: String, handler: @escaping (AuditURLProtocol) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = handler
    }

    static func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers[request.value(forHTTPHeaderField: "X-Audit-Test") ?? ""]
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        handler(self)
    }
    override func stopLoading() {}

    func respond(_ json: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AuditHeldRequest {
    private let lock = NSLock()
    private var request: AuditURLProtocol?
    private var hasHeld = false

    func holdFirst(_ value: AuditURLProtocol) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasHeld else { return false }
        hasHeld = true
        request = value
        return true
    }

    func respond(_ json: String) {
        lock.lock()
        let value = request
        request = nil
        lock.unlock()
        value?.respond(json)
    }
}

final class AppStoreAPIAuditTests: XCTestCase {
    private func api(handler: @escaping (AuditURLProtocol) -> Void) -> APIClient {
        let id = UUID().uuidString
        AuditURLProtocol.register(id, handler: handler)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuditURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Audit-Test": id]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            AuditURLProtocol.remove(id)
        }
        return APIClient(session: session)
    }

    func testRawGETRejectsMalformedJSONAndNonObjects() async {
        for payload in ["not json", "[]", "null", ""] {
            let client = api { $0.respond(payload) }
            do {
                _ = try await client.getJSON("/api/settings")
                XCTFail("Accepted invalid settings payload: \(payload)")
            } catch {}
        }
    }

    func testRawPOSTRejectsMalformedJSONAndNonObjects() async {
        for payload in ["not json", "[]", "null", ""] {
            let client = api { $0.respond(payload) }
            do {
                _ = try await client.postJSON("/api/settings", body: ["show_codex": true])
                XCTFail("Acknowledged invalid save payload: \(payload)")
            } catch {}
        }
    }

    func testRawJSONPreservesObjectsAndHTTPFailures() async throws {
        let client = api { request in
            if request.request.url?.path == "/failure" {
                request.respond("{}", status: 503)
            } else {
                request.respond(#"{"ok":true,"settings":{"language":"en"}}"#)
            }
        }
        let result = try await client.getJSON("/api/settings")
        XCTAssertEqual(result["ok"] as? Bool, true)
        do {
            _ = try await client.getJSON("/failure")
            XCTFail("Accepted HTTP failure")
        } catch APIError.http(let status) {
            XCTAssertEqual(status, 503)
        }
    }

    func testAllRequestMethodsRejectAuthorityAndEmbeddedQueryPaths() async {
        let client = api { _ in XCTFail("Invalid path reached transport") }
        for path in ["@example.com/api/data", "https://example.com/api/data",
                     "//example.com/api/data", "/api/data?action=clear", "/api/data#fragment"] {
            do {
                let _: OKResponse = try await client.get(path)
                XCTFail("GET accepted \(path)")
            } catch {}
            do {
                let _: OKResponse = try await client.post(path, body: ["action": "clear"])
                XCTFail("POST accepted \(path)")
            } catch {}
            do {
                _ = try await client.getJSON(path)
                XCTFail("Raw GET accepted \(path)")
            } catch {}
            do {
                _ = try await client.postJSON(path, body: ["action": "clear"])
                XCTFail("Raw POST accepted \(path)")
            } catch {}
        }
    }

    func testQueryValuesCannotInjectAdditionalParametersOrChangeOrigin() async throws {
        let value = "a&action=clear#fragment /?next=https://example.com"
        let client = api { request in
            let url = request.request.url!
            XCTAssertEqual(url.scheme, "http")
            XCTAssertEqual(url.host, "127.0.0.1")
            XCTAssertEqual(url.port, 7777)
            XCTAssertNil(url.fragment)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.count, 1)
            XCTAssertEqual(query.first?.name, "q")
            XCTAssertEqual(query.first?.value, value)
            request.respond("{}")
        }
        _ = try await client.getJSON("/api/sessions", query: ["q": value])
    }

    func testRedirectPolicyRefusesForwardingActionBodies() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "http://127.0.0.1:7777/api/resume")!
        let task = session.dataTask(with: original)
        let delegate = APIRequestDelegate()
        for destination in ["https://example.com/collect", "http://127.0.0.1:8888/api/data",
                            "http://127.0.0.1:7777/api/data"] {
            let response = HTTPURLResponse(url: original, statusCode: 307,
                                           httpVersion: nil, headerFields: ["Location": destination])!
            var request = URLRequest(url: URL(string: destination)!)
            request.httpMethod = "POST"
            request.httpBody = Data(#"{"cwd":"/private/project"}"#.utf8)
            var called = false
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: request) { redirected in
                called = true
                XCTAssertNil(redirected)
            }
            XCTAssertTrue(called)
        }
    }

    func testResumeActionEncodesUntrustedStringsAsJSONData() async throws {
        let path = "/tmp/project\"; $(touch /tmp/not-executed)\n"
        let client = api { request in
            XCTAssertEqual(request.request.url?.path, "/api/resume")
            XCTAssertEqual(request.request.httpMethod, "POST")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            var bytes = request.request.httpBody ?? Data()
            if let stream = request.request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            }
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            XCTAssertEqual(object?["cwd"] as? String, path)
            XCTAssertEqual(object?["replacement_cwd"] as? String, path)
            XCTAssertEqual(object?["copy_only"] as? Bool, true)
            XCTAssertEqual(object?["account_id"] as? String, "account&other=1")
            request.respond(#"{"ok":true,"copy":true}"#)
        }
        let result: ResumeResult = try await client.post("/api/resume", body: SessionResumeRequest(
            tool: "codex", id: "session", cwd: path, accountId: "account&other=1",
            copyOnly: true, replacementCwd: path, source: nil))
        XCTAssertTrue(result.ok)
    }

    @MainActor
    func testMalformedSettingsResponseDoesNotEraseCurrentSettings() async {
        let store = AppStore(api: api { $0.respond("not json") })
        store.settings = ["language": .string("en"), "show_codex": .bool(false)]
        await store.loadSettings()
        XCTAssertEqual(store.settings["language"], .string("en"))
        XCTAssertEqual(store.settings["show_codex"], .bool(false))
    }

    @MainActor
    func testSlowerRefreshCannotReplaceNewerActiveSnapshot() async {
        let held = AuditHeldRequest()
        let started = expectation(description: "old active request held")
        let client = api { request in
            switch request.request.url?.path {
            case "/api/active":
                if held.holdFirst(request) { started.fulfill() }
                else { request.respond(#"{"active":[{"tool":"codex","id":"new"}]}"#) }
            case "/api/events": request.respond(#"{"events":[]}"#)
            default: request.respond("{}")
            }
        }
        let store = AppStore(api: client)
        store.sessionQuery = "search"
        let old = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await store.refresh()
        XCTAssertEqual(store.active.first?.id, "new")
        held.respond(#"{"active":[{"tool":"codex","id":"old"}]}"#)
        _ = await old.value
        XCTAssertEqual(store.active.first?.id, "new")
    }

    @MainActor
    func testManualUpdateCheckWinsOverOlderPollingResponse() async {
        let held = AuditHeldRequest()
        let started = expectation(description: "old update request held")
        let client = api { request in
            switch request.request.url?.path {
            case "/api/update":
                _ = held.holdFirst(request)
                started.fulfill()
            case "/api/update/check": request.respond(#"{"available":true,"latest":"new"}"#)
            default: request.respond("{}")
            }
        }
        let store = AppStore(api: client)
        store.sessionQuery = "search"
        let old = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await store.checkUpdate()
        held.respond(#"{"available":false,"latest":"old"}"#)
        _ = await old.value
        XCTAssertEqual(store.update?.latest, "new")
        XCTAssertEqual(store.update?.available, true)
    }

    @MainActor
    func testManualUpdateCheckIsNotSupersededByNewPeriodicRequest() async {
        let held = AuditHeldRequest()
        let started = expectation(description: "manual update held")
        let client = api { request in
            if request.request.url?.path == "/api/update/check" {
                _ = held.holdFirst(request)
                started.fulfill()
            } else if request.request.url?.path == "/api/update" {
                XCTFail("Periodic update must not race an in-flight manual check")
                request.respond(#"{"available":false}"#)
            } else { request.respond("{}") }
        }
        let store = AppStore(api: client)
        store.sessionQuery = "search"
        let manual = Task { await store.checkUpdate() }
        await fulfillment(of: [started], timeout: 2)
        await store.refresh()
        held.respond(#"{"available":true,"latest":"new"}"#)
        await manual.value
        XCTAssertEqual(store.update?.latest, "new")
        XCTAssertEqual(store.update?.available, true)
    }

    @MainActor
    func testImmediateStartStopCancelsStartupLoads() async {
        let client = api { _ in XCTFail("Stopped startup task made a request") }
        let store = AppStore(api: client)
        store.start()
        store.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    @MainActor
    func testRestartRejectsDelayedPreStopSettingsAndQuotaReplies() async {
        let oldQuota = AuditHeldRequest()
        let oldSettings = AuditHeldRequest()
        let quotaStarted = expectation(description: "old quota held")
        let settingsStarted = expectation(description: "old settings held")
        let freshSettings = expectation(description: "restart settings loaded")
        let freshQuota = expectation(description: "restart quota loaded")
        let client = api { request in
            switch request.request.url?.path {
            case "/api/quota":
                if oldQuota.holdFirst(request) { quotaStarted.fulfill() }
                else {
                    request.respond(#"{"quota_boot_id":"new","quota_revision":1}"#)
                    freshQuota.fulfill()
                }
            case "/api/settings":
                if oldSettings.holdFirst(request) { settingsStarted.fulfill() }
                else {
                    request.respond(#"{"language":"en","sessions_limit":20}"#)
                    freshSettings.fulfill()
                }
            case "/api/quota/changes": request.respond("{}", status: 503)
            case "/api/sessions": request.respond(#"{"sessions":[]}"#)
            default: request.respond("{}")
            }
        }
        let store = AppStore(api: client)
        store.sessionQuery = "search"
        let oldRefresh = Task { await store.refresh() }
        let oldLoad = Task { await store.loadSettings() }
        await fulfillment(of: [quotaStarted, settingsStarted], timeout: 2)
        store.stop()
        store.start()
        await fulfillment(of: [freshSettings, freshQuota], timeout: 2)
        for _ in 0..<100 where store.quota?.quotaBootId != "new" || store.settings["language"] != .string("en") {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        oldQuota.respond(#"{"quota_boot_id":"old","quota_revision":80}"#)
        oldSettings.respond(#"{"language":"zh","sessions_limit":50}"#)
        let accepted = await oldRefresh.value
        await oldLoad.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(store.quota?.quotaBootId, "new")
        XCTAssertEqual(store.settings["language"], .string("en"))
        XCTAssertEqual(store.sessionPageSize, 20)
        store.stop()
    }

    @MainActor
    func testStopRejectsDelayedInstallActionReply() async {
        let held = AuditHeldRequest()
        let started = expectation(description: "install action held")
        let store = AppStore(api: api { request in
            _ = held.holdFirst(request)
            started.fulfill()
        })
        store.update = try? JSONDecoder().decode(UpdateInfo.self, from: Data(#"{"latest":"new"}"#.utf8))
        let install = Task { await store.startUpdateInstall() }
        await fulfillment(of: [started], timeout: 2)
        store.stop()
        store.updateInstall = nil
        held.respond(#"{"ok":true,"running":true,"stage":"downloading"}"#)
        await install.value
        XCTAssertNil(store.updateInstall)
    }

    func testProductionDecoderHandlesNumericSuffixesAndFlexibleCredits() async throws {
        let client = api { request in
            if request.request.url?.path == "/api/quota" {
                request.respond(#"{"codex":{"ok":true,"credits":{"balance":"12.5"}},"quota_boot_id":"a","quota_revision":4}"#)
            } else {
                request.respond(#"{"days":[],"claude_daily":{},"codex_daily":{},"cost_daily":{},"hourly":[],"cost_7d":12,"claude_cost_30d":24,"projects_7d":[]}"#)
            }
        }
        let quota: QuotaResponse = try await client.get("/api/quota")
        XCTAssertEqual(quota.codex?.credits?.balance, 12.5)
        XCTAssertEqual(quota.quotaBootId, "a")
        let usage: UsageResponse = try await client.get("/api/usage")
        XCTAssertEqual(usage.cost7d, 12)
        XCTAssertEqual(usage.claudeCost30d, 24)
        XCTAssertEqual(usage.projects7d?.count, 0)
        XCTAssertNil(usage.projectsAll7d)
    }

    func testProjectVisibilityFieldsDecodeWithoutChangingLegacyProjects() async throws {
        let client = api { request in
            request.respond(#"{"days":[],"claude_daily":{},"codex_daily":{},"cost_daily":{},"hourly":[],"projects_7d":[{"name":"legacy","cwd":"/legacy","tokens":10,"cost":1}],"projects_all_7d":[{"name":"all","cwd":"/all","tokens":30,"cost":3,"agents":{"codex":20,"qoder_cn":10},"costs_by_agent":{"codex":3,"qoder_cn":0}}]}"#)
        }
        let usage: UsageResponse = try await client.get("/api/usage")
        XCTAssertEqual(usage.projects7d?.first?.name, "legacy")
        XCTAssertNil(usage.projects7d?.first?.costsByAgent)
        XCTAssertEqual(usage.projectsAll7d?.first?.name, "all")
        XCTAssertEqual(usage.projectsAll7d?.first?.costsByAgent?["codex"], 3)
        XCTAssertEqual(usage.projectsAll7d?.first?.costsByAgent?["qoder_cn"], 0)
        let legacy = ProjectUsage(name: "legacy", cwd: "/legacy", tokens: 10, cost: 1, agents: nil)
        XCTAssertNil(legacy.costsByAgent)
    }

    func testRetiredDaemonCannotReplaceNewBootSnapshot() {
        var gate = QuotaSnapshotGate()
        XCTAssertTrue(gate.accept(bootId: "old", revision: 80, request: nil))
        let inFlight = gate.beginRequest()
        XCTAssertTrue(gate.accept(bootId: "new", revision: 1, request: nil))
        XCTAssertFalse(gate.accept(bootId: "old", revision: 81, request: inFlight))
        XCTAssertFalse(gate.accept(bootId: "old", revision: 82, request: nil))
        XCTAssertEqual(gate.bootId, "new")
        XCTAssertEqual(gate.revision, 1)
        XCTAssertTrue(gate.accept(bootId: "new", revision: 2, request: gate.beginRequest()))
    }

    func testFirstPushRejectsDelayedPreviouslyUnknownOldBoot() {
        var gate = QuotaSnapshotGate()
        let oldRequest = gate.beginRequest()
        XCTAssertTrue(gate.accept(bootId: "new", revision: 1, request: nil))
        XCTAssertFalse(gate.accept(bootId: "unknown-old", revision: 80, request: oldRequest))
        XCTAssertEqual(gate.bootId, "new")
        XCTAssertEqual(gate.revision, 1)
        XCTAssertTrue(gate.accept(bootId: "new", revision: 2, request: nil))
        XCTAssertTrue(gate.accept(bootId: "new", revision: 2, request: oldRequest))
        let freshRequest = gate.beginRequest()
        XCTAssertTrue(gate.accept(bootId: "next", revision: 1, request: freshRequest))
        XCTAssertEqual(gate.bootId, "next")
    }

    func testFirstPushRejectsDelayedUnversionedSnapshot() {
        var gate = QuotaSnapshotGate()
        let oldRequest = gate.beginRequest()
        XCTAssertTrue(gate.accept(bootId: "new", revision: 1, request: nil))
        XCTAssertFalse(gate.accept(bootId: nil, revision: nil, request: oldRequest))
        XCTAssertEqual(gate.bootId, "new")
    }

    @MainActor
    func testStopClearsDebouncedSearchLoading() async {
        let client = api { _ in XCTFail("Cancelled search must not make a request") }
        let store = AppStore(api: client)
        store.search("delayed")
        XCTAssertTrue(store.sessionsLoading)
        store.stop()
        XCTAssertFalse(store.sessionsLoading)
        try? await Task.sleep(nanoseconds: 350_000_000)
        XCTAssertFalse(store.sessionsLoading)
    }

    @MainActor
    func testCancelledUpdatePollDoesNotSendRequestsOrReplaceStatus() async {
        let client = api { _ in XCTFail("Cancelled update poll sent a request") }
        let store = AppStore(api: client)
        store.updateInstall = AppStore.updateInstallStatus([
            "ok": true, "running": true, "stage": "downloading", "progress": 40,
        ])
        let task = Task { await store.pollUpdateInstall() }
        task.cancel()
        await task.value
        XCTAssertEqual(store.updateInstall?.stage, "downloading")
        XCTAssertEqual(store.updateInstall?.progress, 40)
    }

    @MainActor
    func testIndexRetryKeepsCurrentPageAndCursor() async throws {
        let first = expectation(description: "first page")
        let second = expectation(description: "second page")
        let retry = expectation(description: "retry second page")
        let lock = NSLock()
        var secondPageRequests = 0
        let client = api { request in
            let query = URLComponents(url: request.request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if query?.first(where: { $0.name == "cursor" })?.value == "page-2" {
                lock.lock()
                secondPageRequests += 1
                let count = secondPageRequests
                lock.unlock()
                request.respond("{\"sessions\":[],\"total\":40,\"indexing\":\(count == 1)}")
                (count == 1 ? second : retry).fulfill()
            } else {
                request.respond(#"{"sessions":[],"total":40,"has_more":true,"next_cursor":"page-2"}"#)
                first.fulfill()
            }
        }
        let store = AppStore(api: client)
        defer { store.stop() }
        store.search("")
        await fulfillment(of: [first], timeout: 2)
        for _ in 0..<100 where store.sessionsLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(store.sessionsHasMore)
        store.nextSessionPage()
        XCTAssertTrue(store.sessionsLoading, "Navigation reserves loading before spawning work")
        await fulfillment(of: [second, retry], timeout: 3)
        for _ in 0..<100 where store.sessionsLoading || store.sessionsIndexing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(store.sessionPage, 2)
        XCTAssertFalse(store.sessionsIndexing)
        XCTAssertFalse(store.sessionsLoading)
    }
}
