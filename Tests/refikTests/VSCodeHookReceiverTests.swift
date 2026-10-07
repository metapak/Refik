import XCTest
import RefikInteractionWire
@testable import refik

final class VSCodeHookReceiverTests: XCTestCase {
    private var tick: TimeInterval = 0
    private func receive(_ receiver: inout VSCodeHookReceiver, _ phase: String, call: String? = nil,
                         question: Bool = false, id: String = UUID().uuidString,
                         tool: String? = "vscode_askQuestions") throws -> [CodexEvent] {
        tick += 1
        var object: [String: Any] = ["phase": phase, "sessionID": "session"]
        object["nativeToolID"] = call; object["toolName"] = tool
        if question { object["questions"] = [["text": "Choose a target", "header": "Target",
            "options": [["label": "First", "description": "First choice"], ["label": "Second", "description": "Second choice"]], "multiSelect": false]] }
        let observation = try JSONDecoder().decode(VSCodeHookObservation.self, from: JSONSerialization.data(withJSONObject: object))
        let input = CodexEvent(sessionID: "copilot:session", turnID: UUID().uuidString, requestID: nil,
            kind: phase == "Stop" ? .completed : .activity, source: .unknown, title: "Project",
            at: Date(timeIntervalSince1970: 1_800_000_000 + tick), id: id, provider: .copilot,
            runtime: RuntimeMetadata(id: "vscode-runtime", host: .vscode, version: "1.136.2"))
        return receiver.events(input, observation: observation)
    }
    func testNativeIDPostResolvesExactQuestionWithoutArgumentsOrActions() throws {
        var receiver = VSCodeHookReceiver()
        _ = try receive(&receiver, "UserPromptSubmit", tool: nil)
        let events = try receive(&receiver, "PreToolUse", call: "call1", question: true)
        let request = try XCTUnwrap(events.first?.requestSnapshot)
        XCTAssertEqual(request.question?.questions.first?.header, "Target")
        XCTAssertEqual(request.question?.questions.first?.options.first?.description, "First choice")
        XCTAssertFalse(request.question!.questions.first!.allowsMultipleSelection)
        XCTAssertNil(events.first?.capabilities?.responseChannelID)
        XCTAssertEqual(try receive(&receiver, "PostToolUse", call: "call1").first?.requestUpdate?.identity, request.identity)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "call1").isEmpty)
        XCTAssertTrue(try receive(&receiver, "PreToolUse", call: "call1", question: true).isEmpty)
    }
    func testConcurrentQuestionsAndDuplicatePreRetainIndependentGenerations() throws {
        var receiver = VSCodeHookReceiver()
        var reducer = StateReducer()
        for event in try receive(&receiver, "UserPromptSubmit", tool: nil) { _ = reducer.apply(event) }
        let a = try receive(&receiver, "PreToolUse", call: "a", question: true)
        let b = try receive(&receiver, "PreToolUse", call: "b", question: true)
        for event in a + b { _ = reducer.apply(event) }
        XCTAssertTrue(try receive(&receiver, "PreToolUse", call: "a", question: true).isEmpty)
        XCTAssertEqual(reducer.sessions["copilot:session"]?.pending.count, 2)
        for event in try receive(&receiver, "PostToolUse", call: "a") { _ = reducer.apply(event) }
        XCTAssertEqual(reducer.sessions["copilot:session"]?.pending.count, 1)
        XCTAssertEqual(try receive(&receiver, "PostToolUse", call: "b").first?.requestUpdate?.identity, b.first?.requestSnapshot?.identity)
    }
    func testNewPromptExpiresPriorPendingAndReusedIDPostFailsClosed() throws {
        var receiver = VSCodeHookReceiver()
        var reducer = StateReducer()
        for event in try receive(&receiver, "UserPromptSubmit", tool: nil) { _ = reducer.apply(event) }
        let old = try receive(&receiver, "PreToolUse", call: "reused", question: true)
        for event in old { _ = reducer.apply(event) }
        for event in try receive(&receiver, "UserPromptSubmit", tool: nil) { _ = reducer.apply(event) }
        XCTAssertTrue(reducer.sessions["copilot:session"]!.pending.isEmpty)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "reused").isEmpty)
        let new = try receive(&receiver, "PreToolUse", call: "reused", question: true)
        XCTAssertNotEqual(old.first?.requestSnapshot?.identity, new.first?.requestSnapshot?.identity)
        for event in new { _ = reducer.apply(event) }
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "reused").isEmpty)
        XCTAssertEqual(reducer.sessions["copilot:session"]?.state, .waitingUser)
    }
    func testUnrelatedHooksAndBoundExhaustionNeverResolvePending() throws {
        var receiver = VSCodeHookReceiver(maximumKeys: 1)
        _ = try receive(&receiver, "UserPromptSubmit", tool: nil)
        _ = try receive(&receiver, "PreToolUse", call: "a", question: true)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "a", tool: nil).isEmpty)
        let subagent = try receive(&receiver, "SubagentStop", tool: nil)
        XCTAssertFalse(subagent.contains { $0.kind == .requestResolved || $0.kind == .completed })
        _ = try receive(&receiver, "PreToolUse", call: "b", question: true)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "a").isEmpty)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", call: "b").isEmpty)
    }
}
