import XCTest
@testable import refik

final class CodexTerminalQuestionTests: XCTestCase {
    private let session = "01a104d8-292f-7f22-85f7-5448d81b1067"
    private func line(_ payload: [String: Any], type: String = "event_msg", at: Int) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": "2026-10-04T03:07:\(String(format: "%02d", at))Z", "payload": payload])
    }
    private func fixture(_ changes: [String: Any] = [:], sessionID: String? = nil) throws -> (RolloutAdapter, URL, Data) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("refik-cli-question-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureSession = sessionID ?? session
        let file = root.appendingPathComponent("rollout-" + fixtureSession + ".jsonl")
        var meta: [String: Any] = ["id": fixtureSession, "cwd": root.path, "source": "cli", "originator": "codex-tui", "cli_version": "0.153.4"]
        meta.merge(changes) { _, new in new }
        let data = try line(meta, type: "session_meta", at: 0)
        try (data + Data([10])).write(to: file)
        var parser = RolloutAdapter(); parser.rolloutFile = file; parser.rolloutRoot = root
        _ = parser.parse(data)
        return (parser, root, data)
    }
    private func call(_ id: String = "call", at: Int = 14) throws -> Data {
        let args = try JSONSerialization.data(withJSONObject: ["questions": [["id": "choice", "header": "Choice", "question": "A or B?", "options": [["label": "A", "description": "A"], ["label": "B", "description": "B"]]]]])
        return try line(["type": "function_call", "name": "request_user_input", "call_id": id, "arguments": String(decoding: args, as: UTF8.self)], type: "response_item", at: at)
    }
    private func asyncCall(_ id: String = "async-call", at: Int = 14) throws -> Data {
        let args = try JSONSerialization.data(withJSONObject: ["questions": [["title": "A or B?", "options": ["A", "B"]]]])
        return try line(["type": "function_call", "name": "request_user_input_async", "call_id": id, "arguments": String(decoding: args, as: UTF8.self)], type: "response_item", at: at)
    }
    @MainActor func testObserved1601TUIAsyncACKCompletionAndExactReply() throws {
        var (parser, root, _) = try fixture(["source": "vscode", "cli_version": "0.160.1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(inspectNotificationPermission: false)
        // Sanitized real 0.160.1 call/ACK/complete timing; reply below is an
        // existing supported envelope fixture, not a claimed live reply.
        func observed(_ data: Data, _ stamp: String) throws -> Data {
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            record["timestamp"] = "2026-10-06T01:04:" + stamp + "Z"
            return try JSONSerialization.data(withJSONObject: record)
        }
        let start = try XCTUnwrap(parser.parse(observed(line(["type": "task_started", "turn_id": "turn"], at: 7), "51.254")))
        XCTAssertEqual(start.source, .cli); XCTAssertEqual(start.runtime?.host, .terminal)
        model.accept(start, historical: false)
        let question = try XCTUnwrap(parser.parseEvents(observed(asyncCall(), "53.714")).first)
        model.accept(question, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .running)
        let proof = try XCTUnwrap(parser.cliQuestionProof)
        model.accept(question, historical: false, cliQuestionProof: proof)
        XCTAssertEqual(model.aggregate, .waiting)
        XCTAssertEqual(SessionPresentation.hostLabel(try XCTUnwrap(model.sessions.first { $0.id == session })), "Terminal")
        XCTAssertFalse(model.canSubmitResponse(try XCTUnwrap(question.requestSnapshot)))
        XCTAssertTrue(parser.parseEvents(try observed(output(#"{"accepted":true}"#, call: "async-call", at: 15), "53.764")).isEmpty)
        XCTAssertTrue(parser.parseEvents(try observed(line(["type": "task_complete", "turn_id": "turn"], at: 16), "55.614")).isEmpty)
        XCTAssertEqual(parser.pendingCLIQuestions.count, 1)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .waitingUser)
        XCTAssertFalse(model.sessions.first { $0.id == session }?.seen ?? true)
        let key = try XCTUnwrap(question.requestID)
        let body = try JSONSerialization.data(withJSONObject: ["questionItemId": key, "answers": ["A"]])
        let text = "<send_user_message_question_reply>" + String(decoding: body, as: UTF8.self) + "</send_user_message_question_reply>"
        let replyData = try line(["type": "item_completed", "turn_id": "turn", "item": ["id": "reply", "type": "UserMessage", "content": [["type": "text", "text": text]]]], at: 20)
        let reply = try observed(replyData, "58.000")
        let resolved = try XCTUnwrap(parser.parseEvents(reply).first)
        model.accept(resolved, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .running)
        XCTAssertTrue(parser.pendingCLIQuestions.isEmpty)
        XCTAssertTrue(parser.parseEvents(reply).isEmpty)
        model.accept(try XCTUnwrap(parser.parse(observed(line(["type": "task_complete", "turn_id": "turn"], at: 22), "59.000"))), historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .completed)
        XCTAssertFalse(model.sessions.first { $0.id == session }?.seen ?? true)
    }
    func test1601QualifierRejectsOtherVersionsOriginsAndSupersededAsync() throws {
        for changes: [String: Any] in [["source": "vscode", "cli_version": "0.160.0"], ["source": "vscode", "cli_version": "0.160.1", "originator": "unknown"]] {
            var (parser, root, _) = try fixture(changes); defer { try? FileManager.default.removeItem(at: root) }
            _ = parser.parse(try line(["type": "task_started", "turn_id": "a"], at: 7))
            XCTAssertNil(parser.cliQuestionProof); XCTAssertTrue(parser.parseEvents(try asyncCall()).isEmpty)
        }
        var (parser, root, _) = try fixture(["source": "vscode", "cli_version": "0.160.1"])
        defer { try? FileManager.default.removeItem(at: root) }
        _ = parser.parse(try line(["type": "task_started", "turn_id": "a"], at: 7))
        XCTAssertEqual(parser.parseEvents(try asyncCall()).count, 1)
        _ = parser.parse(try line(["type": "task_started", "turn_id": "b"], at: 20))
        XCTAssertTrue(parser.pendingCLIQuestions.isEmpty)
        XCTAssertTrue(parser.parseEvents(try asyncCall(at: 21)).isEmpty)
        XCTAssertNotNil(parser.parse(try line(["type": "task_complete", "turn_id": "b"], at: 22)))
    }
    func test1601AsyncPendingBootstrapAndAbortRemainExactTurnBound() throws {
        var (parser, root, _) = try fixture(["source": "vscode", "cli_version": "0.160.1"])
        defer { try? FileManager.default.removeItem(at: root) }
        let start = try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "turn"], at: 7)))
        var reducer = StateReducer(); XCTAssertTrue(reducer.apply(start))
        let question = try XCTUnwrap(parser.parseEvents(asyncCall()).first)
        let proof = try XCTUnwrap(parser.cliQuestionProof)
        let later = CodexEvent(sessionID: session, turnID: "turn", requestID: nil, kind: .activity, source: .cli, title: "QA", at: start.at.addingTimeInterval(12), id: "later", runtime: start.runtime)
        XCTAssertTrue(reducer.apply(later))
        let before = try XCTUnwrap(reducer.sessions[session])
        let data = try JSONEncoder().encode(reducer.sessions)
        var restored = StateReducer(sessions: try JSONDecoder().decode([String: Session].self, from: data))
        XCTAssertTrue(restored.recoverCLIPending(proof, requests: parser.pendingCLIQuestions))
        XCTAssertEqual(restored.sessions[session]?.state, .waitingUser)
        XCTAssertEqual(restored.sessions[session]?.updated, before.updated)
        XCTAssertEqual(restored.sessions[session]?.seen, false)
        XCTAssertTrue(parser.parseEvents(try line(["type": "turn_aborted", "turn_id": "old"], at: 20)).isEmpty)
        let abort = try XCTUnwrap(parser.parse(line(["type": "turn_aborted", "turn_id": "turn"], at: 21)))
        XCTAssertTrue(restored.apply(abort))
        XCTAssertEqual(restored.sessions[session]?.requestSnapshots?.first?.lifecycle, .expired)
        XCTAssertTrue(parser.pendingCLIQuestions.isEmpty)
        XCTAssertTrue(parser.parseEvents(try asyncCall(at: 22)).isEmpty)
        XCTAssertFalse(restored.recoverCLIPending(proof, requests: [try XCTUnwrap(question.requestSnapshot)]))
    }
    private func output(_ value: String, call: String = "call", at: Int = 20) throws -> Data {
        try line(["type": "function_call_output", "call_id": call, "output": value], type: "response_item", at: at)
    }
    @MainActor func testObservedTerminalQuestionAdmissionAnswerAndCompletion() throws {
        var (parser, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(inspectNotificationPermission: false)
        let start = try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "turn"], at: 7)))
        model.accept(start, historical: false)
        let question = try XCTUnwrap(parser.parseEvents(try call()).first), proof = try XCTUnwrap(parser.cliQuestionProof)
        model.accept(question, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .running, "untrusted event alone cannot authorize CLI waiting")
        model.accept(question, historical: false, cliQuestionProof: proof)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .waitingUser)
        XCTAssertEqual(model.aggregate, .waiting)
        XCTAssertFalse(model.canSubmitResponse(question.requestSnapshot!))
        XCTAssertTrue(parser.parseEvents(try call()).isEmpty)
        XCTAssertTrue(parser.parseEvents(try line(["type": "task_complete", "turn_id": "turn"], at: 16)).isEmpty)
        for value in [#"{"accepted":true}"#, #"{"answers":{"foreign":{"answers":["A"]}}}"#, "Tool execution interrupted by user"] {
            XCTAssertTrue(parser.parseEvents(try output(value)).isEmpty)
            XCTAssertTrue(parser.hasPendingBlockingQuestion)
        }
        let answer = #"{"answers":{"choice":{"answers":["A"]}}}"#
        XCTAssertTrue(parser.parseEvents(try output(answer, call: "foreign")).isEmpty)
        let resolved = try XCTUnwrap(parser.parseEvents(try output(answer)).first)
        model.accept(resolved, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .running)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.requestSnapshots?.first?.lifecycle, .resolved)
        let complete = try XCTUnwrap(parser.parse(line(["type": "task_complete", "turn_id": "turn"], at: 22)))
        model.accept(complete, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .completed)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.seen, false)
        XCTAssertNil(model.sessions.first { $0.id == session }?.editorOriginEvidence)
        XCTAssertNil(model.sessions.first { $0.id == session }?.verifiedEditorHost)
    }
    @MainActor func testAbortExpiresInsteadOfAnsweringAndNewTurnRejectsStaleRecords() throws {
        var (parser, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(inspectNotificationPermission: false)
        model.accept(try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "old"], at: 7))), historical: false)
        let question = try XCTUnwrap(parser.parseEvents(try call()).first)
        model.accept(question, historical: false, cliQuestionProof: try XCTUnwrap(parser.cliQuestionProof))
        XCTAssertTrue(parser.parseEvents(try line(["type": "turn_aborted", "turn_id": "foreign"], at: 15)).isEmpty)
        let aborted = try XCTUnwrap(parser.parse(line(["type": "turn_aborted", "turn_id": "old"], at: 21)))
        model.accept(aborted, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.requestSnapshots?.first?.lifecycle, .expired)
        XCTAssertTrue(parser.pendingCLIQuestions.isEmpty)
        let newStart = try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "new"], at: 22)))
        model.accept(newStart, historical: false)
        XCTAssertTrue(parser.parseEvents(try line(["type": "task_started", "turn_id": "old"], at: 23)).isEmpty)
        XCTAssertTrue(parser.parseEvents(try call(at: 24)).isEmpty, "retired call cannot bind newer turn")
        XCTAssertTrue(parser.parseEvents(try line(["type": "turn_aborted", "turn_id": "old"], at: 25)).isEmpty)
        let fresh = try XCTUnwrap(parser.parseEvents(try call("fresh", at: 26)).first)
        model.accept(fresh, historical: false, cliQuestionProof: try XCTUnwrap(parser.cliQuestionProof))
        XCTAssertEqual(model.sessions.first { $0.id == session }?.turnID, "new")
        XCTAssertEqual(model.sessions.first { $0.id == session }?.pending.count, 1)
    }
    func testMetadataProofRejectsUnknownForeignSubagentAndWrongFile() throws {
        let negatives: [[String: Any]] = [["originator": "unknown"], ["source": "exec"], ["source": "vscode"], ["cli_version": "unknown"], ["id": UUID().uuidString], ["parent_thread_id": "foreign"], ["subagent": true], ["cwd": "relative"]]
        for changes in negatives {
            var (parser, root, _) = try fixture(changes); defer { try? FileManager.default.removeItem(at: root) }
            _ = parser.parse(try line(["type": "task_started", "turn_id": "turn"], at: 7))
            XCTAssertNil(parser.cliQuestionProof)
            XCTAssertTrue(parser.parseEvents(try call()).isEmpty)
        }
        var (parser, root, meta) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        parser.rolloutRoot = root.appendingPathComponent("foreign")
        _ = parser.parse(meta); _ = parser.parse(try line(["type": "task_started", "turn_id": "turn"], at: 7))
        XCTAssertNil(parser.cliQuestionProof); XCTAssertTrue(parser.parseEvents(try call()).isEmpty)
    }
    func testValidatedBootstrapRestoresPendingWithoutSeenAndRejectsTerminalOrNewerState() throws {
        var (parser, root, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let start = try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "turn"], at: 7)))
        let question = try XCTUnwrap(parser.parseEvents(try call()).first), proof = try XCTUnwrap(parser.cliQuestionProof)
        var reducer = StateReducer(); XCTAssertTrue(reducer.apply(start))
        let activity = CodexEvent(sessionID: session, turnID: "turn", requestID: nil, kind: .activity, source: .cli, title: "QA", at: start.at.addingTimeInterval(12), id: "activity", provider: .codex)
        XCTAssertTrue(reducer.apply(activity))
        let state = try XCTUnwrap(reducer.sessions[session])
        XCTAssertFalse(reducer.apply(question, allowUnverifiedWait: true), "generic historical timestamp guard remains strict")
        XCTAssertTrue(reducer.recoverCLIPending(proof, requests: parser.pendingCLIQuestions))
        XCTAssertEqual(reducer.sessions[session]?.state, .waitingUser); XCTAssertEqual(reducer.sessions[session]?.seen, false)
        XCTAssertEqual(reducer.sessions[session]?.updated, state.updated)
        XCTAssertFalse(reducer.recoverCLIPending(proof, requests: parser.pendingCLIQuestions))
        for mutation in 0..<4 {
            var copy = reducer
            if mutation == 0 { copy.markSeen([session]) }
            if mutation == 1 { _ = copy.apply(CodexEvent(sessionID: session, turnID: "newer", requestID: nil, kind: .started, source: .cli, title: "QA", at: state.updated.addingTimeInterval(1), id: "newer")) }
            if mutation == 2 { _ = copy.apply(CodexEvent(sessionID: session, turnID: "turn", requestID: nil, kind: .activity, source: .cli, title: "QA", at: state.updated.addingTimeInterval(1), id: "foreign", projectPath: "/foreign")) }
            if mutation == 3 { _ = copy.apply(CodexEvent(sessionID: session, turnID: "turn", requestID: nil, kind: .completed, source: .cli, title: "QA", at: state.updated.addingTimeInterval(1), id: "terminal")) }
            XCTAssertFalse(copy.recoverCLIPending(proof, requests: parser.pendingCLIQuestions))
        }
    }
    @MainActor func testRealWatcherCallbacksRebuildPersistedPendingAndExpireOnAbort() async throws {
        let (initialParser, root, meta) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try XCTUnwrap(initialParser.rolloutFile)
        let stateURL = root.appendingPathComponent("attention-state.json")
        var seeded = StateReducer(), parser = initialParser
        let start = try XCTUnwrap(parser.parse(line(["type": "task_started", "turn_id": "turn"], at: 7)))
        XCTAssertTrue(seeded.apply(start))
        try JSONEncoder().encode(seeded).write(to: stateURL)
        let model = AppModel(inspectNotificationPermission: false, stateURL: stateURL)
        let waiting = expectation(description: "real watcher question delivered")
        let watcher = TranscriptWatcher(root: root, onEvent: { event, historical in
            DispatchQueue.main.async { model.accept(event, historical: historical) }
        }, onBootstrapDone: {}, onHealth: { _ in }, onCLIQuestion: { event, historical, proof in
            DispatchQueue.main.async { model.accept(event, historical: historical, cliQuestionProof: proof); waiting.fulfill() }
        }, onCLIPendingRecovery: { proof, requests in
            DispatchQueue.main.async { model.recoverCLIPending(proof, requests: requests) }
        })
        let startLine = try line(["type": "task_started", "turn_id": "turn"], at: 7)
        try [meta, startLine, call()].reduce(Data()) { $0 + $1 + Data([10]) }.write(to: file)
        watcher.scan()
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.state, .waitingUser)
        XCTAssertEqual(model.aggregate, .waiting)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.seen, false)
        let clock = ISO8601DateFormatter(); clock.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let abort = try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": clock.string(from: Date().addingTimeInterval(1)), "payload": ["type": "turn_aborted", "turn_id": "turn"]])
        let fd = try FileHandle(forWritingTo: file); try fd.seekToEnd(); try fd.write(contentsOf: abort + Data([10])); try fd.close()
        watcher.scan(changedPaths: [file.path])
        for _ in 0..<30 {
            if model.sessions.first(where: { $0.id == session })?.state == .interrupted { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.sessions.first { $0.id == session }?.requestSnapshots?.first?.lifecycle, .expired)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.pending.count, 0)
        XCTAssertEqual(model.sessions.first { $0.id == session }?.seen, false)
    }

    @MainActor func testParallelCLISessionsCannotResolveEachOtherOrReuseReplacedFileProof() throws {
        var (first, rootA, _) = try fixture()
        let otherID = UUID().uuidString
        var (second, rootB, _) = try fixture(sessionID: otherID)
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let model = AppModel(inspectNotificationPermission: false)
        for event in [try first.parse(line(["type": "task_started", "turn_id": "a"], at: 7)), try second.parse(line(["type": "task_started", "turn_id": "b"], at: 7))].compactMap({ $0 }) { model.accept(event, historical: false) }
        let qa = try XCTUnwrap(first.parseEvents(call("a-call")).first), qb = try XCTUnwrap(second.parseEvents(call("b-call")).first)
        let proofA = try XCTUnwrap(first.cliQuestionProof), proofB = try XCTUnwrap(second.cliQuestionProof)
        model.accept(qa, historical: false, cliQuestionProof: proofA)
        model.accept(qb, historical: false, cliQuestionProof: proofA)
        XCTAssertEqual(model.sessions.first { $0.id == otherID }?.state, .running)
        model.accept(qb, historical: false, cliQuestionProof: proofB)
        XCTAssertEqual(model.sessions.filter { $0.state == .waitingUser }.count, 2)
        let answer = #"{"answers":{"choice":{"answers":["A"]}}}"#
        XCTAssertTrue(second.parseEvents(try output(answer, call: "a-call")).isEmpty)
        model.accept(try XCTUnwrap(first.parseEvents(output(answer, call: "a-call")).first), historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == otherID }?.state, .waitingUser)
        let file = try XCTUnwrap(second.rolloutFile)
        try Data("replacement".utf8).write(to: file, options: .atomic)
        XCTAssertFalse(proofB.fileStillValid)
        XCTAssertFalse(proofB.matches(qb))
    }

}
