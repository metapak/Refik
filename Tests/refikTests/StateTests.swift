import XCTest
import AppKit
@testable import refik

final class StateTests: XCTestCase {
    private func event(_ session: String, _ turn: String, _ kind: EventKind, _ n: Int, request: String? = nil) -> CodexEvent {
        CodexEvent(sessionID: session, turnID: turn, requestID: request, kind: kind, source: .cli,
                   title: "Test", at: Date(timeIntervalSince1970: TimeInterval(n)), id: "\(session)-\(turn)-\(kind)-\(n)")
    }
    func testPriorityAndSeen() {
        var state = StateReducer()
        XCTAssertTrue(state.apply(event("a", "1", .started, 1)))
        XCTAssertEqual(state.aggregate, .running)
        XCTAssertTrue(state.apply(event("b", "1", .started, 2)))
        XCTAssertTrue(state.apply(event("b", "1", .completed, 3)))
        XCTAssertEqual(state.aggregate, .completed)
        XCTAssertTrue(state.apply(event("a", "1", .permissionObserved, 4, request: "p"), allowUnverifiedWait: true))
        XCTAssertEqual(state.aggregate, .waiting)
        state.apply(event("a", "1", .requestResolved, 5, request: "p"))
        XCTAssertEqual(state.aggregate, .completed)
        state.markSeen(["b"])
        XCTAssertEqual(state.aggregate, .running)
    }
    func testIndependentRequestsAndOldTurn() {
        var state = StateReducer()
        state.apply(event("a", "1", .started, 1))
        state.apply(event("a", "1", .permissionObserved, 2, request: "x"), allowUnverifiedWait: true)
        state.apply(event("a", "1", .userQuestionObserved, 3, request: "y"), allowUnverifiedWait: true)
        state.apply(event("a", "1", .requestResolved, 4, request: "x"))
        XCTAssertEqual(state.aggregate, .waiting)
        state.apply(event("a", "2", .started, 5))
        XCTAssertFalse(state.apply(event("a", "1", .completed, 6)))
        XCTAssertEqual(state.aggregate, .running)
    }
    func testDuplicateFailureInterruptAndUnknown() {
        var state = StateReducer()
        let start = event("a", "1", .started, 1)
        XCTAssertTrue(state.apply(start)); XCTAssertFalse(state.apply(start))
        state.apply(event("a", "1", .failed, 2))
        XCTAssertEqual(state.aggregate, .neutral)
        state.apply(event("a", "2", .started, 3))
        state.apply(event("a", "2", .interrupted, 4))
        XCTAssertEqual(state.aggregate, .neutral)
        state.apply(event("b", "1", .sessionEnded, 5))
        XCTAssertEqual(state.sessions["b"]?.state, .unknown)
    }
    func testRolloutAdapterIgnoresItemsAndMalformed() throws {
        var parser = RolloutAdapter()
        XCTAssertNil(parser.parse(Data("{half".utf8)))
        XCTAssertNil(parser.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp/project","originator":"Codex Desktop","source":"vscode"}}"#.utf8)))
        XCTAssertNil(parser.parse(Data(#"{"type":"event_msg","payload":{"type":"item_completed","turn_id":"one"}}"#.utf8)))
        let event = parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-01T01:00:00Z","payload":{"type":"task_complete","turn_id":"one"}}"#.utf8))
        XCTAssertEqual(event?.kind, .completed)
        XCTAssertEqual(event?.source, .desktop)
        XCTAssertEqual(event?.title, "project")
    }
    func testPartialLinesAndRotationReset() {
        var buffer = JSONLLineBuffer()
        XCTAssertTrue(buffer.append(Data("{\"type\":\"event".utf8)).isEmpty)
        XCTAssertEqual(buffer.append(Data("}\n{bad\n".utf8)).count, 2)
        // A rotated file gets a fresh cursor and must not inherit old partial bytes.
        buffer = JSONLLineBuffer()
        XCTAssertEqual(buffer.append(Data("{\"new\":true}\n".utf8)).count, 1)
    }
    func testNotificationDeduplicationAndPreferencesEncoding() throws {
        var preferences = Preferences()
        preferences.notifications = true
        preferences.opacity = 0.42
        let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.opacity, 0.42)
        let coordinator = NotificationCoordinator()
        let completion = event("a", "1", .completed, 8)
        XCTAssertTrue(coordinator.claim(event: completion, preferences: restored))
        XCTAssertFalse(coordinator.claim(event: completion, preferences: restored))
        XCTAssertFalse(coordinator.claim(event: event("b", "1", .started, 9), preferences: restored))
    }
    func testToolActivityIsSafeAndDoesNotFinishTurn() {
        var parser = RolloutAdapter()
        _ = parser.parse(Data(#"{"type":"session_meta","payload":{"id":"thread","cwd":"/tmp/project","source":"exec"}}"#.utf8))
        let started = parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-01T01:00:00Z","payload":{"type":"task_started","turn_id":"one"}}"#.utf8))!
        let activity = parser.parse(Data(#"{"type":"event_msg","timestamp":"2026-10-01T01:00:01Z","payload":{"type":"item_completed","turn_id":"one","item":{"id":"tool-1","type":"CommandExecution","command":"secret-token"}}}"#.utf8))!
        XCTAssertEqual(activity.kind, .activity)
        XCTAssertEqual(activity.detail, "Son doğrulanan adım: komut çalıştırıldı")
        XCTAssertFalse(activity.detail!.contains("secret-token"))
        var reducer = StateReducer()
        reducer.apply(started); reducer.apply(activity)
        XCTAssertEqual(reducer.aggregate, .running)
        XCTAssertEqual(reducer.sessions["thread"]?.detail, activity.detail)
    }
    func testWatcherHealthChangesAfterDirectoryDisappears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var health: [Bool] = []
        let watcher = TranscriptWatcher(root: root, onEvent: { _, _ in }, onBootstrapDone: {}, onHealth: { health.append($0) })
        watcher.scan()
        try FileManager.default.removeItem(at: root)
        watcher.scan()
        XCTAssertEqual(health, [true, false])
    }
    func testHookHelperHasStableUserLocation() {
        XCTAssertEqual(HookInstaller.helperDestination.deletingLastPathComponent(), BridgePath.directory)
        XCTAssertFalse(HookInstaller.helperDestination.path.contains(".app/Contents"))
    }
    func testImageLayersDoNotInterceptMascotClicks() {
        let mascot = MascotHitView(frame: NSRect(x: 0, y: 0, width: 52, height: 52))
        XCTAssertEqual(mascot.subviews.count, 2)
        for layer in mascot.subviews {
            XCTAssertNil(layer.hitTest(NSPoint(x: 26, y: 26)))
        }
        XCTAssertTrue(mascot.hitTest(NSPoint(x: 26, y: 26)) === mascot)
    }
    func testMascotWindowReceivesClicksWithoutTakingKeyFocus() {
        let panel = MascotPanel(contentRect: NSRect(x: 0, y: 0, width: 52, height: 52),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = MascotHitView(frame: panel.contentRect(forFrameRect: panel.frame))
        panel.level = .statusBar
        panel.ignoresMouseEvents = false
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.floating.rawValue)
        XCTAssertTrue(panel.contentView?.hitTest(NSPoint(x: 26, y: 26)) is MascotHitView)
    }
    func testLargeJSONLChunkSplitsLinearly() {
        var buffer = JSONLLineBuffer()
        let data = Data(String(repeating: "{\"event\":1}\n", count: 50_000).utf8)
        let start = Date()
        XCTAssertEqual(buffer.append(data).count, 50_000)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(buffer.partial.isEmpty)
    }
    func testChangedPathBeyondBootstrapCapIsRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var seen = Set<String>()
        for index in 0..<35 {
            let id = "thread-\(index)"
            let file = root.appendingPathComponent("\(id).jsonl")
            let content = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/tmp\",\"source\":\"exec\"}}\n" +
                "{\"type\":\"event_msg\",\"timestamp\":\"2026-10-01T01:00:00Z\",\"payload\":{\"type\":\"task_started\",\"turn_id\":\"one\"}}\n"
            try Data(content.utf8).write(to: file)
            let age = index == 34 ? -3 * 24 * 3600 : -index * 60
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(age))], ofItemAtPath: file.path)
        }
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in seen.insert(event.sessionID) }, onBootstrapDone: {}, onHealth: { _ in })
        watcher.scan()
        XCTAssertEqual(seen.count, 30)
        XCTAssertFalse(seen.contains("thread-34"))
        watcher.scan(changedPaths: [root.appendingPathComponent("thread-34.jsonl").path])
        XCTAssertTrue(seen.contains("thread-34"))
    }
    func testLiveLargeRolloutFindsStartBeyondTailWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"large","source":"exec"}}"# + "\n"
        let start = #"{"type":"event_msg","timestamp":"2026-10-01T01:00:00Z","payload":{"type":"task_started","turn_id":"one"}}"# + "\n"
        let filler = String(repeating: "{}\n", count: 3_000_000)
        try Data((header + start + filler).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: file.path)
        var seen: [CodexEvent] = []
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in seen.append(event) }, onBootstrapDone: {}, onHealth: { _ in })
        watcher.scan()
        XCTAssertTrue(seen.isEmpty)
        watcher.scan(changedPaths: [file.path])
        XCTAssertEqual(seen.map(\.kind), [.started])
    }
    func testBootstrapLiveEventKeepsRunningState() {
        var reducer = StateReducer()
        reducer.apply(event("old", "one", .started, 1))
        reducer.apply(event("live", "one", .started, 2))
        reducer.markHistoricalRunningUnknown(except: ["live"])
        XCTAssertEqual(reducer.sessions["old"]?.state, .unknown)
        XCTAssertEqual(reducer.sessions["live"]?.state, .running)
        let activity = event("old", "one", .activity, 3)
        reducer.apply(activity, allowActivityResume: true)
        XCTAssertEqual(reducer.sessions["old"]?.state, .running)
    }
}
