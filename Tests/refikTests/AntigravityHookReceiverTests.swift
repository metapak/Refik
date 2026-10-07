import XCTest
import RefikInteractionWire
@testable import refik

final class AntigravityHookReceiverTests: XCTestCase {
    private var tick: TimeInterval = 0
    private func receive(_ receiver: inout AntigravityHookReceiver, _ phase: String,
                         step: Int? = nil, question: Bool = false, tool: String = "ask_question",
                         idle: Bool? = nil, invocation: Int? = nil) throws -> [CodexEvent] {
        tick += 1
        var object: [String: Any] = ["phase": phase, "conversationID": "conversation", "toolName": tool, "hasError": false]
        if let step { object["stepIndex"] = step }
        if let idle { object["fullyIdle"] = idle }
        if let invocation { object["invocationNum"] = invocation }
        if question { object["questions"] = [["text": "Which option?", "options": ["One", "Two"], "multiSelect": false]] }
        let observation = try JSONDecoder().decode(AntigravityHookObservation.self, from: JSONSerialization.data(withJSONObject: object))
        let input = CodexEvent(sessionID: "antigravity:conversation", turnID: "untrusted-native-turn", requestID: "legacy-unsafe",
            kind: phase == "PostToolUse" ? .requestResolved : .activity, source: .unknown, title: "Project",
            at: Date(timeIntervalSince1970: 1_800_000_000 + tick), id: UUID().uuidString, provider: .antigravity,
            runtime: RuntimeMetadata(id: "runtime", host: .unknown, version: "1"))
        return receiver.events(input, observation: observation)
    }
    func testJSONStringNativeQuestionReachesWaitingAndOnlyExactPostResolves() throws {
        var receiver = AntigravityHookReceiver()
        var reducer = StateReducer()
        for event in try receive(&receiver,"PreInvocation",invocation:0) { _ = reducer.apply(event) }
        let object: [String:Any] = ["conversationId":"conversation","stepIdx":17,"toolCall":["name":"ask_question","args":["questions":"[{\"question\":\"Pick one\",\"options\":[\"A\",\"B\"],\"is_multi_select\":false}]","toolAction":"fixture","toolSummary":"fixture"]]]
        let observation = try XCTUnwrap(AntigravityHookObservation.parse(object,phase:"PreToolUse"))
        let input = CodexEvent(sessionID:"antigravity:conversation",turnID:"untrusted",requestID:nil,kind:.activity,source:.unknown,title:"Fixture",at:Date(timeIntervalSince1970:1_800_000_002),id:UUID().uuidString,provider:.antigravity,runtime:RuntimeMetadata(id:"runtime",host:.unknown,version:"1"))
        let events = receiver.events(input,observation:observation)
        XCTAssertEqual(events.count,1)
        for event in events { _ = reducer.apply(event) }
        XCTAssertEqual(reducer.sessions["antigravity:conversation"]?.state,.waitingUser)
        XCTAssertTrue(receiver.events(input,observation:observation).isEmpty)
        XCTAssertTrue(try receive(&receiver,"PostToolUse",step:18).isEmpty)
        let resolved = try receive(&receiver,"PostToolUse",step:17)
        XCTAssertEqual(resolved.first?.requestUpdate?.identity,events.first?.requestSnapshot?.identity)
        for event in resolved { _ = reducer.apply(event) }
        XCTAssertTrue(reducer.sessions["antigravity:conversation"]!.pending.isEmpty)
    }
    func testThreeQuestionFlowAndNewTurnHaveExactGenerationsAndNoActions() throws {
        var receiver = AntigravityHookReceiver()
        let start = try receive(&receiver, "PreInvocation", invocation: 0)
        let first = try XCTUnwrap(try receive(&receiver, "PreToolUse", step: 7, question: true).first?.requestSnapshot)
        XCTAssertEqual(first.identity.turnID, start.first?.turnID)
        let duplicate = try receive(&receiver, "PreToolUse", step: 7, question: true)
        XCTAssertTrue(duplicate.isEmpty)
        let post = try receive(&receiver, "PostToolUse", step: 7)
        XCTAssertEqual(post.first?.requestUpdate?.identity, first.identity)
        XCTAssertTrue(try receive(&receiver, "PreToolUse", step: 7, question: true).isEmpty)
        let second = try XCTUnwrap(try receive(&receiver, "PreToolUse", step: 9, question: true).first?.requestSnapshot)
        XCTAssertEqual(second.identity.turnID, first.identity.turnID)
        XCTAssertEqual(try receive(&receiver, "PostToolUse", step: 9).first?.requestUpdate?.identity, second.identity)
        _ = try receive(&receiver, "Stop", idle: true)
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        let thirdEvents = try receive(&receiver, "PreToolUse", step: 13, question: true)
        let third = try XCTUnwrap(thirdEvents.first?.requestSnapshot)
        XCTAssertNotEqual(third.identity.turnID, first.identity.turnID)
        XCTAssertNil(thirdEvents.first?.capabilities?.responseChannelID)
        XCTAssertFalse(thirdEvents.first!.capabilities!.hasLive(.answerQuestions, runtime: thirdEvents.first?.runtime))
        XCTAssertEqual(try receive(&receiver, "PostToolUse", step: 13).first?.requestUpdate?.identity, third.identity)
    }
    func testUnrelatedPostAndInvocationNeverResolveQuestion() throws {
        var receiver = AntigravityHookReceiver()
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        let question = try XCTUnwrap(try receive(&receiver, "PreToolUse", step: 7, question: true).first?.requestSnapshot)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 7, tool: "read_file").isEmpty)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 8).isEmpty)
        XCTAssertTrue(try receive(&receiver, "PostInvocation").isEmpty)
        XCTAssertEqual(try receive(&receiver, "PreInvocation", invocation: 0).first?.turnID, question.identity.turnID)
        XCTAssertEqual(try receive(&receiver, "PostToolUse", step: 7).first?.requestUpdate?.identity, question.identity)
    }
    func testReusedNativeKeyCannotResolveNewGeneration() throws {
        var receiver = AntigravityHookReceiver()
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        let old = try XCTUnwrap(try receive(&receiver, "PreToolUse", step: 7, question: true).first?.requestSnapshot)
        _ = try receive(&receiver, "Stop", idle: true)
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        let new = try XCTUnwrap(try receive(&receiver, "PreToolUse", step: 7, question: true).first?.requestSnapshot)
        XCTAssertNotEqual(old.identity, new.identity)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 7).isEmpty)
    }
    func testOverflowDisablesCorrelationWithoutRearmingOldKeys() throws {
        var receiver = AntigravityHookReceiver(maximumKeys: 1)
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        _ = try receive(&receiver, "PreToolUse", step: 7, question: true)
        _ = try receive(&receiver, "PreToolUse", step: 9, question: true)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 7).isEmpty)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 9).isEmpty)
        _ = try receive(&receiver, "Stop", idle: true)
        _ = try receive(&receiver, "PreInvocation", invocation: 0)
        _ = try receive(&receiver, "PreToolUse", step: 7, question: true)
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 7).isEmpty)
    }
    func testReducerTerminalClearsOldPendingAndPersistenceRedactsBody() throws {
        var receiver = AntigravityHookReceiver()
        var reducer = StateReducer()
        for event in try receive(&receiver, "PreInvocation", invocation: 0) { _ = reducer.apply(event) }
        let questionEvents = try receive(&receiver, "PreToolUse", step: 7, question: true)
        for event in questionEvents { XCTAssertTrue(reducer.apply(event)) }
        let pending = try XCTUnwrap(reducer.sessions["antigravity:conversation"])
        XCTAssertEqual(pending.state, .waitingUser)
        let encoded = try JSONEncoder().encode(pending)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("Which option?"))
        for event in try receive(&receiver, "Stop", idle: true) { _ = reducer.apply(event) }
        XCTAssertTrue(reducer.sessions["antigravity:conversation"]!.pending.isEmpty)
        for event in try receive(&receiver, "PreInvocation", invocation: 0) { _ = reducer.apply(event) }
        for event in try receive(&receiver, "PreToolUse", step: 7, question: true) { _ = reducer.apply(event) }
        XCTAssertTrue(try receive(&receiver, "PostToolUse", step: 7).isEmpty)
        XCTAssertEqual(reducer.sessions["antigravity:conversation"]?.state, .waitingUser)
    }

}
