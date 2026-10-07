import XCTest
import AppKit
@testable import refik

final class QuestionTests: XCTestCase {
    private func adapter() -> RolloutAdapter {
        var parser = RolloutAdapter()
        _ = parser.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp/project","source":"vscode"}}"#.utf8))
        return parser
    }
    private func item(_ item: [String: Any], second: Int, turn: String? = "one") -> Data {
        var payload: [String: Any] = ["type": "item_completed", "item": item]
        if let turn { payload["turn_id"] = turn }
        return try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": String(format: "2026-10-01T01:00:%02dZ", second), "payload": payload])
    }
    private func ask(_ id: String = "call_ask", count: Int = 1) -> [String: Any] {
        ["type": "AgentMessage", "id": id, "content": "fixture", "phase": "final_answer", "delivery": "async", "questions": Array(repeating: ["title": "fixture", "options": []] as [String: Any], count: count)]
    }
    private func reply(_ ids: [String]) -> [String: Any] {
        let body = String(data: try! JSONSerialization.data(withJSONObject: ids.map { ["questionItemId": $0, "question": "fixture", "answer": "fixture"] }), encoding: .utf8)!
        return ["type": "UserMessage", "id": "reply", "client_id": "client", "content": [["type": "text", "text": "<send_user_message_question_reply>\(body)</send_user_message_question_reply>"]]]
    }
    private func lifecycle(_ kind: EventKind, _ second: Int, turn: String = "one", fidelity: Fidelity = .official) -> CodexEvent {
        CodexEvent(sessionID: "thread", turnID: turn, requestID: nil, kind: kind, source: .desktop, title: "project", at: Date(timeIntervalSince1970: 1790816400 + Double(second)), id: "\(kind):\(second)", fidelity: fidelity)
    }
    func testNativeQuestionPreservesActualTextOptionsAndObserveOnlyRuntime() {
        var parser = RolloutAdapter()
        _ = parser.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp/project","source":"vscode","originator":"Codex Desktop","cli_version":"0.158.0-alpha.2.1","title":"Actual chat"}}"#.utf8))
        var message = ask()
        message["questions"] = [["title": "Which fixture?", "options": ["Option A", "Option B"]]]
        let observed = parser.parseEvents(item(message, second: 1))[0]
        let request = observed.requestSnapshot!
        XCTAssertEqual(request.question?.questions[0].prompt, "Which fixture?")
        XCTAssertEqual(request.question?.questions[0].options.map(\.label), ["Option A", "Option B"])
        XCTAssertEqual(observed.runtime?.host, .codexDesktop)
        XCTAssertEqual(observed.runtime?.chatName, "Actual chat")
        XCTAssertNil(observed.runtime?.version, "CLI version is not the Desktop runtime version")
        XCTAssertNil(observed.capabilities?.responseChannelID)
        XCTAssertFalse(observed.capabilities!.hasLive(.answerQuestions, runtime: observed.runtime))
        XCTAssertEqual(request.identity.turnID, "one")
        XCTAssertEqual(request.identity.runtimeID, observed.runtime?.id)
        let resolution = parser.parseEvents(item(reply([observed.requestID!]), second: 2))[0]
        XCTAssertEqual(resolution.requestUpdate?.identity, request.identity)
        XCTAssertEqual(resolution.requestUpdate?.lifecycle, .resolved)
    }
    func testNativeQuestionPreservesExplicitMultiAndFreeformFlags() {
        var parser = adapter(); var message = ask()
        message["questions"] = [["id": "actual-question", "question": "Choose fixtures", "header": "Fixtures",
            "multiple": true, "custom": false, "options": [["id": "actual-option", "label": "A", "description": "Fixture description"]]]]
        let observed = parser.parseEvents(item(message, second: 1))[0]
        let question = observed.requestSnapshot!.question!.questions[0]
        XCTAssertEqual(question.id, "actual-question")
        XCTAssertEqual(question.options[0].id, "actual-option")
        XCTAssertEqual(question.options[0].description, "Fixture description")
        XCTAssertTrue(question.allowsMultipleSelection)
        XCTAssertFalse(question.allowsFreeform)
        XCTAssertEqual(observed.runtime?.host, .unknown, "vscode source alone does not identify the Desktop or VS Code host")
    }
    func testNativeQuestionGroupTracksEachExactIndexAndNewTurnClearsLease() {
        var parser = adapter()
        let observed = parser.parseEvents(item(ask(count: 2), second: 1))
        let first = parser.parseEvents(item(reply([observed[0].requestID!]), second: 2))[0]
        let second = parser.parseEvents(item(reply([observed[1].requestID!]), second: 3))[0]
        XCTAssertEqual(first.requestUpdate?.identity, observed[0].requestSnapshot?.identity)
        XCTAssertEqual(second.requestUpdate?.identity, observed[1].requestSnapshot?.identity)
        XCTAssertNotEqual(first.requestUpdate?.identity, second.requestUpdate?.identity)
        _ = parser.parseEvents(Data(#"{"type":"event_msg","timestamp":"2026-10-01T01:00:04Z","payload":{"type":"task_started","turn_id":"two"}}"#.utf8))
        let stale = parser.parseEvents(item(reply([observed[0].requestID!]), second: 5))[0]
        XCTAssertNil(stale.requestUpdate, "Old native call cannot resolve a new turn's structured request")
    }
    func testNativeMalformedQuestionRetainsLegacyObservationWithoutInventingBody() {
        var parser = adapter(); var message = ask()
        message["questions"] = [["title": "Fixture", "options": [42]]]
        let malformed = parser.parseEvents(item(message, second: 1))[0]
        XCTAssertEqual(malformed.kind, .userQuestionObserved)
        XCTAssertNil(malformed.requestSnapshot)
        message["questions"] = [["title": "Fixture", "options": [], "multiple": 1]]
        XCTAssertNil(parser.parseEvents(item(message, second: 2))[0].requestSnapshot)
    }
    func testRealAcceptedShapeResolvesSpecificQuestionAndDeduplicates() {
        var parser = adapter(), reducer = StateReducer()
        let events = parser.parseEvents(item(ask(count: 2), second: 1))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].requestID, #"["request_user_input_async","call_ask",0]"#)
        reducer.apply(lifecycle(.started, 0))
        for event in events { XCTAssertTrue(reducer.apply(event, allowUnverifiedWait: true)); XCTAssertFalse(reducer.apply(event, allowUnverifiedWait: true)) }
        XCTAssertEqual(reducer.aggregate, .waiting)
        let replies = parser.parseEvents(item(reply([events[0].requestID!]), second: 2))
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].kind, .requestResolved)
        reducer.apply(replies[0])
        XCTAssertEqual(reducer.sessions["thread"]?.pending, [events[1].requestID!])
        XCTAssertEqual(reducer.aggregate, .waiting)
        for event in parser.parseEvents(item(reply([events[1].requestID!]), second: 3)) { reducer.apply(event) }
        XCTAssertEqual(reducer.aggregate, .running)
        XCTAssertFalse(events[0].detail!.contains("fixture"))
    }
    @MainActor func testAppAcceptsStructuredDerivedWaitOverGreenAndWorking() {
        let app = AppModel(inspectNotificationPermission: false)
        app.accept(lifecycle(.started, 0), historical: false)
        var completion = lifecycle(.completed, 1); completion = CodexEvent(sessionID: "other", turnID: "two", requestID: nil, kind: completion.kind, source: .desktop, title: "other", at: completion.at, id: "other-completed")
        app.accept(completion, historical: false)
        var parser = adapter()
        let question = parser.parseEvents(item(ask(), second: 2))[0]
        app.accept(question, historical: false)
        for event in [lifecycle(.activity, 3, fidelity: .derived), lifecycle(.started, 4), lifecycle(.reconciledRunning, 5, fidelity: .derived)] { app.accept(event, historical: false) }
        XCTAssertEqual(app.aggregate, .waiting)
        for event in parser.parseEvents(item(reply([question.requestID!]), second: 6)) { app.accept(event, historical: false) }
        XCTAssertEqual(app.aggregate, .completed)
        app.markSeen(["other"])
        XCTAssertEqual(app.aggregate, .running)
    }
    func testProseRawCallsMissingTurnAndUnacceptedRepliesDoNotWaitOrResolve() {
        var parser = adapter()
        XCTAssertTrue(parser.parseEvents(item(["type": "AgentMessage", "id": "prose", "content": "Continue?"], second: 1)).isEmpty)
        XCTAssertTrue(parser.parseEvents(item(ask(), second: 1, turn: nil)).isEmpty)
        XCTAssertTrue(parser.parseEvents(Data(#"{"type":"response_item","timestamp":"2026-10-01T01:00:01Z","payload":{"type":"function_call","name":"request_user_input_async","call_id":"call_raw","arguments":"{}"}}"#.utf8)).isEmpty)
        var unaccepted = reply([#"["request_user_input_async","call_ask",0]"#]); unaccepted["type"] = "SteeringUserMessage"; unaccepted["status"] = "pending"
        XCTAssertTrue(parser.parseEvents(item(unaccepted, second: 2)).isEmpty)
        var malformed = reply(["unrelated"])
        XCTAssertTrue(parser.parseEvents(item(malformed, second: 2)).isEmpty)
        malformed["content"] = [["type": "text", "text": "ordinary reply"]]
        XCTAssertTrue(parser.parseEvents(item(malformed, second: 3)).isEmpty)
    }
    func testNewTurnRejectsOldReplyAndTerminalEndsTurnScopedQuestion() {
        var parser = adapter(), reducer = StateReducer()
        reducer.apply(lifecycle(.started, 0))
        let question = parser.parseEvents(item(ask(), second: 1))[0]
        reducer.apply(question, allowUnverifiedWait: true)
        reducer.apply(lifecycle(.completed, 2))
        XCTAssertEqual(reducer.aggregate, .completed)
        XCTAssertTrue(reducer.sessions["thread"]!.pending.isEmpty)
        XCTAssertFalse(reducer.apply(parser.parseEvents(item(ask("late"), second: 3))[0], allowUnverifiedWait: true))
        reducer.apply(lifecycle(.started, 4, turn: "two"))
        XCTAssertFalse(reducer.apply(parser.parseEvents(item(reply([question.requestID!]), second: 5))[0]))
        XCTAssertEqual(reducer.aggregate, .running)
    }
    func testPermissionAndQuestionResolutionKeepsDeterministicWaitingState() {
        var reducer = StateReducer(), parser = adapter()
        reducer.apply(lifecycle(.started, 0))
        reducer.apply(parser.parseEvents(item(ask(), second: 1))[0], allowUnverifiedWait: true)
        var permission = lifecycle(.permissionObserved, 2)
        permission = CodexEvent(sessionID: "thread", turnID: "one", requestID: "permission", kind: .permissionObserved, source: .desktop, title: "project", at: permission.at, id: "permission")
        reducer.apply(permission)
        XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingPermission)
        let resolved = CodexEvent(sessionID: "thread", turnID: "one", requestID: "permission", kind: .requestResolved, source: .desktop, title: nil, at: lifecycle(.started, 3).at, id: "resolved")
        reducer.apply(resolved)
        XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingUser)
        XCTAssertFalse(reducer.expire(at: .distantFuture))
        XCTAssertEqual(reducer.aggregate, .waiting, "elapsed time never means answered")
    }
    func testOfficialSessionEndRejectsLateQuestionAndResolutionUntilNewTurn() {
        var reducer = StateReducer(), parser = adapter()
        reducer.apply(lifecycle(.started, 0))
        let original = parser.parseEvents(item(ask(), second: 1))[0]
        reducer.apply(original, allowUnverifiedWait: true)
        XCTAssertTrue(reducer.apply(lifecycle(.sessionEnded, 2)))
        XCTAssertEqual(reducer.sessions["thread"]?.officiallyEnded, true)
        XCTAssertEqual(reducer.sessions["thread"]?.state, .unknown)
        let late = parser.parseEvents(item(ask("call_late"), second: 3))[0]
        XCTAssertFalse(reducer.apply(late, allowUnverifiedWait: true))
        let reply = parser.parseEvents(item(reply([original.requestID!]), second: 4))[0]
        XCTAssertFalse(reducer.apply(reply))
        XCTAssertTrue(reducer.sessions["thread"]!.pending.isEmpty)
        XCTAssertTrue(reducer.sessions["thread"]!.pendingKinds.isEmpty)
        XCTAssertEqual(reducer.aggregate, .neutral)
        XCTAssertTrue(reducer.apply(lifecycle(.started, 5, turn: "two")))
        XCTAssertEqual(reducer.sessions["thread"]?.officiallyEnded, false)
        let next = parser.parseEvents(item(ask("call_new"), second: 6, turn: "two"))[0]
        XCTAssertTrue(reducer.apply(next, allowUnverifiedWait: true))
        XCTAssertEqual(reducer.sessions["thread"]?.pending, [next.requestID!])
        XCTAssertEqual(reducer.aggregate, .waiting)
    }
    func testBrightPaletteAndRuntimeAlphaMask() throws {
        let amber = MascotPalette.color(.waiting).usingColorSpace(.deviceRGB)!
        let green = MascotPalette.color(.completed).usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(amber.redComponent, 0.95); XCTAssertGreaterThan(amber.greenComponent, 0.7); XCTAssertLessThan(amber.blueComponent, 0.1)
        XCTAssertGreaterThan(green.greenComponent, 0.95)
        XCTAssertEqual(MascotPalette.color(.running), .white)
        let source = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.red.setFill(); NSRect(x: 5, y: 5, width: 10, height: 10).fill(); return true
        }
        let rendered = MascotPalette.render(source, state: .waiting)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(rendered.tiffRepresentation)))
        let center = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(center.greenComponent, 0.7)
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
    }
}
