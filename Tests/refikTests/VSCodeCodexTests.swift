import XCTest
import RefikInteractionWire
@testable import refik

final class VSCodeCodexTests: XCTestCase {
    private func completed(origin: String?, source: String?) throws -> CodexEvent {
        var parser = RolloutAdapter()
        var meta: [String: Any] = ["id": "thread", "cwd": "/tmp/fixture"]
        if let origin { meta["originator"] = origin }
        if let source { meta["source"] = source }
        _ = parser.parse(try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": meta]))
        _ = parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-02T23:59:59Z","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8))
        return try XCTUnwrap(parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:00Z","payload":{"type":"task_complete","turn_id":"turn"}}"#.utf8)))
    }
    private func session() -> Session {
        let now = Date()
        return Session(id: UUID().uuidString, turnID: "turn", source: .desktop, title: "QA", state: .completed, started: now, updated: now)
    }
    func testConsistentVSCodeRolloutCarriesHostWithoutInventingPeerProof() throws {
        let event = try completed(origin: "codex_vscode", source: "vscode")
        XCTAssertEqual(event.runtime?.host, .vscode)
        XCTAssertEqual(event.provider, .codex)
        XCTAssertNil(event.verifiedEditorHost)
        XCTAssertEqual(try completed(origin: "codex_work_desktop", source: "vscode").runtime?.host, .codexDesktop)
        for pair in [("Codex Desktop", "unrecognized"), ("codex_vscode", "cli"), (nil, "vscode")] as [(String?, String?)] {
            XCTAssertEqual(try completed(origin: pair.0, source: pair.1).runtime?.host, .unknown)
        }
    }
    func testVSCodeAndVerifiedEditorRoutesAreAppOnlyAndDoNotMarkSeen() throws {
        var value = session()
        value.runtime = RuntimeMetadata(id: "rollout", host: .vscode)
        let host = try XCTUnwrap(EditorFocusHost.installations.first { $0.bundleID == "com.microsoft.VSCode" })
        let route = SessionRouting.route(for: value, codexRoutingVerified: true)
        XCTAssertNil(route.url)
        XCTAssertEqual(route.applicationURL, EditorFocusHost.verified(host) ? host.application : nil)
        XCTAssertEqual(route.bundleID, EditorFocusHost.verified(host) ? host.bundleID : "")
        XCTAssertFalse(value.seen)
        value.runtime = RuntimeMetadata(id: "old", host: .codexDesktop)
        value.verifiedEditorHost = "com.microsoft.VSCode"
        XCTAssertNil(SessionRouting.route(for: value, codexRoutingVerified: true).url)
    }
    func testDesktopRetainsExactRouteWhileUnknownCannotClaimDesktopThread() {
        var value = session()
        value.runtime = RuntimeMetadata(id: "desktop", host: .codexDesktop)
        XCTAssertEqual(SessionRouting.route(for: value, codexRoutingVerified: true).url?.absoluteString, "codex://threads/\(value.id)")
        value.runtime = nil
        XCTAssertNil(SessionRouting.route(for: value, codexRoutingVerified: true).url)
        value.verifiedEditorHost = "unrecognized.editor"
        XCTAssertNil(SessionRouting.route(for: value, codexRoutingVerified: true).url)
    }

    private func fixture(_ body: (URL, URL, String, Data) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let file = root.appendingPathComponent("rollout-2026-10-03-" + id + ".jsonl")
        let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "cwd": root.path, "source": "vscode", "originator": "codex_vscode"]])
        try meta.write(to: file)
        try body(root, file, id, meta)
    }
    private func originEvent(_ id: String, root: URL, kind: EventKind = .completed, turn: String = "turn", at: Double = 2) -> CodexEvent {
        var event = CodexEvent(sessionID: id, turnID: turn, requestID: nil, kind: kind, source: .desktop, title: "QA", at: Date(timeIntervalSince1970: at), id: UUID().uuidString, fidelity: .derived)
        event.runtime = RuntimeMetadata(id: "rollout", host: .vscode); event.projectPath = root.path
        return event
    }
    func testOriginProofCannotBeForgedThroughWireAndValidatesFileIdentityRoot() throws {
        try fixture { root, file, id, meta in
            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            XCTAssertNil(CodexEditorOriginProof(metadata: meta, file: file, root: root.appendingPathComponent("other")))
            let wrong = root.appendingPathComponent("wrong.jsonl"); try meta.write(to: wrong)
            XCTAssertNil(CodexEditorOriginProof(metadata: meta, file: wrong, root: root))
            let event = originEvent(id, root: root)
            var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
            wire["editorOriginEvidence"] = "codexVSCodeRollout"
            let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: wire))
            var reducer = StateReducer(); XCTAssertTrue(reducer.apply(decoded))
            XCTAssertNil(reducer.sessions[id]?.editorOriginEvidence)
            var mismatch = event; mismatch.projectPath = root.appendingPathComponent("wrong").path
            XCTAssertFalse(reducer.associateEditorOrigin(proof, event: mismatch))
            XCTAssertTrue(reducer.associateEditorOrigin(proof, event: event))
            XCTAssertNil(reducer.sessions[id]?.verifiedEditorHost)
            let saved = try JSONEncoder().encode(reducer.sessions[id]!)
            XCTAssertEqual(try JSONDecoder().decode(Session.self, from: saved).editorOriginEvidence, .codexVSCodeRollout)
            var old = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any]); old.removeValue(forKey: "editorOriginEvidence")
            XCTAssertNil(try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: old)).editorOriginEvidence)
            XCTAssertTrue(reducer.apply(originEvent(id, root: root, kind: .started, turn: "new", at: 3)))
            XCTAssertNil(reducer.sessions[id]?.editorOriginEvidence)
        }
    }
    func testMetadataOriginStillRequiresFreshExactForegroundLeaseAndTerminalBoundary() throws {
        try fixture { root, file, id, meta in
            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            var reducer = StateReducer(); let event = originEvent(id, root: root)
            XCTAssertTrue(reducer.apply(event)); XCTAssertTrue(reducer.associateEditorOrigin(proof, event: event))
            var eligibility = EditorFocusEligibility(); eligibility.observe(reducer, at: 20)
            let receiver = EditorFocusReceiver()
            let host = EditorHostBinding(bundleID: "com.microsoft.VSCode", pid: 42, launchSeconds: 1, launchMicros: 2)
            let epoch = UUID().uuidString, window = UUID().uuidString, generation = UUID().uuidString
            receiver.receive(epoch: epoch, host: host, observation: EditorFocusObservation(windowID: window, generation: generation, sequence: 1, focused: true, projectPath: root.path), at: 21, date: Date(timeIntervalSince1970: 4))
            func commit(_ now: Double, foreground: Bool = true, current: Bool = true) -> Bool {
                receiver.withProof(at: now, foreground: { _ in foreground }, currentHost: { _ in current }) { p in
                    reducer.dismissProject(p.project, at: Date(timeIntervalSince1970: 4), observedAt: p.observedAt, editorHost: p.host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: p.issuedMonotonic))
                }
            }
            XCTAssertFalse(commit(26)); XCTAssertFalse(commit(22, foreground: false)); XCTAssertFalse(commit(22, current: false))
            XCTAssertFalse(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 4), editorHost: "foreign.editor", eligibleEditorGenerations: eligibility.eligible(afterChallenge: 21)))
            XCTAssertFalse(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 4), editorHost: host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: 20)))
            XCTAssertTrue(commit(22)); XCTAssertTrue(reducer.sessions[id]!.seen)
        }
    }
    func testUnresolvedAsyncAcceptanceRevokesMetadataOriginWithoutAQuestionSnapshot() throws {
        try fixture { root, file, id, meta in
            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            var reducer = StateReducer(); let event = originEvent(id, root: root)
            XCTAssertTrue(reducer.apply(event)); XCTAssertTrue(reducer.associateEditorOrigin(proof, event: event))
            let call = Data(#"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"call","arguments":"{}"}}"#.utf8)
            XCTAssertTrue(TranscriptWatcher.isNativeQuestionCall(call))
            XCTAssertTrue(reducer.revokeEditorOrigin(id))
            XCTAssertFalse(reducer.associateEditorOrigin(proof, event: event), "ordinary replay cannot clear an unresolved async question after restart")
            XCTAssertNil(reducer.sessions[id]?.requestSnapshots)
            var eligibility = EditorFocusEligibility(); eligibility.observe(reducer, at: 20)
            XCTAssertTrue(eligibility.eligible(afterChallenge: 21).isEmpty)
            XCTAssertFalse(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 4), editorHost: "com.microsoft.VSCode", eligibleEditorGenerations: eligibility.eligible(afterChallenge: 21)))
        }
    }
    func testInternalWatcherPropagationExpiresHistoricalQuestionOnlyOnValidatedNewTurn() throws {
        try fixture { root, file, id, meta in
            var reducer = StateReducer()
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func line(_ type: String, _ payload: [String: Any], _ offset: Double) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: Date().addingTimeInterval(offset)), "payload": payload])
            }
            let lines = [meta,
                try line("event_msg", ["type": "task_started", "turn_id": "one"], 1),
                try line("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "call", "arguments": "{}"], 2),
                try line("response_item", ["type": "function_call_output", "call_id": "call", "output": "{\"accepted\":true}"], 3),
                try line("event_msg", ["type": "task_complete", "turn_id": "one"], 4),
                try line("event_msg", ["type": "task_started", "turn_id": "two"], 5),
                try line("event_msg", ["type": "task_complete", "turn_id": "two"], 6)]
            var bytes = Data(); for line in lines { bytes.append(line); bytes.append(10) }; try bytes.write(to: file)
            var propagated = 0, revoked = 0
            let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in _ = reducer.apply(event) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOrigin: { event, proof in
                if reducer.associateEditorOrigin(proof, event: event) { propagated += 1 }
            }, onEditorOriginBlocked: { id, reason, turn in if reducer.revokeEditorOrigin(id, reason: reason, turnID: turn) { revoked += 1 } }, onEditorOriginTurnStarted: { event, proof in
                _ = reducer.supersedeEditorOriginBlock(proof, event: event)
            })
            watcher.scan()
            XCTAssertEqual(propagated, 2); XCTAssertEqual(revoked, 1)
            XCTAssertEqual(reducer.sessions[id]?.turnID, "two")
            XCTAssertEqual(reducer.sessions[id]?.runtime?.host, .vscode)
            XCTAssertEqual(reducer.sessions[id]?.editorOriginEvidence, .codexVSCodeRollout)
            XCTAssertNil(reducer.sessions[id]?.editorFocusBlockReason)
            XCTAssertFalse(reducer.sessions[id]!.seen, "supersession is not acknowledgment")
        }
        try fixture { root, file, id, meta in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var bytes = meta; bytes.append(10)
            for (offset, type) in [(1.0, "task_started"), (2.0, "task_complete")] {
                bytes.append(try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": formatter.string(from: Date().addingTimeInterval(offset)), "payload": ["type": type, "turn_id": "fresh"]])); bytes.append(10)
            }
            try bytes.write(to: file)
            var reducer = StateReducer()
            let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in _ = reducer.apply(event) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOrigin: { event, proof in _ = reducer.associateEditorOrigin(proof, event: event) })
            watcher.scan()
            XCTAssertEqual(reducer.sessions[id]?.editorOriginEvidence, .codexVSCodeRollout)
        }
    }
    @MainActor func testActualBootstrapReplayRestoresResolvedOriginWithoutSeeingPersistedCompletion() throws {
        try fixture { root, file, id, meta in
            let start = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-10-03T00:00:00Z", "payload": ["type": "task_started", "turn_id": "turn"]])
            let call = try nativeCall()
            let answer = try nativeLine(["type": "function_call_output", "call_id": "call", "output": "{\"answers\":{\"choice\":{\"answers\":[\"A\"]}}}"], at: 2)
            let end = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-10-03T00:00:03Z", "payload": ["type": "task_complete", "turn_id": "turn"]])
            let lines = [meta, start, call, answer, end]
            var bytes = Data(); for line in lines { bytes.append(line); bytes.append(10) }; try bytes.write(to: file)
            var parser = RolloutAdapter(), persisted = StateReducer()
            for line in lines { for event in parser.parseEvents(line) { _ = persisted.apply(event, allowUnverifiedWait: true) } }
            XCTAssertEqual(persisted.sessions[id]?.state, .completed)
            let stateURL = root.appendingPathComponent("state.json")
            try JSONEncoder().encode(persisted).write(to: stateURL)
            let model = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            let watcher = TranscriptWatcher(root: root, onEvent: { event, historical in model.accept(event, historical: historical) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOriginBlocked: { sid, reason, turn in model.observeEditorOriginBlock(sid, reason: reason, turn: turn) }, onEditorOriginReplayed: { event, proof in model.reconcileReplayedEditorOrigin(proof, event: event) })
            watcher.scan()
            let saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            let session = try XCTUnwrap(saved.sessions[id])
            XCTAssertEqual(session.editorOriginEvidence, .codexVSCodeRollout)
            XCTAssertNil(session.editorFocusBlockReason)
            XCTAssertEqual(session.orderedRequests.first?.lifecycle, .resolved)
            XCTAssertFalse(session.seen)
            var focused = saved
            var eligibility = EditorFocusEligibility(); eligibility.observe(focused, at: 20)
            XCTAssertFalse(focused.dismissProject(root.path, at: Date(), editorHost: "foreign.editor", eligibleEditorGenerations: eligibility.eligible(afterChallenge: 21)))
            let receiver = EditorFocusReceiver()
            let host = EditorHostBinding(bundleID: "com.microsoft.VSCode", pid: 42, launchSeconds: 1, launchMicros: 2)
            let proofDate = Date()
            receiver.receive(epoch: UUID().uuidString, host: host, observation: EditorFocusObservation(windowID: UUID().uuidString, generation: UUID().uuidString, sequence: 1, focused: true, projectPath: root.path), at: 21, date: proofDate)
            func acknowledge(_ time: Double, foreground: Bool) -> Bool {
                receiver.withProof(at: time, foreground: { _ in foreground }, currentHost: { _ in true }) { p in
                    focused.dismissProject(p.project, at: proofDate, observedAt: p.observedAt, editorHost: p.host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: p.issuedMonotonic))
                }
            }
            XCTAssertFalse(acknowledge(26, foreground: true))
            XCTAssertFalse(acknowledge(22, foreground: false))
            XCTAssertFalse(focused.sessions[id]!.seen)
            XCTAssertTrue(acknowledge(22, foreground: true))
            XCTAssertTrue(focused.sessions[id]!.seen)
            XCTAssertFalse(saved.sessions[id]!.seen)

            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            var replay = saved
            XCTAssertTrue(replay.revokeEditorOrigin(id, reason: .codexBlockingQuestionUnresolved, turnID: "turn"))
            XCTAssertEqual(replay.sessions[id]?.editorOriginEvidence, .codexVSCodeRollout, "question does not erase source identity")
            var replayParser = RolloutAdapter(); var resolved: CodexEvent?
            for line in lines { for event in replayParser.parseEvents(line) where event.kind == .requestResolved { resolved = event } }
            let exact = try XCTUnwrap(resolved)
            var wrong = exact
            let identity = try XCTUnwrap(exact.requestUpdate?.identity)
            wrong.requestUpdate = RequestLifecycleUpdate(identity: RequestIdentity(provider: identity.provider, runtimeID: identity.runtimeID, sessionID: identity.sessionID, turnID: identity.turnID, requestID: identity.requestID, generation: "foreign-generation"), lifecycle: .resolved)
            XCTAssertFalse(replay.reconcileReplayedEditorOrigin(proof, event: wrong))
            wrong = exact; wrong.turnID = "old"
            XCTAssertFalse(replay.reconcileReplayedEditorOrigin(proof, event: wrong))
            XCTAssertNotNil(replay.sessions[id]?.editorFocusBlockReason)
            XCTAssertTrue(replay.reconcileReplayedEditorOrigin(proof, event: exact))
            XCTAssertNil(replay.sessions[id]?.editorFocusBlockReason)
            XCTAssertFalse(replay.sessions[id]!.seen)
            var partial = StateReducer(), partialParser = RolloutAdapter()
            for line in [meta, start, call, try nativeCall("other"), answer] {
                for event in partialParser.parseEvents(line) { _ = partial.apply(event, allowUnverifiedWait: true) }
            }
            XCTAssertFalse(partial.reconcileReplayedEditorOrigin(proof, event: exact), "other unresolved call blocks replay reconciliation")
            XCTAssertEqual(partial.sessions[id]?.pending.count, 1)
        }
    }
    @MainActor func testCapturedAsyncCallACKCompletionAndPersistedBootstrapStayYellowUntilExactReplyOrNewTurn() throws {
        try fixture { root, file, id, meta in
            func lifecycle(_ type: String, _ turn: String, _ at: Int) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": String(format: "2026-10-03T00:00:%02dZ", at), "payload": ["type": type, "turn_id": turn]])
            }
            let start = try lifecycle("task_started", "turn", 0)
            let args = "{\"questions\":[{\"title\":\"Fixture?\",\"options\":[\"A\",\"B\"]}]}"
            let call = try nativeLine(["type": "function_call", "name": "request_user_input_async", "call_id": "call", "arguments": args], at: 1)
            let ack = try nativeLine(["type": "function_call_output", "call_id": "call", "output": "{\"accepted\":true}"], at: 2)
            let end = try lifecycle("task_complete", "turn", 3)
            let lines = [meta, start, call, ack, end]
            var parser = RolloutAdapter(), live = StateReducer()
            for line in lines { for event in parser.parseEvents(line) { _ = live.apply(event, allowUnverifiedWait: true) } }
            XCTAssertEqual(live.sessions[id]?.state, .waitingUser)
            XCTAssertEqual(live.sessions[id]?.pending.count, 1)
            XCTAssertEqual(live.sessions[id]?.orderedRequests.first?.question?.questions.first?.id, "0")
            XCTAssertEqual(live.sessions[id]?.orderedRequests.first?.lifecycle, .pending)
            XCTAssertTrue(parser.parseEvents(call).isEmpty)
            XCTAssertTrue(parser.parseEvents(ack).isEmpty)
            XCTAssertTrue(parser.parseEvents(end).isEmpty)
            XCTAssertEqual(parser.pendingNativeAsyncSnapshots.count, 1)
            let delivered = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": "2026-10-03T00:00:02Z", "payload": ["type": "item_completed", "turn_id": "turn", "item": ["id": "call", "type": "AgentMessage", "delivery": "async", "questions": [["title": "Fixture?", "options": ["A", "B"]]]]]])
            XCTAssertTrue(parser.parseEvents(delivered).isEmpty, "only exact call identity permits dedup")
            // Persist the actual older-version failure: completion without async snapshot.
            var oldParser = RolloutAdapter(), persisted = StateReducer()
            for line in [meta, start, end] { for event in oldParser.parseEvents(line) { _ = persisted.apply(event) } }
            var bytes = Data(); for line in lines { bytes.append(line); bytes.append(10) }; try bytes.write(to: file)
            let stateURL = root.appendingPathComponent("state.json"); try JSONEncoder().encode(persisted).write(to: stateURL)
            let model = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            let watcher = TranscriptWatcher(root: root, onEvent: { event, historical in model.accept(event, historical: historical) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOriginBlocked: { sid, reason, turn in model.observeEditorOriginBlock(sid, reason: reason, turn: turn) }, onNativeAsyncPendingRecovery: { proof, requests in model.recoverNativeAsyncPending(proof, requests: requests) })
            watcher.scan()
            var restored = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(restored.sessions[id]?.state, .waitingUser)
            XCTAssertEqual(restored.aggregate, .waiting)
            XCTAssertEqual(restored.sessions[id]?.pending.count, 1)
            XCTAssertFalse(restored.sessions[id]!.seen)
            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            let pending = parser.pendingNativeAsyncSnapshots
            var wrong = pending; let ident = wrong[0].identity
            wrong[0] = PendingRequestSnapshot(identity: RequestIdentity(provider: ident.provider, runtimeID: ident.runtimeID, sessionID: ident.sessionID, turnID: "old", requestID: ident.requestID, generation: ident.generation), kind: .question, question: pending[0].question, observedAt: pending[0].observedAt)
            XCTAssertFalse(restored.recoverNativeAsyncPending(proof, requests: wrong))
            func reply(_ target: String, at: Int) throws -> Data {
                let tuple = String(decoding: try JSONSerialization.data(withJSONObject: ["request_user_input_async", target, 0]), as: UTF8.self)
                let value = String(decoding: try JSONSerialization.data(withJSONObject: ["questionItemId": tuple, "answer": "A"]), as: UTF8.self)
                return try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": String(format: "2026-10-03T00:00:%02dZ", at), "payload": ["type": "item_completed", "turn_id": "turn", "item": ["id": "reply", "type": "UserMessage", "content": [["type": "text", "text": "<send_user_message_question_reply>" + value + "</send_user_message_question_reply>"]]]]])
            }
            XCTAssertTrue(parser.parseEvents(try reply("foreign", at: 4)).isEmpty)
            let exact = try XCTUnwrap(parser.parseEvents(try reply("call", at: 4)).first)
            XCTAssertNotNil(exact.requestUpdate)
            XCTAssertTrue(live.apply(exact))
            XCTAssertTrue(parser.pendingNativeAsyncSnapshots.isEmpty)
            func delayedDelivery(_ turn: String, at: Int) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": String(format: "2026-10-03T00:00:%02dZ", at), "payload": ["type": "item_completed", "turn_id": turn, "item": ["id": "different-item", "call_id": "call", "type": "AgentMessage", "delivery": "async", "questions": [["title": "Fixture?", "options": ["A", "B"]]]]]])
            }
            XCTAssertTrue(parser.parseEvents(try delayedDelivery("turn", at: 4)).isEmpty, "late explicitly correlated delivery cannot reopen an answered native call")
            XCTAssertTrue(parser.pendingNativeAsyncSnapshots.isEmpty)

            XCTAssertTrue(parser.parseEvents(try reply("call", at: 4)).isEmpty)
            let complete = try XCTUnwrap(parser.parseEvents(try lifecycle("task_complete", "turn", 5)).first)
            XCTAssertTrue(live.apply(complete)); XCTAssertEqual(live.sessions[id]?.state, .completed)
            // A real saved resolved async interaction survives a complete replay.
            var resolvedBytes = Data()
            for line in [meta, start, call, ack, try reply("call", at: 4), try lifecycle("task_complete", "turn", 5)] { resolvedBytes.append(line); resolvedBytes.append(10) }
            try resolvedBytes.write(to: file); try JSONEncoder().encode(live).write(to: stateURL)
            let restarted = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            let replayWatcher = TranscriptWatcher(root: root, onEvent: { event, historical in restarted.accept(event, historical: historical) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOriginBlocked: { sid, reason, turn in restarted.observeEditorOriginBlock(sid, reason: reason, turn: turn) }, onNativeAsyncPendingRecovery: { proof, requests in restarted.recoverNativeAsyncPending(proof, requests: requests) }, onEditorOriginReplayed: { event, proof in restarted.reconcileReplayedEditorOrigin(proof, event: event) })
            replayWatcher.scan()
            let restartedState = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(restartedState.sessions[id]?.orderedRequests.first?.lifecycle, .resolved)
            XCTAssertNil(restartedState.sessions[id]?.editorFocusBlockReason)
            XCTAssertFalse(restartedState.sessions[id]!.seen)

            // Supersession is not an answer; old pending cannot veto a new task.
            var superseded = RolloutAdapter()
            for line in [meta, start, call, ack] { _ = superseded.parseEvents(line) }
            let newStart = try XCTUnwrap(superseded.parseEvents(try lifecycle("task_started", "next", 6)).first)
            XCTAssertTrue(restored.apply(newStart))
            XCTAssertTrue(restored.sessions[id]!.pending.isEmpty)
            XCTAssertFalse(restored.sessions[id]!.seen)
            XCTAssertTrue(superseded.parseEvents(call).isEmpty)
            XCTAssertTrue(superseded.parseEvents(try delayedDelivery("next", at: 7)).isEmpty, "a retired native call cannot bind a delivery to the new turn")
            XCTAssertTrue(superseded.pendingNativeAsyncSnapshots.isEmpty)

            XCTAssertNotNil(superseded.parseEvents(try lifecycle("task_complete", "next", 7)).first)
        }
    }
    @MainActor func testActualRepeatedMetadataFollowupCompletesPersistsFocusesAndBootstraps() throws {
        try fixture { root, file, id, meta in
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let base = Date().addingTimeInterval(1)
            func line(_ outer: String, _ payload: [String: Any], _ offset: Double) throws -> Data {
                try JSONSerialization.data(withJSONObject: ["type": outer, "timestamp": formatter.string(from: base.addingTimeInterval(offset)), "payload": payload])
            }
            let refreshObject = try XCTUnwrap(JSONSerialization.jsonObject(with: meta) as? [String: Any])
            let payload = try XCTUnwrap(refreshObject["payload"] as? [String: Any])
            let lines = [meta,
                try line("event_msg", ["type": "task_started", "turn_id": "old"], 0),
                try line("response_item", ["type": "function_call", "name": "request_user_input_async", "call_id": "old-call", "arguments": "{\"questions\":[{\"title\":\"Fixture?\",\"options\":[\"A\",\"B\"]}]}"], 1),
                try line("response_item", ["type": "function_call_output", "call_id": "old-call", "output": "{\"accepted\":true}"], 2),
                try line("event_msg", ["type": "task_complete", "turn_id": "old"], 3),
                try line("event_msg", ["type": "task_started", "turn_id": "new"], 4),
                try line("session_meta", payload, 4.119),
                try line("response_item", ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "DONE"]]], 6),
                try line("event_msg", ["type": "task_complete", "turn_id": "new"], 7)]
            var bytes = Data(); for item in lines { bytes.append(item); bytes.append(10) }; try bytes.write(to: file)
            let stateURL = root.appendingPathComponent("state.json")
            let model = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            var observed: [EventKind] = []
            let observer = TranscriptWatcher(root: root, onEvent: { event, historical in observed.append(event.kind); model.accept(event, historical: historical) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOrigin: { event, proof in model.associateEditorOrigin(proof, event: event) }, onEditorOriginBlocked: { sid, reason, turn in model.observeEditorOriginBlock(sid, reason: reason, turn: turn) }, onNativeAsyncPendingRecovery: { proof, requests in model.recoverNativeAsyncPending(proof, requests: requests) }, onEditorOriginReplayed: { event, proof in model.reconcileReplayedEditorOrigin(proof, event: event) }, onEditorOriginTurnStarted: { event, proof in model.supersedeEditorOriginBlock(proof, event: event) })
            var direct = RolloutAdapter(); direct.rolloutFile = file; direct.rolloutRoot = root
            var directEvents: [CodexEvent] = []
            for item in lines { directEvents += direct.parseEvents(item) }
            XCTAssertEqual(directEvents.last?.kind, .completed)
            observer.scan()
            XCTAssertEqual(observed.last, .completed, "Watcher emitted \(observed)")
            var saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(saved.sessions[id]?.turnID, "new")
            XCTAssertEqual(saved.sessions[id]?.state, .completed)
            XCTAssertFalse(saved.sessions[id]!.seen)
            XCTAssertTrue(saved.sessions[id]!.pending.isEmpty)
            XCTAssertNil(saved.sessions[id]?.editorFocusBlockReason)
            XCTAssertEqual(saved.sessions[id]?.editorOriginEvidence, .codexVSCodeRollout)
            var eligibility = EditorFocusEligibility(); eligibility.observe(saved, at: 20)
            let receiver = EditorFocusReceiver(); let host = EditorHostBinding(bundleID: "com.microsoft.VSCode", pid: 42, launchSeconds: 1, launchMicros: 2)
            let focusDate = base.addingTimeInterval(8)
            receiver.receive(epoch: UUID().uuidString, host: host, observation: EditorFocusObservation(windowID: UUID().uuidString, generation: UUID().uuidString, sequence: 1, focused: true, projectPath: root.path), at: 21, date: focusDate)
            XCTAssertTrue(receiver.withProof(at: 22, foreground: { _ in true }, currentHost: { _ in true }) { proof in
                saved.dismissProject(proof.project, at: focusDate, observedAt: proof.observedAt, editorHost: proof.host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: proof.issuedMonotonic))
            })
            XCTAssertTrue(saved.sessions[id]!.seen)
            // Completed/unseen bootstrap retains the full workflow and old call tombstone.
            let completed = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            let restarted = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            let replay = TranscriptWatcher(root: root, onEvent: { event, _ in restarted.accept(event, historical: true) }, onBootstrapDone: {}, onHealth: { _ in }, onEditorOriginReplayed: { event, proof in restarted.reconcileReplayedEditorOrigin(proof, event: event) })
            replay.scan()
            let reloaded = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(reloaded.sessions[id]?.state, .completed)
            XCTAssertEqual(reloaded.sessions[id]?.seen, completed.sessions[id]?.seen)
            XCTAssertTrue(reloaded.sessions[id]!.pending.isEmpty)
            // The installed failure is already-running, not already-completed.
            var historicalBytes = Data()
            for item in lines {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: item) as? [String: Any])
                if let raw = object["timestamp"] as? String, let at = formatter.date(from: raw) { object["timestamp"] = formatter.string(from: at.addingTimeInterval(-20)) }
                historicalBytes.append(try JSONSerialization.data(withJSONObject: object)); historicalBytes.append(10)
            }
            try historicalBytes.write(to: file)
            var brokenJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(completed)) as? [String: Any])
            var working = try XCTUnwrap(brokenJSON["sessions"] as? [String: [String: Any]])
            working[id]?["state"] = "running"; working[id]?["updated"] = base.addingTimeInterval(-16).timeIntervalSinceReferenceDate
            working[id]?["started"] = base.addingTimeInterval(-16).timeIntervalSinceReferenceDate
            // The actual failed installation never received the terminal event.
            working[id]?["lastEventIDs"] = Array((completed.sessions[id]?.lastEventIDs ?? []).subtracting(directEvents.filter { $0.kind == .completed }.map(\.id)))
            brokenJSON["sessions"] = working
            let brokenData = try JSONSerialization.data(withJSONObject: brokenJSON); try brokenData.write(to: stateURL)
            let recovering = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
            let historical = TranscriptWatcher(root: root, onEvent: { event, h in recovering.accept(event, historical: h) }, onBootstrapDone: {}, onHealth: { _ in }, onHistoricalEditorCompletion: { proof, event in recovering.recoverHistoricalEditorCompletion(proof, event: event) }, onEditorOriginReplayed: { event, proof in recovering.reconcileReplayedEditorOrigin(proof, event: event) })
            historical.scan()
            let repaired = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: stateURL))
            XCTAssertEqual(repaired.sessions[id]?.state, .completed)
            XCTAssertFalse(repaired.sessions[id]!.seen, "historical recovery of a received result is not an acknowledgment")
            XCTAssertEqual(try XCTUnwrap(repaired.sessions[id]?.updated).timeIntervalSinceReferenceDate, base.addingTimeInterval(-13).timeIntervalSinceReferenceDate, accuracy: 0.002)
            var afterRecovery = repaired
            var recoveredEligibility = EditorFocusEligibility(); recoveredEligibility.observe(afterRecovery, at: 30)
            let recoveredReceiver = EditorFocusReceiver()
            recoveredReceiver.receive(epoch: UUID().uuidString, host: host, observation: EditorFocusObservation(windowID: UUID().uuidString, generation: UUID().uuidString, sequence: 1, focused: true, projectPath: root.path), at: 31, date: focusDate)
            XCTAssertTrue(recoveredReceiver.withProof(at: 32, foreground: { _ in true }, currentHost: { _ in true }) { proof in
                afterRecovery.dismissProject(proof.project, at: focusDate, observedAt: proof.observedAt, editorHost: proof.host.bundleID, eligibleEditorGenerations: recoveredEligibility.eligible(afterChallenge: proof.issuedMonotonic))
            })
            XCTAssertTrue(afterRecovery.sessions[id]!.seen)
            let proof = try XCTUnwrap(CodexEditorOriginProof(metadata: meta, file: file, root: root))
            var directHistorical = RolloutAdapter(); directHistorical.rolloutFile = file; directHistorical.rolloutRoot = root
            var terminal: CodexEvent?
            for item in historicalBytes.split(separator: UInt8(10)) { for event in directHistorical.parseEvents(Data(item)) where event.kind == .completed { terminal = event } }
            let actualEnd = try XCTUnwrap(terminal)
            for variant in ["seen", "newer", "pending", "foreign-root", "foreign-runtime"] {
                var altered = working
                if variant == "seen" { altered[id]?["seen"] = true }
                if variant == "newer" { altered[id]?["turnID"] = "later" }
                if variant == "pending" { altered[id]?["pending"] = ["active-request"] }
                var object = brokenJSON; object["sessions"] = altered
                var state = try JSONDecoder().decode(StateReducer.self, from: JSONSerialization.data(withJSONObject: object))
                var event = actualEnd
                if variant == "foreign-root" { event.projectPath = root.appendingPathComponent("foreign").path }
                if variant == "foreign-runtime" { event.runtime = RuntimeMetadata(id: "different-rollout-runtime", host: .vscode) }
                XCTAssertFalse(state.recoverHistoricalEditorCompletion(proof, event: event), variant)
            }

        }
    }
    func testMetadataRefreshPreservesOnlyValidatedConsistentOrderedIdentity() throws {
        try fixture { root, file, id, meta in
            let start = Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:01Z","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8)
            let end = Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:03Z","payload":{"type":"task_complete","turn_id":"turn"}}"#.utf8)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: meta) as? [String: Any])
            let payload = try XCTUnwrap(original["payload"] as? [String: Any])
            func refresh(_ changes: [String: Any], time: String = "2026-10-03T00:00:02Z") throws -> Data {
                var p = payload; for (k,v) in changes { p[k] = v }
                return try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": time, "payload": p])
            }
            for changes in [[String: Any](), ["id": UUID().uuidString], ["cwd": "/"], ["source": "cli"], ["originator": "conflict"], ["subagent": true], ["parent_thread_id": "parent"]] {
                var adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
                _ = adapter.parseEvents(meta); _ = adapter.parseEvents(start)
                let data = try refresh(changes)
                XCTAssertEqual(adapter.preservesMetadataRefresh(data), changes.isEmpty)
                _ = adapter.parseEvents(data)
                XCTAssertEqual(adapter.currentTurnID, changes.isEmpty ? "turn" : nil)
                if changes.isEmpty { XCTAssertEqual(adapter.parseEvents(end).first?.kind, .completed) } else { XCTAssertTrue(adapter.parseEvents(end).isEmpty) }
            }
            for time in ["invalid", "2026-10-03T00:00:00Z"] {
                var adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
                _ = adapter.parseEvents(meta); _ = adapter.parseEvents(start); _ = adapter.parseEvents(try refresh([:], time: time))
                XCTAssertNil(adapter.currentTurnID)
                XCTAssertTrue(adapter.parseEvents(end).isEmpty)
            }
            var malformed = RolloutAdapter(); malformed.rolloutFile = file; malformed.rolloutRoot = root
            _ = malformed.parseEvents(meta); _ = malformed.parseEvents(start)
            _ = malformed.parseEvents(Data(#"{"type":"session_meta","timestamp":"2026-10-03T00:00:02Z","payload":"invalid"}"#.utf8))
            XCTAssertNil(malformed.currentTurnID); XCTAssertTrue(malformed.parseEvents(end).isEmpty)
            var duplicate = RolloutAdapter(); duplicate.rolloutFile = file; duplicate.rolloutRoot = root
            _ = duplicate.parseEvents(meta); _ = duplicate.parseEvents(start)
            let exact = try refresh([:]); _ = duplicate.parseEvents(exact); _ = duplicate.parseEvents(exact)
            XCTAssertEqual(duplicate.parseEvents(end).first?.kind, .completed)
            var desktop = RolloutAdapter(); desktop.rolloutFile = file; desktop.rolloutRoot = root
            var desktopPayload = payload; desktopPayload["originator"] = "codex_work_desktop"
            let desktopMeta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": desktopPayload])
            _ = desktop.parseEvents(desktopMeta); _ = desktop.parseEvents(start)
            let desktopRefresh = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": "2026-10-03T00:00:02Z", "payload": desktopPayload])
            XCTAssertTrue(desktop.preservesMetadataRefresh(desktopRefresh)); _ = desktop.parseEvents(desktopRefresh)
            XCTAssertEqual(desktop.parseEvents(end).first?.runtime?.host, .codexDesktop)

        }
    }
    private func nativeLine(_ payload: [String: Any], at: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "response_item", "timestamp": String(format: "2026-10-03T00:00:%02dZ", at), "payload": payload])
    }
    private func nativeParser() -> RolloutAdapter {
        var parser = RolloutAdapter()
        _ = parser.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp","source":"vscode","originator":"codex_vscode"}}"#.utf8))
        _ = parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:00Z","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8))
        return parser
    }
    private func nativeCall(_ call: String = "call") throws -> Data {
        let args = try JSONSerialization.data(withJSONObject: ["questions": [["header": "Choice", "id": "choice", "question": "Fixture?", "options": [["label": "A", "description": "First"], ["label": "B", "description": "Second"]]]]])
        return try nativeLine(["type": "function_call", "id": "item", "name": "request_user_input", "call_id": call, "arguments": String(decoding: args, as: UTF8.self)], at: 1)
    }
    func testCapturedBlockingQuestionWaitsUntilExactNativeAnswerAndRejectsReplay() throws {
        var parser = nativeParser(), reducer = StateReducer()
        let start = CodexEvent(sessionID: "thread", turnID: "turn", requestID: nil, kind: .started, source: .desktop, title: "QA", at: Date(timeIntervalSince1970: 1), id: "start")
        XCTAssertTrue(reducer.apply(start))
        let call = try nativeCall()
        let events = parser.parseEvents(call)
        let question = try XCTUnwrap(events.first)
        XCTAssertEqual(question.kind, .userQuestionObserved)
        XCTAssertEqual(question.requestSnapshot?.question?.questions.first?.id, "choice")
        XCTAssertTrue(reducer.apply(question, allowUnverifiedWait: true))
        XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingUser)
        XCTAssertTrue(parser.parseEvents(call).isEmpty)
        XCTAssertTrue(parser.parseEvents(Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:03Z","payload":{"type":"task_complete","turn_id":"turn"}}"#.utf8)).isEmpty)
        XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingUser)
        for output in [#"{"accepted":true}"#, #"{"answers":{"foreign":{"answers":["A"]}}}"#, #"{"answers":{}}"#, #"{"cancelled":true}"#, #"{"error":{"message":"fixture"}}"#] {
            XCTAssertTrue(parser.parseEvents(try nativeLine(["type": "function_call_output", "call_id": "call", "output": output], at: 4)).isEmpty)
            XCTAssertTrue(parser.hasPendingBlockingQuestion)
        }
        let answer = #"{"answers":{"choice":{"answers":["A"]}}}"#
        XCTAssertTrue(parser.parseEvents(try nativeLine(["type": "function_call_output", "call_id": "unrelated", "output": answer], at: 5)).isEmpty)
        let resolved = try XCTUnwrap(parser.parseEvents(try nativeLine(["type": "function_call_output", "call_id": "call", "output": answer], at: 5)).first)
        XCTAssertEqual(resolved.requestUpdate?.identity, question.requestSnapshot?.identity)
        XCTAssertTrue(reducer.apply(resolved)); XCTAssertEqual(reducer.sessions["thread"]?.pending.count, 0)
        XCTAssertEqual(reducer.sessions["thread"]?.requestSnapshots?.first?.lifecycle, .resolved)
        XCTAssertFalse(parser.hasPendingBlockingQuestion)
        XCTAssertTrue(parser.parseEvents(call).isEmpty, "closed request cannot be reopened by replay")
        let completed = try XCTUnwrap(parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:06Z","payload":{"type":"task_complete","turn_id":"turn"}}"#.utf8)))
        XCTAssertTrue(reducer.apply(completed)); XCTAssertEqual(reducer.sessions["thread"]?.state, .completed)
    }
    func testOldPendingCannotBlockNewAuthoritativeTurnAndStaleEventsCannotRebind() throws {
        var parser = nativeParser(), reducer = StateReducer()
        let oldQuestion = try XCTUnwrap(parser.parseEvents(try nativeCall()).first)
        XCTAssertTrue(reducer.apply(oldQuestion, allowUnverifiedWait: true))
        func lifecycle(_ type: String, _ turn: String, _ at: Int) -> Data {
            Data("{\"type\":\"event_msg\",\"timestamp\":\"2026-10-03T00:00:\(String(format: "%02d", at))Z\",\"payload\":{\"type\":\"\(type)\",\"turn_id\":\"\(turn)\"}}".utf8)
        }
        let newStart = try XCTUnwrap(parser.parse(lifecycle("task_started", "new", 3)))
        XCTAssertTrue(reducer.apply(newStart)); XCTAssertEqual(reducer.sessions["thread"]?.turnID, "new")
        let newCall = try nativeLine(["type": "function_call", "name": "request_user_input", "call_id": "new-call", "arguments": String(data: JSONSerialization.data(withJSONObject: ["questions": [["header": "Choice", "id": "choice", "question": "Fixture?", "options": [["label": "A", "description": "First"], ["label": "B", "description": "Second"]]]]]), encoding: .utf8)!], at: 4)
        let newQuestion = try XCTUnwrap(parser.parseEvents(newCall).first)
        XCTAssertEqual(newQuestion.turnID, "new")
        XCTAssertTrue(reducer.apply(newQuestion, allowUnverifiedWait: true)); XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingUser)
        XCTAssertTrue(parser.parseEvents(lifecycle("task_started", "new", 5)).isEmpty, "duplicate start cannot reset current pending")
        XCTAssertTrue(parser.parseEvents(lifecycle("task_started", "turn", 6)).isEmpty, "retired turn cannot return")
        var replay = try XCTUnwrap(JSONSerialization.jsonObject(with: nativeCall()) as? [String: Any])
        replay["timestamp"] = "2026-10-03T00:00:05Z"
        XCTAssertTrue(parser.parseEvents(try JSONSerialization.data(withJSONObject: replay)).isEmpty, "superseded call cannot become a new-turn question even with a newer timestamp")
        let answer = #"{"answers":{"choice":{"answers":["A"]}}}"#
        XCTAssertTrue(parser.parseEvents(try nativeLine(["type": "function_call_output", "call_id": "call", "output": answer], at: 6)).isEmpty)
        XCTAssertTrue(parser.parseEvents(lifecycle("task_complete", "turn", 7)).isEmpty)
        XCTAssertTrue(parser.parseEvents(lifecycle("task_complete", "new", 7)).isEmpty, "current question still blocks completion")
        let resolved = try XCTUnwrap(parser.parseEvents(try nativeLine(["type": "function_call_output", "call_id": "new-call", "output": answer], at: 8)).first)
        XCTAssertEqual(resolved.requestUpdate?.identity, newQuestion.requestSnapshot?.identity)
        XCTAssertTrue(reducer.apply(resolved)); XCTAssertEqual(reducer.sessions["thread"]?.pending.count, 0)
        XCTAssertTrue(parser.parseEvents(lifecycle("task_complete", "turn", 9)).isEmpty, "late old completion cannot terminate the current turn")
        let completed = try XCTUnwrap(parser.parse(lifecycle("task_complete", "new", 10)))
        XCTAssertTrue(reducer.apply(completed)); XCTAssertEqual(reducer.sessions["thread"]?.state, .completed)
    }
    func testMalformedTimestampCannotMutateActiveTurnAndUnknownHostCannotObserve() throws {
        var parser = nativeParser()
        XCTAssertTrue(parser.parseEvents(Data(#"{"type":"event_msg","timestamp":"invalid","payload":{"type":"task_started","turn_id":"bad"}}"#.utf8)).isEmpty)
        XCTAssertEqual(parser.currentTurnID, "turn")
        let call = try nativeCall()
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: call) as? [String: Any]); malformed["timestamp"] = "invalid"
        let invalid = try JSONSerialization.data(withJSONObject: malformed)
        XCTAssertNil(parser.orderedNativeQuestionTurn(invalid)); XCTAssertTrue(parser.parseEvents(invalid).isEmpty)
        XCTAssertEqual(parser.currentTurnID, "turn", "Malformed timestamp cannot change the active turn")
        XCTAssertTrue(parser.hasPendingBlockingQuestion, "Malformed timestamp still vetoes completion proof")
        XCTAssertEqual(parser.orderedNativeQuestionTurn(call), "turn")
        XCTAssertEqual(parser.parseEvents(call).first?.turnID, "turn")
        var unknown = RolloutAdapter()
        _ = unknown.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp","source":"vscode"}}"#.utf8))
        _ = unknown.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-03T00:00:00Z","payload":{"type":"task_started","turn_id":"turn"}}"#.utf8))
        XCTAssertTrue(unknown.parseEvents(call).isEmpty)
    }
}
