import XCTest
import Foundation
import Darwin
import RefikInteractionWire
@testable import refik

final class HookBridgeTransportTests: XCTestCase {
    private func temporaryBridge(monotonicNow: @escaping () -> Double = { HookWire.uptime }, onInteraction: ((CodexEvent, String) -> Void)? = nil,
                                 onInvalidation: ((RequestIdentity) -> Void)? = nil,
                                 onAntigravityObservation: ((CodexEvent, AntigravityHookObservation) -> Void)? = nil) throws -> (HookBridge, URL) {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("refik-bridge-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bridge = HookBridge(socketURL: directory.appendingPathComponent("events.sock"),
                                tokenURL: directory.appendingPathComponent("signal.token"),
                                monotonicNow: monotonicNow, onInteraction: onInteraction, onInvalidation: onInvalidation,
                                onAntigravityObservation: onAntigravityObservation, onEvent: { _ in })
        bridge.start()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !HookWire.secureFile(directory.appendingPathComponent("events.sock"), socket: true) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(HookWire.secureFile(directory.appendingPathComponent("events.sock"), socket: true))
        return (bridge, directory)
    }
    private func helper(_ directory: URL, provider: String = "claude", interactive: Bool = true, eventName: String = "PermissionRequest", payload: [String: Any]? = nil) throws -> (Process, Pipe) {
        let binary = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/refikHook")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("Build refikHook first") }
        let fixture = directory.appendingPathComponent(provider)
        if !FileManager.default.isExecutableFile(atPath: fixture.path) {
            let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compiler.arguments = [FileManager.default.currentDirectoryPath + "/Tests/HookTransport/provider_fixture.c", "-o", fixture.path]
            try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
        }
        let process = Process(); process.executableURL = fixture
        process.arguments = [binary.path, provider, eventName] + (interactive ? ["--interactive", "--runtime-version=2.1.287", "--host=terminal"] : [])
        process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR": directory.path]) { _, new in new }
        let input = Pipe(); let output = Pipe(); process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let body = try payload.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data(#"{"session_id":"fixture-session","turn_id":"fixture-turn","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"printf fixture"}}"#.utf8)
        try input.fileHandleForWriting.write(contentsOf: body)
        try input.fileHandleForWriting.close()
        return (process, output)
    }
    private func output(_ process: Process, _ pipe: Pipe) throws -> Data {
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); XCTFail("Helper did not exit") }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try pipe.fileHandleForReading.readToEnd() ?? Data()
    }
    func testAuthenticatedPermissionDeliveryAndDuplicateClick() async throws {
        let ready = expectation(description: "interactive request")
        var event: CodexEvent?; var channel: String?
        let (bridge, directory) = try temporaryBridge(onInteraction: { incoming, id in event = incoming; channel = id; ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let (process, pipe) = try helper(directory)
        await fulfillment(of: [ready], timeout: 2)
        let request = try XCTUnwrap(event?.requestSnapshot); let channelID = try XCTUnwrap(channel)
        XCTAssertEqual(event?.runtime?.host, .unknown)
        XCTAssertEqual(event?.runtime?.version, "2.1.287")
        let response = InteractionResponse(identity: request.identity, permissionDecision: .allow)
        let receipt = try await bridge.submit(response, channelID: channelID)
        XCTAssertEqual(receipt.lifecycle, .submitted)
        do { _ = try await bridge.submit(response, channelID: channelID); XCTFail("Duplicate delivery succeeded") } catch {}
        let native = try JSONSerialization.jsonObject(with: output(process, pipe)) as? [String: Any]
        let specific = native?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual((specific?["decision"] as? [String: String])?["behavior"], "allow")
    }
    func testResumeNativeAndStopProduceNoDecision() async throws {
        for stop in [false, true] {
            let ready = expectation(description: "request")
            let invalidated = expectation(description: "exact invalidation")
            var channel: String?
            let (bridge, directory) = try temporaryBridge(onInteraction: { _, id in channel = id; ready.fulfill() }, onInvalidation: { _ in invalidated.fulfill() })
            let (process, pipe) = try helper(directory)
            await fulfillment(of: [ready], timeout: 2)
            if stop { bridge.stop() } else { bridge.resumeNative(channelID: try XCTUnwrap(channel)) }
            await fulfillment(of: [invalidated], timeout: 2)
            XCTAssertEqual(try output(process, pipe), Data())
            bridge.stop(); try? FileManager.default.removeItem(at: directory)
        }
    }
    func testInvalidResponseDoesNotConsumeLease() async throws {
        let ready = expectation(description: "request"); var event: CodexEvent?; var channel: String?
        let (bridge, directory) = try temporaryBridge(onInteraction: { incoming, id in event = incoming; channel = id; ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let (process, pipe) = try helper(directory)
        await fulfillment(of: [ready], timeout: 2)
        let identity = try XCTUnwrap(event?.requestSnapshot?.identity); let id = try XCTUnwrap(channel)
        do { _ = try await bridge.submit(InteractionResponse(identity: identity), channelID: id); XCTFail("Invalid response delivered") } catch {}
        let receipt = try await bridge.submit(InteractionResponse(identity: identity, permissionDecision: .deny), channelID: id)
        XCTAssertEqual(receipt.lifecycle, .submitted)
        XCTAssertFalse(try output(process, pipe).isEmpty)
    }
    func testStdoutFailureReportsDeliveryUnknown() async throws {
        let ready = expectation(description: "request"); var event: CodexEvent?; var channel: String?
        let (bridge, directory) = try temporaryBridge(onInteraction: { incoming, id in event = incoming; channel = id; ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let (process, pipe) = try helper(directory)
        try pipe.fileHandleForReading.close()
        await fulfillment(of: [ready], timeout: 2)
        let identity = try XCTUnwrap(event?.requestSnapshot?.identity)
        let receipt = try await bridge.submit(InteractionResponse(identity: identity, permissionDecision: .allow), channelID: try XCTUnwrap(channel))
        XCTAssertEqual(receipt.lifecycle, .deliveryUnknown)
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    func testInteractiveCapacityAndStopClosesEveryHelper() async throws {
        let ready = expectation(description: "sixteen admitted leases"); ready.expectedFulfillmentCount = 16
        let (bridge, directory) = try temporaryBridge(onInteraction: { _, _ in ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        var helpers: [(Process, Pipe)] = []
        for _ in 0..<16 { helpers.append(try helper(directory)) }
        await fulfillment(of: [ready], timeout: 2)
        let (overflow, outputPipe) = try helper(directory)
        XCTAssertEqual(try output(overflow, outputPipe), Data())
        bridge.stop()
        for (process, pipe) in helpers { XCTAssertEqual(try output(process, pipe), Data()) }
    }

    func testWrongAuthenticationNeverRegistersChannel() async throws {
        let forbidden = expectation(description: "unauthenticated request"); forbidden.isInverted = true
        let (bridge, directory) = try temporaryBridge(onInteraction: { _, _ in forbidden.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let client = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(client, 0); defer { close(client) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(directory.appendingPathComponent("events.sock").path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: path.count + 1) { bytes in
                for (i, byte) in path.enumerated() { bytes[i] = byte }; bytes[path.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(result, 0); HookWire.timeout(client, seconds: 1)
        XCTAssertTrue(HookWire.send(HookFrame(type: "request", token: "wrong-secret"), fd: client))
        XCTAssertNil(HookWire.frame(client))
        await fulfillment(of: [forbidden], timeout: 0.1)
    }
    func testInstallerUsesProviderNativeObserverSchemaAndPreservesForeignCommands() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("refik-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("refikHook")
        for provider in [Provider.cursor, .windsurf, .copilot] {
            let url = directory.appendingPathComponent(provider.rawValue + ".json")
            let event = provider == .cursor ? "sessionStart" : provider == .windsurf ? "pre_run_command" : "sessionStart"
            let commandKey = provider == .copilot ? "bash" : "command"
            let original: [String: Any] = ["unrelated": true, "hooks": [event: [[commandKey: "foreign-command"]]]]
            try JSONSerialization.data(withJSONObject: original).write(to: url)
            try HookInstaller.setEnabled(true, provider: provider, at: url, helper: helper)
            let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let hooks = updated["hooks"] as! [String: [[String: Any]]]
            XCTAssertEqual(hooks[event]?.first?[commandKey] as? String, "foreign-command")
            XCTAssertEqual(updated["unrelated"] as? Bool, true)
            if provider == .cursor { XCTAssertNil(hooks["preToolUse"]); XCTAssertNil(hooks["beforeShellExecution"]) }
            if provider == .windsurf { XCTAssertNil(updated["version"]); XCTAssertEqual(hooks[event]?.last?["show_output"] as? Bool, false) }
            if provider == .copilot { XCTAssertEqual(updated["version"] as? Int, 1); XCTAssertEqual(hooks[event]?.last?["timeoutSec"] as? Int, 1) }
            try HookInstaller.setEnabled(false, provider: provider, at: url, helper: helper)
            let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let remaining = removed["hooks"] as! [String: [[String: Any]]]
            XCTAssertEqual(remaining[event]?.count, 1)
        }
    }

    func testUnknownAndMissingWireProtocolAreRejected() throws {
        for version in [nil, 999] as [Int?] {
            var pair: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
            defer { close(pair[0]); close(pair[1]) }
            var frame: [String: Any] = ["type": "ready"]
            if let version { frame["protocolVersion"] = version }
            XCTAssertTrue(HookWire.writeData(try JSONSerialization.data(withJSONObject: frame) + Data([10]), fd: pair[0]))
            XCTAssertNil(HookWire.frame(pair[1], deadline: HookWire.uptime + 0.1))
        }
        XCTAssertFalse(HookRuntimeContract.supports(provider: "claude", version: "2.1.271"))
        XCTAssertFalse(HookRuntimeContract.supports(provider: "codex", version: nil))
        XCTAssertTrue(HookRuntimeContract.supports(provider: "codex", version: "0.153.4"))
        XCTAssertTrue(HookRuntimeContract.supports(provider: "codex", version: "0.159.2"))
    }
    func testMonotonicLeaseExpiresDespiteDisplayClockRollback() async throws {
        let ready = expectation(description: "request"); var event: CodexEvent?; var channel: String?
        let clockLock = NSLock(); var uptime = HookWire.uptime
        let now = { () -> Double in clockLock.lock(); defer { clockLock.unlock() }; return uptime }
        let (bridge, directory) = try temporaryBridge(monotonicNow: now, onInteraction: { incoming, id in event = incoming; channel = id; ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let (process, pipe) = try helper(directory)
        await fulfillment(of: [ready], timeout: 2)
        var request = try XCTUnwrap(event?.requestSnapshot)
        request.expiresAt = Date().addingTimeInterval(-86_400) // Display wall clock rolls back independently.
        let advance = { clockLock.lock(); uptime += HookWire.maxLease + 1; clockLock.unlock() }; advance()
        do {
            _ = try await bridge.submit(InteractionResponse(identity: request.identity, permissionDecision: .allow), channelID: try XCTUnwrap(channel))
            XCTFail("Expired monotonic lease accepted after wall clock change")
        } catch {}
        bridge.resumeNative(channelID: try XCTUnwrap(channel))
        XCTAssertEqual(try output(process, pipe), Data())
    }

    func testInstallerOnlyEnablesPinnedContracts() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("refik-pin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for version in [nil, "2.1.271", "9.99.99", "2.1.287"] as [String?] {
            let url = directory.appendingPathComponent(UUID().uuidString + ".json")
            try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: directory.appendingPathComponent("refikHook"), runtimeVersion: version, runtimeHost: .terminal)
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let hooks = root["hooks"] as! [String: [[String: Any]]]
            let handler = (hooks["PermissionRequest"]!.last!["hooks"] as! [[String: Any]])[0]
            let command = handler["command"] as! String
            XCTAssertEqual(command.contains("--interactive"), version == "2.1.287")
            XCTAssertEqual(handler["timeout"] as? Int, version == "2.1.287" ? 130 : 3)
            let observer = (hooks["PostToolUse"]!.last!["hooks"] as! [[String: Any]])[0]
            XCTAssertEqual(observer["timeout"] as? Int, 3)
            XCTAssertFalse(command.contains("--host=terminal"))
        }
    }

    func testCompleteVersionTokenParsing() {
        XCTAssertEqual(HookRuntimeContract.parseVersionOutput("codex-cli 0.159.2\n"), "0.159.2")
        XCTAssertEqual(HookRuntimeContract.parseVersionOutput("2.1.287 (Claude Code)\n"), "2.1.287")
        for variant in ["2.1.287-beta.1", "2.1.287+custom", "0.159.2-custom"] {
            XCTAssertEqual(HookRuntimeContract.parseVersionOutput(variant), variant)
            XCTAssertFalse(HookRuntimeContract.supports(provider: variant.hasPrefix("2.") ? "claude" : "codex", version: HookRuntimeContract.parseVersionOutput(variant)))
        }
        for junk in ["2.1.287a", "junk2.1.287", "2.1.287/junk", "junk 2.1.287", "v2.1.287", "2.1.287 9.99.99"] {
            XCTAssertNil(HookRuntimeContract.parseVersionOutput(junk), junk)
        }
    }

    func testActualHelperDeliversAuthenticatedPassiveAntigravityObservation() async throws {
        let observed = expectation(description: "authenticated AG question")
        let (bridge, directory) = try temporaryBridge(onAntigravityObservation: { event, observation in
            XCTAssertEqual(event.runtime?.id, "hook:antigravity:unknown")
            XCTAssertEqual(event.runtime?.host, .unknown, "the actual helper fixture has no verified native AG host")
            XCTAssertNil(event.capabilities); XCTAssertNil(event.requestID); XCTAssertNil(event.requestSnapshot)
            XCTAssertEqual(observation.phase, .preToolUse); XCTAssertEqual(observation.stepIndex, 7)
            XCTAssertEqual(observation.questions?.first?.options, ["A", "B"])
            observed.fulfill()
        })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/.build/debug/refikHook")
        process.arguments = ["antigravity", "PreToolUse"]
        process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR":directory.path]) { _,new in new }
        let input = Pipe(); let stdout = Pipe(); process.standardInput = input; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"conversationId":"fixture","stepIdx":7,"toolCall":{"name":"ask_question","args":{"questions":[{"question":"Pick one","options":["A","B"],"is_multi_select":false}]}}}"#.utf8))
        try input.fileHandleForWriting.close()
        await fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(try output(process, stdout), Data())
    }

    func testUnauthenticatedAntigravityObservationIsRejected() async throws {
        let forbidden = expectation(description: "unauthenticated AG"); forbidden.isInverted = true
        let (bridge,directory) = try temporaryBridge(onAntigravityObservation: { _,_ in forbidden.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let client = socket(AF_UNIX,SOCK_STREAM,0); defer { close(client) }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(directory.appendingPathComponent("events.sock").path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) { ptr in ptr.withMemoryRebound(to:CChar.self,capacity:bytes.count+1) { chars in
            for (i,b) in bytes.enumerated() { chars[i]=CChar(bitPattern:b) }; chars[bytes.count]=0
        }}
        XCTAssertEqual(withUnsafePointer(to:&address) { ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(client,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }},0)
        let observation = try XCTUnwrap(AntigravityHookObservation.parse(["conversationId":"fixture","invocationNum":0,"initialNumSteps":0],phase:"PreInvocation"))
        let payload = try JSONSerialization.data(withJSONObject:["provider":"antigravity","sessionID":"antigravity:fixture","turnID":"fixture","kind":"started","source":"unknown","title":"fixture","id":"fixture","at":ISO8601DateFormatter().string(from:Date()),"runtime":["id":"hook:antigravity:antigravity","host":"antigravity"]])
        XCTAssertTrue(HookWire.send(HookFrame(type:"observation",token:"wrong",payload:payload,antigravityObservation:observation),fd:client))
        await fulfillment(of:[forbidden],timeout:0.15)
    }

    func testClaudeRepairPreservesPinsAndForeignConfiguration() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("refik-claude-repair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), helper = directory.appendingPathComponent("refikHook")
        let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "http", "url": "http://localhost:1234/foreign"]]]
        let status: [String: Any] = ["type": "command", "command": "foreign-status"]
        try JSONSerialization.data(withJSONObject: ["hooks": ["PreToolUse": [foreign]], "statusLine": status, "other": true]).write(to: url)
        try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper, runtimeVersion: "2.1.287")
        try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper)
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertTrue((repaired["statusLine"] as! NSDictionary).isEqual(status)); XCTAssertEqual(repaired["other"] as? Bool, true)
        let hooks = repaired["hooks"] as! [String: [[String: Any]]]
        XCTAssertTrue((hooks["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        for event in HookInstaller.claudeEvents {
            let handler = (hooks[event]!.last!["hooks"] as! [[String: Any]])[0]
            XCTAssertTrue((handler["command"] as! String).hasSuffix(" --interactive --runtime-version=2.1.287"))
            XCTAssertEqual(handler["timeout"] as? Int, ["PreToolUse", "PermissionRequest"].contains(event) ? 130 : 3)
        }
        try HookInstaller.setEnabled(false, provider: .claude, at: url, helper: helper)
        let removed = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let remaining = removed["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(remaining.count, 1); XCTAssertTrue((remaining["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        XCTAssertTrue((removed["statusLine"] as! NSDictionary).isEqual(status))
    }
    func testClaudeNilPinDoesNotActivateAndMalformedOrConflictingConfigDoesNotWrite() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("refik-claude-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json"), helper = directory.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper)
        let plain = String(data: try Data(contentsOf: url), encoding: .utf8)!
        XCTAssertFalse(plain.contains("--interactive")); XCTAssertFalse(plain.contains("--runtime-version"))
        let pinned = LegacyMigration.quoted(helper.path) + " claude PreToolUse --interactive --runtime-version=2.1.287"
        let unpinned = LegacyMigration.quoted(helper.path) + " claude Stop"
        let bad: [[String: Any]] = [
            ["hooks": ["PreToolUse": [["hooks": [["command": "foreign"], "bad-handler"]]]]],
            ["hooks": ["PreToolUse": [["hooks": [["command": "foreign"]]], "bad-group"]]],
            ["hooks": ["PreToolUse": [["hooks": [["command": pinned]]]], "Stop": [["hooks": [["command": unpinned]]]]]],
            ["hooks": ["PreToolUse": [["hooks": [["command": pinned + " ; echo other"]]]]]]
        ]
        for root in bad {
            let original = try JSONSerialization.data(withJSONObject: root); try original.write(to: url)
            XCTAssertThrowsError(try HookInstaller.setEnabled(true, provider: .claude, at: url, helper: helper))
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testExplicitClaudeInstallationVerifiesRuntimeAndPreservesForeignConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refik-claude-explicit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("settings.json"), helper = directory.appendingPathComponent("refikHook")
        let executable = directory.appendingPathComponent("claude")
        let foreign: [String: Any] = ["matcher": "Bash", "hooks": [["type": "command", "command": "foreign-hook"]]]
        let original: [String: Any] = ["hooks": ["PreToolUse": [foreign]], "statusLine": ["type": "command", "command": "foreign-status"], "other": true]
        let identity = AntigravityTerminalOrigin.FileIdentity(device: 1, inode: 2, size: 3, seconds: 4, nanos: 5)
        var operations = AntigravityTerminalOrigin.live
        operations.file = { $0 == executable ? identity : nil }
        operations.signed = { $0 == executable && $1 == "com.anthropic.claude-code" && $2 == "Q6L2SF6YDW" }
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        XCTAssertTrue(try HookInstaller.setExplicitlyEnabled(true, provider: .claude, at: config, helper: helper,
            claudeCandidates: [executable], operations: operations, probe: { _ in "2.1.287" }))
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        XCTAssertEqual(root["other"] as? Bool, true)
        XCTAssertTrue((root["statusLine"] as! NSDictionary).isEqual(original["statusLine"] as! NSDictionary))
        var hooks = root["hooks"] as! [String: [[String: Any]]]
        XCTAssertTrue((hooks["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        for event in HookInstaller.claudeEvents {
            let handler = (hooks[event]!.last!["hooks"] as! [[String: Any]])[0]
            XCTAssertTrue((handler["command"] as! String).hasSuffix(" --interactive --runtime-version=2.1.287"))
        }
        // Unknown versions and untrusted/replaced executables cannot retain a
        // previous interactive pin or run a probe before signature validation.
        XCTAssertFalse(try HookInstaller.setExplicitlyEnabled(true, provider: .claude, at: config, helper: helper,
            claudeCandidates: [executable], operations: operations, probe: { _ in "2.1.288" }))
        XCTAssertFalse(String(decoding: try Data(contentsOf: config), as: UTF8.self).contains("--interactive"))
        var untrusted = operations; untrusted.signed = { _, _, _ in false }
        XCTAssertFalse(try HookInstaller.setExplicitlyEnabled(true, provider: .claude, at: config, helper: helper,
            claudeCandidates: [executable], operations: untrusted, probe: { _ in XCTFail("untrusted executable probed"); return "2.1.287" }))
        var reads = 0; var replaced = operations
        replaced.file = { _ in reads += 1; return reads == 1 ? identity : nil }
        XCTAssertFalse(try HookInstaller.setExplicitlyEnabled(true, provider: .claude, at: config, helper: helper,
            claudeCandidates: [executable], operations: replaced, probe: { _ in "2.1.287" }))
        XCTAssertFalse(try HookInstaller.repairExistingClaude(at: config, helper: helper), "startup cannot opt observer hooks into replies")
        XCTAssertFalse(try HookInstaller.setExplicitlyEnabled(false, provider: .claude, at: config, helper: helper,
            claudeCandidates: [executable], operations: operations, probe: { _ in XCTFail("disable probed runtime"); return nil }))
        root = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        hooks = root["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks.count, 1)
        XCTAssertTrue((hooks["PreToolUse"]!.first! as NSDictionary).isEqual(foreign))
        XCTAssertTrue((root["statusLine"] as! NSDictionary).isEqual(original["statusLine"] as! NSDictionary))
    }

    @MainActor func testParallelClaudeNativeFallbackAndStructuredSubmissionUseExactIndependentLeases() async throws {
        let ready = expectation(description: "two questions"); ready.expectedFulfillmentCount = 2
        var incoming: [(CodexEvent, String)] = []
        let (bridge, directory) = try temporaryBridge(onInteraction: { event, channel in incoming.append((event, channel)); ready.fulfill() })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let tool: [String: Any] = ["questions": [
            ["question": "First?", "header": "One", "multiSelect": true, "options": [["label": "A", "description": "a"], ["label": "B", "description": "b"]]],
            ["question": "Second?", "header": "Two", "multiSelect": false, "options": [["label": "C", "description": "c"], ["label": "D", "description": "d"]]]
        ], "keep": "original"]
        func payload(_ session: String) -> [String: Any] { ["session_id": session, "prompt_id": "prompt", "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion", "tool_use_id": "tool", "tool_input": tool] }
        let first = try helper(directory, eventName: "PreToolUse", payload: payload("first"))
        let second = try helper(directory, eventName: "PreToolUse", payload: payload("second"))
        await fulfillment(of: [ready], timeout: 3)
        let coordinator = IntegrationCoordinator(); var reducer = StateReducer()
        for (event, channel) in incoming {
            let request = try XCTUnwrap(event.requestSnapshot)
            coordinator.register(try XCTUnwrap(event.capabilities), transport: bridge, runtime: event.runtime, requestIdentity: request.identity)
            reducer.apply(event)
            XCTAssertTrue(bridge.hasLiveChannel(channel, identity: request.identity))
        }
        let one = try XCTUnwrap(incoming.first { $0.0.sessionID == "claude:first" }), two = try XCTUnwrap(incoming.first { $0.0.sessionID == "claude:second" })
        let requestOne = try XCTUnwrap(one.0.requestSnapshot), requestTwo = try XCTUnwrap(two.0.requestSnapshot)
        XCTAssertEqual(coordinator.transport(for: try XCTUnwrap(reducer.sessions["claude:first"]), request: requestOne)?.1, one.1)
        XCTAssertEqual(coordinator.transport(for: try XCTUnwrap(reducer.sessions["claude:second"]), request: requestTwo)?.1, two.1)
        XCTAssertFalse(bridge.resumeNative(channelID: one.1, identity: requestTwo.identity))
        XCTAssertTrue(bridge.resumeNative(channelID: one.1, identity: requestOne.identity))
        XCTAssertFalse(bridge.resumeNative(channelID: one.1, identity: requestOne.identity))
        coordinator.remove(channelID: one.1); reducer.invalidateResponseChannel(requestOne.identity)
        XCTAssertNil(coordinator.transport(for: try XCTUnwrap(reducer.sessions["claude:first"]), request: requestOne))
        XCTAssertEqual(reducer.sessions["claude:first"]?.state, .waitingUser)
        XCTAssertEqual(reducer.sessions["claude:first"]?.orderedRequests.first?.lifecycle, .pending)
        XCTAssertEqual(try output(first.0, first.1), Data(), "native fallback emits no permission/answer decision")
        XCTAssertEqual(coordinator.transport(for: try XCTUnwrap(reducer.sessions["claude:second"]), request: requestTwo)?.1, two.1)
        let response = InteractionResponse(identity: requestTwo.identity, answers: [QuestionAnswer(questionID: "q0", optionIDs: ["o0", "o1"], text: "extra"), QuestionAnswer(questionID: "q1", optionIDs: [], text: "freeform")])
        let receipt = try await bridge.submit(response, channelID: two.1)
        XCTAssertEqual(receipt.lifecycle, .submitted)
        let output = try JSONSerialization.jsonObject(with: self.output(second.0, second.1)) as! [String: Any]
        let specific = output["hookSpecificOutput"] as! [String: Any], updated = specific["updatedInput"] as! [String: Any]
        XCTAssertEqual(updated["keep"] as? String, "original")
        XCTAssertTrue((updated["questions"] as! NSArray).isEqual(tool["questions"] as! [[String: Any]]))
        XCTAssertEqual(updated["answers"] as? [String: String], ["First?": "A, B, extra", "Second?": "freeform"])
        XCTAssertNil(specific["updatedPermissions"])
        XCTAssertFalse(bridge.hasLiveChannel(two.1, identity: requestTwo.identity))
        do { _ = try await bridge.submit(response, channelID: two.1); XCTFail("duplicate sent") } catch {}
    }

    @MainActor func testExactHookLeaseExpiryRejectsOldRequestWithoutRevokingLaterSibling() async throws {
        var clock = 100.0
        var values: [(CodexEvent, String)] = []
        let firstReady = expectation(description: "first"), secondReady = expectation(description: "second")
        let (bridge, directory) = try temporaryBridge(monotonicNow: { clock }, onInteraction: { event, channel in
            values.append((event, channel)); if values.count == 1 { firstReady.fulfill() } else { secondReady.fulfill() }
        })
        defer { bridge.stop(); try? FileManager.default.removeItem(at: directory) }
        let first = try helper(directory)
        await fulfillment(of: [firstReady], timeout: 2)
        clock = 105
        let second = try helper(directory, payload: ["session_id": "later-session", "turn_id": "turn", "hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "fixture"]])
        await fulfillment(of: [secondReady], timeout: 2)
        let coordinator = IntegrationCoordinator(); var reducer = StateReducer()
        for (event, channel) in values {
            let request = try XCTUnwrap(event.requestSnapshot)
            coordinator.register(try XCTUnwrap(event.capabilities), transport: bridge, runtime: event.runtime, requestIdentity: request.identity)
            reducer.apply(event)
        }
        let old = values[0], later = values[1]
        let oldRequest = try XCTUnwrap(old.0.requestSnapshot), laterRequest = try XCTUnwrap(later.0.requestSnapshot)
        clock = 221
        XCTAssertFalse(bridge.hasLiveChannel(old.1, identity: oldRequest.identity))
        XCTAssertFalse(bridge.resumeNative(channelID: old.1, identity: oldRequest.identity), "expired UI action cannot consume the old lease")
        XCTAssertNil(coordinator.transport(for: try XCTUnwrap(reducer.sessions[old.0.sessionID]), request: oldRequest))
        XCTAssertTrue(bridge.hasLiveChannel(later.1, identity: laterRequest.identity))
        XCTAssertEqual(coordinator.transport(for: try XCTUnwrap(reducer.sessions[later.0.sessionID]), request: laterRequest)?.1, later.1)
        bridge.resumeNative(channelID: old.1) // test-owned cleanup, not a UI decision
        XCTAssertTrue(bridge.resumeNative(channelID: later.1, identity: laterRequest.identity))
        XCTAssertEqual(try output(first.0, first.1), Data())
        XCTAssertEqual(try output(second.0, second.1), Data())
    }

}
