import XCTest
import Foundation
@testable import refik

final class WatcherFairnessTests: XCTestCase {
    private let chunk = 4 * 1024 * 1024
    private func line(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
    }
    private func meta(_ id: String) -> Data {
        line(["type": "session_meta", "payload": ["id": id, "cwd": "/tmp/project", "source": "vscode"]])
    }
    private func lifecycle(_ kind: String, turn: String = "one", second: Int = 0) -> Data {
        line(["type": "event_msg", "timestamp": String(format: "2026-10-02T01:00:%02dZ", second), "payload": ["type": kind, "turn_id": turn]])
    }
    private func item(_ item: [String: Any], turn: String = "one", second: Int) -> Data {
        line(["type": "event_msg", "timestamp": String(format: "2026-10-02T01:00:%02dZ", second), "payload": ["type": "item_completed", "turn_id": turn, "item": item]])
    }
    private func ask(_ id: String, turn: String = "one", second: Int = 1) -> Data {
        item(["type": "AgentMessage", "id": id, "delivery": "async", "phase": "final_answer", "questions": [["title": "fixture", "options": []]]], turn: turn, second: second)
    }
    private func reply(_ id: String, second: Int = 2) -> Data {
        let key = String(data: try! JSONSerialization.data(withJSONObject: ["request_user_input_async", id, 0]), encoding: .utf8)!
        let body = String(data: try! JSONSerialization.data(withJSONObject: [["questionItemId": key, "question": "fixture", "answer": "fixture"]]), encoding: .utf8)!
        return item(["type": "UserMessage", "id": "reply", "content": [["type": "text", "text": "<send_user_message_question_reply>\(body)</send_user_message_question_reply>"]]], second: second)
    }
    private func pad(_ data: inout Data, to target: Int) {
        let prefix = Data(#"{"type":"ignored","payload":{"padding":""#.utf8)
        let suffix = Data(#""}}"#.utf8) + Data([10])
        while data.count < target {
            let length = min(64 * 1024, target - data.count)
            precondition(length >= prefix.count + suffix.count)
            data.append(prefix); data.append(Data(repeating: 120, count: length - prefix.count - suffix.count)); data.append(suffix)
        }
    }
    func testSmallMatchingReplyIsServicedBeforeLargeFirstSeenReplayEOF() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = root.appendingPathComponent("large.jsonl"), small = root.appendingPathComponent("small.jsonl")
        var history = meta("large") + lifecycle("task_started")
        pad(&history, to: chunk * 3)
        history.append(lifecycle("task_complete", second: 3))
        try history.write(to: large)
        try (meta("small") + lifecycle("task_started") + ask("call_small") + reply("call_small")).write(to: small)
        let completed = expectation(description: "large EOF eventually reached"), resolved = expectation(description: "small request resolved")
        let lock = NSLock(); var order: [String] = []; var reducer = StateReducer(); var scheduleSmall: (() -> Void)?
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in
            lock.lock(); order.append("\(event.sessionID):\(event.kind.rawValue)"); reducer.apply(event, allowUnverifiedWait: true); lock.unlock()
            if event.sessionID == "large" && event.kind == .started { scheduleSmall?() }
            if event.sessionID == "large" && event.kind == .completed { completed.fulfill() }
            if event.sessionID == "small" && event.kind == .requestResolved { resolved.fulfill() }
        }, onBootstrapDone: {}, onHealth: { _ in })
        scheduleSmall = { [weak watcher] in watcher?.reconcile(changedPaths: [small.path]) }
        watcher.reconcile(changedPaths: [large.path])
        wait(for: [resolved, completed], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: "small:requestResolved")), try XCTUnwrap(order.firstIndex(of: "large:completed")))
        XCTAssertEqual(order.filter { $0 == "large:started" }.count, 1)
        XCTAssertEqual(order.filter { $0 == "large:completed" }.count, 1)
        XCTAssertEqual(reducer.sessions["small"]?.state, .running)
        XCTAssertTrue(reducer.sessions["small"]!.pending.isEmpty)
    }
    func testQuestionAndReplyAcrossChunkBoundariesThenTruncationReset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("boundary.jsonl")
        var history = meta("boundary") + lifecycle("task_started")
        pad(&history, to: chunk - 20); history.append(ask("call_boundary"))
        pad(&history, to: chunk * 2 - 20); history.append(reply("call_boundary"))
        try history.write(to: file)
        let first = expectation(description: "split reply resolves"), rotated = expectation(description: "new turn question after truncation")
        let lock = NSLock(); var reducer = StateReducer(); var events: [CodexEvent] = []
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in
            lock.lock(); events.append(event); reducer.apply(event, allowUnverifiedWait: true); lock.unlock()
            if event.kind == .requestResolved { first.fulfill() }
            if event.turnID == "two" && event.kind == .userQuestionObserved { rotated.fulfill() }
        }, onBootstrapDone: {}, onHealth: { _ in })
        watcher.reconcile(changedPaths: [file.path])
        wait(for: [first], timeout: 10)
        lock.lock(); XCTAssertEqual(reducer.sessions["boundary"]?.state, .running); XCTAssertTrue(reducer.sessions["boundary"]!.pending.isEmpty); lock.unlock()
        try (meta("boundary") + lifecycle("task_started", turn: "two", second: 3) + ask("call_rotated", turn: "two", second: 4)).write(to: file)
        watcher.reconcile(changedPaths: [file.path])
        wait(for: [rotated], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(reducer.sessions["boundary"]?.turnID, "two")
        XCTAssertEqual(reducer.sessions["boundary"]?.state, .waitingUser)
        XCTAssertEqual(events.filter { $0.kind == .userQuestionObserved }.count, 2)
        XCTAssertEqual(events.filter { $0.kind == .requestResolved }.count, 1)
        XCTAssertEqual(reducer.sessions["boundary"]?.pending.count, 1)
    }
    func testNativeAppendNotificationResolvesAnswerWithoutAssistantMessage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("live.jsonl")
        try (meta("live") + lifecycle("task_started") + ask("call_live")).write(to: file)
        let ready = expectation(description: "bootstrap"), resolved = expectation(description: "native reply notification")
        let lock = NSLock(); var reducer = StateReducer()
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in
            lock.lock(); reducer.apply(event, allowUnverifiedWait: true); lock.unlock()
            if event.kind == .requestResolved && event.requestID?.contains("call_live") == true { resolved.fulfill() }
        }, onBootstrapDone: { ready.fulfill() }, onHealth: { _ in })
        watcher.start(); defer { watcher.stop() }
        wait(for: [ready], timeout: 5)
        lock.lock(); XCTAssertEqual(reducer.sessions["live"]?.state, .waitingUser); lock.unlock()
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: reply("wrong_call"))
        try handle.write(contentsOf: reply("call_live", second: 3))
        try handle.close()
        wait(for: [resolved], timeout: 5)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(reducer.sessions["live"]?.state, .running)
        XCTAssertTrue(reducer.sessions["live"]!.pending.isEmpty)
    }
    func testDirectoryNotificationDiscoversOnlyItsRolloutsAndIgnoresOutsidePath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inside = root.appendingPathComponent("changed"), sibling = root.appendingPathComponent("unchanged")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for directory in [inside, sibling, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        for (directory, id) in [(inside, "inside"), (sibling, "sibling"), (outside, "outside")] {
            try (meta(id) + lifecycle("task_started")).write(to: directory.appendingPathComponent("rollout.jsonl"))
        }
        var seen: [String] = []
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in seen.append(event.sessionID) }, onBootstrapDone: {}, onHealth: { _ in })
        watcher.scan(changedPaths: [inside.path, outside.path])
        XCTAssertEqual(seen, ["inside"])
    }
    func testKnownFilePollResolvesOpenWriterReplyWithoutNotificationAndResetsTruncation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("open-writer.jsonl")
        try (meta("poll") + lifecycle("task_started") + ask("call_poll")).write(to: file)
        var reducer = StateReducer()
        let watcher = TranscriptWatcher(root: root, onEvent: { event, _ in reducer.apply(event, allowUnverifiedWait: true) }, onBootstrapDone: {}, onHealth: { _ in })
        // No stream is started: the recovery path must work without any native
        // notification, including while the producer keeps its file open.
        watcher.scan()
        XCTAssertEqual(reducer.sessions["poll"]?.state, .waitingUser)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: reply("wrong_call"))
        watcher.scanKnownFiles()
        XCTAssertEqual(reducer.sessions["poll"]?.state, .waitingUser)
        let answer = reply("call_poll", second: 3), split = answer.count / 2
        try handle.write(contentsOf: answer.prefix(split))
        watcher.scanKnownFiles()
        XCTAssertEqual(reducer.sessions["poll"]?.state, .waitingUser)
        try handle.write(contentsOf: answer.suffix(answer.count - split))
        watcher.scanKnownFiles()
        XCTAssertEqual(reducer.sessions["poll"]?.state, .running)
        XCTAssertTrue(reducer.sessions["poll"]!.pending.isEmpty)
        try handle.truncate(atOffset: 0); try handle.seek(toOffset: 0)
        try handle.write(contentsOf: meta("poll") + lifecycle("task_started", turn: "two", second: 4) + ask("call_next", turn: "two", second: 5))
        watcher.scanKnownFiles()
        XCTAssertEqual(reducer.sessions["poll"]?.turnID, "two")
        XCTAssertEqual(reducer.sessions["poll"]?.state, .waitingUser)
        XCTAssertEqual(reducer.sessions["poll"]?.pending.count, 1)
    }
}
