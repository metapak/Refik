import XCTest
import SQLite3
@testable import refik

final class NativeAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func completion(_ id: String = "a", turn: String = "turn", time: Double = 900) -> Session {
        Session(id: id, turnID: turn, source: .desktop, title: "Same project", state: .completed,
                started: Date(timeIntervalSince1970: time - 10), updated: Date(timeIntervalSince1970: time))
    }
    private func context(_ identity: String = "account", host: String = "local", generation: Double = 1) -> NativeAttentionContext {
        NativeAttentionContext(identity: identity, host: host, authGeneration: Date(timeIntervalSince1970: generation), expires: now.addingTimeInterval(100))
    }
    private func snapshot(_ ids: Set<String>, _ context: NativeAttentionContext? = nil) -> NativeAttentionSnapshot {
        NativeAttentionSnapshot(context: context ?? self.context(), unread: ids)
    }
    func testLateUnscopedTerminalHookCannotCompleteNewerTurnOrClearItsPendingRequest() {
        for kind in [EventKind.completed, .failed, .interrupted, .sessionEnded] {
            func e(_ turn: String, _ kind: EventKind, _ at: Double, request: String? = nil) -> CodexEvent {
                CodexEvent(sessionID: "thread", turnID: turn, requestID: request, kind: kind, source: .desktop,
                    title: "QA", at: Date(timeIntervalSince1970: at), id: UUID().uuidString)
            }
            var reducer = StateReducer()
            XCTAssertTrue(reducer.apply(e("A", .started, 1)))
            XCTAssertTrue(reducer.apply(e("B", .started, 2)))
            XCTAssertTrue(reducer.apply(e("B", .userQuestionObserved, 3, request: "B-question")))
            var old = e("thread", kind, 10); old.missingTurnIdentity = true
            XCTAssertFalse(reducer.apply(old))
            XCTAssertEqual(reducer.sessions["thread"]?.turnID, "B")
            XCTAssertEqual(reducer.sessions["thread"]?.state, .waitingUser)
            XCTAssertEqual(reducer.sessions["thread"]?.pending, ["B-question"])
            XCTAssertEqual(reducer.sessions["thread"]?.updated, Date(timeIntervalSince1970: 3))
        }
    }
    func testUnknownSameTurnTerminalReplayPreservesNativeSuppressionAndFirstGeneration() throws {
        var reducer = StateReducer()
        var event = CodexEvent(sessionID: "thread", turnID: "turn", requestID: nil, kind: .completed, source: .desktop,
            title: "QA", at: Date(timeIntervalSince1970: 900), id: "original")
        event.runtime = RuntimeMetadata(id: "verified-desktop", host: .codexDesktop)
        XCTAssertTrue(reducer.apply(event))
        let session = try XCTUnwrap(reducer.sessions["thread"])
        let observations = NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context(), unread: [], observedAt: now), completions: [NativeCompletion(session)], at: now)
        XCTAssertTrue(reducer.reconcileProviderAttention(observations, at: now))
        let suppressed = try XCTUnwrap(reducer.sessions["thread"])
        XCTAssertNotNil(suppressed.providerAttention); XCTAssertFalse(suppressed.seen)
        let replay = CodexEvent(sessionID: "thread", turnID: "turn", requestID: nil, kind: .completed, source: .unknown,
            title: "QA", at: now.addingTimeInterval(1), id: "different-hook-id", runtime: RuntimeMetadata(id: "unverified-hook", host: .unknown))
        XCTAssertFalse(reducer.apply(replay))
        let after = try XCTUnwrap(reducer.sessions["thread"])
        XCTAssertEqual(after.runtime, suppressed.runtime)
        XCTAssertEqual(after.updated, suppressed.updated); XCTAssertEqual(after.providerAttention, suppressed.providerAttention)
        XCTAssertEqual(after.source, suppressed.source); XCTAssertEqual(after.seen, suppressed.seen)
        XCTAssertFalse(after.requestsResultAttention)
        var derived = event; derived.fidelity = .derived
        var corroborated = StateReducer(); XCTAssertTrue(corroborated.apply(derived))
        XCTAssertTrue(corroborated.reconcileProviderAttention(observations, at: now))
        let beforeOfficial = try XCTUnwrap(corroborated.sessions["thread"])
        XCTAssertTrue(corroborated.apply(replay))
        let official = try XCTUnwrap(corroborated.sessions["thread"])
        XCTAssertEqual(official.fidelity, .official)
        XCTAssertEqual(official.updated, beforeOfficial.updated); XCTAssertEqual(official.started, beforeOfficial.started)
        XCTAssertEqual(official.runtime, beforeOfficial.runtime); XCTAssertEqual(official.providerAttention, beforeOfficial.providerAttention)
        XCTAssertEqual(official.seen, beforeOfficial.seen); XCTAssertFalse(official.requestsResultAttention)
    }
    func testOnlyFreshRemovalOfArmedExactCompletedTurnDismisses() {
        var correlation = NativeAttentionCorrelation()
        let a = NativeCompletion(completion()), b = NativeCompletion(completion("b"))
        XCTAssertTrue(correlation.observe(snapshot([]), completions: [a, b], at: now).isEmpty, "absence at startup is not a dismissal")
        XCTAssertTrue(correlation.observe(snapshot(["a", "b"]), completions: [a, b], at: now.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(correlation.observe(snapshot(["b"]), completions: [a, b], at: now.addingTimeInterval(2)), [a])
        XCTAssertTrue(correlation.observe(snapshot(["b"]), completions: [a, b], at: now.addingTimeInterval(3)).isEmpty)
    }
    func testWrongThreadSameProjectAndNewTurnDoNotDismiss() {
        var correlation = NativeAttentionCorrelation()
        let a = NativeCompletion(completion()), newer = NativeCompletion(completion(turn: "new", time: 999))
        _ = correlation.observe(snapshot(["a"]), completions: [a], at: now)
        XCTAssertTrue(correlation.observe(snapshot(["a"]), completions: [NativeCompletion(completion("b"))], at: now.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(correlation.observe(snapshot([]), completions: [a], at: now.addingTimeInterval(2)).isEmpty)
        _ = correlation.observe(snapshot(["a"]), completions: [a], at: now.addingTimeInterval(3))
        XCTAssertTrue(correlation.observe(snapshot([]), completions: [newer], at: now.addingTimeInterval(4)).isEmpty)
    }
    func testContextChangesMissingBucketGapRestartAndExpiryDiscardBaseline() {
        let a = NativeCompletion(completion())
        for changed in [context("other"), context(host: "other"), context(generation: 2)] {
            var correlation = NativeAttentionCorrelation()
            _ = correlation.observe(snapshot(["a"]), completions: [a], at: now)
            XCTAssertTrue(correlation.observe(snapshot([], changed), completions: [a], at: now.addingTimeInterval(1)).isEmpty)
        }
        for interruption in ["missing", "gap", "restart", "expired"] {
            var correlation = NativeAttentionCorrelation()
            _ = correlation.observe(snapshot(["a"]), completions: [a], at: now)
            var date = now.addingTimeInterval(2)
            if interruption == "missing" { _ = correlation.observe(nil, completions: [a], at: now.addingTimeInterval(1)) }
            if interruption == "gap" { date = now.addingTimeInterval(9) }
            if interruption == "restart" { correlation = NativeAttentionCorrelation() }
            if interruption == "expired" { date = now.addingTimeInterval(101) }
            XCTAssertTrue(correlation.observe(snapshot([]), completions: [a], at: date).isEmpty, interruption)
        }
    }
    func testMembershipBeforeCompletionDoesNotArmFutureResult() {
        var correlation = NativeAttentionCorrelation()
        let a = NativeCompletion(completion(time: 1002))
        _ = correlation.observe(snapshot(["a"]), completions: [a], at: now)
        XCTAssertTrue(correlation.observe(snapshot([]), completions: [a], at: now.addingTimeInterval(3)).isEmpty)
    }
    private func auth(account: String = "account", user: String = "user", expiry: Double = 2000) throws -> Data {
        let claims: [String: Any] = ["exp": expiry, "https://api.openai.com/auth": ["chatgpt_account_id": account, "user_id": user]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": "header.\(payload).synthetic", "account_id": account]])
    }
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func state(_ root: URL, context: NativeAttentionContext, ids: [String], version: Int = 1, time: Double = 10) throws {
        let data = try JSONSerialization.data(withJSONObject: ["electron-thread-read-state-v1": ["version": version, "unreadByIdentity": [context.identity: [context.host: ids]]]])
        let url = root.appendingPathComponent(".codex-global-state.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path)
    }
    func testReaderMatchesExplicitCurrentClaimsAndRejectsWrongBucketsAndMalformedState() throws {
        try fixture { root in
            let data = try auth(), generation = Date(timeIntervalSince1970: 1)
            let context = try XCTUnwrap(NativeAttentionReader.context(authData: data, generation: generation, now: now))
            let authURL = root.appendingPathComponent("auth.json")
            try data.write(to: authURL); try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: generation], ofItemAtPath: authURL.path)
            let reader = NativeAttentionReader(root: root)
            try state(root, context: context, ids: ["a"])
            XCTAssertEqual(reader.snapshot(now: now)?.unread, ["a"])
            try state(root, context: self.context("wrong"), ids: ["a"], time: 11)
            XCTAssertNil(reader.snapshot(now: now))
            try state(root, context: context, ids: [], time: 12)
            XCTAssertEqual(reader.snapshot(now: now)?.unread, [], "present empty bucket is an explicit removal, not bucket loss")
            try state(root, context: context, ids: ["a", "a"], time: 13)
            XCTAssertNil(reader.snapshot(now: now))
            try state(root, context: context, ids: ["a"], version: 2, time: 14)
            XCTAssertNil(reader.snapshot(now: now))
            try Data("{}".utf8).write(to: root.appendingPathComponent(".codex-global-state.json"), options: .atomic)
            XCTAssertNil(reader.snapshot(now: now))
        }
    }
    func testReaderRereadsCompleteStoreReplacementEvenWithSameModificationDate() throws {
        try fixture { root in
            let data = try auth(), generation = Date(timeIntervalSince1970: 1)
            let context = try XCTUnwrap(NativeAttentionReader.context(authData: data, generation: generation, now: now))
            let authURL = root.appendingPathComponent("auth.json")
            try data.write(to: authURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: generation], ofItemAtPath: authURL.path)
            let reader = NativeAttentionReader(root: root)
            try state(root, context: context, ids: ["a"], time: 10)
            XCTAssertEqual(reader.snapshot(now: now)?.unread, ["a"])
            try state(root, context: context, ids: [], time: 10)
            let removed = try XCTUnwrap(reader.snapshot(now: now))
            XCTAssertEqual(removed.unread, []); XCTAssertEqual(removed.observedAt, now)
            try state(root, context: context, ids: ["a"], time: 10)
            XCTAssertEqual(reader.snapshot(now: now)?.unread, ["a"])
        }
    }
    func testAuthRotationExpiryPermissionsAndExplicitConfigOverridesFailClosed() throws {
        try fixture { root in
            let url = root.appendingPathComponent("auth.json"), data = try auth()
            try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let reader = NativeAttentionReader(root: root)
            let c = try XCTUnwrap(NativeAttentionReader.context(authData: data, generation: now, now: now))
            try state(root, context: c, ids: ["a"])
            XCTAssertNotNil(reader.snapshot(now: now))
            try auth(account: "new").write(to: url, options: .atomic)
            XCTAssertNil(reader.snapshot(now: now))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            XCTAssertNil(reader.snapshot(now: now))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            XCTAssertNil(reader.snapshot(now: Date(timeIntervalSince1970: 2001)))
            for value in ["cli_auth_credentials_store = 'keyring'", "websocket_url = 'ws://localhost/custom'"] {
                try value.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
                XCTAssertNil(reader.snapshot(now: now))
            }
            try "cli_auth_credentials_store = 'file'".write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
            XCTAssertNotNil(reader.snapshot(now: now))
        }
    }
    func testQuotedEscapedAndDottedRelevantConfigurationKeysCannotBypassReaderGate() throws {
        try fixture { root in
            let data = try auth(), url = root.appendingPathComponent("auth.json")
            try data.write(to: url); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let c = try XCTUnwrap(NativeAttentionReader.context(authData: data, generation: now, now: now))
            try state(root, context: c, ids: ["a"])
            let reader = NativeAttentionReader(root: root), configURL = root.appendingPathComponent("config.toml")
            let rejected = [
                #""cli_auth_credentials_store" = "keyring""#,
                #"'cli_auth_credentials_store' = 'auto'"#,
                #""cli_auth_credentials\u005fstore" = "ephemeral""#,
                #""\U00000063li_auth_credentials_store" = "keyring""#,
                #""websocket_url" = "ws://localhost/custom""#,
                #"'websocket_url' = 'ws://localhost/#custom' # trailing comment"#,
                #""websocket\u005furl" = "ws://localhost/custom""#,
                #"host."websocket_url" = "ws://localhost/custom""#,
                #""cli_auth_credentials_store".nested = "file""#,
                "[profiles.'quoted#profile']\n\"cli_auth_credentials_store\" = 'keyring'",
                #"host = { "websocket_url" = "ws://localhost/custom" }"#,
                "cli_auth_credentials_store = \"\"\"file\"\"\"",
                #""cli_auth_credentials\qstore" = "file""#
            ]
            for config in rejected {
                try config.write(to: configURL, atomically: true, encoding: .utf8)
                XCTAssertNil(reader.snapshot(now: now), config)
            }
            for config in [
                #""cli_auth_credentials_store" = "file" # permitted explicit default"#,
                #"'cli_auth_credentials_store' = 'file'"#,
                #""cli_auth_credentials\u005fstore" = "f\u0069le""#,
                "[profiles.\"quoted#profile\"] # actual table boundary\ncli_auth_credentials_store = 'file'"
            ] {
                try config.write(to: configURL, atomically: true, encoding: .utf8)
                XCTAssertNotNil(reader.snapshot(now: now), config)
            }
        }
    }
    func testConfigurationCommentsTablesAndQuotedMarkerStringsAreUnambiguous() {
        XCTAssertTrue(NativeAttentionConfiguration.supportsDefaultHost("# 'websocket_url' = 'ignored'\n[projects.\"/tmp/project#one\"] # section\ntrust_level = 'trusted'\nmessage = \"websocket_url = fake # not a comment\""))
        XCTAssertTrue(NativeAttentionConfiguration.supportsDefaultHost("[[projects]]\nname = 'literal\\text#value'"))
        XCTAssertFalse(NativeAttentionConfiguration.supportsDefaultHost("[\"websocket_url\"]\nvalue = 'override'"))
        XCTAssertFalse(NativeAttentionConfiguration.supportsDefaultHost("[projects\ncli_auth_credentials_store = 'file'"))
        XCTAssertFalse(NativeAttentionConfiguration.supportsDefaultHost("\"cli_auth_credentials_store\" = 'file' trailing"))
        XCTAssertFalse(NativeAttentionConfiguration.supportsDefaultHost("\"cli_auth_credentials\\uD800store\" = 'file'"))
    }
    func testLatestCompletedDesktopSQLProofRejectsNewerTurnArchivedAndSubagent() throws {
        try fixture { root in
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','turn','completed',800,900,1)", nil, nil, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp/project')", nil, nil, nil), SQLITE_OK)
            let reader = NativeAttentionReader(root: root), session = completion()
            XCTAssertEqual(reader.verifiedCompletions([session]), [NativeCompletion(session)])
            for host in [RuntimeHost.vscode, .unknown] {
                var foreign = session
                foreign.runtime = RuntimeMetadata(id: "fixture", host: host)
                XCTAssertTrue(reader.verifiedCompletions([foreign]).isEmpty)
            }
            var desktop = session
            desktop.runtime = RuntimeMetadata(id: "fixture", host: .codexDesktop)
            XCTAssertEqual(reader.verifiedCompletions([desktop]), [NativeCompletion(desktop)])
            var ideLegacy = session
            ideLegacy.editorOriginEvidence = .codexVSCodeRollout
            XCTAssertTrue(reader.verifiedCompletions([ideLegacy]).isEmpty)

            var suppressed = session
            suppressed.providerAttention = ProviderAttentionDisposition(turn: session.turnID, completed: session.updated,
                authority: "opaque-authority", suppressedAt: now)
            XCTAssertEqual(reader.verifiedCompletions([suppressed]), [NativeCompletion(session)], "suppressed outcomes remain observed for later native unread")
            sqlite3_exec(history, "INSERT INTO thread_turns VALUES('a','new','inProgress',950,NULL,2)", nil, nil, nil)
            XCTAssertTrue(reader.verifiedCompletions([session]).isEmpty)
            sqlite3_exec(history, "DELETE FROM thread_turns WHERE turn_id='new'", nil, nil, nil)
            for change in ["archived=1", "archived=0,agent_path='/child'", "agent_path=NULL,source='cli'"] {
                sqlite3_exec(database, "UPDATE threads SET \(change)", nil, nil, nil)
                XCTAssertTrue(reader.verifiedCompletions([session]).isEmpty)
            }
        }
    }
    private func rollout(_ root: URL, origin: String = "codex_work_desktop", parent: Bool = false) throws -> URL {
        let url = root.appendingPathComponent("root.jsonl")
        var metadata: [String: Any] = ["id": "a", "cwd": "/tmp/project", "source": "vscode", "originator": origin]
        if parent { metadata["parent_thread_id"] = "parent" }
        let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": metadata])
        var bytes = header; bytes.append(10)
        bytes.append(lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z"))
        bytes.append(Data("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\"}}\n".utf8))
        bytes.append(lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z"))
        try bytes.write(to: url); return url
    }
    private func lifecycle(_ type: String, turn: String, time: String) -> Data {
        var data = try! JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": time,
            "payload": ["type": type, "turn_id": turn]])
        data.append(10); return data
    }
    private func watcher(_ root: URL) -> TranscriptWatcher {
        TranscriptWatcher(root: root, onEvent: { _, _ in }, onBootstrapDone: {}, onHealth: { _ in })
    }
    private func settledProofs(_ observer: TranscriptWatcher, sessionIDs: Set<String> = ["a"]) -> [RolloutCompletionProof] {
        let initial = observer.completionProofs(sessionIDs: sessionIDs)
        let deadline = Date().addingTimeInterval(10)
        while observer.completionRecoveryPending && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertFalse(observer.completionRecoveryPending, "bounded recovery must finish")
        return initial.isEmpty ? observer.completionProofs(sessionIDs: sessionIDs) : initial
    }
    func testRolloutProofRequiresExactDesktopRootStartAndCompletionAndRejectsReplay() throws {
        try fixture { root in
            let url = try rollout(root), observer = watcher(root)
            observer.scan()
            let proof = try XCTUnwrap(settledProofs(observer).first)
            XCTAssertEqual(proof.completion.thread, "a"); XCTAssertEqual(proof.completion.turn, "turn")
            XCTAssertEqual(proof.started, completion().started)
            XCTAssertNotNil(proof.completion.proofGeneration)
            let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z"))
            XCTAssertTrue(settledProofs(observer).isEmpty, "pending append invalidates before parsing")
            observer.scan(changedPaths: [url.path])
            XCTAssertTrue(settledProofs(observer).isEmpty, "terminal replay is not fresh proof")
        }
        for invalid in [("Codex CLI", false), ("codex_work_desktop", true)] {
            try fixture { root in
                _ = try rollout(root, origin: invalid.0, parent: invalid.1)
                let observer = watcher(root); observer.scan()
                XCTAssertTrue(settledProofs(observer).isEmpty)
            }
        }
    }
    func testRolloutProofInvalidatesNewTurnUnknownTerminalTruncationAndRotation() throws {
        for invalidation in ["new", "unknown", "truncate", "rotate"] {
            try fixture { root in
                let url = try rollout(root), observer = watcher(root)
                observer.scan(); XCTAssertEqual(settledProofs(observer).count, 1)
                if invalidation == "rotate" {
                    try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("old.txt"))
                    try Data().write(to: url)
                } else if invalidation == "truncate" { try Data().write(to: url) }
                else {
                    let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
                    try h.seekToEnd(); try h.write(contentsOf: lifecycle(invalidation == "new" ? "task_started" : "task_unknown_terminal",
                        turn: invalidation == "new" ? "new" : "turn", time: "1970-01-01T00:15:10.000Z"))
                }
                XCTAssertTrue(settledProofs(observer).isEmpty)
                observer.scan(changedPaths: [url.path]); XCTAssertTrue(settledProofs(observer).isEmpty, invalidation)
            }
        }
    }
    func testRolloutProofRejectsMissingStartDifferentTurnMalformedAndPartialLifecycle() throws {
        for invalid in ["missingStart", "differentTurn", "malformed", "partial"] {
            try fixture { root in
                let url = try rollout(root), observer = watcher(root)
                if invalid == "missingStart" || invalid == "differentTurn" {
                    var bytes = try Data(contentsOf: url)
                    var records = bytes.split(separator: UInt8(10)).map { Data($0) }
                    let starts = records.indices.filter { index in
                        guard let object = try? JSONSerialization.jsonObject(with: records[index]) as? [String: Any],
                              object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { return false }
                        return payload["type"] as? String == "task_started" && payload["turn_id"] as? String == "turn" &&
                            object["timestamp"] as? String == "1970-01-01T00:14:50.000Z"
                    }
                    XCTAssertEqual(starts.count, 1, "the intended authoritative start must actually be removed")
                    guard let index = starts.first, starts.count == 1 else { return }
                    records.remove(at: index)
                    bytes = Data(); for record in records { bytes.append(record); bytes.append(10) }
                    if invalid == "differentTurn" {
                        let headerEnd = bytes.firstIndex(of: 10)!
                        bytes.insert(contentsOf: lifecycle("task_started", turn: "other", time: "1970-01-01T00:14:50.000Z"), at: bytes.index(after: headerEnd))
                    }
                    try bytes.write(to: url)
                } else {
                    observer.scan(); XCTAssertEqual(settledProofs(observer).count, 1)
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data((invalid == "partial" ? "{\"type\":\"task_started\"" : "{\"type\":\"task_started\"broken}\n").utf8))
                }
                observer.scan(changedPaths: [url.path])
                XCTAssertTrue(settledProofs(observer).isEmpty, invalid)
            }
        }
    }
    func testOlderSQLIndexAllowsExactRolloutButNewerConflictingTurnRejects() throws {
        try fixture { root in
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp/project')", nil, nil, nil)
            _ = try rollout(root); let observer = watcher(root); observer.scan()
            let proofs = settledProofs(observer), reader = NativeAttentionReader(root: root), session = completion()
            XCTAssertTrue(reader.verifiedCompletions([session]).isEmpty)
            XCTAssertEqual(reader.verifiedCompletions([session], rolloutProofs: proofs), proofs.map(\.completion))
            for update in ["started_at=890", "started_at=950", "started_at=100,turn_id='turn',status='interrupted'"] {
                sqlite3_exec(history, "UPDATE thread_turns SET \(update)", nil, nil, nil)
                XCTAssertTrue(reader.verifiedCompletions([session], rolloutProofs: proofs).isEmpty)
            }
            sqlite3_exec(history, "UPDATE thread_turns SET started_at=100,turn_id='old'", nil, nil, nil)
            for update in ["archived=1", "archived=0,agent_path='child'", "agent_path=NULL,cwd='/wrong'"] {
                sqlite3_exec(database, "UPDATE threads SET \(update)", nil, nil, nil)
                XCTAssertTrue(reader.verifiedCompletions([session], rolloutProofs: proofs).isEmpty)
            }
        }
    }
    func testWholeSecondOfficialHookGenerationBindsExactFractionalRolloutPair() throws {
        try fixture { root in
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'\(project.path)')", nil, nil, nil)
            var session = completion()
            session.runtime = RuntimeMetadata(id: "hook:codex:/signed/helper-emitter", host: .codexDesktop)
            session.projectPath = project.path
            let proof = RolloutCompletionProof(completion: NativeCompletion(thread: "a", turn: "turn",
                completed: Date(timeIntervalSince1970: 900.098), proofGeneration: "epoch"),
                started: Date(timeIntervalSince1970: 890.326), cwd: project.path)
            let reader = NativeAttentionReader(root: root)
            let bound = try XCTUnwrap(reader.verifiedCompletions([session], rolloutProofs: [proof]).first)
            XCTAssertEqual(bound.completed, session.updated)
            XCTAssertEqual(bound.registryStarted, session.started)
            XCTAssertTrue(bound.matches(proof))
            var reducer = StateReducer(sessions: [session.id: session])
            let observations = NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context(), unread: [], observedAt: now), completions: [bound], at: now)
            XCTAssertTrue(reducer.reconcileProviderAttention(observations, at: now))
            XCTAssertEqual(reducer.sessions[session.id]?.updated, session.updated)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions[session.id]).seen)
            XCTAssertNotNil(reducer.sessions[session.id]?.providerAttention)
            let replaced = RolloutCompletionProof(completion: NativeCompletion(thread: "a", turn: "turn", completed: proof.completion.completed, proofGeneration: "replaced"), started: proof.started, cwd: proof.cwd)
            XCTAssertFalse(bound.matches(replaced))
            for mutation in ["start", "end", "fraction", "runtime", "host", "fidelity", "root", "turn"] {
                var other = session
                switch mutation {
                case "start": other.started = other.started.addingTimeInterval(1)
                case "end": other.updated = other.updated.addingTimeInterval(1)
                case "fraction": other.updated = other.updated.addingTimeInterval(0.05)
                case "runtime": other.runtime = RuntimeMetadata(id: "unverified", host: .codexDesktop)
                case "host": other.runtime?.host = .vscode
                case "fidelity": other.fidelity = .derived
                case "root": other.projectPath = "/tmp/foreign"
                default: other.turnID = "foreign"
                }
                XCTAssertTrue(reader.verifiedCompletions([other], rolloutProofs: [proof]).isEmpty, mutation)
            }
            var newer = session; newer.started = newer.started.addingTimeInterval(1)
            reducer = StateReducer(sessions: [session.id: newer])
            XCTAssertFalse(reducer.reconcileProviderAttention(observations, at: now))
        }
    }
    func testMixedPrecisionRolloutCompletionBindsOnlyExactGenerationAndDoesNotMarkSeen() throws {
        try fixture { root in
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp')", nil, nil, nil)
            var session = completion(); session.updated = Date(timeIntervalSince1970: 900.637)
            session.fidelity = .derived; session.projectPath = "/tmp"
            session.runtime = RuntimeMetadata(id: "codex-rollout:desktop:a", host: .codexDesktop)
            let proof = RolloutCompletionProof(completion: NativeCompletion(thread: "a", turn: "turn", completed: session.updated, proofGeneration: "fixture"), started: Date(timeIntervalSince1970: 890.729), cwd: "/tmp")
            let reader = NativeAttentionReader(root: root)
            let bound = try XCTUnwrap(reader.verifiedCompletions([session], rolloutProofs: [proof]).first)
            XCTAssertTrue(bound.matches(proof))
            for mutation in ["turn", "root", "provider", "runtime", "fraction", "start"] {
                var other = session
                switch mutation {
                case "turn": other.turnID = "other"
                case "root": other.projectPath = "/foreign"
                case "provider": other.provider = .claude
                case "runtime": other.runtime = RuntimeMetadata(id: "codex-rollout:desktop:other", host: .codexDesktop)
                case "fraction": other.updated = other.updated.addingTimeInterval(0.001)
                default: other.started = other.started.addingTimeInterval(0.001)
                }
                XCTAssertTrue(reader.verifiedCompletions([other], rolloutProofs: [proof]).isEmpty, mutation)
            }
            for unread in [false, true] {
                var reducer = StateReducer(sessions: [session.id: session])
                let observations = NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context(), unread: unread ? ["a"] : [], observedAt: now), completions: [bound], at: now)
                _ = reducer.reconcileProviderAttention(observations, at: now)
                XCTAssertEqual(reducer.sessions["a"]?.requestsResultAttention, unread)
                XCTAssertEqual(reducer.sessions["a"]?.seen, false)
                XCTAssertEqual(reducer.sessions["a"]?.started, session.started)
            }
            session.pending.insert("question"); session.pendingKinds["question"] = .waitingUser
            var reducer = StateReducer(sessions: [session.id: session])
            let observations = NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context(), unread: [], observedAt: now), completions: [bound], at: now)
            XCTAssertFalse(reducer.reconcileProviderAttention(observations, at: now))
            XCTAssertEqual(reducer.sessions["a"]?.pending, session.pending)
        }
    }
    func testCrossSecondRegistryStartBindsExactNativeCompletionAndPreservesGuards() throws {
        try fixture { root in
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp')", nil, nil, nil)
            var session = completion(); session.started = Date(timeIntervalSince1970: 891)
            session.updated = Date(timeIntervalSince1970: 900.477)
            session.fidelity = .derived; session.projectPath = "/tmp"
            session.runtime = RuntimeMetadata(id: "codex-rollout:desktop:a", host: .codexDesktop)
            let proof = RolloutCompletionProof(completion: NativeCompletion(thread: "a", turn: "turn", completed: session.updated, proofGeneration: "fixture"), started: Date(timeIntervalSince1970: 890.964), cwd: "/tmp")
            let reader = NativeAttentionReader(root: root)
            let bound = try XCTUnwrap(reader.verifiedCompletions([session], rolloutProofs: [proof]).first)
            XCTAssertTrue(bound.matches(proof)); XCTAssertEqual(bound.registryStarted, session.started)
            for unread in [false, true] {
                var reducer = StateReducer(sessions: [session.id: session])
                let observations = NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context(), unread: unread ? ["a"] : [], observedAt: now), completions: [bound], at: now)
                _ = reducer.reconcileProviderAttention(observations, at: now)
                XCTAssertEqual(reducer.sessions["a"]?.requestsResultAttention, unread)
                XCTAssertEqual(reducer.sessions["a"]?.seen, false)
                for guardKind in ["start", "turn", "end", "pending", "seen"] {
                    var changed = session
                    switch guardKind {
                    case "start": changed.started = changed.started.addingTimeInterval(1)
                    case "turn": changed.turnID = "newer"
                    case "end": changed.updated = changed.updated.addingTimeInterval(1)
                    case "pending": changed.pending = ["question"]
                    default: changed.seen = true
                    }
                    reducer = StateReducer(sessions: [session.id: changed])
                    XCTAssertFalse(reducer.reconcileProviderAttention(observations, at: now), guardKind)
                }
            }
            for mutation in ["turn", "root", "runtime", "host", "source", "provider", "end", "fractionalStart", "pending", "seen"] {
                var other = session
                switch mutation {
                case "turn": other.turnID = "other"
                case "root": other.projectPath = "/foreign"
                case "runtime": other.runtime = RuntimeMetadata(id: "codex-rollout:desktop:other", host: .codexDesktop)
                case "host": other.runtime?.host = .vscode
                case "source": other.source = .cli
                case "provider": other.provider = .claude
                case "end": other.updated = other.updated.addingTimeInterval(0.001)
                case "fractionalStart": other.started = other.started.addingTimeInterval(0.001)
                case "pending": other.pending = ["question"]
                default: other.seen = true
                }
                XCTAssertTrue(reader.verifiedCompletions([other], rolloutProofs: [proof]).isEmpty, mutation)
            }
            let replaced = RolloutCompletionProof(completion: NativeCompletion(thread: "a", turn: "turn", completed: session.updated, proofGeneration: "changed"), started: proof.started, cwd: proof.cwd)
            XCTAssertFalse(bound.matches(replaced))
            sqlite3_exec(history, "INSERT INTO thread_turns VALUES('a','newer','running',901,NULL,2)", nil, nil, nil)
            XCTAssertTrue(reader.verifiedCompletions([session], rolloutProofs: [proof]).isEmpty)
        }
    }
    func testOptInCurrentDesktopReadOnlyPrecisionDryRun() throws {
        guard ProcessInfo.processInfo.environment["REFIK_TEST_CURRENT_NATIVE_ATTENTION"] == "1" else { throw XCTSkip("explicit local metadata dry-run only") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik/attention-state.json")
        let reducer = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: state))
        let sid = "01a08671-ed27-7ba3-b946-3a602b2e4fad"
        let session = try XCTUnwrap(reducer.sessions[sid])
        let database = root.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?, stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt); sqlite3_close(db) }
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id=?", -1, &stmt, nil), SQLITE_OK)
        _ = sid.withCString { sqlite3_bind_text(stmt, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let path = try XCTUnwrap(sqlite3_column_text(stmt, 0)).withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        let url = URL(fileURLWithPath: path)
        XCTAssertTrue(url.path.hasPrefix(root.appendingPathComponent("sessions").path + "/"))
        XCTAssertEqual(url.resolvingSymlinksInPath(), url)
        let before = try FileManager.default.attributesOfItem(atPath: path)
        let size = try XCTUnwrap(before[.size] as? NSNumber).uint64Value
        let observer = watcher(root.appendingPathComponent("sessions"))
        let proof = try XCTUnwrap(observer.boundedCompletionProof(url, size: size,
            identity: try XCTUnwrap(before[.systemFileNumber] as? NSNumber).uint64Value,
            modified: try XCTUnwrap(before[.modificationDate] as? Date)))
        XCTAssertEqual(proof.completion.turn, session.turnID)
        let reader = NativeAttentionReader(root: root), now = Date()
        let snapshot = reader.snapshot(now: now)
        let bound = reader.verifiedCompletions([session], rolloutProofs: [proof])
        var clone = reducer
        let observations = NativeAttentionMirror.observations(snapshot, completions: bound, at: Date())
        let reconciled = clone.reconcileProviderAttention(observations, at: Date())
        let report: [String: Bool] = ["snapshotReady": snapshot != nil, "exactProofReady": true,
            "registryProofBound": bound.count == 1, "nativeUnread": snapshot?.unread.contains(sid) ?? true,
            "cloneDispositionApplied": reconciled, "cloneSeenUnchanged": clone.sessions[sid]?.seen == session.seen]
        let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print("REFIK_READONLY_NATIVE_ATTENTION " + String(decoding: bytes, as: UTF8.self))
        XCTAssertNotNil(snapshot); XCTAssertEqual(bound.count, 1); XCTAssertTrue(reconciled)
        XCTAssertEqual(clone.sessions[sid]?.seen, session.seen)
    }
    func testOriginRefusalIsReceiverOnlyAndPersistsWithoutChangingTerminalGeneration() throws {
        var event = CodexEvent(sessionID: "a", turnID: "turn", requestID: nil, kind: .completed, source: .unknown,
            title: "QA", at: Date(timeIntervalSince1970: 900), id: "first")
        event.codexOriginObservation = CodexOriginObservation(stage: .missingLocator, locatorPresent: false)
        var forged = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        forged["codexOriginObservation"] = ["stage": "desktopBound", "locatorPresent": true]
        XCTAssertNil(try JSONDecoder().decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: forged)).codexOriginObservation)
        var reducer = StateReducer(); XCTAssertTrue(reducer.apply(event))
        let restored = try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer))
        XCTAssertEqual(restored.sessions["a"]?.codexOriginObservation, event.codexOriginObservation)
        let replay = CodexEvent(sessionID: "a", turnID: "turn", requestID: nil, kind: .completed, source: .unknown,
            title: "QA", at: Date(timeIntervalSince1970: 901), id: "replay", codexOriginObservation: CodexOriginObservation(stage: .invalidHeader, locatorPresent: true))
        XCTAssertTrue(reducer.apply(replay))
        XCTAssertEqual(reducer.sessions["a"]?.updated, event.at)
        XCTAssertFalse(try XCTUnwrap(reducer.sessions["a"]).seen)
        XCTAssertEqual(reducer.sessions["a"]?.codexOriginObservation?.stage, .invalidHeader)
        XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "a", turnID: "new", requestID: nil, kind: .started,
            source: .unknown, title: "QA", at: Date(timeIntervalSince1970: 902), id: "next")))
        XCTAssertNil(reducer.sessions["a"]?.codexOriginObservation)
    }
    private func oversizedHistory(_ root: URL, middle: Data = Data(), ending: Data? = nil) throws -> URL {
        let url = try rollout(root), records = try Data(contentsOf: url).split(separator: UInt8(10))
        var data = Data(records[0]); data.append(10)
        // Synthetic content only: the real resumed rollout is never copied.
        data.append(Data("{\"type\":\"response_item\",\"payload\":{\"text\":\"task_started ".utf8))
        data.append(Data(repeating: 120, count: 2 * 1024 * 1024))
        data.append(Data("\"}}\n".utf8))
        data.append(lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z"))
        data.append(middle)
        data.append(ending ?? lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z"))
        try data.write(to: url); return url
    }
    func testOversizedHistoryRecoversExactTerminalAndExistingNativeReadMirror() throws {
        try fixture { root in
            _ = try oversizedHistory(root)
            let observer = watcher(root); observer.scan()
            let proof = try XCTUnwrap(settledProofs(observer).first)
            XCTAssertEqual(settledProofs(observer).first?.completion.proofGeneration, proof.completion.proofGeneration, "stable snapshot keeps the proof epoch")
            var history: OpaquePointer?, database: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            defer { sqlite3_close(history); sqlite3_close(database) }
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp/project')", nil, nil, nil)
            let reader = NativeAttentionReader(root: root), session = completion()
            let verified = reader.verifiedCompletions([session], rolloutProofs: [proof])
            XCTAssertEqual(verified, [proof.completion])
            var sampled = snapshot([]); sampled.observedAt = now
            let observations = NativeAttentionMirror.observations(sampled, completions: verified, at: now)
            func state(_ value: Session) throws -> StateReducer {
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
                return try JSONDecoder().decode(StateReducer.self, from: JSONSerialization.data(withJSONObject: ["sessions": [value.id: encoded]]))
            }
            var reducer = try state(session)
            XCTAssertTrue(reducer.reconcileProviderAttention(observations, at: now))
            XCTAssertFalse(try XCTUnwrap(reducer.sessions["a"]).requestsResultAttention)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions["a"]).seen, "existing native attention semantics are preserved")
            XCTAssertTrue(NativeAttentionMirror.observations(nil, completions: verified, at: now).isEmpty)
            var pending = session; pending.pending.insert("pending"); reducer = try state(pending)
            XCTAssertFalse(reducer.reconcileProviderAttention(observations, at: now))
            for change in ["cwd='/wrong'", "cwd='/tmp/project',source='cli'", "source='vscode',started_at=950"] {
                if change.contains("started_at") { sqlite3_exec(history, "UPDATE thread_turns SET started_at=950", nil, nil, nil) }
                else { sqlite3_exec(database, "UPDATE threads SET \(change)", nil, nil, nil) }
                XCTAssertTrue(reader.verifiedCompletions([session], rolloutProofs: [proof]).isEmpty)
            }
        }
    }
    private func compactionHistory(_ root: URL, suffix: Data = Data()) throws -> URL {
        let url = try rollout(root), header = try XCTUnwrap(Data(contentsOf: url).split(separator: UInt8(10)).first)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: header); try handle.write(contentsOf: Data([10]))
        try handle.write(contentsOf: lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z"))
        let prefix = Data("{\"type\":\"compacted\",\"payload\":{\"text\":\"".utf8), end = Data("\"}}\n".utf8)
        try handle.write(contentsOf: prefix)
        var remaining = 23_670_465 - prefix.count - end.count
        let chunk = Data(repeating: 120, count: 256 * 1024)
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count)); remaining -= count
        }
        try handle.write(contentsOf: end)
        try handle.write(contentsOf: lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z"))
        try handle.write(contentsOf: suffix)
        return url
    }
    func testScopedProofWaitsForCompleteFirstHeaderAndNeverUsesLaterStrayHeader() throws {
        for invalid in [false, true] {
            try fixture { root in
                let url = try rollout(root), records = try Data(contentsOf: url)
                let split = records.count / 5
                try Data(records.prefix(split)).write(to: url)
                let observer = watcher(root); observer.scan()
                XCTAssertTrue(observer.completionProofs(sessionIDs: ["a"]).isEmpty)
                let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
                if invalid { try handle.write(contentsOf: Data("broken\n".utf8)); try handle.write(contentsOf: records) }
                else { try handle.write(contentsOf: records.dropFirst(split)) }
                try handle.close(); observer.scan()
                XCTAssertEqual(settledProofs(observer).count, invalid ? 0 : 1)
                XCTAssertEqual(observer.completionRecoveryMetrics.invocations, 0)
            }
        }
    }
    func testScopedRecoverySchedulesOnlyRequestedDesktopRootAndClearsRemovedCandidate() throws {
        try fixture { root in
            let url = try oversizedHistory(root), observer = watcher(root); observer.scan()
            XCTAssertTrue(observer.completionProofs(sessionIDs: []).isEmpty)
            XCTAssertTrue(observer.completionProofs(sessionIDs: ["running-other"]).isEmpty)
            XCTAssertEqual(observer.completionRecoveryMetrics.invocations, 0)
            XCTAssertFalse(observer.completionRecoveryPending)
            XCTAssertEqual(settledProofs(observer).count, 1)
            XCTAssertEqual(observer.completionRecoveryMetrics.invocations, 1)
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
            try handle.write(contentsOf: Data("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\"}}\n".utf8)); try handle.close()
            observer.scan()
            XCTAssertTrue(observer.completionProofs(sessionIDs: ["a"]).isEmpty)
            XCTAssertTrue(observer.completionRecoveryPending)
            XCTAssertTrue(observer.completionProofs(sessionIDs: []).isEmpty)
            XCTAssertFalse(observer.completionRecoveryPending)
            XCTAssertEqual(settledProofs(observer).count, 1, "re-added candidate recovers current exact generation")
        }
    }
    func testScopedRecoveryRejectsForeignHeadersBeforeReadingTail() throws {
        for invalid in ["editor", "cli", "parent", "agent", "unknown", "malformed", "partial", "oversized"] {
            try fixture { root in
                let url = try oversizedHistory(root), data = try Data(contentsOf: url)
                let end = try XCTUnwrap(data.firstIndex(of: 10))
                var payload: [String: Any] = ["id": "a", "cwd": "/tmp/project", "source": "vscode", "originator": "codex_work_desktop"]
                if invalid == "editor" { payload["originator"] = "codex_vscode" }
                if invalid == "cli" { payload["source"] = "cli" }
                if invalid == "parent" { payload["parent_thread_id"] = "parent" }
                if invalid == "agent" { payload["agent_path"] = "agent" }
                if invalid == "unknown" { payload["originator"] = "unknown" }
                if invalid == "oversized" { payload["title"] = String(repeating: "x", count: 300_000) }
                var header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload]) + Data([10])
                if invalid == "malformed" { header = Data("broken\n".utf8) }
                if invalid == "partial" { header = Data("{\"type\":\"session_meta\"".utf8) }
                try (header + data[data.index(after: end)...]).write(to: url)
                let observer = watcher(root); observer.scan()
                XCTAssertTrue(settledProofs(observer).isEmpty, invalid)
                XCTAssertEqual(observer.completionRecoveryMetrics.invocations, 0, invalid)
                if !["partial", "oversized"].contains(invalid) {
                    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                    XCTAssertNil(observer.boundedCompletionProof(url,
                        size: try XCTUnwrap(attrs[.size] as? NSNumber).uint64Value,
                        identity: try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value,
                        modified: try XCTUnwrap(attrs[.modificationDate] as? Date)), invalid)
                    XCTAssertLessThanOrEqual(observer.completionRecoveryMetrics.bytes, 256 * 1024, invalid)
                }
            }
        }
    }
    func testScopedRecoveryMetadataConflictCannotClaimLaterSessionAndReplacementResetsHeader() throws {
        try fixture { root in
            let url = try oversizedHistory(root), observer = watcher(root); observer.scan()
            XCTAssertEqual(settledProofs(observer).count, 1)
            let originalHeader = try XCTUnwrap(Data(contentsOf: url).split(separator: UInt8(10)).first)
            let foreignHeader = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": "foreign", "cwd": "/tmp/project", "source": "vscode", "originator": "codex_work_desktop"]]) + Data([10])
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
            try handle.write(contentsOf: foreignHeader)
            try handle.write(contentsOf: originalHeader + Data([10]))
            try handle.write(contentsOf: lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z"))
            try handle.write(contentsOf: lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z")); try handle.close()
            observer.scan()
            XCTAssertTrue(settledProofs(observer, sessionIDs: ["a", "foreign"]).isEmpty)
            XCTAssertEqual(observer.completionRecoveryMetrics.invocations, 1)
            let replacement = root.appendingPathComponent("replacement")
            try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
            let fresh = try oversizedHistory(replacement)
            try FileManager.default.removeItem(at: url); try FileManager.default.moveItem(at: fresh, to: url)
            observer.scan()
            XCTAssertEqual(settledProofs(observer).count, 1)
        }
    }
    func testScopedRecoveryPreservesDuplicateRolloutAmbiguity() throws {
        try fixture { root in
            let url = try oversizedHistory(root)
            try FileManager.default.copyItem(at: url, to: root.appendingPathComponent("duplicate.jsonl"))
            let observer = watcher(root); observer.scan()
            let proofs = settledProofs(observer)
            XCTAssertEqual(proofs.count, 2)
            var database: OpaquePointer?, history: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            defer { sqlite3_close(database); sqlite3_close(history) }
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp/project')", nil, nil, nil)
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            XCTAssertTrue(NativeAttentionReader(root: root).verifiedCompletions([completion()], rolloutProofs: proofs).isEmpty)
        }
    }
    func testOptInScopedWatcherRecoveryPerformance() throws {
        guard ProcessInfo.processInfo.environment["REFIK_SCOPED_RECOVERY_BENCHMARK"] == "1" else { throw XCTSkip("opt-in watcher benchmark") }
        try fixture { root in
            var urls: [URL] = []
            for index in 0..<7 {
                let url = root.appendingPathComponent("scope-\(index).jsonl")
                var payload: [String: Any] = ["id": index == 0 ? "eligible" : "excluded-\(index)", "cwd": "/tmp/project", "source": "vscode", "originator": "codex_work_desktop"]
                if index % 3 == 1 { payload["originator"] = "codex_vscode" }
                if index % 3 == 2 { payload["parent_thread_id"] = "parent" }
                let header = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload]) + Data([10])
                try header.write(to: url)
                let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
                try handle.write(contentsOf: lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z"))
                try handle.write(contentsOf: Data("{\"type\":\"compacted\",\"text\":\"".utf8))
                let chunk = Data(repeating: 120, count: 256 * 1024)
                for _ in 0..<36 { try handle.write(contentsOf: chunk) }
                try handle.write(contentsOf: Data("\"}\n".utf8))
                try handle.write(contentsOf: lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z")); try handle.close()
                urls.append(url)
            }
            let observer = watcher(root); observer.scan()
            var before = rusage(), after = rusage(); getrusage(RUSAGE_SELF, &before)
            let start = Date()
            for round in 0..<3 {
                if round > 0 {
                    for url in urls {
                        let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
                        try handle.write(contentsOf: Data("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\"}}\n".utf8)); try handle.close()
                    }
                    observer.scan()
                }
                XCTAssertTrue(settledProofs(observer, sessionIDs: ["eligible"]).contains { $0.completion.thread == "eligible" })
                _ = observer.completionProofs(sessionIDs: ["eligible"])
            }
            getrusage(RUSAGE_SELF, &after)
            func cpu(_ value: rusage) -> Double { Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000 }
            let metrics = observer.completionRecoveryMetrics
            print("SCOPED_WATCHER_BENCHMARK files=7 rounds=3 invocations=\(metrics.invocations) bytes=\(metrics.bytes) wall=\(Date().timeIntervalSince(start)) cpu=\(cpu(after) - cpu(before))")
        }
    }
    // Opt-in, identical synthetic workload for before/after CPU and latency measurements.
    func testOptInCompletionRecoveryPerformance() throws {
        guard ProcessInfo.processInfo.environment["REFIK_RECOVERY_BENCHMARK"] == "1" else { throw XCTSkip("opt-in benchmark") }
        try fixture { root in
            let url = try compactionHistory(root)
            let handle = try FileHandle(forWritingTo: url); try handle.seekToEnd()
            let normal = Data((String(repeating: "{\"type\":\"event_msg\",\"timestamp\":\"1970-01-01T00:14:55.000Z\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":1234}}}\n", count: 20_000)).utf8)
            try handle.write(contentsOf: normal); try handle.close()
            let observer = watcher(root)
            func timed(_ phase: String) throws {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = try XCTUnwrap(attrs[.size] as? NSNumber).uint64Value
                let inode = try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value
                let modified = try XCTUnwrap(attrs[.modificationDate] as? Date)
                var before = rusage(), after = rusage(); getrusage(RUSAGE_SELF, &before)
                let start = Date()
                for _ in 0..<3 { XCTAssertNotNil(observer.boundedCompletionProof(url, size: size, identity: inode, modified: modified)) }
                getrusage(RUSAGE_SELF, &after)
                func cpu(_ value: rusage) -> Double { Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000 }
                print("RECOVERY_BENCHMARK phase=\(phase) bytes=\(size) runs=3 wall=\(Date().timeIntervalSince(start)) cpu=\(cpu(after) - cpu(before))")
            }
            try timed("initial")
            let append = try FileHandle(forWritingTo: url); try append.seekToEnd()
            try append.write(contentsOf: Data("{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\"}}\n".utf8)); try append.close()
            try timed("small_append")
        }
    }
    func testTwentyThreeMegabyteCompactionRecoversExactReadAndUnreadWithoutSeen() throws {
        try fixture { root in
            let url = try compactionHistory(root)
            // Reproduce the previous 8 MiB algorithm: its first fragment is
            // discarded, leaving a terminal with no matching start.
            let handle = try FileHandle(forReadingFrom: url)
            let size = try handle.seekToEnd(); try handle.seek(toOffset: size - 8 * 1024 * 1024)
            let tail = try XCTUnwrap(handle.read(upToCount: 8 * 1024 * 1024)); try handle.close()
            let boundary = try XCTUnwrap(tail.firstIndex(of: 10))
            let oldRecords = tail[tail.index(after: boundary)...].split(separator: UInt8(10))
            let oldLifecycle = oldRecords.compactMap { record -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                      object["type"] as? String == "event_msg" else { return nil }
                return (object["payload"] as? [String: Any])?["type"] as? String
            }
            XCTAssertEqual(oldLifecycle, ["task_complete"])
            let observer = watcher(root); observer.scan()
            let proof = try XCTUnwrap(settledProofs(observer).first)
            XCTAssertEqual(proof.completion.thread, "a"); XCTAssertEqual(proof.completion.turn, "turn")
            XCTAssertEqual(proof.started, completion().started); XCTAssertEqual(proof.completion.completed, completion().updated)
            XCTAssertEqual(proof.cwd, "/tmp/project")
            XCTAssertEqual(settledProofs(observer).first?.completion.proofGeneration, proof.completion.proofGeneration)
            var database: OpaquePointer?, history: OpaquePointer?
            sqlite3_open(root.appendingPathComponent("state_5.sqlite").path, &database)
            sqlite3_open(root.appendingPathComponent("thread_history_1.sqlite").path, &history)
            defer { sqlite3_close(database); sqlite3_close(history) }
            sqlite3_exec(database, "CREATE TABLE threads(id TEXT,source TEXT,archived INTEGER,agent_path TEXT,cwd TEXT); INSERT INTO threads VALUES('a','vscode',0,NULL,'/tmp/project')", nil, nil, nil)
            sqlite3_exec(history, "CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,status TEXT,started_at INTEGER,completed_at INTEGER,rollout_ordinal INTEGER); INSERT INTO thread_turns VALUES('a','old','interrupted',100,110,1)", nil, nil, nil)
            let verified = NativeAttentionReader(root: root).verifiedCompletions([completion()], rolloutProofs: [proof])
            XCTAssertEqual(verified, [proof.completion], "stale SQL requires exact recovered lifecycle")
            var reducer = StateReducer(sessions: ["a": completion()])
            for unread in [Set<String>(), ["a"]] {
                var sampled = snapshot(unread); sampled.observedAt = now
                XCTAssertTrue(reducer.reconcileProviderAttention(NativeAttentionMirror.observations(sampled, completions: verified, at: now), at: now))
                let session = try XCTUnwrap(reducer.sessions["a"])
                XCTAssertEqual(session.requestsResultAttention, unread.contains("a")); XCTAssertFalse(session.seen)
            }
        }
    }
    func testLargeCompactionRecoveryStillRejectsNewerLifecycleAndUnresolvedNativeQuestion() throws {
        for invalid in ["newer", "unknown", "pending", "partial"] {
            try fixture { root in
                let suffix: Data
                switch invalid {
                case "newer": suffix = lifecycle("task_started", turn: "new", time: "1970-01-01T00:15:10.000Z")
                case "unknown": suffix = lifecycle("turn_unknown", turn: "turn", time: "1970-01-01T00:15:10.000Z")
                case "pending": suffix = Data("{\"type\":\"response_item\",\"timestamp\":\"1970-01-01T00:15:10.000Z\",\"payload\":{\"type\":\"function_call\",\"name\":\"request_user_input_async\",\"call_id\":\"pending\",\"arguments\":\"{}\"}}\n".utf8)
                default: suffix = Data("{\"type\":\"event_msg\"".utf8)
                }
                _ = try compactionHistory(root, suffix: suffix)
                let observer = watcher(root); observer.scan()
                XCTAssertTrue(settledProofs(observer).isEmpty, invalid)
            }
        }
    }
    func testBackgroundCompactionRecoveryRejectsChangedSnapshotBeforePublishing() throws {
        for change in ["append", "rewrite", "replace"] {
            try fixture { root in
                let url = try compactionHistory(root), observer = watcher(root); observer.scan()
                XCTAssertTrue(observer.completionProofs(sessionIDs: ["a"]).isEmpty, "query schedules work without waiting for history I/O")
                XCTAssertTrue(observer.completionRecoveryPending)
                if change == "append" {
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: lifecycle("task_started", turn: "new", time: "1970-01-01T00:15:10.000Z"))
                } else if change == "rewrite" {
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    let count = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).uint64Value
                    try handle.seek(toOffset: count - 2); try handle.write(contentsOf: Data([120]))
                    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
                } else { try Data("{\"type\":\"session_meta\"}\n".utf8).write(to: url, options: .atomic) }
                observer.scan()
                XCTAssertTrue(settledProofs(observer).isEmpty, change)
            }
        }
    }
    func testOversizedCompactionValidationIsStructuralAndChecksAllDiscardedBytes() {
        let padding = String(repeating: "x", count: 1_000_001)
        let cases: [(String, Bool)] = [
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\"}}", true),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\\uD83D\\uDE00\"}}", true),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\\q\"}}", false),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\\uD800\"}}", false),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\"},\"n\":1 2}", false),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\"},}", false),
            ("{\"type\":\"event_msg\",\"payload\":{\"type\":\"compacted\",\"text\":\"\(padding)\"}}", false),
            ("{\"payload\":{\"type\":\"compacted\",\"text\":\"\(padding)\"}}", false),
            ("{\"type\":\"compacted\",\"payload\":{\"text\":\"\(padding)\"}", false)
        ]
        for (index, pair) in cases.enumerated() {
            let (text, expected) = pair
            let data = Data(text.utf8); var validator = RecoveryJSONRecord()
            for start in stride(from: 0, to: data.count, by: 4093) {
                validator.append(data[start..<min(start + 4093, data.count)])
            }
            XCTAssertEqual(validator.isCompaction, expected, "case \(index)")
        }
        var validator = RecoveryJSONRecord()
        validator.append(Data("{\"type\":\"compacted\",\"text\":\"".utf8))
        validator.append(Data(repeating: 120, count: 1_000_001))
        validator.append(Data([0xc0, 0xaf, 34, 125]))
        XCTAssertFalse(validator.isCompaction, "invalid UTF-8 after discarded text is rejected")
    }
    func testRecoveryValidatesOversizedPrefixAndSuffixAcrossThreshold() throws {
        let padding = Data(repeating: 120, count: 1_100_000)
        let prefix = Data("{\"type\":\"compacted\",\"payload\":{\"text\":\"".utf8)
        let suffix = Data("\"}}\n".utf8)
        let records: [(Data, Bool)] = [
            (prefix + padding + suffix, true),
            (prefix + Data("\\q".utf8) + padding + suffix, false),
            (prefix + padding + Data("\\q".utf8) + suffix, false),
            (prefix + Data([0xc0, 0xaf]) + padding + suffix, false),
            (prefix + padding + Data([0xc0, 0xaf]) + suffix, false),
            (prefix + Data("\\uD83D\\uDE00".utf8) + padding + suffix, true),
            (prefix + Data("\\uD800".utf8) + padding + suffix, false)
        ]
        for (index, pair) in records.enumerated() {
            try fixture { root in
                let url = try rollout(root)
                let data = try Data(contentsOf: url)
                let records = data.split(separator: UInt8(10))
                var replaced = Data()
                for (offset, record) in records.enumerated() {
                    if offset == 2 { replaced.append(pair.0) }
                    else { replaced.append(record); replaced.append(10) }
                }
                try replaced.write(to: url)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let proof = watcher(root).boundedCompletionProof(url,
                    size: try XCTUnwrap(attrs[.size] as? NSNumber).uint64Value,
                    identity: try XCTUnwrap(attrs[.systemFileNumber] as? NSNumber).uint64Value,
                    modified: try XCTUnwrap(attrs[.modificationDate] as? Date))
                XCTAssertEqual(proof != nil, pair.1, "case \(index)")
            }
        }
    }
    func testOversizedHistoryRecoveryRejectsCurrentGapsMissingStartAndWrongProvenance() throws {
        let oversized = Data(repeating: 120, count: 1_000_001) + Data("\n".utf8)
        for invalid in ["oversized", "malformed", "unknown", "partial", "missingStart", "foreignTurn", "newer", "header", "vscode", "parent"] {
            try fixture { root in
                let middle = invalid == "oversized" ? oversized : invalid == "malformed" ? Data("broken\n".utf8) : invalid == "unknown" ? lifecycle("task_unknown_terminal", turn: "turn", time: "1970-01-01T00:14:55.000Z") : Data()
                let ending = invalid == "partial" ? Data("{\"type\":\"event_msg\"".utf8) : invalid == "foreignTurn" ? lifecycle("task_complete", turn: "foreign", time: "1970-01-01T00:15:00.000Z") : nil
                let url = try oversizedHistory(root, middle: middle, ending: ending)
                var data = try Data(contentsOf: url)
                if invalid == "missingStart" {
                    let records: [Data] = data.split(separator: UInt8(10))
                    var removed = 0
                    data = Data()
                    for record in records {
                        if let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                           let payload = object["payload"] as? [String: Any], payload["type"] as? String == "task_started",
                           payload["turn_id"] as? String == "turn" { removed += 1; continue }
                        data.append(record); data.append(10)
                    }
                    XCTAssertEqual(removed, 1)
                } else if invalid == "newer" { data.append(lifecycle("task_started", turn: "new", time: "1970-01-01T00:15:10.000Z")) }
                else if ["header", "vscode", "parent"].contains(invalid) {
                    let end = try XCTUnwrap(data.firstIndex(of: 10))
                    let replacement: Data
                    if invalid == "header" { replacement = Data("{\"type\":\"session_meta\"}\n".utf8) }
                    else {
                        var payload: [String: Any] = ["id": "a", "cwd": "/tmp/project", "source": "vscode", "originator": invalid == "vscode" ? "codex_vscode" : "codex_work_desktop"]
                        if invalid == "parent" { payload["parent_thread_id"] = "parent" }
                        replacement = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": payload]) + Data([10])
                    }
                    data.replaceSubrange(...end, with: replacement)
                }
                try data.write(to: url)
                let observer = watcher(root); observer.scan()
                XCTAssertTrue(settledProofs(observer).isEmpty, invalid)
            }
        }
    }
    func testRecoveredProofRejectsAppendSameSizeRewriteAndReplacement() throws {
        for change in ["append", "rewrite", "replace"] {
            try fixture { root in
                let url = try oversizedHistory(root), observer = watcher(root); observer.scan()
                XCTAssertEqual(settledProofs(observer).count, 1)
                if change == "append" {
                    let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                    try handle.seekToEnd(); try handle.write(contentsOf: lifecycle("task_started", turn: "new", time: "1970-01-01T00:15:10.000Z"))
                } else {
                    var data = try Data(contentsOf: url)
                    let previousNewline = try XCTUnwrap(data.dropLast().lastIndex(of: 10))
                    let range = data.index(after: previousNewline)..<data.endIndex
                    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(data[range])) as? [String: Any])
                    XCTAssertEqual((object["payload"] as? [String: Any])?["type"] as? String, "task_complete")
                    data.replaceSubrange(range, with: Data(repeating: 120, count: range.count - 1) + Data([10]))
                    if change == "replace" { try data.write(to: url, options: .atomic) }
                    else { try data.write(to: url); try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path) }
                }
                XCTAssertTrue(settledProofs(observer).isEmpty, change)
                observer.scan(changedPaths: [url.path]); XCTAssertTrue(settledProofs(observer).isEmpty, change)
            }
        }
    }
    func testRecoveryTailDiscardsHistoricalFragmentButNeverInventsStartOutsideBudget() throws {
        for startInTail in [true, false] {
            try fixture { root in
                let url = try rollout(root), original = try Data(contentsOf: url)
                let headerEnd = try XCTUnwrap(original.firstIndex(of: 10))
                let handle = try FileHandle(forWritingTo: url)
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: original[...headerEnd])
                // A sparse prefix verifies bounded tail behavior without copying
                // or allocating the user's multi-gigabyte resumed history.
                try handle.seek(toOffset: 64 * 1024 * 1024)
                try handle.write(contentsOf: Data([10]))
                if !startInTail { try handle.write(contentsOf: lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z")) }
                try handle.write(contentsOf: Data("{\"text\":\"task_started ".utf8))
                try handle.write(contentsOf: Data(repeating: 120, count: (startInTail ? 7 : 65) * 1024 * 1024))
                try handle.write(contentsOf: Data("\"}\n".utf8))
                if startInTail { try handle.write(contentsOf: lifecycle("task_started", turn: "turn", time: "1970-01-01T00:14:50.000Z")) }
                try handle.write(contentsOf: lifecycle("task_complete", turn: "turn", time: "1970-01-01T00:15:00.000Z"))
                try handle.close()
                let observer = watcher(root); observer.scan()
                XCTAssertEqual(settledProofs(observer).count, startInTail ? 1 : 0)
            }
        }
    }
    func testRolloutFileGenerationChangeInvalidatesNativeUnreadArm() {
        var correlation = NativeAttentionCorrelation()
        let first = NativeCompletion(thread: "a", turn: "turn", completed: completion().updated, proofGeneration: "inode-one")
        let replaced = NativeCompletion(thread: "a", turn: "turn", completed: completion().updated, proofGeneration: "inode-two")
        _ = correlation.observe(snapshot(["a"]), completions: [first], at: now)
        XCTAssertTrue(correlation.observe(snapshot([]), completions: [replaced], at: now.addingTimeInterval(1)).isEmpty)
    }
    func testNativeDismissalRetainsBoundedIndependentOutcomeHistoryAndRechecksTurn() throws {
        var reducer = StateReducer()
        func event(_ id: String, _ turn: String = "turn") -> CodexEvent {
            CodexEvent(sessionID: id, turnID: turn, requestID: nil, kind: .completed, source: .desktop, title: "Project", at: now, id: "event:\(id):\(turn)")
        }
        reducer.apply(event("a"))
        XCTAssertFalse(reducer.dismissNative([NativeCompletion(completion(turn: "old"))], at: now))
        for i in 0..<105 {
            reducer.apply(event("result-\(i)"))
            XCTAssertTrue(reducer.dismissNative([NativeCompletion(reducer.sessions["result-\(i)"]!)], at: now))
        }
        for i in 0..<205 { reducer.apply(event("other-\(i)")) }
        XCTAssertEqual(reducer.nativeDismissalHistory?.count, 100)
        XCTAssertEqual(reducer.nativeDismissalHistory?.first?.session.id, "result-5")
        XCTAssertEqual(reducer.nativeDismissalHistory?.last?.reason, "codex-native-attention-dismissal")
        let restored = try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer))
        XCTAssertEqual(restored.nativeDismissalHistory?.count, 100)
        XCTAssertFalse(restored.nativeDismissalHistory!.last!.session.seen, "complete outcome before dismissal is retained")
        XCTAssertNil(try JSONDecoder().decode(StateReducer.self, from: Data("{\"sessions\":{}}".utf8)).nativeDismissalHistory)
    }
    @MainActor func testArchiveCommitFailureKeepsGreenAndSuccessfulCommitSurvivesRestart() throws {
        try fixture { root in
            @MainActor func app(_ url: URL) -> (AppModel, NativeCompletion) {
                let model = AppModel(inspectNotificationPermission: false, stateURL: url)
                model.accept(CodexEvent(sessionID: "a", turnID: "turn", requestID: nil, kind: .completed, source: .desktop, title: "Project", at: now, id: "done"), historical: false)
                return (model, NativeCompletion(model.sessions[0]))
            }
            let (failed, result) = app(root)
            failed.dismissNative([result], at: now)
            XCTAssertEqual(failed.aggregate, .completed)
            let url = root.appendingPathComponent("attention.json"), (success, complete) = app(url)
            success.dismissNative([complete], at: now)
            XCTAssertEqual(success.aggregate, .neutral)
            XCTAssertTrue(AppModel(inspectNotificationPermission: false, stateURL: url).sessions.isEmpty)
            let persisted = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
            XCTAssertEqual(persisted.nativeDismissalHistory?.first?.session.turnID, "turn")
        }
    }
}
