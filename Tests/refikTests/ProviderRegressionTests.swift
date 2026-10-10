import XCTest
import Foundation
@testable import refik

final class ProviderRegressionTests: XCTestCase {
    private var fixtureSequence = 0
    private func normalizationOutput(_ payload: [String: Any], _ name: String, provider: String = "claude") throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/refikHook", ".build/out/Products/Debug/refikHook"].map { root.appendingPathComponent($0) }
        let hook = try XCTUnwrap(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }, "Build refikHook before testing")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = Process(), out = Pipe(), error = Pipe()
        process.executableURL = hook; process.arguments = ["--normalize", provider, name]
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        process.standardInput = input; process.standardOutput = out; process.standardError = error
        process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR": "/tmp/refik-normalize-" + UUID().uuidString]) { _, new in new }
        try process.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
        return data
    }
    private func normalized(_ payload: [String: Any], _ name: String, provider: String = "claude") throws -> CodexEvent {
        let data = try normalizationOutput(payload, name, provider: provider)
        // Receipt ordering is explicit in the fixture, independent of process
        // startup duration or wall-clock second boundaries.
        var fixture = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        fixtureSequence += 1
        fixture["at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(fixtureSequence)))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: fixture))
    }

    func testClaudeStopContinuationExactBooleanNeverCompletesOrResolvesPending() throws {
        var reducer = StateReducer(); reducer.apply(try normalized(base, "UserPromptSubmit"))
        reducer.apply(try normalized(question, "PreToolUse"))
        let payload = base.merging(["stop_hook_active": true, "background_tasks": [], "session_crons": []]) { _, new in new }
        XCTAssertTrue(try normalizationOutput(payload, "Stop").isEmpty)
        XCTAssertEqual(reducer.aggregate, .waiting)
        for value in [false, "true", 1, NSNull()] as [Any] {
            let stop = try normalized(payload.merging(["stop_hook_active": value]) { _, new in new }, "Stop")
            XCTAssertEqual(stop.kind, .completed, "only the documented exact true suppresses Stop")
        }
    }
    func testCodexSubagentIdentityObserversCannotCreateAttentionLifecycleEvents() throws {
        for name in HookInstaller.codexIdentityEvents {
            let payload: [String: Any] = ["session_id": UUID().uuidString, "turn_id": UUID().uuidString,
                "agent_id": UUID().uuidString, "agent_type": "worker", "cwd": "/tmp/isolated"]
            XCTAssertTrue(try normalizationOutput(payload, name, provider: "codex").isEmpty)
        }
    }
    func testClaudeAutoDeniedToolCannotClearOtherQuestionOrPermission() throws {
        var reducer = StateReducer(); reducer.apply(try normalized(base, "UserPromptSubmit"))
        let ask = try normalized(question, "PreToolUse"); reducer.apply(ask)
        let tool = base.merging(["tool_name": "Bash", "tool_use_id": "permission", "tool_input": ["command": "fixture"]]) { _, new in new }
        let permission = try normalized(tool, "PermissionRequest"); reducer.apply(permission)
        let manual = try normalized(tool.merging(["permission_mode": "default"]) { _, new in new }, "PermissionDenied")
        XCTAssertEqual(manual.kind, .unknownEvent); reducer.apply(manual)
        XCTAssertEqual(reducer.sessions[ask.sessionID]?.pending.count, 2)
        let auto = try normalized(tool.merging(["permission_mode": "auto"]) { _, new in new }, "PermissionDenied")
        XCTAssertEqual(auto.kind, .requestResolved); reducer.apply(auto)
        XCTAssertEqual(reducer.sessions[ask.sessionID]?.pending, [ask.requestID!])
        XCTAssertEqual(reducer.aggregate, .waiting)
        reducer.apply(try normalized(question, "PostToolUse")); XCTAssertEqual(reducer.aggregate, .running)
    }
    func testClaudeGenericInputNotificationsNeverInventQuestionOrResponseChannel() throws {
        for type in ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"] {
            var reducer = StateReducer(); reducer.apply(try normalized(base, "UserPromptSubmit"))
            let notification = try normalized(base.merging(["notification_type": type]) { _, new in new }, "Notification")
            XCTAssertEqual(notification.kind, .userQuestionObserved)
            XCTAssertNil(notification.requestSnapshot); XCTAssertNil(notification.capabilities)
            reducer.apply(notification); XCTAssertEqual(reducer.aggregate, .waiting)
            let unrelated = base.merging(["tool_name": "Bash", "tool_input": ["command": "other"], "tool_use_id": "other"]) { _, new in new }
            reducer.apply(try normalized(unrelated, "PostToolUse")); XCTAssertEqual(reducer.aggregate, .waiting)
            reducer.apply(try normalized(base.merging(["prompt_id": "next"]) { _, new in new }, "UserPromptSubmit"))
            XCTAssertEqual(reducer.aggregate, .running); XCTAssertTrue(reducer.sessions[notification.sessionID]!.pending.isEmpty)
        }
        for type in ["idle_prompt", "auth_success"] {
            XCTAssertTrue(try normalizationOutput(base.merging(["notification_type": type]) { _, new in new }, "Notification").isEmpty)
        }
        XCTAssertEqual(try normalized(base.merging(["notification_type": "permission_prompt"]) { _, new in new }, "Notification").kind, .permissionObserved)
    }
    private let base: [String: Any] = ["session_id": "session", "prompt_id": "prompt", "cwd": "/tmp/project"]
    private var question: [String: Any] {
        base.merging(["tool_name": "AskUserQuestion", "tool_use_id": "question-1", "tool_input": ["questions": [["question": "fixture?", "header": "Choice", "multiSelect": false, "options": [["label": "A", "description": "fixture"], ["label": "B", "description": "fixture"]]]]]]) { _, new in new }
    }
    func testProviderHookRetainsExactCwdAndRejectsAmbiguousWorkspaceIdentity() throws {
        for provider in ["codex", "claude", "antigravity"] {
            let name = provider == "antigravity" ? "PreInvocation" : "UserPromptSubmit"
            let payload: [String: Any] = ["session_id": "session", "conversationId": "conversation", "prompt_id": "turn", "turn_id": "turn", "cwd": "/tmp/exact-project"]
            XCTAssertEqual(try normalized(payload, name, provider: provider).projectPath, "/tmp/exact-project")
        }
        let single: [String: Any] = ["conversationId": "conversation", "workspacePaths": ["file:///tmp/exact-project"]]
        XCTAssertEqual(try normalized(single, "PreInvocation", provider: "antigravity").projectPath, "file:///tmp/exact-project")
        let multiple: [String: Any] = ["conversationId": "conversation", "workspacePaths": ["/tmp/one", "/tmp/two"]]
        XCTAssertNil(try normalized(multiple, "PreInvocation", provider: "antigravity").projectPath)
    }
    func testAntigravityDocumentedStopAndUnknownIdleNeverInventSuccess() throws {
        let payload: [String: Any] = ["conversationId": "conversation", "executionNum": 1, "terminationReason": "model_stop", "error": "", "fullyIdle": true]
        XCTAssertEqual(try normalized(payload, "Stop", provider: "antigravity").kind, .completed)
        for invalid in [NSNull(), "true", 1, 0] as [Any] {
            var p = payload; p["fullyIdle"] = invalid
            let event = try normalized(p, "Stop", provider: "antigravity")
            var reducer = StateReducer()
            var start = event; start = CodexEvent(sessionID: event.sessionID, turnID: event.turnID, requestID: nil, kind: .started, source: .unknown, title: nil, at: event.at.addingTimeInterval(-1), id: "start", provider: .antigravity)
            reducer.apply(start); reducer.apply(event)
            XCTAssertEqual(reducer.sessions[event.sessionID]?.state, .unknown)
            XCTAssertEqual(reducer.aggregate, .neutral)
        }
        var missing = payload; missing.removeValue(forKey: "fullyIdle")
        XCTAssertEqual(try normalized(missing, "Stop", provider: "antigravity").kind, .sessionEnded)
        var wrongError = payload; wrongError["error"] = false
        XCTAssertEqual(try normalized(wrongError, "Stop", provider: "antigravity").kind, .sessionEnded)
    }
    func testAntigravityBackgroundHardFailureAndCounterDomains() throws {
        var p: [String: Any] = ["conversationId": "conversation", "fullyIdle": false, "terminationReason": "model_stop", "error": "", "executionNum": 19]
        XCTAssertEqual(try normalized(p, "Stop", provider: "antigravity").kind, .activity)
        p["error"] = "failure"
        XCTAssertEqual(try normalized(p, "Stop", provider: "antigravity").kind, .failed)
        p["error"] = ""; p["terminationReason"] = "error"
        XCTAssertEqual(try normalized(p, "Stop", provider: "antigravity").kind, .failed)
        p["terminationReason"] = "max_steps_exceeded"
        XCTAssertEqual(try normalized(p, "Stop", provider: "antigravity").kind, .interrupted)
        let stop = try normalized(p, "Stop", provider: "antigravity")
        let invocation = try normalized(["conversationId": "conversation", "invocationNum": 7], "PreInvocation", provider: "antigravity")
        XCTAssertEqual(stop.turnID, "conversation"); XCTAssertEqual(invocation.turnID, "conversation")
        XCTAssertFalse(stop.turnID.contains("19")); XCTAssertFalse(invocation.turnID.contains("7"))
    }
    @MainActor func testClaudePromptPreferenceAndLateOldPromptEventsCannotReplaceCurrent() throws {
        let app = AppModel(inspectNotificationPermission: false)
        var first = base; first["prompt_id"] = "old"; first["turn_id"] = "legacy"
        let start = try normalized(first, "UserPromptSubmit")
        XCTAssertEqual(start.turnID, "old"); app.accept(start, historical: false)
        var next = base; next["prompt_id"] = "new"
        app.accept(try normalized(next, "UserPromptSubmit"), historical: false)
        for name in ["PermissionRequest", "PostToolUse", "PostToolUseFailure", "PreToolUse", "Stop"] {
            let old = first.merging(["tool_name": "Bash", "tool_input": ["command": "fixture"], "tool_use_id": "old-tool", "background_tasks": [], "session_crons": []]) { _, new in new }
            app.accept(try normalized(old, name), historical: false)
            XCTAssertEqual(app.sessions.first?.turnID, "new", name)
            XCTAssertEqual(app.aggregate, .running, name)
        }
    }
    @MainActor func testClaudeSessionStartNeutralAndMissingIdentityConservativeFallback() throws {
        let app = AppModel(inspectNotificationPermission: false)
        let legacy: [String: Any] = ["session_id": "session"]
        app.accept(try normalized(legacy, "SessionStart"), historical: false)
        XCTAssertEqual(app.aggregate, .neutral)
        app.accept(try normalized(base, "UserPromptSubmit"), historical: false)
        app.accept(try normalized(base, "SessionStart"), historical: false)
        XCTAssertEqual(app.aggregate, .running, "session metadata does not replace actual running work")
        for name in ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest", "PostToolUse"] {
            app.accept(try normalized(legacy, name), historical: false)
            XCTAssertEqual(app.sessions.first?.turnID, "prompt")
            XCTAssertEqual(app.aggregate, .running)
        }
        var turn = legacy; turn["turn_id"] = "legacy-turn"
        XCTAssertEqual(try normalized(turn, "UserPromptSubmit").turnID, "legacy-turn")
        var reducer = StateReducer()
        XCTAssertTrue(reducer.apply(try normalized(legacy, "UserPromptSubmit")))
        XCTAssertTrue(reducer.apply(try normalized(legacy.merging(["background_tasks": [], "session_crons": []]) { _, new in new }, "Stop")))
        XCTAssertEqual(reducer.aggregate, .completed)
    }
    func testClaudeQuestionMixedPermissionAndMatchingOutcomeOnly() throws {
        for outcome in ["PostToolUse", "PostToolUseFailure"] {
            var reducer = StateReducer()
            reducer.apply(try normalized(base, "UserPromptSubmit"))
            let ask = try normalized(question, "PreToolUse")
            XCTAssertEqual(ask.kind, .userQuestionObserved)
            XCTAssertTrue(ask.requestID?.hasPrefix("question:") == true)
            XCTAssertFalse(ask.detail!.contains("fixture"))
            XCTAssertTrue(reducer.apply(ask)); XCTAssertFalse(reducer.apply(try normalized(question, "PreToolUse")))
            let permissionPayload = base.merging(["tool_name": "Bash", "tool_input": ["command": "fixture"], "tool_use_id": "permission-1"]) { _, new in new }
            let permission = try normalized(permissionPayload, "PermissionRequest")
            reducer.apply(permission)
            XCTAssertEqual(reducer.sessions[ask.sessionID]?.pending.count, 2)
            let unrelated = base.merging(["tool_name": "Bash", "tool_input": ["command": "other"], "tool_use_id": "question-1"]) { _, new in new }
            reducer.apply(try normalized(unrelated, "PreToolUse")); reducer.apply(try normalized(unrelated, outcome))
            XCTAssertEqual(reducer.sessions[ask.sessionID]?.pending.count, 2)
            reducer.apply(try normalized(question, outcome))
            XCTAssertEqual(reducer.sessions[ask.sessionID]?.pending, [permission.requestID!])
            XCTAssertEqual(reducer.sessions[ask.sessionID]?.state, .waitingPermission)
            XCTAssertFalse(reducer.apply(try normalized(question, "PreToolUse")), "replayed ask cannot reopen resolved request")
            reducer.apply(try normalized(permissionPayload, outcome))
            XCTAssertEqual(reducer.aggregate, .running)
        }
    }
    func testClaudeQuestionScopeSeparatesAgentSessionAndPrompt() throws {
        var reducer = StateReducer(); reducer.apply(try normalized(base, "UserPromptSubmit"))
        let ask = try normalized(question, "PreToolUse"); reducer.apply(ask)
        for (field, value) in [("agent_id", "agent"), ("session_id", "other"), ("prompt_id", "old"), ("tool_use_id", "other")] {
            var wrong = question; wrong[field] = value
            let resolved = try normalized(wrong, "PostToolUse")
            XCTAssertNotEqual(resolved.requestID, ask.requestID)
            reducer.apply(resolved)
            XCTAssertTrue(reducer.sessions[ask.sessionID]!.pending.contains(ask.requestID!))
        }
        reducer.apply(try normalized(question, "PostToolUse"))
        XCTAssertEqual(reducer.aggregate, .running)
    }
    func testClaudeMalformedOrMissingQuestionIDsAndTimeoutStayConservative() throws {
        for change in [["tool_input": ["questions": []]], ["tool_input": ["questions": [["question": "text"]]]], ["tool_use_id": ""], ["tool_name": "OtherAskUserQuestion"]] as [[String: Any]] {
            let event = try normalized(question.merging(change) { _, new in new }, "PreToolUse")
            XCTAssertEqual(event.kind, .activity)
            XCTAssertNil(event.requestID)
        }
        var optional = question
        var input = optional["tool_input"] as! [String: Any]
        var questions = input["questions"] as! [[String: Any]]
        questions[0].removeValue(forKey: "multiSelect")
        input["questions"] = questions; optional["tool_input"] = input
        XCTAssertEqual(try normalized(optional, "PreToolUse").kind, .userQuestionObserved)
        for invalid in [0, 1, "false"] as [Any] {
            questions[0]["multiSelect"] = invalid; input["questions"] = questions; optional["tool_input"] = input
            XCTAssertEqual(try normalized(optional, "PreToolUse").kind, .activity)
        }
        var missing = question; missing.removeValue(forKey: "tool_use_id")
        XCTAssertEqual(try normalized(missing, "PreToolUse").kind, .activity)
        var reducer = StateReducer(); reducer.apply(try normalized(base, "UserPromptSubmit"))
        let ask = try normalized(question, "PreToolUse"); reducer.apply(ask)
        reducer.apply(try normalized(missing, "PostToolUse"))
        XCTAssertEqual(reducer.aggregate, .waiting)
        _ = reducer.expire(at: ask.at.addingTimeInterval(601))
        XCTAssertEqual(reducer.sessions[ask.sessionID]?.state, .waitingUser)
        XCTAssertFalse(reducer.sessions[ask.sessionID]!.pending.isEmpty)
    }
    @MainActor func testUsageExpiryPrunesSharedStoreAndRejectsStaleIngestion() {
        let app = AppModel(inspectNotificationPermission: false), now = Date()
        func usage(_ provider: Provider, _ at: Date, _ ttl: Double, window: String = "7 gün") -> CodexEvent {
            CodexEvent(sessionID: "usage", turnID: "usage", requestID: nil, kind: .usage, source: .unknown, title: window, at: at, id: UUID().uuidString, detail: "used", provider: provider, progress: 0.8, ttl: ttl)
        }
        app.accept(usage(.codex, now, 2), historical: false)
        app.accept(usage(.claude, now, 20), historical: false)
        XCTAssertEqual(app.usageWindows.count, 2)
        app.expire(at: now.addingTimeInterval(3))
        XCTAssertEqual(app.usageWindows.map(\.provider), [.claude])
        app.accept(usage(.codex, now.addingTimeInterval(-30), 2), historical: false)
        XCTAssertEqual(app.usageWindows.map(\.provider), [.claude])
        app.expire(at: now.addingTimeInterval(21))
        XCTAssertTrue(app.usageWindows.isEmpty, "panel and settings share the pruned published store")
        app.accept(usage(.codex, now, 100_000), historical: false)
        XCTAssertTrue(app.usageWindows.isEmpty)
    }
    func testExistingClaudeStartupMigrationPreservesPinsAndIsNoOpWhenCurrent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refik-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), helper = directory.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper, runtimeVersion: "2.1.287")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = root["hooks"] as! [String: Any]; hooks.removeValue(forKey: "PermissionDenied")
        let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "http", "url": "http://localhost/foreign"]]]
        hooks["PreToolUse"] = [foreign] + (hooks["PreToolUse"] as! [[String: Any]])
        root["hooks"] = hooks; root["statusLine"] = ["type": "command", "command": "foreign-status"]
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        XCTAssertTrue(try HookInstaller.repairExistingClaude(at: url, helper: helper))
        let bytes = try Data(contentsOf: url)
        let repaired = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        XCTAssertTrue((repaired["statusLine"] as! NSDictionary).isEqual(root["statusLine"] as! NSDictionary))
        let current = repaired["hooks"] as! [String: [[String: Any]]]
        XCTAssertTrue((current["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        for event in HookInstaller.claudeEvents {
            let h = (current[event]!.last!["hooks"] as! [[String: Any]])[0]
            XCTAssertTrue((h["command"] as! String).hasSuffix(" --interactive --runtime-version=2.1.287"))
            XCTAssertEqual(h["timeout"] as? Int, ["PreToolUse", "PermissionRequest"].contains(event) ? 130 : 3)
        }
        let modification = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(try HookInstaller.repairExistingClaude(at: url, helper: helper))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modification)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), files)
        for bad in [ ["disableAllHooks": true, "hooks": hooks], ["hooks": ["Stop": hooks["Stop"]!]], ["hooks": ["Stop": ["malformed"]]] ] as [[String: Any]] {
            let original = try JSONSerialization.data(withJSONObject: bad); try original.write(to: url)
            if bad["disableAllHooks"] != nil || (bad["hooks"] as? [String: Any])?.count == 1 && ((bad["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) != nil {
                XCTAssertFalse(try HookInstaller.repairExistingClaude(at: url, helper: helper))
            } else { XCTAssertThrowsError(try HookInstaller.repairExistingClaude(at: url, helper: helper)) }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
        var conflicting = repaired
        var conflictingHooks = current
        var stop = conflictingHooks["Stop"]!
        stop[stop.count - 1]["hooks"] = [["type": "command", "command": LegacyMigration.quoted(helper.path) + " claude Stop", "timeout": 3]]
        conflictingHooks["Stop"] = stop; conflicting["hooks"] = conflictingHooks
        let conflictBytes = try JSONSerialization.data(withJSONObject: conflicting)
        try conflictBytes.write(to: url)
        XCTAssertThrowsError(try HookInstaller.repairExistingClaude(at: url, helper: helper))
        XCTAssertEqual(try Data(contentsOf: url), conflictBytes)
        let absent = directory.appendingPathComponent("absent.json")
        XCTAssertFalse(try HookInstaller.repairExistingClaude(at: absent, helper: helper))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        try bytes.write(to: url)
        XCTAssertThrowsError(try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper, expectedOriginal: Data("changed".utf8)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    @MainActor func testClaudeStartupRepairRunsOnceInBackgroundAndReportsFailure() async {
        let model = AppModel(inspectNotificationPermission: false)
        let called = expectation(description: "startup callback")
        called.assertForOverFulfill = true
        model.claudeStartupRepair = { called.fulfill(); throw CocoaError(.fileReadCorruptFile) }
        model.beginClaudeStartupRepair(); model.beginClaudeStartupRepair()
        await fulfillment(of: [called], timeout: 2)
        for _ in 0..<20 {
            if model.integrationMessage.contains("Claude bağlantısı güncellenemedi") { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(model.integrationMessage.contains("Kur / onar"))
    }

    func testStartupRepairAndUIDisableShareMutationLock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refik-concurrent-repair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), helper = directory.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper, runtimeVersion: "2.1.287")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var hooks = root["hooks"] as! [String: Any]; hooks.removeValue(forKey: "PermissionDenied")
        let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "http", "url": "http://localhost/foreign"]]]
        hooks["PreToolUse"] = [foreign] + (hooks["PreToolUse"] as! [[String: Any]])
        root["hooks"] = hooks; root["statusLine"] = ["type": "command", "command": "foreign-status"]
        try JSONSerialization.data(withJSONObject: root).write(to: url)
        let repairEntered = expectation(description: "repair owns mutation lock")
        let disableStarted = expectation(description: "UI disable started")
        let repairDone = expectation(description: "repair finished")
        let disableDone = expectation(description: "UI disable finished")
        let releaseRepair = DispatchSemaphore(value: 0)
        let disableFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { repairDone.fulfill() }
            do {
                _ = try HookInstaller.repairExistingClaude(at: url, helper: helper, beforeRepair: {
                    repairEntered.fulfill()
                    XCTAssertEqual(releaseRepair.wait(timeout: .now() + 3), .success)
                })
            } catch { XCTFail("repair failed: \(error)") }
        }
        await fulfillment(of: [repairEntered], timeout: 2)
        DispatchQueue.global().async {
            disableStarted.fulfill()
            do { try HookInstaller.setEnabled(false, provider: .claude, at: url, helper: helper) }
            catch { XCTFail("disable failed: \(error)") }
            disableFinished.signal()
            disableDone.fulfill()
        }
        await fulfillment(of: [disableStarted], timeout: 2)
        XCTAssertEqual(disableFinished.wait(timeout: .now() + 0.15), .timedOut, "UI disable must wait until the in-flight replacement finishes")
        releaseRepair.signal()
        await fulfillment(of: [repairDone, disableDone], timeout: 4)
        let final = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let remaining = final["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(remaining.count, 1)
        XCTAssertTrue((remaining["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        XCTAssertTrue((final["statusLine"] as! NSDictionary).isEqual(root["statusLine"] as! NSDictionary))
        XCTAssertFalse(try HookInstaller.repairExistingClaude(at: url, helper: helper))
    }

}
