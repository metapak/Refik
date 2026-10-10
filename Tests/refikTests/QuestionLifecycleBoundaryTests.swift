import XCTest
import Darwin
@testable import refik

private struct PreDispatchFixtureTransport: InteractionResponseTransport {
    let beforeFailure: @MainActor () -> Void
    func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt {
        await beforeFailure()
        throw OpenCodePreDispatchError(underlying: OpenCodeConnectionError.staleRequest)
    }
}

final class QuestionLifecycleBoundaryTests: XCTestCase {
    private let session = "11111111-2222-4333-8444-555555555555"
    private func record(_ payload: [String: Any], type: String = "event_msg", second: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": String(format: "2026-10-09T19:09:%02dZ", second), "payload": payload])
    }
    private func fixture(origin: String = "codex_work_desktop", continuation: Bool = false) throws -> (RolloutAdapter, URL, URL, Data) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("refik-question-boundary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-2026-09-21T20-08-12-" + session + (continuation ? "_" + UUID().uuidString : "") + ".jsonl")
        let header = try record(["id": session, "cwd": root.path, "source": "vscode", "originator": origin], type: "session_meta", second: 0)
        try (header + Data([10])).write(to: file)
        var adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
        _ = adapter.parse(header)
        return (adapter, root, file, header)
    }
    private func call(name: String = "request_user_input_async", id: String = "call") throws -> Data {
        try record(["type": "function_call", "name": name, "call_id": id, "arguments": "{\"questions\":[{\"title\":\"Continue?\",\"options\":[\"A\",\"B\"]}]}"], type: "response_item", second: 2)
    }
    private func accepted(id: String = "call", turn: String = "turn", second: Int = 3) throws -> Data {
        try record(["type": "item_completed", "turn_id": turn, "item": ["type": "AgentMessage", "delivery": "async", "id": id, "questions": [["title": "Continue?", "options": ["A", "B"]]]]], second: second)
    }
    private func reply(_ key: String, second: Int) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: ["questionItemId": key, "answer": "A"])
        return try record(["type": "item_completed", "turn_id": "turn", "item": ["type": "UserMessage", "id": "reply", "content": [["type": "text", "text": "<send_user_message_question_reply>" + String(decoding: body, as: UTF8.self) + "</send_user_message_question_reply>"]]]], second: second)
    }
    @MainActor func testDesktopAcceptedAsyncExpiresAtExactCompletionAndCannotReopen() throws {
        var (adapter, root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(inspectNotificationPermission: false)
        model.accept(try XCTUnwrap(adapter.parse(record(["type": "task_started", "turn_id": "turn"], second: 1))), historical: false)
        XCTAssertTrue(adapter.parseEvents(try call()).isEmpty)
        XCTAssertTrue(adapter.hasPendingBlockingQuestion)
        XCTAssertTrue(adapter.parseEvents(try record(["type": "function_call_output", "call_id": "call", "output": "{\"accepted\":true}"], type: "response_item", second: 3)).isEmpty)
        XCTAssertTrue(adapter.hasPendingBlockingQuestion, "ACK cannot classify or answer a question")
        let question = try XCTUnwrap(adapter.parseEvents(accepted(second: 4)).first)
        model.accept(question, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .waitingUser)
        XCTAssertFalse(adapter.hasPendingBlockingQuestion, "validated Desktop accepted async observation is optional")
        XCTAssertNil(adapter.parse(try record(["type": "task_complete", "turn_id": "foreign"], second: 5)))
        let completion = try XCTUnwrap(adapter.parse(record(["type": "task_complete", "turn_id": "turn"], second: 6)))
        model.accept(completion, historical: false)
        let finished = try XCTUnwrap(model.sessions.first { $0.id == session })
        XCTAssertEqual(finished.state, .completed); XCTAssertTrue(finished.pending.isEmpty)
        XCTAssertEqual(finished.orderedRequests.first?.lifecycle, .expired)
        XCTAssertTrue(adapter.parseEvents(try reply(XCTUnwrap(question.requestID), second: 7)).isEmpty)
        XCTAssertTrue(adapter.parseEvents(try accepted(second: 8)).isEmpty)
        XCTAssertTrue(adapter.parseEvents(try call()).isEmpty)
        XCTAssertFalse(adapter.hasPendingBlockingQuestion)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .completed)
    }
    func testUnknownAsyncAndMalformedSyncCannotAuthorizeCompletion() throws {
        for origin in ["unknown", "codex_work_desktop"] {
            var (adapter, root, _, _) = try fixture(origin: origin); defer { try? FileManager.default.removeItem(at: root) }
            _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 1))
            _ = adapter.parseEvents(try call(name: origin == "unknown" ? "request_user_input_async" : "request_user_input"))
            if origin == "unknown" { _ = adapter.parseEvents(try accepted()) }
            XCTAssertTrue(adapter.hasPendingBlockingQuestion)
            XCTAssertNil(adapter.parse(try record(["type": "task_complete", "turn_id": "turn"], second: 5)))
        }
    }
    func testDesktopOrphanAndPartiallyMalformedAcceptedItemsVetoCompletion() throws {
        for variant in ["orphan", "mismatch", "partial", "partial-matched", "matched"] {
            var (adapter, root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 1))
            if ["mismatch", "partial-matched", "matched"].contains(variant) {
                _ = adapter.parseEvents(try call(id: variant == "mismatch" ? "different-call" : "call"))
            }
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted()) as? [String: Any])
            if variant.hasPrefix("partial") {
                var payload = try XCTUnwrap(object["payload"] as? [String: Any])
                var item = try XCTUnwrap(payload["item"] as? [String: Any])
                item["questions"] = [["title": "Continue?", "options": ["A", "B"]], ["title": "Malformed", "options": [42]]]
                payload["item"] = item; object["payload"] = payload
            }
            let observed = adapter.parseEvents(object)
            XCTAssertFalse(observed.isEmpty, "valid observed subset may retain attention")
            XCTAssertEqual(adapter.hasPendingBlockingQuestion, variant != "matched", variant)
            if variant.hasPrefix("partial"), let key = observed.first?.requestID {
                _ = adapter.parseEvents(try reply(key, second: 4))
                XCTAssertTrue(adapter.hasPendingBlockingQuestion, "answering a valid subset cannot release a malformed remainder")
            }
            let completed = adapter.parse(try record(["type": "task_complete", "turn_id": "turn"], second: 6))
            XCTAssertEqual(completed != nil, variant == "matched", variant)
        }
    }
    func testMalformedQuestionTimestampVetoesDesktopCLIAndVSCode() throws {
        let hosts: [[String: Any]] = [
            ["source": "vscode", "originator": "codex_work_desktop"],
            ["source": "cli", "originator": "codex-tui", "cli_version": "0.153.4"],
            ["source": "vscode", "originator": "codex_vscode"]
        ]
        for host in hosts {
            for malformed: Any? in [nil, 42, "invalid"] {
                var (adapter, root, file, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
                var metadata = host; metadata["id"] = session; metadata["cwd"] = root.path
                let header = try record(metadata, type: "session_meta", second: 0)
                try (header + Data([10])).write(to: file)
                adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
                _ = adapter.parse(header)
                _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 1))
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: call()) as? [String: Any])
                object["timestamp"] = malformed
                XCTAssertTrue(adapter.parseEvents(object).isEmpty)
                XCTAssertEqual(adapter.currentTurnID, "turn")
                XCTAssertTrue(adapter.hasPendingBlockingQuestion, "Malformed timestamp must veto for " + String(describing: host))
                XCTAssertNil(adapter.parse(try record(["type": "task_complete", "turn_id": "turn"], second: 6)))
            }
            var (adapter, root, file, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            var metadata = host; metadata["id"] = session; metadata["cwd"] = root.path
            let header = try record(metadata, type: "session_meta", second: 0)
            try (header + Data([10])).write(to: file)
            adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
            _ = adapter.parse(header)
            _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 3))
            _ = adapter.parseEvents(try call()) // Valid timestamp predates current start.
            XCTAssertFalse(adapter.hasPendingBlockingQuestion, "provably old ordered call cannot bind the current turn")
        }
    }
    func testAbortAndNewerTurnExpireOptionalCallsWithTombstones() throws {
        for boundary in ["turn_aborted", "task_started"] {
            var (adapter, root, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 1))
            _ = adapter.parseEvents(try call()); let question = try XCTUnwrap(adapter.parseEvents(accepted()).first)
            XCTAssertNotNil(adapter.parse(try record(["type": boundary, "turn_id": boundary == "task_started" ? "new" : "turn"], second: 5)))
            XCTAssertTrue(adapter.parseEvents(try reply(XCTUnwrap(question.requestID), second: 6)).isEmpty)
            XCTAssertTrue(adapter.parseEvents(try accepted(turn: boundary == "task_started" ? "new" : "turn", second: 7)).isEmpty)
            XCTAssertFalse(adapter.hasPendingBlockingQuestion)
        }
    }
    func testDesktopContinuationFilenameRejectsCollisionsAndInvalidSuffixes() throws {
        for name in [
            "prefix-rollout-2026-09-21T20-08-12-" + session + "_" + UUID().uuidString + ".jsonl",
            "rollout-2026-09-21T20-08-12-" + session + "_not-a-uuid.jsonl",
            "rollout-2026-09-21T20-08-12-" + UUID().uuidString + "_" + UUID().uuidString + ".jsonl",
            "rollout-2026-09-21T20-08-12-" + session + "_" + UUID().uuidString + "_extra.jsonl"
        ] {
            var (adapter, root, file, header) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let collision = root.appendingPathComponent(name); try (header + Data([10])).write(to: collision)
            try FileManager.default.removeItem(at: file)
            adapter = RolloutAdapter(); adapter.rolloutFile = collision; adapter.rolloutRoot = root
            _ = adapter.parse(header)
            _ = adapter.parse(try record(["type": "task_started", "turn_id": "turn"], second: 1))
            _ = adapter.parseEvents(try call()); _ = adapter.parseEvents(try accepted())
            XCTAssertTrue(adapter.hasPendingBlockingQuestion, name)
            XCTAssertNil(adapter.parse(try record(["type": "task_complete", "turn_id": "turn"], second: 6)))
        }
    }
    func testBoundedRecoveryUsesDesktopQuestionPolicy() throws {
        let (_, root, file, header) = try fixture(continuation: true); defer { try? FileManager.default.removeItem(at: root) }
        var bytes = header + Data([10])
        bytes.append(try record(["type": "task_started", "turn_id": "turn"], second: 1)); bytes.append(10)
        bytes.append(try JSONSerialization.data(withJSONObject: ["type": "compacted", "payload": ["text": String(repeating: "x", count: 1_010_000)]])); bytes.append(10)
        bytes.append(try call()); bytes.append(10)
        bytes.append(try accepted()); bytes.append(10)
        bytes.append(try record(["type": "function_call_output", "call_id": "call", "output": "{\"accepted\":true}"], type: "response_item", second: 4)); bytes.append(10)
        bytes.append(try record(["type": "task_complete", "turn_id": "turn"], second: 6)); bytes.append(10)
        try bytes.write(to: file)
        let watcher = TranscriptWatcher(root: root, onEvent: { _, _ in }, onBootstrapDone: {}, onHealth: { _ in })
        var info = stat(); XCTAssertEqual(lstat(file.path, &info), 0)
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)).addingTimeInterval(Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let proof = try XCTUnwrap(watcher.boundedCompletionProof(file, size: UInt64(info.st_size), identity: UInt64(info.st_ino), modified: modified))
        XCTAssertEqual(proof.completion.thread, session); XCTAssertEqual(proof.completion.turn, "turn")
        XCTAssertEqual(proof.cwd, root.path)
        XCTAssertLessThanOrEqual(watcher.completionRecoveryMetrics.bytes, 64 * 1024 * 1024)
    }
    func testOptInCurrentDesktopCompletionProofWithoutStateMutation() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["REFIK_ACTUAL_ROLLOUT"], let rootPath = environment["REFIK_ACTUAL_CODEX_ROOT"],
              let expectedSession = environment["REFIK_EXPECTED_SESSION_ID"], let expectedTurn = environment["REFIK_EXPECTED_TURN_ID"] else {
            throw XCTSkip("Opt-in read-only current rollout evidence")
        }
        XCTAssertNotNil(UUID(uuidString: expectedSession))
        XCTAssertNotNil(UUID(uuidString: expectedTurn))
        let file = URL(fileURLWithPath: path), root = URL(fileURLWithPath: rootPath)
        var info = stat(); XCTAssertEqual(lstat(path, &info), 0)
        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)).addingTimeInterval(Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        let watcher = TranscriptWatcher(root: root, onEvent: { _, _ in }, onBootstrapDone: {}, onHealth: { _ in })
        let proof = try XCTUnwrap(watcher.boundedCompletionProof(file, size: UInt64(info.st_size), identity: UInt64(info.st_ino), modified: modified))
        XCTAssertEqual(proof.completion.thread, expectedSession)
        XCTAssertEqual(proof.completion.turn, expectedTurn)
        var completed = Session(id: expectedSession, turnID: proof.completion.turn, source: .desktop, title: "Evidence", state: .completed, started: proof.started, updated: proof.completion.completed)
        completed.projectPath = proof.cwd; completed.runtime = RuntimeMetadata(id: "codex-rollout:desktop:" + expectedSession, host: .codexDesktop)
        XCTAssertEqual(NativeAttentionReader(root: root).verifiedCompletions([completed], rolloutProofs: [proof]), [proof.completion])
        XCTAssertLessThanOrEqual(watcher.completionRecoveryMetrics.bytes, 64 * 1024 * 1024 + 256 * 1024)
    }
    func testWireLeaseMarkerCannotBypassForeignInteractionExpiry() throws {
        let now = Date(), runtime = RuntimeMetadata(id: "hook:opencode:foreign", host: .terminal)
        let identity = RequestIdentity(provider: .opencode, runtimeID: runtime.id, sessionID: "foreign", turnID: "turn", requestID: "question", generation: "generation")
        let request = PendingRequestSnapshot(identity: identity, kind: .question, question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Continue?")]), observedAt: now, expiresAt: now.addingTimeInterval(1), expiryScope: .responseChannelLease)
        var event = CodexEvent(sessionID: "foreign", turnID: "turn", requestID: request.id, kind: .userQuestionObserved, source: .cli, title: nil, at: now, id: "foreign", provider: .opencode, runtime: runtime, requestSnapshot: request)
        event.verifiedHookLease = true
        let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONEncoder().encode(event))
        XCTAssertFalse(decoded.verifiedHookLease, "caller cannot serialize receiver attestation")
        var reducer = StateReducer(); XCTAssertTrue(reducer.apply(decoded))
        XCTAssertTrue(reducer.expire(at: now.addingTimeInterval(2)))
        XCTAssertEqual(reducer.sessions["foreign"]?.state, .unknown)
        XCTAssertEqual(reducer.sessions["foreign"]?.orderedRequests.first?.lifecycle, .expired)
    }
    @MainActor func testPreDispatchFailureRestoresOnlySamePendingGeneration() async throws {
        for replace in [false, true] {
            let model = AppModel(inspectNotificationPermission: false), now = Date()
            let runtime = RuntimeMetadata(id: "opencode:fixture", host: .terminal, version: "1")
            let capabilities = RuntimeCapabilities(provider: .opencode, runtimeID: runtime.id, version: "1", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .live, source: "fixture")], responseChannelID: "channel")
            func request(_ generation: String, at: Date) -> PendingRequestSnapshot {
                PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: runtime.id, sessionID: "opencode:session", turnID: "turn", requestID: "question", generation: generation), kind: .question, question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: generation)]), turnScope: .request, observedAt: at)
            }
            func observe(_ request: PendingRequestSnapshot) {
                model.accept(CodexEvent(sessionID: request.identity.sessionID, turnID: "turn", requestID: request.id, kind: .userQuestionObserved, source: .cli, title: nil, at: request.observedAt, id: request.identity.generation, provider: .opencode, runtime: runtime, capabilities: capabilities, requestSnapshot: request), historical: false, trustedAdapterSnapshot: true)
            }
            let original = request("original", at: now.addingTimeInterval(-1))
            var newer = request("newer", at: now)
            model.accept(CodexEvent(sessionID: original.identity.sessionID, turnID: "turn", requestID: nil, kind: .started, source: .cli, title: nil, at: now.addingTimeInterval(-2), id: "start", provider: .opencode, runtime: runtime, capabilities: capabilities), historical: false)
            observe(original)
            model.registerInteractionTransport(PreDispatchFixtureTransport(beforeFailure: { if replace { newer = request("newer", at: Date()); observe(newer) } }), capabilities: capabilities)
            XCTAssertTrue(model.canSubmitResponse(original))
            let result = await model.submitResponse(InteractionResponse(identity: original.identity, answers: [QuestionAnswer(questionID: "q", text: "answer")]))
            let current = try XCTUnwrap(model.sessions.first?.orderedRequests.first)
            XCTAssertEqual(current.identity, replace ? newer.identity : original.identity)
            XCTAssertEqual(current.lifecycle, .pending); XCTAssertEqual(model.aggregate, .waiting)
            XCTAssertEqual(result.lifecycle, replace ? nil : .pending)
            XCTAssertTrue(model.canSubmitResponse(current))
        }
    }
    func testLegacyCodableInvocationLeaseAndAmbiguousProviderDeadline() throws {
        for invocation in [true, false] {
            let now = Date(), runtime = RuntimeMetadata(id: "hook:claude:fixture", host: .unknown)
            let identity = RequestIdentity(provider: .claude, runtimeID: runtime.id, sessionID: "claude:legacy", turnID: invocation ? "hook:invocation" : "turn", requestID: "question", generation: "old-generation")
            let legacy = PendingRequestSnapshot(identity: identity, kind: .question, question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Continue?")]), turnScope: invocation ? .hookInvocation : .providerTurn, observedAt: now.addingTimeInterval(-650), expiresAt: now.addingTimeInterval(-50))
            let bytes = try JSONEncoder().encode(legacy)
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("expiryScope"))
            let decoded = try JSONDecoder().decode(PendingRequestSnapshot.self, from: bytes)
            var session = Session(id: identity.sessionID, turnID: "turn", source: .cli, title: "Legacy", state: .waitingUser, started: now.addingTimeInterval(-700), updated: legacy.observedAt)
            session.provider = .claude; session.runtime = runtime; session.pending = [identity.requestID]
            session.pendingKinds = [identity.requestID: .waitingUser]; session.requestSnapshots = [decoded]
            var reducer = StateReducer(sessions: [session.id: session]); XCTAssertTrue(reducer.expire(at: now))
            XCTAssertEqual(reducer.sessions[session.id]?.state, invocation ? .waitingUser : .unknown)
            XCTAssertEqual(reducer.sessions[session.id]?.orderedRequests.first?.lifecycle, invocation ? .pending : .expired)
            XCTAssertEqual(reducer.sessions[session.id]?.orderedRequests.first?.expiresAt, legacy.expiresAt)
        }
    }
    @MainActor func testHookLeaseDisablesPreviouslyUsableReplyRoute() throws {
        let model = AppModel(inspectNotificationPermission: false), now = Date()
        let runtime = RuntimeMetadata(id: "hook:codex:fixture", host: .terminal, version: "1")
        let capabilities = RuntimeCapabilities(provider: .codex, runtimeID: runtime.id, version: "1", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .live, source: "fixture")], responseChannelID: "channel")
        let identity = RequestIdentity(provider: .codex, runtimeID: runtime.id, sessionID: "hook-session", turnID: "hook:invocation", requestID: "question", generation: "generation")
        let request = PendingRequestSnapshot(identity: identity, kind: .question, question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Continue?")]), turnScope: .hookInvocation, observedAt: now, expiresAt: now.addingTimeInterval(0.5), expiryScope: .responseChannelLease)
        model.accept(CodexEvent(sessionID: identity.sessionID, turnID: "turn", requestID: nil, kind: .started, source: .cli, title: nil, at: now.addingTimeInterval(-1), id: "start", runtime: runtime, capabilities: capabilities), historical: false)
        var observed = CodexEvent(sessionID: identity.sessionID, turnID: identity.turnID, requestID: request.id, kind: .userQuestionObserved, source: .cli, title: nil, at: now, id: "ask", ttl: 600, runtime: runtime, capabilities: capabilities, requestSnapshot: request, requestTurnScope: .hookInvocation)
        observed.verifiedHookLease = true
        model.accept(observed, historical: false)
        model.registerInteractionTransport(PreDispatchFixtureTransport(beforeFailure: {}), capabilities: capabilities)
        XCTAssertTrue(model.canSubmitResponse(request), "a live route is available before the lease deadline")
        Thread.sleep(forTimeInterval: 0.6)
        model.expire(at: now.addingTimeInterval(601))
        XCTAssertFalse(model.canSubmitResponse(request))
        XCTAssertEqual(model.sessions.first?.state, .waitingUser)
        XCTAssertEqual(model.sessions.first?.orderedRequests.first?.lifecycle, .pending)
    }
    @MainActor func testHookLeaseExpiryKeepsPendingAndDisablesReply() throws {
        let model = AppModel(inspectNotificationPermission: false), now = Date()
        let runtime = RuntimeMetadata(id: "hook:claude:fixture", host: .terminal, version: "1", chatName: nil)
        let identity = RequestIdentity(provider: .claude, runtimeID: runtime.id, sessionID: "claude:session", turnID: "hook:invocation", requestID: "request", generation: "generation")
        func event(_ kind: EventKind, id: String, at: Date, request: PendingRequestSnapshot? = nil, update: RequestLifecycleUpdate? = nil) -> CodexEvent {
            var event = CodexEvent(sessionID: identity.sessionID, turnID: kind == .started ? "turn" : identity.turnID, requestID: kind == .started ? nil : identity.requestID,
                kind: kind, source: .cli, title: nil, at: at, id: id, provider: .claude,
                ttl: kind == .userQuestionObserved ? 600 : nil, runtime: runtime, requestSnapshot: request,
                requestUpdate: update, requestTurnScope: kind == .started ? nil : .hookInvocation)
            event.verifiedHookLease = true
            return event
        }
        model.accept(event(.started, id: "start", at: now.addingTimeInterval(-700)), historical: false)
        let request = PendingRequestSnapshot(identity: identity, kind: .question, question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Continue?")]), turnScope: .hookInvocation, observedAt: now.addingTimeInterval(-650), expiresAt: now.addingTimeInterval(-50), expiryScope: .responseChannelLease)
        model.accept(event(.userQuestionObserved, id: "ask", at: request.observedAt, request: request), historical: false)
        model.expire(at: now)
        let waiting = try XCTUnwrap(model.sessions.first { $0.id == identity.sessionID })
        XCTAssertEqual(waiting.state, .waitingUser); XCTAssertEqual(waiting.orderedRequests.first?.lifecycle, .pending)
        XCTAssertFalse(model.canSubmitResponse(request)); XCTAssertEqual(waiting.orderedRequests.first?.expiresAt, request.expiresAt)
        let foreign = RequestIdentity(provider: .claude, runtimeID: runtime.id, sessionID: identity.sessionID, turnID: identity.turnID, requestID: identity.requestID, generation: "foreign")
        model.accept(event(.requestResolved, id: "foreign", at: now, update: RequestLifecycleUpdate(identity: foreign, lifecycle: .resolved)), historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == identity.sessionID }?.state, .waitingUser)
        model.accept(event(.requestResolved, id: "exact", at: now, update: RequestLifecycleUpdate(identity: identity, lifecycle: .resolved)), historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == identity.sessionID }?.state, .running)
    }
}
