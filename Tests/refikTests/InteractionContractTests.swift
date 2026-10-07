import XCTest
@testable import refik

final class InteractionContractTests: XCTestCase {
    let time = Date(timeIntervalSince1970: 100)
    func event(_ kind: EventKind, _ second: Double, turn: String = "turn", request: String? = nil) -> CodexEvent {
        CodexEvent(sessionID: "session", turnID: turn, requestID: request, kind: kind, source: .cli, title: nil, at: time.addingTimeInterval(second), id: "\(kind):\(second)")
    }
    func snapshot(_ id: String = "request", generation: String = "one") -> PendingRequestSnapshot {
        PendingRequestSnapshot(identity: RequestIdentity(provider: .codex, runtimeID: "runtime", sessionID: "session", turnID: "turn", requestID: id, generation: generation), kind: .question,
            question: QuestionRequestBody(questions: [StructuredQuestion(id: "first", prompt: "First?", options: [QuestionOption(id: "yes", label: "Yes")]), StructuredQuestion(id: "second", prompt: "Second?")]), observedAt: time)
    }
    func waiting() -> StateReducer {
        var reducer = StateReducer()
        var start = event(.started, 0)
        start.runtime = RuntimeMetadata(id: "runtime", host: .terminal, version: "1", chatName: "Name")
        start.capabilities = RuntimeCapabilities(provider: .codex, runtimeID: "runtime", version: "1", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .live, source: "verified test channel")], responseChannelID: "channel")
        XCTAssertTrue(reducer.apply(start))
        var ask = event(.userQuestionObserved, 1, request: "request"); ask.requestSnapshot = snapshot()
        XCTAssertTrue(reducer.apply(ask))
        return reducer
    }
    func testLegacyEventAndSessionDecodeWithoutNewKeys() throws {
        let original = event(.started, 0)
        let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.runtime); XCTAssertNil(decoded.requestSnapshot)
        let oldSession = Session(id: "s", turnID: "t", source: .desktop, title: "Legacy", state: .completed, started: time, updated: time)
        let decodedSession = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(oldSession))
        XCTAssertTrue(decodedSession.orderedRequests.isEmpty); XCTAssertTrue(decodedSession.requestsResultAttention)
    }
    func testExactGenerationLifecycleAndPartialMultiquestionValidation() {
        var reducer = waiting()
        let request = snapshot()
        let partial = InteractionResponse(identity: request.identity, answers: [QuestionAnswer(questionID: "first", optionIDs: ["yes"])])
        XCTAssertFalse(partial.isValid(for: request))
        let complete = InteractionResponse(identity: request.identity, answers: [QuestionAnswer(questionID: "first", optionIDs: ["yes"]), QuestionAnswer(questionID: "second", text: "Answer")])
        XCTAssertTrue(complete.isValid(for: request))
        XCTAssertTrue(reducer.sessions["session"]!.canRespond(to: request))
        var wrong = event(.requestResolved, 2, request: "request")
        wrong.requestUpdate = RequestLifecycleUpdate(identity: snapshot(generation: "old").identity, lifecycle: .accepted)
        XCTAssertFalse(reducer.apply(wrong))
        XCTAssertFalse(reducer.apply(event(.requestResolved, 2, request: "request")))
        var submitting = event(.requestResolved, 3, request: "request")
        submitting.requestUpdate = RequestLifecycleUpdate(identity: request.identity, lifecycle: .submitting)
        XCTAssertTrue(reducer.apply(submitting))
        XCTAssertEqual(reducer.sessions["session"]!.pending, ["request"])
        XCTAssertFalse(reducer.sessions["session"]!.canRespond(to: requestWithLifecycle(.submitting)))
        var accepted = event(.requestResolved, 4, request: "request")
        accepted.requestUpdate = RequestLifecycleUpdate(identity: request.identity, lifecycle: .accepted)
        XCTAssertTrue(reducer.apply(accepted)); XCTAssertEqual(reducer.sessions["session"]!.state, .running)
        XCTAssertEqual(reducer.sessions["session"]!.orderedRequests.first?.lifecycle, .accepted)
        XCTAssertFalse(reducer.apply(accepted))
    }
    func requestWithLifecycle(_ lifecycle: RequestLifecycle) -> PendingRequestSnapshot { var request = snapshot(); request.lifecycle = lifecycle; return request }
    func testWrongTurnPermissionDistinctionAndCapabilityVersion() {
        var reducer = waiting()
        var wrongTurn = event(.requestResolved, 2, turn: "other", request: "request")
        wrongTurn.requestUpdate = RequestLifecycleUpdate(identity: snapshot().identity, lifecycle: .accepted)
        XCTAssertFalse(reducer.apply(wrongTurn))
        var permission = snapshot(); permission = PendingRequestSnapshot(identity: permission.identity, kind: .permission, question: permission.question, observedAt: time)
        XCTAssertFalse(permission.isValid)
        var session = reducer.sessions["session"]!
        session.runtime?.version = "2"
        XCTAssertFalse(session.canRespond(to: snapshot()))
        XCTAssertTrue(reducer.apply(event(.started, 3, turn: "new")))
        XCTAssertTrue(reducer.sessions["session"]!.orderedRequests.isEmpty)
        XCTAssertFalse(reducer.apply(event(.requestResolved, 4, request: "request")))
    }
    func testOrderAndCanonicalSameJobMergeWithoutNameGuessing() {
        var reducer = waiting()
        var ask = event(.userQuestionObserved, 2, request: "second"); ask.requestSnapshot = snapshot("second")
        XCTAssertTrue(reducer.apply(ask))
        XCTAssertEqual(reducer.sessions["session"]!.orderedRequests.map(\.id), ["request", "second"])
        var alias = event(.activity, 3); alias.sessionID = "host-alias"
        alias.runtime = RuntimeMetadata(id: "runtime", host: .vscode, version: "1", chatName: "Name", canonicalSessionID: "session")
        XCTAssertTrue(reducer.apply(alias)); XCTAssertEqual(reducer.sessions.count, 1)
        var unrelated = event(.started, 4); unrelated.sessionID = "unrelated"
        unrelated.runtime = RuntimeMetadata(id: "other-runtime", host: .terminal, version: "1", chatName: "Name")
        XCTAssertTrue(reducer.apply(unrelated)); XCTAssertEqual(reducer.sessions.count, 2)
    }
    func testExpiryIsNotAcceptanceAndDocumentedCapabilityCannotRespond() {
        var reducer = StateReducer()
        var start = event(.started, 0)
        start.runtime = RuntimeMetadata(id: "runtime", host: .terminal, version: "1", chatName: nil)
        start.capabilities = RuntimeCapabilities(provider: .codex, runtimeID: "runtime", version: "1", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .documented, source: "documentation")], responseChannelID: "channel")
        XCTAssertTrue(reducer.apply(start))
        var request = snapshot(); request.expiresAt = time.addingTimeInterval(3)
        var ask = event(.userQuestionObserved, 1, request: "request"); ask.requestSnapshot = request
        XCTAssertTrue(reducer.apply(ask))
        XCTAssertFalse(reducer.sessions["session"]!.canRespond(to: request))
        XCTAssertTrue(reducer.expire(at: time.addingTimeInterval(4)))
        XCTAssertEqual(reducer.sessions["session"]!.orderedRequests.first?.lifecycle, .expired)
        XCTAssertEqual(reducer.sessions["session"]!.state, .unknown)
        var late = event(.requestResolved, 5, request: "request")
        late.requestUpdate = RequestLifecycleUpdate(identity: request.identity, lifecycle: .accepted)
        XCTAssertFalse(reducer.apply(late))
    }
    func testPermissionRequiresDistinctBodyAndResponseDecision() {
        let request = PendingRequestSnapshot(identity: snapshot().identity, kind: .permission,
            permission: PermissionRequestBody(requestedAction: "Run build", scope: "Project directory"), observedAt: time)
        XCTAssertTrue(request.isValid)
        XCTAssertTrue(InteractionResponse(identity: request.identity, permissionDecision: .deny).isValid(for: request))
        XCTAssertFalse(InteractionResponse(identity: request.identity, answers: [QuestionAnswer(questionID: "first", text: "yes")]).isValid(for: request))
    }

    func testNativeCopilotHostRoundTripPreservesLegacyRuntimeDecoding() throws {
        let native = RuntimeMetadata(id: "native-copilot", host: .githubCopilotDesktop, version: "fixture", chatName: nil)
        let encoded = try JSONEncoder().encode(native)
        XCTAssertEqual(try JSONDecoder().decode(RuntimeMetadata.self, from: encoded), native)
        XCTAssertEqual(RuntimeHost.githubCopilotDesktop.rawValue, "githubCopilotDesktop")
        XCTAssertEqual(native.host.label, "GitHub Copilot Desktop")
        let legacy = try JSONDecoder().decode(RuntimeMetadata.self, from: Data(#"{"id":"legacy","host":"vscode"}"#.utf8))
        XCTAssertEqual(legacy.host, .vscode)
        XCTAssertNil(legacy.version); XCTAssertNil(legacy.sourceContextID)
        var session = Session(id: "native", turnID: "turn", source: .unknown, title: "Fixture", state: .running, started: time, updated: time)
        session.provider = .copilot; session.runtime = native
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.provider, .copilot); XCTAssertEqual(restored.runtime?.host, .githubCopilotDesktop)
        XCTAssertNil(restored.capabilities, "Host metadata does not grant a response channel")
    }

    private struct ExactFixtureTransport: InteractionResponseTransport {
        func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt {
            ResponseReceipt(identity: response.identity, lifecycle: .submitted)
        }
    }
    @MainActor func testExactClaudeChannelsCannotCrossSessionTurnToolOrGenerationAndOpenCodeKeepsMultiRequest() {
        func request(_ provider: Provider, _ session: String, _ turn: String, _ tool: String, _ generation: String) -> PendingRequestSnapshot {
            PendingRequestSnapshot(identity: RequestIdentity(provider: provider, runtimeID: "shared-runtime", sessionID: session, turnID: turn, requestID: tool, generation: generation), kind: .question,
                question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Question?", options: [QuestionOption(id: "a", label: "A")])]), observedAt: time)
        }
        func session(_ request: PendingRequestSnapshot) -> Session {
            var value = Session(id: request.identity.sessionID, turnID: request.identity.turnID, source: .unknown, title: "Fixture", state: .waitingUser, started: time, updated: time)
            value.provider = request.identity.provider; value.pending = [request.id]; value.requestSnapshots = [request]
            value.runtime = RuntimeMetadata(id: "shared-runtime", host: .unknown, version: "2.1.287")
            return value
        }
        func caps(_ provider: Provider, _ channel: String) -> RuntimeCapabilities {
            RuntimeCapabilities(provider: provider, runtimeID: "shared-runtime", version: "2.1.287", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .live, source: "fixture")], responseChannelID: channel)
        }
        let coordinator = IntegrationCoordinator(), transport = ExactFixtureTransport()
        let first = request(.claude, "one", "turn", "tool", "generation"), second = request(.claude, "two", "turn", "tool", "generation")
        coordinator.register(caps(.claude, "one"), transport: transport, runtime: session(first).runtime, requestIdentity: first.identity)
        coordinator.register(caps(.claude, "two"), transport: transport, runtime: session(second).runtime, requestIdentity: second.identity)
        XCTAssertEqual(coordinator.transport(for: session(first), request: first)?.1, "one")
        XCTAssertEqual(coordinator.transport(for: session(second), request: second)?.1, "two")
        for foreign in [request(.claude, "foreign", "turn", "tool", "generation"), request(.claude, "one", "foreign", "tool", "generation"), request(.claude, "one", "turn", "foreign", "generation"), request(.claude, "one", "turn", "tool", "foreign")] {
            XCTAssertNil(coordinator.transport(for: session(foreign), request: foreign))
        }
        coordinator.register(caps(.claude, "replacement"), transport: transport, runtime: session(first).runtime, requestIdentity: first.identity)
        coordinator.remove(channelID: "one")
        XCTAssertEqual(coordinator.transport(for: session(first), request: first)?.1, "replacement")
        coordinator.remove(channelID: "replacement")
        XCTAssertNil(coordinator.transport(for: session(first), request: first))
        XCTAssertEqual(coordinator.transport(for: session(second), request: second)?.1, "two")
        coordinator.register(caps(.claude, "generic"), transport: transport, runtime: session(first).runtime)
        XCTAssertNil(coordinator.transport(for: session(first), request: first), "Claude cannot fall back to a runtime-only route")
        for tool in ["first", "second"] {
            let open = request(.opencode, "open", "turn", tool, "generation")
            coordinator.register(caps(.opencode, "open-channel"), transport: transport, runtime: session(open).runtime)
            XCTAssertEqual(coordinator.transport(for: session(open), request: open)?.1, "open-channel")
        }
    }

}
