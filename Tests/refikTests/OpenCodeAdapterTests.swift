import XCTest
@testable import refik

final class OpenCodeAdapterTests: XCTestCase {
    private func adapter(_ server: MockOpenCodeServer, endpoint: String = "http://127.0.0.1:49171") throws -> OpenCodeAdapter {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OpenCodeMockProtocol.self]
        OpenCodeMockProtocol.server = server
        return try OpenCodeAdapter(configuration: OpenCodeConnectionConfiguration(serverURL: URL(string: endpoint)!, projectDirectory: "/project"), session: URLSession(configuration: config))
    }
    func testOnlyExplicitLoopbackEndpointAllowed() throws {
        for address in ["https://example.com", "http://127.0.0.1.evil.test", "http://user:pass@localhost", "http://localhost/path", "file:///tmp"] {
            XCTAssertThrowsError(try OpenCodeAdapter(configuration: .init(serverURL: URL(string: address)!, projectDirectory: "/project")))
        }
    }
    func testCapabilityProbeAndSnapshotPreserveAllQuestions() async throws {
        let server = MockOpenCodeServer()
        let adapter = try adapter(server)
        try await adapter.connect()
        let snapshot = await adapter.snapshot()
        XCTAssertTrue(snapshot.connected)
        XCTAssertEqual(snapshot.version, "1.18.34")
        XCTAssertEqual(snapshot.pending.count, 2)
        let question = try XCTUnwrap(snapshot.pending.first { $0.kind == .question })
        XCTAssertEqual(question.identity.turnID, "msg_1")
        XCTAssertEqual(question.identity.runtimeID, snapshot.runtimeID)
        XCTAssertEqual(question.question?.questions.count, 2)
        XCTAssertEqual(question.question?.questions[0].options[0].description, "First choice")
        XCTAssertTrue(question.question!.questions[1].allowsMultipleSelection)
        XCTAssertTrue(snapshot.pending.first { $0.kind == .permission }!.permission!.explanation!.contains("perm_1"))
        try await adapter.refresh()
        let refreshed = await adapter.snapshot()
        XCTAssertEqual(snapshot.pending.sorted { $0.id < $1.id }, refreshed.pending.sorted { $0.id < $1.id })
    }
    func testUndeclaredEndpointFailsClosedDespiteNewVersion() async throws {
        let server = MockOpenCodeServer(); server.supported = false
        let adapter = try adapter(server)
        do { try await adapter.connect(); XCTFail("Expected unsupported") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .unsupportedAPI) }
        let rejected = await adapter.snapshot()
        XCTAssertFalse(rejected.connected)
        XCTAssertFalse(server.paths.contains("/question"))
    }
    func testPermissionOnlyOnceAndExactAck() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server)
        try await adapter.connect()
        let snapshot = await adapter.snapshot()
        let request = try XCTUnwrap(snapshot.pending.first { $0.kind == .permission })
        let receipt = try await adapter.submit(.init(identity: request.identity, permissionDecision: .allow), channelID: snapshot.channelID!)
        XCTAssertEqual(receipt.lifecycle, .accepted)
        XCTAssertEqual(server.posted?["reply"] as? String, "once")
        XCTAssertEqual(server.postPath, "/permission/perm_1/reply")
        do { _ = try await adapter.submit(.init(identity: request.identity, permissionDecision: .allow), channelID: snapshot.channelID!); XCTFail("Duplicate must be stale") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .staleRequest) }
        XCTAssertEqual(server.postCount, 1)
    }
    func testQuestionAnswersUseLabelsInQuestionOrder() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server)
        try await adapter.connect()
        let snapshot = await adapter.snapshot()
        let request = snapshot.pending.first { $0.kind == .question }!
        let answers = [QuestionAnswer(questionID: "1", optionIDs: ["0"], text: "Custom"), QuestionAnswer(questionID: "0", optionIDs: ["1"])]
        _ = try await adapter.submit(.init(identity: request.identity, answers: answers), channelID: snapshot.channelID!)
        XCTAssertEqual(server.posted?["answers"] as? [[String]], [["B"], ["A", "Custom"]])
    }
    func test404RemovalIsNeverAccepted() async throws {
        let server = MockOpenCodeServer(); server.postStatus = 404
        let adapter = try adapter(server); try await adapter.connect()
        let snapshot = await adapter.snapshot(); let request = snapshot.pending.first { $0.kind == .permission }!
        do { _ = try await adapter.submit(.init(identity: request.identity, permissionDecision: .deny), channelID: snapshot.channelID!); XCTFail("404 must be stale") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .staleRequest) }
        let removed = await adapter.snapshot()
        XCTAssertFalse(removed.pending.contains { $0.identity == request.identity })
    }
    func testHTTP200FalseDoesNotResolveAndStopInvalidatesChannel() async throws {
        let server = MockOpenCodeServer(); server.ack = false
        let adapter = try adapter(server); try await adapter.connect()
        let snapshot = await adapter.snapshot(); let request = snapshot.pending.first { $0.kind == .permission }!
        do { _ = try await adapter.submit(.init(identity: request.identity, permissionDecision: .deny), channelID: snapshot.channelID!); XCTFail("False is unconfirmed") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .unconfirmedResponse) }
        let unresolved = await adapter.snapshot()
        XCTAssertTrue(unresolved.pending.contains { $0.identity == request.identity })
        await adapter.stop()
        do { _ = try await adapter.submit(.init(identity: request.identity, permissionDecision: .deny), channelID: snapshot.channelID!); XCTFail("Stopped channel") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .disconnected) }
    }
    func testReconnectionRotatesChannelWithoutInventingNewBackendRequest() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server); try await adapter.connect()
        let first = await adapter.snapshot(); try await adapter.connect(); let second = await adapter.snapshot()
        XCTAssertEqual(first.runtimeID, second.runtimeID)
        XCTAssertNotEqual(first.channelID, second.channelID)
        XCTAssertEqual(Set(first.pending.map(\.identity)), Set(second.pending.map(\.identity)))
    }
    func testCanonicalNamespaceSeparatesDifferentLocalServers() async throws {
        let server = MockOpenCodeServer()
        let first = try adapter(server, endpoint: "http://127.0.0.1:49171")
        try await first.connect(); let firstSnapshot = await first.snapshot()
        let second = try adapter(server, endpoint: "http://127.0.0.1:49172")
        try await second.connect(); let secondSnapshot = await second.snapshot()
        XCTAssertNotEqual(firstSnapshot.pending.first!.identity.sessionID, secondSnapshot.pending.first!.identity.sessionID)
        XCTAssertTrue(firstSnapshot.pending.allSatisfy { $0.identity.sessionID.hasPrefix("opencode:") })
        XCTAssertTrue(secondSnapshot.pending.allSatisfy { $0.identity.sessionID.hasPrefix("opencode:") })
        let equivalent = try adapter(server, endpoint: "HTTP://127.0.0.1:49171/")
        try await equivalent.connect(); let equivalentSnapshot = await equivalent.snapshot()
        XCTAssertEqual(firstSnapshot.pending.first!.identity.sessionID, equivalentSnapshot.pending.first!.identity.sessionID)
    }
    func testRequestWithoutToolUsesExplicitRequestScope() async throws {
        let server = MockOpenCodeServer(); server.includeQuestionTool = false
        let adapter = try adapter(server); try await adapter.connect()
        let snapshot = await adapter.snapshot(); let request = snapshot.pending.first { $0.kind == .question }!
        XCTAssertEqual(request.identity.turnID, "request:que_1")
        XCTAssertEqual(request.turnScope, .request)
    }
    func testSSEDisconnectRecoversSnapshotWithNewLeaseAndStops() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server)
        let recovered = expectation(description: "Recovered authoritative connected snapshot")
        let recorder = OpenCodeEventRecorder(recovered: recovered)
        await adapter.start { recorder.record($0) }
        await fulfillment(of: [recovered], timeout: 8)
        await adapter.stop()
        let stopped = await adapter.snapshot()
        XCTAssertFalse(stopped.connected)
        XCTAssertEqual(stopped.pending.count, 2)
        XCTAssertNil(stopped.channelID)
        XCTAssertEqual(recorder.questionIdentities.count, 1)
        XCTAssertTrue(recorder.events.allSatisfy { $0.requestSnapshot == nil || $0.requestTurnScope == .request })
        XCTAssertFalse(recorder.events.contains { $0.requestUpdate?.lifecycle == .expired })
        XCTAssertTrue(recorder.events.contains { $0.capabilities?.responseChannelID == nil })
        XCTAssertEqual(Set(recorder.events.compactMap { $0.runtime?.sourceContextID }).count, 1)
        XCTAssertTrue(recorder.events.allSatisfy { $0.runtime?.canonicalSessionID == $0.sessionID })
        XCTAssertTrue(recorder.events.contains { $0.capabilities?.hasLive(.openSession, runtime: $0.runtime) == true })
        XCTAssertFalse(recorder.events.filter { $0.capabilities?.responseChannelID == nil }.contains { $0.capabilities?.hasLive(.openSession, runtime: $0.runtime) == true })
    }
    func testStopDuringSubmissionRetainsUnknownLeaseAcrossReconnect() async throws {
        let server = MockOpenCodeServer(); server.ack = false; server.delayPost = true
        let sent = expectation(description: "POST reached transport")
        server.postStarted = sent
        let adapter = try adapter(server); try await adapter.connect()
        let first = await adapter.snapshot(); let request = first.pending.first { $0.kind == .permission }!
        let response = InteractionResponse(identity: request.identity, permissionDecision: .allow)
        let submission = Task { try await adapter.submit(response, channelID: first.channelID!) }
        await fulfillment(of: [sent], timeout: 2)
        await adapter.stop()
        _ = await submission.result
        try await adapter.connect()
        let current = await adapter.snapshot()
        XCTAssertEqual(current.pending.first { $0.identity == request.identity }?.lifecycle, .deliveryUnknown)
        do { _ = try await adapter.submit(response, channelID: current.channelID!); XCTFail("Stopped uncertain POST cannot retry") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .staleRequest) }
        XCTAssertEqual(server.postCount, 1)
    }
    func testChangedQuestionBodyInvalidatesOldGeneration() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server); try await adapter.connect()
        let first = await adapter.snapshot(); let request = first.pending.first { $0.kind == .question }!
        server.questionText = "Changed prompt"
        try await adapter.refresh()
        let changed = await adapter.snapshot(); let replacement = changed.pending.first { $0.kind == .question }!
        XCTAssertNotEqual(request.identity.generation, replacement.identity.generation)
        do { _ = try await adapter.submit(.init(identity: request.identity, answers: [QuestionAnswer(questionID: "0", optionIDs: ["0"]), QuestionAnswer(questionID: "1", optionIDs: ["0"])]), channelID: first.channelID!); XCTFail("Old generation") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .staleRequest) }
        XCTAssertEqual(server.postCount, 0)
    }
    func testUnknownDeliveryCannotBeRetriedEvenAfterSnapshot() async throws {
        let server = MockOpenCodeServer(); server.ack = false
        let adapter = try adapter(server); try await adapter.connect()
        let first = await adapter.snapshot(); let request = first.pending.first { $0.kind == .permission }!
        let response = InteractionResponse(identity: request.identity, permissionDecision: .allow)
        do { _ = try await adapter.submit(response, channelID: first.channelID!); XCTFail("Unconfirmed") } catch {}
        try await adapter.connect()
        let current = await adapter.snapshot()
        XCTAssertEqual(current.pending.first { $0.identity == request.identity }?.lifecycle, .deliveryUnknown)
        do { _ = try await adapter.submit(response, channelID: current.channelID!); XCTFail("Unknown delivery cannot retry") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .staleRequest) }
        XCTAssertEqual(server.postCount, 1)
    }
    func testSelectSessionRequiresDeclaredCapabilityAndExactProject() async throws {
        let server = MockOpenCodeServer(); let adapter = try adapter(server); try await adapter.connect()
        let selected = await adapter.snapshot()
        try await adapter.selectSession(sessionID: selected.pending.first!.identity.sessionID)
        XCTAssertEqual(server.posted?["sessionID"] as? String, "ses_1")
        do { try await adapter.selectSession(sessionID: "ses_other"); XCTFail("Other project") }
        catch { XCTAssertEqual(error as? OpenCodeConnectionError, .unsupportedAPI) }
    }
}

private final class MockOpenCodeServer: @unchecked Sendable {
    var supported = true
    var ack = true
    var postStatus = 200
    var questionPending = true
    var questionText = "Which?"
    var includeQuestionTool = true
    var permissionPending = true
    var delayPost = false
    var postStarted: XCTestExpectation?
    var posted: [String: Any]?
    var postPath: String?
    var postCount = 0
    var paths: [String] = []
    func response(_ request: URLRequest) -> (Int, Any) {
        let path = request.url!.path; paths.append(path)
        if request.httpMethod == "POST" {
            postCount += 1; postPath = path
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var collected = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; collected.append(buffer, count: count) }
                body = collected
            }
            if let data = body { posted = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            if ack || postStatus == 404 {
                if path.hasPrefix("/question/") { questionPending = false }
                if path.hasPrefix("/permission/") { permissionPending = false }
            }
            return (postStatus, ack)
        }
        switch path {
        case "/global/health": return (200, ["healthy": true, "version": "1.18.34"])
        case "/doc":
            var routes: [String: Any] = [:]
            for path in ["/question", "/permission", "/session", "/session/status", "/event"] { routes[path] = ["get": [:]] }
            for path in ["/question/{requestID}/reply", "/permission/{requestID}/reply", "/tui/select-session"] { routes[path] = ["post": [:]] }
            return (200, ["paths": supported ? routes : [:]])
        case "/session": return (200, [["id": "ses_1", "directory": "/project", "title": "Real session"], ["id": "ses_other", "directory": "/other", "title": "Excluded"]])
        case "/session/status": return (200, ["ses_1": ["type": "busy"]])
        case "/event": return (200, [:])
        case "/question":
            let options = [["label": "A", "description": "First choice"], ["label": "B", "description": "Second choice"]]
            var question: [String: Any] = ["id": "que_1", "sessionID": "ses_1", "questions": [["question": questionText, "header": "Pick", "options": options, "custom": false], ["question": "What else?", "options": options, "multiple": true]]]
            if includeQuestionTool { question["tool"] = ["messageID": "msg_1", "callID": "call_1"] }
            return (200, questionPending ? [question] : [])
        case "/permission": return (200, permissionPending ? [["id": "perm_1", "sessionID": "ses_1", "permission": "bash", "patterns": ["swift test"], "tool": ["messageID": "msg_1", "callID": "call_2"]]] : [])
        default: return (404, [:])
        }
    }
}
private final class OpenCodeMockProtocol: URLProtocol, @unchecked Sendable {
    static var server: MockOpenCodeServer!
    private var delayedResponse: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, payload) = Self.server.response(request)
        let isStream = request.url?.path == "/event"
        let data = isStream ? Data("data: {\"type\":\"server.connected\"}\n\n".utf8) : try! JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])
        let deliver = { [self] in
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": isStream ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        }
        if Self.server.delayPost && request.httpMethod == "POST" {
            let work = DispatchWorkItem(block: deliver); delayedResponse = work
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: work)
            Self.server.postStarted?.fulfill()
        } else { deliver() }
    }
    override func stopLoading() { delayedResponse?.cancel() }
}

private final class OpenCodeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let recovered: XCTestExpectation
    private var stored: [CodexEvent] = []
    private var identities: Set<RequestIdentity> = []
    private var channels: Set<String> = []
    init(recovered: XCTestExpectation) { self.recovered = recovered }
    var events: [CodexEvent] { lock.lock(); defer { lock.unlock() }; return stored }
    var questionIdentities: Set<RequestIdentity> { lock.lock(); defer { lock.unlock() }; return identities }
    func record(_ event: CodexEvent) {
        lock.lock(); defer { lock.unlock() }
        stored.append(event)
        if event.requestSnapshot?.kind == .question, let request = event.requestSnapshot {
            identities.insert(request.identity)
        }
        if let channel = event.capabilities?.responseChannelID, channels.insert(channel).inserted, channels.count == 2 {
            recovered.fulfill()
        }
    }
}
