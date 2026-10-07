import XCTest
@testable import RefikInteractionWire
@testable import refik

final class CursorHookHostTests: XCTestCase {
    // Sanitized fields from Cursor 3.22.12's actual imported Claude hook input.
    private var sample: [String: Any] {
        ["hook_event_name": "beforeSubmitPrompt", "session_id": "qa-session",
         "conversation_id": "qa-session", "generation_id": "qa-turn",
         "workspace_roots": ["/tmp/refik-live-qa-20261002/cursor"], "cursor_version": "3.22.12"]
    }
    func testImportedOriginRequiresVerifiedCursorAndPreservesAuthenticClaude() throws {
        let cursor = CursorHookHost.Metadata(executable: CursorHookHost.executable, version: "3.22.12")
        XCTAssertTrue(CursorHookHost.isCompatibilityPayload(sample))
        XCTAssertEqual(CursorHookHost.provider(configured: "claude", compatibilityPayload: true, authenticClaude: false, emitter: cursor), "cursor")
        XCTAssertNil(CursorHookHost.provider(configured: "claude", compatibilityPayload: true, authenticClaude: false, emitter: nil))
        XCTAssertEqual(CursorHookHost.provider(configured: "claude", compatibilityPayload: true, authenticClaude: true, emitter: cursor), "claude")
        XCTAssertEqual(CursorHookHost.provider(configured: "claude", compatibilityPayload: false, authenticClaude: false, emitter: cursor), "claude")
        XCTAssertEqual(CursorHookHost.provider(configured: "cursor", compatibilityPayload: true, authenticClaude: false, emitter: nil), "cursor")
        for key in ["cursor_version", "conversation_id", "hook_event_name"] {
            var body = sample; body.removeValue(forKey: key)
            XCTAssertFalse(CursorHookHost.isCompatibilityPayload(body))
        }
        var body = sample; body["conversation_id"] = "other"
        XCTAssertFalse(CursorHookHost.isCompatibilityPayload(body))
        body = sample; body["hook_event_name"] = "UserPromptSubmit"
        XCTAssertFalse(CursorHookHost.isCompatibilityPayload(body))
    }
    func testCursorProofRequiresExactSignedInstalledApplication() throws {
        XCTAssertNil(CursorHookHost.verifiedApplication(executable: URL(fileURLWithPath: "/tmp/Cursor")))
        XCTAssertNil(CursorHookHost.currentEmitter())
        guard FileManager.default.fileExists(atPath: CursorHookHost.executable.path) else { throw XCTSkip("Cursor is not installed") }
        let proof = try XCTUnwrap(CursorHookHost.verifiedApplication(executable: CursorHookHost.executable))
        XCTAssertEqual(proof.executable.path, "/Applications/Cursor.app/Contents/MacOS/Cursor")
        XCTAssertFalse(proof.version.isEmpty)
    }
    private func normalize(_ body: [String: Any], provider: String, argument: String) throws -> Data {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/.build/debug/refikHook")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = helper; process.arguments = ["--normalize", provider, argument]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body))
        try input.fileHandleForWriting.close(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try output.fileHandleForReading.readToEnd() ?? Data()
    }
    func testUnverifiedImportedInputIsDroppedAndCanonicalCursorEventsShareOneSession() throws {
        XCTAssertTrue(try normalize(sample, provider: "claude", argument: "UserPromptSubmit").isEmpty)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var reducer = StateReducer()
        for (phase, expected) in [("beforeSubmitPrompt", EventKind.started), ("preToolUse", .activity), ("postToolUse", .requestResolved), ("stop", .completed)] {
            var body = sample; body["hook_event_name"] = phase
            let data = try normalize(body, provider: "cursor", argument: "UserPromptSubmit")
            let event = try decoder.decode(CodexEvent.self, from: data)
            XCTAssertEqual(event.kind, expected); XCTAssertEqual(event.sessionID, "cursor:qa-session")
            XCTAssertEqual(event.turnID, "qa-turn"); XCTAssertEqual(event.runtime?.host, .cursor)
            XCTAssertEqual(event.projectPath, "/tmp/refik-live-qa-20261002/cursor")
            XCTAssertNil(event.requestSnapshot); XCTAssertNil(event.capabilities)
            XCTAssertTrue(reducer.apply(event))
            // Native and imported observations use the same canonical identity.
            let duplicate = try decoder.decode(CodexEvent.self, from: normalize(body, provider: "cursor", argument: phase))
            _ = reducer.apply(duplicate)
            XCTAssertEqual(reducer.sessions.count, 1)
        }
        XCTAssertEqual(reducer.sessions["cursor:qa-session"]?.state, .completed)
    }
    func testSingleCapturedWorkspaceRootSupportsExactProjectDismissalAndMultiRootIsRejected() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for roots in [[], ["/tmp/first", "/tmp/second"]] as [[String]] {
            var body = sample; body["workspace_roots"] = roots
            let event = try decoder.decode(CodexEvent.self, from: normalize(body, provider: "cursor", argument: "UserPromptSubmit"))
            XCTAssertNil(event.projectPath)
        }
        for roots in [["/tmp/second"], ["/tmp/first", "/tmp/second"]] {
            var body = sample; body["workspacePaths"] = ["/tmp/first"]; body["workspace_roots"] = roots
            let event = try decoder.decode(CodexEvent.self, from: normalize(body, provider: "cursor", argument: "UserPromptSubmit"))
            XCTAssertNil(event.projectPath, "conflicting or ambiguous root fields cannot identify a project")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project"), other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let proof = CursorHookHost.Metadata(executable: CursorHookHost.executable, version: "3.22.12")
        let importedProvider = try XCTUnwrap(CursorHookHost.provider(configured: "claude", compatibilityPayload: true, authenticClaude: false, emitter: proof))
        var reducer = StateReducer()
        for (session, path) in [("qa-session", project.path), ("other-session", other.path)] {
            for (index, phase) in ["beforeSubmitPrompt", "stop"].enumerated() {
                var body = sample; body["session_id"] = session; body["conversation_id"] = session
                body["workspace_roots"] = [path]; body["hook_event_name"] = phase
                for provider in ["cursor", importedProvider] {
                    var normalized = try XCTUnwrap(JSONSerialization.jsonObject(with: normalize(body, provider: provider, argument: phase == "stop" ? "Stop" : "UserPromptSubmit")) as? [String: Any])
                    normalized["at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(index + 1)))
                    let event = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: normalized))
                    XCTAssertEqual(event.projectPath, path)
                    _ = reducer.apply(event)
                }
            }
        }
        XCTAssertEqual(reducer.sessions.count, 2)
        let canonical = try XCTUnwrap(ProjectIdentity.canonical(project.path))
        XCTAssertEqual(reducer.sessions["cursor:qa-session"]?.projectPath, canonical)
        XCTAssertTrue(reducer.dismissProject(canonical, at: Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(reducer.sessions["cursor:qa-session"]?.seen, true)
        XCTAssertEqual(reducer.sessions["cursor:other-session"]?.seen, false)
    }
}
