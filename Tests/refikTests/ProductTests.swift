import XCTest
import Foundation
import Darwin
@testable import refik

final class ProductTests: XCTestCase {
    private func event(_ provider: Provider, _ session: String, _ kind: EventKind, _ second: Int, request: String? = nil) -> CodexEvent {
        var value = CodexEvent(sessionID: session, turnID: "turn", requestID: request, kind: kind, source: .unknown,
                               title: "Job", at: Date(timeIntervalSince1970: Double(second)), id: "\(session)-\(second)")
        value.provider = provider
        return value
    }
    func testPriorityAcrossProvidersAndFailureNews() {
        var reducer = StateReducer()
        reducer.apply(event(.watch, "w", .started, 1))
        reducer.apply(event(.claude, "c", .completed, 2))
        XCTAssertEqual(reducer.aggregate, .completed)
        reducer.apply(event(.signal, "s", .permissionObserved, 3, request: "manual"))
        XCTAssertEqual(reducer.aggregate, .waiting)
        reducer.apply(event(.signal, "s", .requestResolved, 4, request: "manual"))
        XCTAssertEqual(reducer.aggregate, .completed)
        reducer.markSeen(["c"])
        XCTAssertEqual(reducer.aggregate, .running)
        reducer.apply(event(.watch, "w", .failed, 5))
        XCTAssertEqual(reducer.aggregate, .running)
        XCTAssertFalse(reducer.sessions["w"]!.seen)
        reducer.markSeen(["w"])
        XCTAssertTrue(reducer.sessions["w"]!.seen)
    }
    func testSessionEndClearsWaitingAndDrop() {
        var reducer = StateReducer()
        reducer.apply(event(.claude, "c", .permissionObserved, 1, request: "p"))
        XCTAssertEqual(reducer.aggregate, .waiting)
        reducer.apply(event(.claude, "c", .sessionEnded, 2))
        XCTAssertEqual(reducer.sessions["c"]?.state, .unknown)
        reducer.apply(event(.signal, "s", .started, 3))
        reducer.apply(event(.signal, "s", .dropped, 4))
        XCTAssertNil(reducer.sessions["s"])
    }
    func testProgressAndTTLValidation() {
        var reducer = StateReducer()
        var value = event(.signal, "s", .started, 1)
        value.progress = 1.2
        XCTAssertFalse(reducer.apply(value))
        value.progress = 0.4; value.ttl = 2
        XCTAssertTrue(reducer.apply(value))
        XCTAssertEqual(reducer.sessions["s"]?.progress, 0.4)
        reducer.expire(at: Date(timeIntervalSince1970: 2))
        XCTAssertNotNil(reducer.sessions["s"])
        reducer.expire(at: Date(timeIntervalSince1970: 3))
        XCTAssertNil(reducer.sessions["s"])
    }
    func testRowLimitAndOversizedDetail() {
        var reducer = StateReducer()
        for number in 0..<200 { XCTAssertTrue(reducer.apply(event(.signal, "s\(number)", .started, number + 1))) }
        XCTAssertFalse(reducer.apply(event(.signal, "overflow", .started, 300)))
        var oversized = event(.signal, "s0", .activity, 301)
        oversized.detail = String(repeating: "x", count: 501)
        XCTAssertFalse(reducer.apply(oversized))
    }
    func testSignalTerminalReplayDoesNotRearmNews() {
        var reducer = StateReducer()
        var done = event(.signal, "signal:job", .completed, 1)
        XCTAssertTrue(reducer.apply(done))
        reducer.markSeen(["signal:job"])
        done = event(.signal, "signal:job", .completed, 2)
        XCTAssertFalse(reducer.apply(done))
        XCTAssertTrue(reducer.sessions["signal:job"]!.seen)
        XCTAssertEqual(reducer.aggregate, .neutral)
        XCTAssertTrue(reducer.apply(event(.signal, "signal:job", .started, 3)))
        XCTAssertTrue(reducer.apply(event(.signal, "signal:job", .completed, 4)))
        XCTAssertEqual(reducer.aggregate, .completed)
    }
    func testManualRateLimitPerEntityAndGlobal() {
        var limiter = ManualRateLimiter()
        let now = Date(timeIntervalSince1970: 100)
        for _ in 0..<12 { XCTAssertTrue(limiter.accept("one", at: now)) }
        XCTAssertFalse(limiter.accept("one", at: now))
        for index in 0..<48 { XCTAssertTrue(limiter.accept("other-\(index)", at: now)) }
        XCTAssertFalse(limiter.accept("overflow", at: now))
        XCTAssertTrue(limiter.accept("one", at: now.addingTimeInterval(2)))
    }
    func testOptionalEventFieldsDecode() throws {
        let json = #"{"sessionID":"s","turnID":"t","kind":"started","at":"2026-10-01T00:00:00Z","id":"e"}"#
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(CodexEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.provider, .codex)
        XCTAssertEqual(event.fidelity, .official)
    }
    func testIntegrationMergeAndUninstallPreservesOthers() throws {
        for provider in [Provider.codex, .claude, .antigravity] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("settings.json")
            let initial = provider == .antigravity ? #"{"other":{"Stop":[{"command":"other"}]},"unknown":42}"# :
                #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"other"}]}]},"unknown":42}"#
            try Data(initial.utf8).write(to: url)
            let helper = URL(fileURLWithPath: "/tmp/refikHook")
            try HookInstaller.setEnabled(true, provider: provider, at: url, helper: helper)
            let first = try Data(contentsOf: url)
            try HookInstaller.setEnabled(true, provider: provider, at: url, helper: helper)
            XCTAssertEqual(first, try Data(contentsOf: url), "idempotent \(provider)")
            XCTAssertEqual((try JSONSerialization.jsonObject(with: first) as? [String: Any])?["unknown"] as? Int, 42)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains("backup") })
            try HookInstaller.setEnabled(false, provider: provider, at: url, helper: helper)
            let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            XCTAssertEqual(result["unknown"] as? Int, 42)
            if provider == .antigravity { XCTAssertNotNil(result["other"]); XCTAssertNil(result["refik-observer"]) }
            else {
                let hooks = result["hooks"] as! [String: Any]
                let stop = hooks["Stop"] as! [[String: Any]]
                XCTAssertEqual((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String, "other")
            }
        }
    }
    private var cli: URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [".build/debug/refikCLI", ".build/out/Products/Debug/refikCLI"].map { root.appendingPathComponent($0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
    }
    private func run(_ args: [String], input: String? = nil, dataDirectory: URL? = nil) throws -> (Int32, String, String) {
        let process = Process(); process.executableURL = cli; process.arguments = args
        let out = Pipe(), err = Pipe(), stdin = Pipe()
        process.standardOutput = out; process.standardError = err
        if input != nil { process.standardInput = stdin }
        process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR": dataDirectory?.path ?? ("/tmp/mm-test-" + UUID().uuidString)]) { _, new in new }
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)); try? stdin.fileHandleForWriting.close() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: output, encoding: .utf8) ?? "", String(data: errors, encoding: .utf8) ?? "")
    }
    func testWatchAndSignalUseIsolatedSocket() throws {
        let root = URL(fileURLWithPath: "/tmp/mm-" + String(UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: root) }
        let received = expectation(description: "isolated watch and signal events")
        received.expectedFulfillmentCount = 5
        let bridge = HookBridge(socketURL: root.appendingPathComponent("events.sock"), tokenURL: root.appendingPathComponent("signal.token")) { event in
            XCTAssertTrue([Provider.watch, .signal].contains(event.provider))
            received.fulfill()
        }
        bridge.start(); defer { bridge.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: root.appendingPathComponent("events.sock").path) { usleep(10_000) }
        XCTAssertEqual(try run(["watch", "/bin/echo", "hello"], dataDirectory: root).1, "hello\n")
        XCTAssertEqual(try run(["watch", "/usr/bin/false"], dataDirectory: root).0, 1)
        XCTAssertEqual(try run(["signal", "isolated", "--done"], dataDirectory: root).0, 0)
        wait(for: [received], timeout: 2)
        XCTAssertNotEqual(root, BridgePath.directory)
    }
    func testWatchExitCodesAndNoNoise() throws {
        XCTAssertEqual(try run(["watch", "/usr/bin/true"]).0, 0)
        XCTAssertEqual(try run(["watch", "/usr/bin/false"]).0, 1)
        XCTAssertEqual(try run(["watch", "/bin/sh", "-c", "exit 37"]).0, 37)
        let result = try run(["watch", "/bin/echo", "hello world"])
        XCTAssertEqual(result.1, "hello world\n")
        XCTAssertEqual(result.2, "")
    }
    func testWatchStdinStderrANSIAndQuotes() throws {
        let input = try run(["watch", "/bin/cat"], input: "abc xyz\n")
        XCTAssertEqual(input.1, "abc xyz\n")
        let stderr = try run(["watch", "/bin/sh", "-c", "printf error >&2; printf '\\033[31mred\\033[0m'"])
        XCTAssertEqual(stderr.1, "\u{1b}[31mred\u{1b}[0m")
        XCTAssertEqual(stderr.2, "error")
        let quote = try run(["watch", "/bin/echo", "a 'quoted' value"])
        XCTAssertEqual(quote.1, "a 'quoted' value\n")
    }
    func testWatchLargeOutputAndUnavailableApp() throws {
        let result = try run(["watch", "/bin/sh", "-c", "head -c 100000 /dev/zero | tr '\\0' x"])
        XCTAssertEqual(result.0, 0)
        XCTAssertEqual(result.1.count, 100000)
        XCTAssertEqual(try run(["watch", "/no/such/command"]).0, 127)
    }
    func testWatchForwardsINTAndTERM() throws {
        for number in [SIGINT, SIGTERM] {
            let process = Process()
            process.executableURL = cli
            process.arguments = ["watch", "/bin/sleep", "5"]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR": "/tmp/mm-test-" + UUID().uuidString]) { _, new in new }
        try process.run()
            usleep(200_000)
            kill(process.processIdentifier, number)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 128 + number)
        }
    }
    func testSignalValidation() throws {
        XCTAssertEqual(try run(["signal", "render", "--progress", "0.4"]).0, 0)
        XCTAssertEqual(try run(["signal", "render", "--waiting", "--detail", "review"]).0, 0)
        XCTAssertEqual(try run(["signal", "render", "--done"]).0, 0)
        XCTAssertEqual(try run(["signal", "render", "--failed"]).0, 0)
        XCTAssertEqual(try run(["signal", "render", "--drop"]).0, 0)
        XCTAssertEqual(try run(["signal", "render", "--progress", "1.4"]).0, 64)
        XCTAssertEqual(try run(["signal", "render", "--ttl", "999999"]).0, 64)
    }
    func testClaudeStatuslinePreservesOriginalOutputAndExit() throws {
        let command = "printf 'original\\n'; exit 7"
        let encoded = Data(command.utf8).base64EncodedString()
        let reset = Int(Date().timeIntervalSince1970) + 3600
        let input = #"{"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":\#(reset)}}}"#
        let result = try run(["statusline", encoded], input: input)
        XCTAssertEqual(result.0, 7)
        XCTAssertEqual(result.1, "original\n")
        XCTAssertEqual(result.2, "")
    }
    func testCodexUsageBoundedParserAndStaleData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-test.jsonl")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = "bad json\n" + #"{"timestamp":"2027-01-15T08:00:00Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":32.5,"window_minutes":300,"resets_at":1800003600},"secondary":{"used_percent":null}}}}"# + "\n"
        try Data(text.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        let events = CodexUsageReader.events(in: root, now: now)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fidelity, .derived)
        XCTAssertEqual(events[0].progress, 0.325)
        XCTAssertTrue(CodexUsageReader.events(in: root, now: now.addingTimeInterval(90_000)).isEmpty)
    }
    func testScreenGeometryLeftRightAndVerticalClamp() {
        let area = NSRect(x: 100, y: 50, width: 1200, height: 800)
        XCTAssertEqual(ScreenPlacement.mascot(in: area, edge: "left", vertical: -1), NSPoint(x: 104, y: 50))
        XCTAssertEqual(ScreenPlacement.mascot(in: area, edge: "right", vertical: 2), NSPoint(x: 1244, y: 798))
        let right = NSRect(origin: ScreenPlacement.mascot(in: area, edge: "right", vertical: 0.5), size: NSSize(width: 52, height: 52))
        let left = NSRect(origin: ScreenPlacement.mascot(in: area, edge: "left", vertical: 0.5), size: NSSize(width: 52, height: 52))
        let panel = NSSize(width: 324, height: 475)
        XCTAssertLessThan(ScreenPlacement.panel(in: area, mascot: right, panel: panel, edge: "right").x, right.minX)
        XCTAssertGreaterThan(ScreenPlacement.panel(in: area, mascot: left, panel: panel, edge: "left").x, left.maxX)
        XCTAssertGreaterThanOrEqual(ScreenPlacement.panel(in: area, mascot: right, panel: panel, edge: "right").y, area.minY)
        let short = ScreenPlacement.panelLayout(visibleHeight: 340, rowCount: 9, hasUsage: true, hasActive: false)
        XCTAssertLessThanOrEqual(short.height, 332)
        XCTAssertLessThanOrEqual(short.listHeight + 190, short.height)
        let normal = ScreenPlacement.panelLayout(visibleHeight: 900, rowCount: 9, hasUsage: true, hasActive: false)
        XCTAssertLessThanOrEqual(normal.height, 475)
    }
    func testGazeIsStableAndBounded() {
        let center = NSPoint(x: 200, y: 200)
        XCTAssertEqual(MascotHitView.gazeTarget(mouse: center, center: center), .zero)
        let target = MascotHitView.gazeTarget(mouse: NSPoint(x: 1200, y: 200), center: center)
        XCTAssertEqual(target.x, 1.7, accuracy: 0.001)
        XCTAssertEqual(target.y, 0, accuracy: 0.001)
        XCTAssertEqual(target, MascotHitView.gazeTarget(mouse: NSPoint(x: 1200, y: 200), center: center))
    }
    private var hook: URL { cli.deletingLastPathComponent().appendingPathComponent("refikHook") }
    private func normalizeHook(_ object: [String: Any], provider: String = "claude", event: String = "Stop") throws -> [String: Any]? {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONSerialization.data(withJSONObject: object).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let process = Process(); process.executableURL = hook; process.arguments = ["--normalize", provider, event]
        process.standardInput = try FileHandle(forReadingFrom: source)
        let output = Pipe(); process.standardOutput = output; process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(["REFIK_DATA_DIR": "/tmp/mm-test-" + UUID().uuidString]) { _, new in new }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try data.isEmpty ? nil : JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    func testClaudeStopOnlyCompletesWithoutBackgroundWork() throws {
        let base: [String: Any] = ["session_id": "s", "hook_event_name": "Stop", "cwd": "/tmp"]
        var payload = base
        payload["background_tasks"] = []; payload["session_crons"] = []
        XCTAssertEqual(try normalizeHook(payload)?["kind"] as? String, "completed")
        payload["background_tasks"] = [["id": "running"]]
        XCTAssertEqual(try normalizeHook(payload)?["kind"] as? String, "activity")
        payload["background_tasks"] = []; payload["session_crons"] = [["id": "scheduled"]]
        XCTAssertEqual(try normalizeHook(payload)?["kind"] as? String, "activity")
        XCTAssertEqual(try normalizeHook(base)?["kind"] as? String, "sessionEnded")
    }
    func testDesktopSessionWithoutTurnDoesNotInventActiveAndKnownTurnKeepsIdentity() throws {
        let threadOnly: [String: Any] = ["session_id": "desktop-thread", "cwd": "/tmp/project"]
        XCTAssertEqual(try normalizeHook(threadOnly, provider: "codex", event: "SessionStart")?["kind"] as? String, "unknownEvent")
        XCTAssertEqual(try normalizeHook(threadOnly, provider: "codex", event: "UserPromptSubmit")?["kind"] as? String, "unknownEvent")
        var submitted = threadOnly; submitted["turn_id"] = "desktop-turn"
        let value = try normalizeHook(submitted, provider: "codex", event: "UserPromptSubmit")
        XCTAssertEqual(value?["kind"] as? String, "started")
        XCTAssertEqual(value?["sessionID"] as? String, "desktop-thread")
        XCTAssertEqual(value?["turnID"] as? String, "desktop-turn")
    }
    @MainActor func testMissingDesktopPermissionTurnNormalizesAssociatesAndResolves() throws {
        let payload: [String: Any] = ["session_id": "desktop-permission", "tool_name": "Bash", "tool_input": ["command": "echo fixture"]]
        let permission = try normalizeHook(payload, provider: "codex", event: "PermissionRequest")!
        XCTAssertEqual(permission["missingTurnIdentity"] as? Bool, true)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: permission))
        let app = AppModel(inspectNotificationPermission: false)
        var running = CodexEvent(sessionID: "desktop-permission", turnID: "actual-turn", requestID: nil,
            kind: .reconciledRunning, source: .desktop, title: "Project", at: event.at.addingTimeInterval(-10), id: "recovered")
        running.fidelity = .derived
        app.accept(running, historical: false); app.accept(event, historical: false)
        XCTAssertEqual(app.aggregate, .waiting); XCTAssertEqual(app.sessions.first?.turnID, "actual-turn")
        var keyedTool = payload; keyedTool["turn_id"] = "actual-turn"
        let resolution = try normalizeHook(keyedTool, provider: "codex", event: "PostToolUse")!
        let resolved = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: resolution))
        app.accept(resolved, historical: false)
        XCTAssertEqual(app.aggregate, .running); XCTAssertTrue(app.sessions.first?.pending.isEmpty ?? false)
    }
    func testHookInputOverLimitIsSilent() throws {
        let huge: [String: Any] = ["session_id": "s", "hook_event_name": "Stop", "junk": String(repeating: "x", count: 70_000)]
        XCTAssertNil(try normalizeHook(huge))
    }
    func testPermissionCorrelationKeepsOtherPendingRequest() throws {
        let base: [String: Any] = ["session_id": "session", "turn_id": "turn", "tool_name": "Bash", "tool_input": ["command": "echo x"]]
        var first = base; first["request_id"] = "one"
        var second = base; second["request_id"] = "two"
        let openedOne = try normalizeHook(first, provider: "codex", event: "PermissionRequest")!
        let openedTwo = try normalizeHook(second, provider: "codex", event: "PermissionRequest")!
        XCTAssertNotEqual(openedOne["requestID"] as? String, openedTwo["requestID"] as? String)
        let resolved = try normalizeHook(first, provider: "codex", event: "PostToolUse")!
        XCTAssertEqual(openedOne["requestID"] as? String, resolved["requestID"] as? String)
        var reducer = StateReducer()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for normalized in [openedOne, openedTwo, resolved] {
            let event = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: normalized))
            XCTAssertTrue(reducer.apply(event))
        }
        XCTAssertEqual(reducer.sessions["session"]?.pending, Set([try XCTUnwrap(openedTwo["requestID"] as? String)]))
        XCTAssertEqual(reducer.sessions["session"]?.state, .waitingPermission)
        var uncorrelated = base
        let unknownOne = try normalizeHook(uncorrelated, provider: "codex", event: "PermissionRequest")!
        let unknownTwo = try normalizeHook(uncorrelated, provider: "codex", event: "PermissionRequest")!
        XCTAssertNotEqual(unknownOne["requestID"] as? String, unknownTwo["requestID"] as? String)
        XCTAssertEqual(unknownOne["fidelity"] as? String, "official")
        XCTAssertNil(unknownOne["ttl"])
        uncorrelated["tool_use_id"] = "unrelated-tool"
        let unrelated = try normalizeHook(uncorrelated, provider: "codex", event: "PostToolUse")!
        XCTAssertNotEqual(unknownOne["requestID"] as? String, unrelated["requestID"] as? String)
    }
    @MainActor func testOfficialUnkeyedPermissionRemainsPendingUntilProviderTerminalBoundary() throws {
        let base: [String: Any] = ["session_id": "app-probe", "turn_id": "turn", "tool_name": "Bash", "tool_input": ["command": "echo hi"]]
        let first = try normalizeHook(base, provider: "codex", event: "PermissionRequest")!
        let second = try normalizeHook(base, provider: "codex", event: "PermissionRequest")!
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let a = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: first))
        let b = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: second))
        let app = AppModel(inspectNotificationPermission: false)
        app.accept(a, historical: false)
        XCTAssertEqual(app.aggregate, .waiting)
        XCTAssertEqual(app.sessions.first?.state, .waitingPermission)
        app.accept(b, historical: false)
        XCTAssertEqual(app.sessions.first?.pending.count, 2)
        var tool = base; tool["tool_use_id"] = "unrelated"
        let resolved = try normalizeHook(tool, provider: "codex", event: "PostToolUse")!
        let toolEvent = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: resolved))
        app.accept(toolEvent, historical: false)
        XCTAssertEqual(app.aggregate, .waiting)
        XCTAssertEqual(app.sessions.first?.pending.count, 2)
        var reducer = StateReducer()
        reducer.apply(a); reducer.apply(b)
        XCTAssertFalse(reducer.expire(at: a.at.addingTimeInterval(601)))
        XCTAssertEqual(reducer.sessions["app-probe"]?.state, .waitingPermission)
        XCTAssertEqual(reducer.aggregate, .waiting)
        XCTAssertEqual(reducer.sessions["app-probe"]?.pending.count, 2)
        let stopped = try normalizeHook(base, provider: "codex", event: "Stop")!
        let stoppedEvent = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: stopped))
        var completed = StateReducer()
        completed.apply(a); completed.apply(b); completed.apply(stoppedEvent)
        XCTAssertEqual(completed.sessions["app-probe"]?.state, .completed)
        XCTAssertTrue(completed.sessions["app-probe"]?.pending.isEmpty ?? false)
        let late = try normalizeHook(base, provider: "codex", event: "PermissionRequest")!
        let lateEvent = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: late))
        XCTAssertFalse(completed.apply(lateEvent))
        XCTAssertEqual(completed.aggregate, .completed)
        let aborted = try normalizeHook(base, provider: "codex", event: "Interrupt")!
        let interrupted = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: aborted))
        app.accept(interrupted, historical: false)
        XCTAssertEqual(app.aggregate, .neutral)
        XCTAssertEqual(app.sessions.first?.state, .interrupted)
        app.accept(a, historical: false)
        XCTAssertEqual(app.aggregate, .neutral, "stale replay cannot reopen a stopped turn")
    }
    @MainActor func testUnkeyedToolOutcomeClearsOnlyUniqueMatchingPrompt() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for (provider, outcome) in [("codex", "PostToolUse"), ("claude", "PostToolUseFailure")] {
            let base: [String: Any] = ["session_id": "two-tools", "turn_id": "turn", "tool_name": "Bash"]
            var one = base; one["tool_input"] = ["command": "echo one"]
            var two = base; two["tool_input"] = ["command": "echo two"]
            let openedOne = try normalizeHook(one, provider: provider, event: "PermissionRequest")!
            let openedTwo = try normalizeHook(two, provider: provider, event: "PermissionRequest")!
            let resolvedOne = try normalizeHook(one.merging(["tool_use_id": "tool-1"]) { _, new in new },
                                                provider: provider, event: outcome)!
            XCTAssertEqual(openedOne["requestMatchKey"] as? String, resolvedOne["requestMatchKey"] as? String)
            XCTAssertNotEqual(openedTwo["requestMatchKey"] as? String, resolvedOne["requestMatchKey"] as? String)
            var reducer = StateReducer()
            let app = AppModel(inspectNotificationPermission: false)
            for value in [openedOne, openedTwo, resolvedOne] {
                let event = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: value))
                XCTAssertTrue(reducer.apply(event))
                app.accept(event, historical: false)
            }
            let session = provider == "codex" ? "two-tools" : "claude:two-tools"
            XCTAssertEqual(reducer.sessions[session]?.pending.count, 1, provider)
            XCTAssertTrue(reducer.sessions[session]?.pending.contains(openedTwo["requestID"] as! String) ?? false)
            XCTAssertEqual(reducer.aggregate, .waiting)
            XCTAssertEqual(app.aggregate, .waiting)
            let resolvedTwo = try normalizeHook(two.merging(["tool_use_id": "tool-2"]) { _, new in new },
                                                provider: provider, event: outcome)!
            let secondEvent = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: resolvedTwo))
            app.accept(secondEvent, historical: false)
            XCTAssertEqual(app.aggregate, .running)
            XCTAssertTrue(app.sessions.first?.pending.isEmpty ?? false)
        }
    }
    func testClaudeNotificationFallbackDoesNotDuplicatePrompt() throws {
        let base: [String: Any] = ["session_id": "claude-session", "tool_name": "Bash", "tool_input": ["command": "echo hi"]]
        let prompt = try normalizeHook(base, provider: "claude", event: "PermissionRequest")!
        let notification = try normalizeHook(base.merging(["notification_type": "permission_prompt"]) { _, new in new },
                                             provider: "claude", event: "Notification")!
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var reducer = StateReducer()
        for value in [prompt, notification] {
            let event = try decoder.decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertTrue(reducer.apply(event))
        }
        XCTAssertEqual(prompt["fidelity"] as? String, "official")
        XCTAssertEqual(reducer.sessions["claude:claude-session"]?.pending.count, 1)
        XCTAssertEqual(reducer.aggregate, .waiting)
    }
    func testIdleSocketClientDoesNotBlockNextEvent() throws {
        let root = URL(fileURLWithPath: "/tmp/mm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketURL = root.appendingPathComponent("events.sock")
        let received = expectation(description: "event after idle client")
        let bridge = HookBridge(socketURL: socketURL, tokenURL: root.appendingPathComponent("token")) { _ in received.fulfill() }
        bridge.start()
        defer { bridge.stop() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketURL.path) { usleep(10_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        func connect() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                    for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
                    chars[bytes.count] = 0
                }
            }
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            XCTAssertEqual(status, 0)
            return fd
        }
        let idle = connect()
        defer { close(idle) }
        let next = connect()
        var event = self.event(.codex, "socket-test", .started, 1)
        event.provider = .codex
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let written = data.withUnsafeBytes { Darwin.write(next, $0.baseAddress, data.count) }
        XCTAssertEqual(written, data.count, "client event write failed with errno \(errno)")
        close(next)
        wait(for: [received], timeout: 0.5)
        var idlePoll = pollfd(fd: idle, events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(Darwin.poll(&idlePoll, 1, 1000), 0)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(idle, &byte, 1), 0, "idle client closes after bounded timeout")
    }
}
