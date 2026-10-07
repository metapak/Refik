import Foundation
import SQLite3

// Private, version-specific recovery metadata. No conversation columns are selected.
// An inProgress index alone is insufficient after a crash: the installed Desktop
// server must still own the rollout for writing. Hooks remain authoritative.
struct DesktopReconciliation {
    static func events(root: URL, writableRollouts: Set<String>, now: Date = Date()) -> [CodexEvent] {
        let history = root.appendingPathComponent("thread_history_1.sqlite")
        let state = root.appendingPathComponent("state_5.sqlite")
        guard FileManager.default.fileExists(atPath: history.path), FileManager.default.fileExists(atPath: state.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(history.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS state", -1, &attach, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(attach) }
        let uri = "file:" + state.path + "?mode=ro"
        _ = uri.withCString { sqlite3_bind_text(attach, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(attach) == SQLITE_DONE else { return [] }
        let sql = """
        SELECT t.thread_id,t.turn_id,t.started_at,s.cwd,s.rollout_path
        FROM thread_turns t JOIN state.threads s ON s.id=t.thread_id
        WHERE t.status='inProgress' AND t.completed_at IS NULL AND s.source='vscode'
          AND s.archived=0 AND (s.agent_path IS NULL OR s.agent_path='')
          AND NOT EXISTS (SELECT 1 FROM thread_turns newer WHERE newer.thread_id=t.thread_id AND (newer.started_at>t.started_at OR newer.rollout_ordinal>t.rollout_ordinal))
        LIMIT 200
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        func field(_ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
        var events: [CodexEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let session = field(0), turn = field(1), cwd = field(3), path = field(4)
            let started = sqlite3_column_int64(stmt, 2)
            guard started > 0, Double(started) <= now.timeIntervalSince1970,
                  path.hasPrefix(root.appendingPathComponent("sessions").path + "/"),
                  writableRollouts.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path),
                  !session.isEmpty, !turn.isEmpty else { continue }
            var event = CodexEvent(sessionID: session, turnID: turn, requestID: nil, kind: .reconciledRunning,
                source: .desktop, title: ProjectLabel.resolve(explicit: nil, cwd: cwd, title: nil), at: Date(timeIntervalSince1970: Double(started)),
                id: "recovery:\(session):\(turn):\(Int(now.timeIntervalSince1970))", detail: "Canlı Desktop turu yerel kayıttan doğrulandı")
            event.projectPath = ProjectIdentity.canonical(cwd)
            event.fidelity = .derived
            events.append(event)
        }
        return events
    }

    static func writableDesktopRollouts() -> Set<String> {
        func run(_ path: String, _ arguments: [String]) -> String {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return "" }
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }
        // Process arguments/environment are deliberately never inspected.
        let processes = run("/bin/ps", ["-axo", "pid=,ppid=,comm="])
        var parents: [String: String] = [:], commands: [String: String] = [:]
        for line in processes.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if fields.count == 3 { parents[String(fields[0])] = String(fields[1]); commands[String(fields[0])] = String(fields[2]) }
        }
        let pids = commands.keys.filter { pid in
            guard let command = commands[pid], let parent = parents[pid].flatMap({ commands[$0] }) else { return false }
            return command.hasPrefix("/Applications/") && command.contains(".app/Contents/Resources/") && command.hasSuffix("/codex") &&
                (parent.hasSuffix(".app/Contents/MacOS/ChatGPT") || parent.hasSuffix(".app/Contents/MacOS/Codex"))
        }
        guard !pids.isEmpty else { return [] }
        let output = run("/usr/sbin/lsof", ["-n", "-p", pids.joined(separator: ","), "-F", "fan"])
        var access = "", paths = Set<String>()
        for line in output.split(separator: "\n") {
            if line.first == "f" { access = "" }
            if line.first == "a" { access = String(line.dropFirst()) }
            if line.first == "n", access == "w" || access == "u" {
                let path = String(line.dropFirst())
                if path.hasSuffix(".jsonl") { paths.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) }
            }
        }
        return paths
    }
}

final class DesktopReconciler {
    private let root: URL
    private let queue = DispatchQueue(label: "refik.desktop-recovery", qos: .utility)
    private let onEvents: ([CodexEvent]) -> Void
    private var timer: DispatchSourceTimer?
    private var lastScan = Date.distantPast
    init(root: URL, onEvents: @escaping ([CodexEvent]) -> Void) { self.root = root; self.onEvents = onEvents }
    func start() {
        queue.async { [self] in
            self.scan()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer; timer.resume()
        }
    }
    func reconcile() { queue.async { self.scan() } }
    func stop() { queue.async { self.timer?.cancel(); self.timer = nil } }
    private func scan() {
        guard Date().timeIntervalSince(lastScan) >= 3 else { return }
        lastScan = Date()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("thread_history_1.sqlite").path),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("state_5.sqlite").path) else {
            onEvents([]); return
        }
        onEvents(DesktopReconciliation.events(root: root, writableRollouts: DesktopReconciliation.writableDesktopRollouts()))
    }
}
