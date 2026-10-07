import XCTest
import SQLite3
@testable import refik

final class ReconciliationTests: XCTestCase {
    private func fixture(_ body: (URL, String) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("sessions/root.jsonl").path
        var db: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &db)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('thread','turn','inProgress',100,NULL,1);", nil, nil, nil), SQLITE_OK)
        var state: OpaquePointer?
        sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &state)
        defer { sqlite3_close(state) }
        XCTAssertEqual(sqlite3_exec(state, "CREATE TABLE threads(id TEXT,cwd TEXT,rollout_path TEXT,source TEXT,archived INTEGER,agent_path TEXT); INSERT INTO threads VALUES('thread','/tmp/project','\(path)','vscode',0,NULL);", nil, nil, nil), SQLITE_OK)
        try body(root, path)
    }
    private func event(_ kind: EventKind, _ time: Double, turn: String = "turn", official: Bool = true) -> CodexEvent {
        var e = CodexEvent(sessionID: "thread", turnID: turn, requestID: kind == .permissionObserved ? "request" : nil,
            kind: kind, source: .desktop, title: "Project", at: Date(timeIntervalSince1970: time), id: "\(kind):\(time):\(turn)")
        e.fidelity = official ? .official : .derived
        return e
    }
    func testStartupRequiresExplicitInProgressAndWritableDesktopOwnership() throws {
        try fixture { root, path in
            XCTAssertTrue(DesktopReconciliation.events(root: root, writableRollouts: []).isEmpty)
            let events = DesktopReconciliation.events(root: root, writableRollouts: [path], now: Date(timeIntervalSince1970: 200))
            XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.fidelity, .derived)
            XCTAssertEqual(events.first?.turnID, "turn")
            var state = StateReducer(); state.apply(events[0])
            XCTAssertEqual(state.aggregate, .running); XCTAssertEqual(state.visibleAttentionRows.count, 1)
        }
    }
    @MainActor func testRestartReconstructsAndListenerReconnectOrWakeUsesSameSnapshot() throws {
        try fixture { root, path in
            let url = root.appendingPathComponent("attention.json")
            let events = DesktopReconciliation.events(root: root, writableRollouts: [path])
            let app = AppModel(inspectNotificationPermission: false, stateURL: url)
            app.reconcile(events); XCTAssertEqual(app.aggregate, .running)
            let restored = AppModel(inspectNotificationPermission: false, stateURL: url)
            XCTAssertEqual(restored.aggregate, .neutral)
            restored.reconcile(events); XCTAssertEqual(restored.aggregate, .running)
            restored.reconcile(events); XCTAssertEqual(restored.sessions.count, 1)
            restored.reconcile([]); XCTAssertEqual(restored.aggregate, .neutral)
            restored.reconcile(events); XCTAssertEqual(restored.aggregate, .running)
        }
    }
    func testHistoricalCompletedOrSubagentOrSupersededTurnCannotBeRecovered() throws {
        try fixture { root, path in
            var db: OpaquePointer?; sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &db)
            defer { sqlite3_close(db) }
            sqlite3_exec(db, "UPDATE thread_turns SET status='completed',completed_at=150", nil, nil, nil)
            XCTAssertTrue(DesktopReconciliation.events(root: root, writableRollouts: [path]).isEmpty)
            sqlite3_exec(db, "UPDATE thread_turns SET status='inProgress',completed_at=NULL; INSERT INTO thread_turns VALUES('thread','new','completed',100,250,2)", nil, nil, nil)
            XCTAssertTrue(DesktopReconciliation.events(root: root, writableRollouts: [path]).isEmpty)
            sqlite3_exec(db, "DELETE FROM thread_turns WHERE turn_id='new'", nil, nil, nil)
            var state: OpaquePointer?; sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &state)
            defer { sqlite3_close(state) }
            sqlite3_exec(state, "UPDATE threads SET agent_path='/root/child'", nil, nil, nil)
            XCTAssertTrue(DesktopReconciliation.events(root: root, writableRollouts: [path]).isEmpty)
        }
    }
    func testOfficialHookAndRolloutDeduplicateAndCompletionCannotResurrect() {
        var state = StateReducer()
        state.apply(event(.reconciledRunning, 100, official: false))
        state.apply(event(.started, 100)); state.apply(event(.activity, 110, official: false))
        XCTAssertEqual(state.visibleAttentionRows.count, 1)
        state.apply(event(.completed, 120)); state.markSeen(["thread"])
        XCTAssertFalse(state.apply(event(.reconciledRunning, 100, official: false)))
        XCTAssertFalse(state.apply(event(.started, 130, official: false)))
        XCTAssertTrue(state.visibleAttentionRows.isEmpty)
        state.apply(event(.reconciledRunning, 140, turn: "next", official: false))
        XCTAssertEqual(state.sessions["thread"]?.turnID, "next")
        XCTAssertEqual(state.aggregate, .running)
        XCTAssertFalse(state.apply(event(.completed, 150, turn: "turn")))
        state.apply(event(.sessionEnded, 160, turn: "next"))
        XCTAssertFalse(state.apply(event(.reconciledRunning, 140, turn: "next", official: false)))
        XCTAssertEqual(state.aggregate, .neutral)
    }
    func testRecoveryDoesNotOverrideOfficialWaitingOrHideOtherThreadSameProject() {
        var state = StateReducer(); state.apply(event(.started, 100)); state.apply(event(.permissionObserved, 101))
        state.apply(event(.reconciledRunning, 100, official: false))
        XCTAssertEqual(state.sessions["thread"]?.state, .waitingPermission)
        var other = CodexEvent(sessionID: "other", turnID: "turn", requestID: nil, kind: .reconciledRunning,
            source: .desktop, title: "Project", at: Date(timeIntervalSince1970: 100), id: "other")
        other.fidelity = .derived; state.apply(other)
        XCTAssertEqual(state.visibleAttentionRows.count, 2)
        state.reconcilePresence([])
        XCTAssertEqual(state.sessions["thread"]?.state, .waitingPermission)
        XCTAssertEqual(state.sessions["other"]?.state, .unknown)
    }
    @MainActor func testBootstrapPreservesPersistedUnseenCompletionBesideRecoveredWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let app = AppModel(inspectNotificationPermission: false, stateURL: url)
        let completion = event(.completed, 150)
        app.accept(completion, historical: false)
        let restored = AppModel(inspectNotificationPermission: false, stateURL: url)
        var replay = completion; replay.fidelity = .derived
        restored.accept(replay, historical: true)
        XCTAssertEqual(restored.aggregate, .completed)
        XCTAssertEqual(restored.sessions.count, 1)
        restored.markSeen(["thread"])
        restored.accept(replay, historical: true)
        XCTAssertTrue(restored.sessions.isEmpty)
    }
    func testRecoveryScanFindsCompletionWithoutFilesystemNotification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout.jsonl")
        let header = #"{"type":"session_meta","payload":{"id":"thread","source":"vscode","cwd":"/tmp/project"}}"# + "\n"
        try Data(header.utf8).write(to: file)
        let completion = expectation(description: "missed terminal lifecycle recovered")
        let watcher = TranscriptWatcher(root: root, onEvent: { event, historical in
            if event.kind == .completed { XCTAssertFalse(historical); completion.fulfill() }
        }, onBootstrapDone: {}, onHealth: { _ in })
        watcher.scan()
        let timestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1))
        let line = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn\"}}\n"
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)); try handle.close()
        watcher.reconcile()
        wait(for: [completion], timeout: 2)
    }
    func testTerminalReplayAcrossHookAndRolloutPreservesAcknowledgement() {
        for kind in [EventKind.completed, .failed, .interrupted] {
            for firstOfficial in [false, true] {
                var state = StateReducer()
                state.apply(event(kind, 120, official: firstOfficial)); state.markSeen(["thread"])
                state.apply(event(kind, 121, official: !firstOfficial))
                XCTAssertEqual(state.sessions["thread"]?.seen, true)
                XCTAssertTrue(state.visibleAttentionRows.isEmpty)
                XCTAssertEqual(state.aggregate, .neutral)
                XCTAssertEqual(state.sessions["thread"]?.fidelity, .official)
            }
        }
    }
    func testDerivedStartCannotClearOfficialWaitingForSameTurn() {
        var state = StateReducer()
        state.apply(event(.started, 100)); state.apply(event(.permissionObserved, 101))
        XCTAssertFalse(state.apply(event(.started, 102, official: false)))
        XCTAssertEqual(state.sessions["thread"]?.state, .waitingPermission)
        XCTAssertEqual(state.sessions["thread"]?.fidelity, .official)
        XCTAssertEqual(state.sessions["thread"]?.pending.count, 1)
        XCTAssertEqual(state.aggregate, .waiting)
    }
    func testMissingTurnAssociationRequiresKnownActiveCanonicalThread() {
        var missing = event(.permissionObserved, 110, turn: "thread")
        missing.missingTurnIdentity = true
        var state = StateReducer()
        XCTAssertFalse(state.apply(missing)); XCTAssertTrue(state.sessions.isEmpty)
        state.apply(event(.reconciledRunning, 100, official: false))
        XCTAssertTrue(state.apply(missing)); XCTAssertEqual(state.sessions["thread"]?.turnID, "turn")
        XCTAssertEqual(state.aggregate, .waiting)
        state.apply(event(.completed, 120))
        missing = event(.permissionObserved, 130, turn: "thread"); missing.missingTurnIdentity = true
        XCTAssertFalse(state.apply(missing)); XCTAssertEqual(state.aggregate, .completed)
        var otherProvider = StateReducer()
        var watch = event(.started, 100); watch.provider = .watch
        otherProvider.apply(watch); XCTAssertFalse(otherProvider.apply(missing))
    }
    func testUnknownSchemaFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("thread_history_1.sqlite"))
        try Data().write(to: root.appendingPathComponent("state_5.sqlite"))
        XCTAssertTrue(DesktopReconciliation.events(root: root, writableRollouts: ["historical"]).isEmpty)
    }
}
