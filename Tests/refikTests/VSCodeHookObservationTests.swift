import XCTest
@testable import RefikInteractionWire

final class VSCodeHookObservationTests: XCTestCase {
    private func input() -> [String: Any] {
        ["session_id":"fixture", "tool_use_id":"native-call", "tool_name":"vscode_askQuestions", "tool_input":["questions":[["question":"Pick one", "header":"Choice", "options":[["label":"A","description":"First"],["label":"B","description":"Second"]]]]]]
    }
    func testActualVSCodeQuestionSchemaDefaultsToSingleSelection() throws {
        let pre = try XCTUnwrap(VSCodeHookObservation.parse(input(),phase:"PreToolUse"))
        let post = try XCTUnwrap(VSCodeHookObservation.parse(input(),phase:"PostToolUse"))
        XCTAssertEqual(pre.nativeToolID,"native-call"); XCTAssertEqual(pre.nativeToolID,post.nativeToolID)
        XCTAssertEqual(pre.questions?.first?.options.map(\.label),["A","B"])
        XCTAssertEqual(pre.questions?.first?.multiSelect,false)
    }
    func testMissingIdentityWrongToolAndMalformedBodyCannotPromoteQuestions() throws {
        var object=input();object.removeValue(forKey:"tool_use_id")
        XCTAssertNil(try XCTUnwrap(VSCodeHookObservation.parse(object,phase:"PreToolUse")).questions)
        object=input();object["tool_name"]="ask_question"
        XCTAssertNil(try XCTUnwrap(VSCodeHookObservation.parse(object,phase:"PreToolUse")).questions)
        object=input();object["tool_input"]=["questions":[["question":"Pick one","header":"Choice","multiSelect":1,"options":[["label":"A","description":"First"],["label":"B","description":"Second"]]]]]
        XCTAssertNil(try XCTUnwrap(VSCodeHookObservation.parse(object,phase:"PreToolUse")).questions)
        XCTAssertNil(VSCodeHookObservation.parse(input(),phase:"preToolUse"))
    }
    func testEveryPascalCaseLifecycleCarriesSameRawSession() throws {
        for phase in ["SessionStart","UserPromptSubmit","PreToolUse","PostToolUse","PreCompact","SubagentStart","SubagentStop","Stop","SessionEnd"] {
            XCTAssertEqual(try XCTUnwrap(VSCodeHookObservation.parse(["session_id":"fixture"],phase:phase)).sessionID,"fixture")
        }
    }
    func testVSCodeOriginRequiresItsExactSignedInstalledApplication() throws {
        XCTAssertNil(VSCodeHookHost.verifiedApplication(executable:URL(fileURLWithPath:"/tmp/Code")))
        XCTAssertNil(VSCodeHookHost.currentEmitter())
        guard FileManager.default.fileExists(atPath:VSCodeHookHost.executable.path) else { throw XCTSkip("VS Code is not installed") }
        let metadata=try XCTUnwrap(VSCodeHookHost.verifiedApplication(executable:VSCodeHookHost.executable))
        XCTAssertEqual(metadata.executable.path,"/Applications/Visual Studio Code.app/Contents/MacOS/Code")
        XCTAssertFalse(metadata.version.isEmpty)
    }
    func testHelperNormalizationRetainsSchemaWithoutResponseCapabilities() throws {
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/.build/debug/refikHook")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw XCTSkip("Build helper first") }
        let process=Process();process.executableURL=helper;process.arguments=["--normalize","copilot","PreToolUse","--host=vscode"]
        let stdin=Pipe();let stdout=Pipe();process.standardInput=stdin;process.standardOutput=stdout;process.standardError=FileHandle.nullDevice
        try process.run();try stdin.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:input()));try stdin.fileHandleForWriting.close()
        process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let data=try XCTUnwrap(stdout.fileHandleForReading.readToEnd());let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertNotNil(object["vscodeObservation"]);XCTAssertNil(object["capabilities"]);XCTAssertNil(object["requestSnapshot"])
        XCTAssertEqual((object["runtime"] as? [String:Any])?["host"] as? String,"unknown")
    }
}
