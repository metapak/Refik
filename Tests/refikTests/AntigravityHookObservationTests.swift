import XCTest
import RefikInteractionWire

final class AntigravityHookObservationTests: XCTestCase {
    private func input() -> [String: Any] {
        ["conversationId": "fixture", "stepIdx": 7, "toolCall": ["name": "ask_question", "args": ["questions": [["question": "Pick one", "options": ["A", "B"], "is_multi_select": false]]]]]
    }
    func testValidatedQuestionAndMutatedPostKeepExactStepMetadata() throws {
        let pre = try XCTUnwrap(AntigravityHookObservation.parse(input(), phase: "PreToolUse"))
        XCTAssertEqual(pre.stepIndex, 7); XCTAssertEqual(pre.questions?.first?.options, ["A", "B"])
        var changed = input()
        changed["toolCall"] = ["name": "ask_question", "args": ["questions": [["question": "Pick one", "options": ["A", "B"], "is_multi_select": false]], "answer": "A", "extra": "mutated"]]
        let post = try XCTUnwrap(AntigravityHookObservation.parse(changed, phase: "PostToolUse"))
        XCTAssertEqual(pre.conversationID, post.conversationID); XCTAssertEqual(pre.stepIndex, post.stepIndex)
        XCTAssertEqual(pre.toolName, post.toolName); XCTAssertEqual(pre.questions, post.questions)
    }
    func testJSONStringQuestionsCapturedShapeUsesSameValidation() throws {
        let valid = "[{\"question\":\"Pick one\",\"options\":[\"A\",\"B\"],\"is_multi_select\":false}]"
        func observation(_ value: String, tool: String = "ask_question") throws -> AntigravityHookObservation {
            var object = input()
            object["toolCall"] = ["name":tool,"args":["questions":value,"toolAction":"fixture","toolSummary":"fixture"]]
            return try XCTUnwrap(AntigravityHookObservation.parse(object, phase:"PreToolUse"))
        }
        XCTAssertEqual(try observation(valid).questions, try XCTUnwrap(AntigravityHookObservation.parse(input(),phase:"PreToolUse")).questions)
        for invalid in ["not JSON", "{}", "[]", "[1]", valid.replacingOccurrences(of:"false",with:"1"), valid.replacingOccurrences(of:"[\"A\",\"B\"]",with:"[\"A\",\"A\"]"), String(repeating:" ",count:200_001)+valid] {
            XCTAssertNil(try observation(invalid).questions)
        }
        XCTAssertNil(try observation(valid,tool:"run_command").questions)
    }
    func testInvalidIndicesAndQuestionBooleansAreNeverCoerced() throws {
        for value: Any in [true, -1, 7.5, "7", 1_000_000_001] {
            var object = input(); object["stepIdx"] = value
            XCTAssertNil(try XCTUnwrap(AntigravityHookObservation.parse(object, phase: "PreToolUse")).stepIndex)
        }
        var object = input()
        object["toolCall"] = ["name": "ask_question", "args": ["questions": [["question": "Pick one", "options": ["A", "B"], "is_multi_select": 1]]]]
        XCTAssertNil(try XCTUnwrap(AntigravityHookObservation.parse(object, phase: "PreToolUse")).questions)
    }
    func testInvocationResetAndStopRetainOnlyDocumentedFields() throws {
        let start = try XCTUnwrap(AntigravityHookObservation.parse(["conversationId":"fixture", "invocationNum":0, "initialNumSteps":12], phase:"PreInvocation"))
        XCTAssertEqual(start.invocationNum, 0); XCTAssertEqual(start.initialNumSteps, 12)
        let stop = try XCTUnwrap(AntigravityHookObservation.parse(["conversationId":"fixture", "executionNum":1, "fullyIdle":true, "terminationReason":"unknown arbitrary body", "error":""], phase:"Stop"))
        XCTAssertEqual(stop.fullyIdle, true); XCTAssertNil(stop.terminationReason); XCTAssertFalse(stop.hasError)
        XCTAssertNil(AntigravityHookObservation.parse(["conversationId":"fixture"], phase:"PermissionRequest"))
    }
    func testHelperOnlyMapsConfirmedIdleNoErrorReasonsToCompletion() throws {
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/.build/debug/refikHook")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw XCTSkip("Build helper first") }
        let cases: [(String, Any?, Any?, String)] = [
            ("NO_TOOL_CALL",true,"","completed"), ("model_stop",true,"","completed"),
            ("NO_TOOL_CALL",false,"","activity"), ("NO_TOOL_CALL",true,"runtime error","failed"),
            ("NO_TOOL_CALL",true,true,"sessionEnded"), ("NO_TOOL_CALL",1,"","sessionEnded"),
            ("NO_TOOL_CALL",nil,"","sessionEnded"), ("MAX_INVOCATIONS",true,"","sessionEnded"),
            ("MAX_FORCED_INVOCATIONS",true,"","sessionEnded"), ("MAX_TOKEN_BUDGET_EXCEEDED",true,"","sessionEnded"),
            ("UNSPECIFIED",true,"","sessionEnded"), ("unknown",true,"","sessionEnded"),
            ("USER_CANCELED",true,"","sessionEnded"), ("max_steps_exceeded",true,"","interrupted")]
        for (reason,idle,error,kind) in cases {
            var object: [String:Any] = ["conversationId":"fixture","terminationReason":reason]
            if let idle { object["fullyIdle"]=idle }; if let error { object["error"]=error }
            let process=Process();process.executableURL=helper;process.arguments=["--normalize","antigravity","Stop"]
            let input=Pipe();let output=Pipe();process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
            try process.run();try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:object));try input.fileHandleForWriting.close()
            process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
            let data=try XCTUnwrap(output.fileHandleForReading.readToEnd());let event=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual(event["kind"] as? String,kind,reason)
            XCTAssertNil(event["capabilities"]);XCTAssertNil(event["requestSnapshot"])
        }
        let observation=try XCTUnwrap(AntigravityHookObservation.parse(["conversationId":"fixture","fullyIdle":true,"terminationReason":"NO_TOOL_CALL","error":""],phase:"Stop"))
        XCTAssertEqual(observation.terminationReason,"NO_TOOL_CALL")
    }
}
