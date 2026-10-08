import XCTest
@testable import refik

final class CodexCompletionObservationTests: XCTestCase {
    private let sid = "01a10938-3b1a-7483-b333-be9a8d945824"
    private let base = Date(timeIntervalSince1970: 1_791_154_844)
    private func event(_ kind: EventKind, turn: String = "turn", at: Double = 2, id: String = UUID().uuidString, source: CodexSource = .unknown) -> CodexEvent {
        CodexEvent(sessionID: sid, turnID: turn, requestID: nil, kind: kind, source: source, title: "QA", at: base.addingTimeInterval(at), id: id)
    }
    private func stop(turn: String = "turn", at: Double = 2) -> CodexEvent {
        var value = event(.completed, turn: turn, at: at)
        value.codexOriginObservation = CodexOriginObservation(stage: .missingLocator, locatorPresent: false)
        return value
    }
    private func rollout(host: RuntimeHost = .terminal, started: Double = 0.326, completed: Double = 1.098) throws -> (URL, CodexEvent, CodexEvent) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("refik-completion-observation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("rollout-" + sid + ".jsonl")
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ payload: [String: Any], type: String = "event_msg", at: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: base.addingTimeInterval(at)), "payload": payload])
        }
        let meta = try line(["id": sid, "cwd": root.path, "source": host == .terminal ? "cli" : "vscode", "originator": host == .terminal ? "codex-tui" : (host == .vscode ? "codex_vscode" : "Codex Desktop"), "cli_version": "0.153.4"], type: "session_meta", at: 0)
        let start = try line(["type": "task_started", "turn_id": "turn"], at: started)
        let complete = try line(["type": "task_complete", "turn_id": "turn"], at: completed)
        try (meta + Data([10]) + start + Data([10]) + complete + Data([10])).write(to: file)
        var parser = RolloutAdapter(); parser.rolloutRoot = root; parser.rolloutFile = file
        _ = parser.parse(meta)
        return (root, try XCTUnwrap(parser.parse(start)), try XCTUnwrap(parser.parse(complete)))
    }
    private func registry(_ values: [(String, Session)]) throws -> StateReducer {
        var objects: [String: Any] = [:]
        for (id, session) in values {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
            object["id"] = id; objects[id] = object
        }
        return try JSONDecoder().decode(StateReducer.self, from: JSONSerialization.data(withJSONObject: ["sessions": objects]))
    }
    func testMissingLocatorRunningInventoryExcludesNinePhantomsButRetainsFourVerifiedRoots() throws {
        func unknown(_ index: Int) -> Session {
            var session = Session(id: "unknown-\(index)", turnID: "turn", source: .unknown, title: "Shared project", state: .running, started: base, updated: base)
            session.runtime = RuntimeMetadata(id: "hook:codex:unknown", host: .unknown)
            session.codexOriginObservation = CodexOriginObservation(stage: .missingLocator, locatorPresent: false)
            return session
        }
        let unknowns = (0..<9).map(unknown)
        let roots = (0..<4).map { index -> Session in
            var session = unknown(index + 9); session.source = .desktop
            session.runtime = RuntimeMetadata(id: "codex-rollout:desktop:root-\(index)", host: .codexDesktop)
            return session
        }
        let reducer = StateReducer(sessions: Dictionary(uniqueKeysWithValues: (unknowns + roots).map { ($0.id, $0) }))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(reducer)
        XCTAssertEqual(reducer.visibleAttentionRows.count, 4)
        XCTAssertEqual(reducer.attentionFooter, "4 çalışıyor")
        XCTAssertEqual(reducer.aggregate, .running)
        XCTAssertEqual(reducer.sessions.count, 13)
        XCTAssertEqual(try encoder.encode(reducer), before, "presentation queries must not mutate retained evidence")
        for session in unknowns {
            XCTAssertFalse(session.isPublicAttentionEligible)
            XCTAssertEqual(reducer.sessions[session.id]?.state, .running)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions[session.id]).seen)
        }
        XCTAssertEqual(StateReducer(sessions: Dictionary(uniqueKeysWithValues: unknowns.map { ($0.id, $0) })).aggregate, .neutral)
        var pending = unknown(0); pending.pending = ["question"]
        XCTAssertTrue(pending.isPublicAttentionEligible)
        pending.state = .waitingUser
        XCTAssertEqual(StateReducer(sessions: [pending.id: pending]).aggregate, .waiting)
        for mutation in ["provider", "terminal", "editor", "refusal", "legacy", "verifiedEditor"] {
            var session = unknown(0)
            switch mutation {
            case "provider": session.provider = .claude
            case "terminal": session.runtime = RuntimeMetadata(id: "verified", host: .terminal)
            case "editor": session.runtime = RuntimeMetadata(id: "verified", host: .vscode)
            case "refusal": session.codexOriginObservation = CodexOriginObservation(stage: .applied, locatorPresent: true)
            case "legacy": session.runtime = nil
            default: session.verifiedEditorHost = "com.microsoft.VSCode"
            }
            XCTAssertTrue(session.isPublicAttentionEligible, mutation)
        }
        var reducerWithUnknown = StateReducer(sessions: [unknowns[0].id: unknowns[0]])
        var native = event(.activity, at: 1, source: .desktop); native.sessionID = unknowns[0].id
        native.runtime = RuntimeMetadata(id: "codex-rollout:desktop:" + native.sessionID, host: .codexDesktop)
        native.fidelity = .derived
        XCTAssertTrue(reducerWithUnknown.apply(native))
        XCTAssertEqual(reducerWithUnknown.visibleAttentionRows.count, 1)
        XCTAssertEqual(reducerWithUnknown.aggregate, .running)
        XCTAssertFalse(try XCTUnwrap(reducerWithUnknown.sessions[native.sessionID]).seen)
    }
    func testMissingLocatorStartStopHasNoPublicAttentionOrPhantomWorking() throws {
        var reducer = StateReducer()
        XCTAssertTrue(reducer.apply(event(.started, at: 0)))
        let previous = reducer.sessions[sid]
        let end = stop()
        XCTAssertTrue(reducer.apply(end))
        let held = try XCTUnwrap(reducer.sessions[sid])
        XCTAssertEqual(held.state, .unknown)
        XCTAssertFalse(held.seen)
        XCTAssertEqual(held.unverifiedCodexCompletion?.originalState, .running)
        XCTAssertEqual(held.started, base)
        XCTAssertEqual(held.updated, base)
        XCTAssertEqual(reducer.aggregate, .neutral)
        XCTAssertTrue(reducer.visibleAttentionRows.isEmpty)
        XCTAssertFalse(NotificationCoordinator.isNewAttention(event: end, previous: previous, current: held))
        XCTAssertFalse(reducer.apply(end))
        XCTAssertEqual(try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer)).sessions[sid]?.unverifiedCodexCompletion, held.unverifiedCodexCompletion)
    }
    func testPendingQuestionAndVerifiedRunningAreNotEndedByUnverifiedStop() throws {
        var reducer = StateReducer()
        _ = reducer.apply(event(.started, at: 0))
        var session = try XCTUnwrap(reducer.sessions[sid]); session.pending = ["question"]; session.state = .waitingUser
        reducer = try registry([(sid, session)])
        XCTAssertTrue(reducer.apply(stop()))
        XCTAssertEqual(reducer.sessions[sid]?.pending, ["question"])
        XCTAssertEqual(reducer.aggregate, .waiting)
        XCTAssertEqual(reducer.visibleAttentionRows.count, 1)
        session.pending = []; session.state = .running; session.source = .cli
        reducer = try registry([(sid, session)])
        XCTAssertTrue(reducer.apply(stop(at: 3)))
        XCTAssertEqual(reducer.sessions[sid]?.state, .running)
    }
    @MainActor func testValidatedLifecyclePromotesHeldCompletionOnceUsingNativeClockAndNoSeen() throws {
        for host in [RuntimeHost.terminal, .vscode, .codexDesktop] {
            let (root, start, complete) = try rollout(host: host); defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(inspectNotificationPermission: false)
            var unknownStart = event(.started, at: 0); unknownStart.projectPath = root.path
            model.accept(unknownStart, historical: false)
            var unknownStop = stop(); unknownStop.projectPath = root.path
            model.accept(unknownStop, historical: false)
            XCTAssertEqual(model.aggregate, .neutral)
            model.accept(start, historical: true)
            model.accept(complete, historical: true)
            let final = try XCTUnwrap(model.sessions.first { $0.id == sid })
            XCTAssertEqual(final.state, .completed)
            XCTAssertEqual(final.updated, complete.at)
            XCTAssertEqual(final.started, start.at)
            XCTAssertEqual(final.runtime?.host, host)
            XCTAssertFalse(final.seen)
            XCTAssertNil(final.unverifiedCodexCompletion)
            XCTAssertEqual(model.aggregate, .completed)
            model.accept(complete, historical: false)
            XCTAssertEqual(model.sessions.first { $0.id == sid }?.updated, complete.at)
            XCTAssertFalse(model.sessions.first { $0.id == sid }!.seen)
        }
    }
    @MainActor func testExactCachedCLITurnCorroboratesMissingLocatorWithoutInheritedHostTrust() throws {
        let (root, start, _) = try rollout(); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(inspectNotificationPermission: false)
        model.accept(start, historical: false)
        var end = stop(); end.projectPath = root.path
        model.accept(end, historical: false)
        XCTAssertEqual(model.sessions.first { $0.id == sid }?.state, .completed)
        XCTAssertNil(model.sessions.first { $0.id == sid }?.unverifiedCodexCompletion)
        var reducer = StateReducer(); var guessed = event(.started, at: 0, source: .cli)
        guessed.runtime = start.runtime; guessed.projectPath = root.path
        _ = reducer.apply(guessed); _ = reducer.apply(end)
        XCTAssertEqual(reducer.sessions[sid]?.state, .running, "serialized host alone is not turn proof")
    }
    func testExactDesktopCompletionAligns36MillisecondCrossSecondRegistryStart() throws {
        let (root, start, complete) = try rollout(host: .codexDesktop, started: 0.964, completed: 262.477)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = Session(id: sid, turnID: "turn", source: .desktop, title: "QA", state: .completed,
            started: base.addingTimeInterval(1), updated: complete.at)
        session.fidelity = .derived; session.projectPath = root.path; session.runtime = complete.runtime
        var reducer = StateReducer(sessions: [sid: session])
        XCTAssertTrue(reducer.apply(complete))
        XCTAssertEqual(reducer.sessions[sid]?.started, start.at)
        XCTAssertEqual(reducer.sessions[sid]?.updated, session.updated)
        XCTAssertEqual(reducer.sessions[sid]?.seen, false)
        let wireReplay = try JSONDecoder().decode(CodexEvent.self, from: JSONEncoder().encode(complete))
        XCTAssertNil(wireReplay.codexNativeTurnProof)
        reducer = StateReducer(sessions: [sid: session]); _ = reducer.apply(wireReplay)
        XCTAssertEqual(reducer.sessions[sid]?.started, session.started, "wire identity alone cannot align the start")
        for mutation in ["turn", "root", "runtime", "source", "end", "seen", "pending", "changedRollout"] {
            var candidate = session
            switch mutation {
            case "turn": candidate.turnID = "other"
            case "root": candidate.projectPath = "/foreign"
            case "runtime": candidate.runtime = RuntimeMetadata(id: "codex-rollout:desktop:foreign", host: .codexDesktop)
            case "source": candidate.source = .cli
            case "end": candidate.updated = complete.at.addingTimeInterval(0.001)
            case "seen": candidate.seen = true
            case "pending": candidate.pending = ["question"]
            default:
                let file = root.appendingPathComponent("rollout-" + sid + ".jsonl")
                let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
                try handle.write(contentsOf: Data("\n".utf8)); try handle.close()
            }
            reducer = StateReducer(sessions: [sid: candidate]); _ = reducer.apply(complete)
            XCTAssertEqual(reducer.sessions[sid]?.started, candidate.started, mutation)
        }
    }
    func testVerifiedDesktopCompletionNormalizesOnlySameWholeSecondStart() throws {
        let (root, start, complete) = try rollout(host: .codexDesktop)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = Session(id: sid, turnID: "turn", source: .desktop, title: "QA", state: .running,
            started: base, updated: base)
        session.projectPath = root.path
        session.runtime = RuntimeMetadata(id: "hook:codex:fixture", host: .codexDesktop)
        for wrongStart in [false, true] {
            var candidate = session
            if wrongStart { candidate.started = base.addingTimeInterval(-1) }
            var reducer = StateReducer(sessions: [sid: candidate])
            XCTAssertTrue(reducer.apply(complete))
            XCTAssertEqual(reducer.sessions[sid]?.started, wrongStart ? candidate.started : start.at)
            XCTAssertEqual(reducer.sessions[sid]?.updated, complete.at)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions[sid]).seen)
        }
        session.pending = ["question"]; session.pendingKinds["question"] = .waitingUser
        var reducer = StateReducer(sessions: [sid: session]); _ = reducer.apply(complete)
        XCTAssertEqual(reducer.sessions[sid]?.started, base)
        XCTAssertEqual(reducer.sessions[sid]?.pending, [], "existing verified completion resolution remains unchanged")
    }
    func testForeignTurnRootFileMutationAndWireCannotPromote() throws {
        let (root, _, complete) = try rollout(); defer { try? FileManager.default.removeItem(at: root) }
        let proof = try XCTUnwrap(complete.codexNativeTurnProof)
        var foreign = complete; foreign.sessionID = UUID().uuidString
        XCTAssertFalse(proof.matches(foreign))
        foreign = complete; foreign.turnID = "other"; XCTAssertFalse(proof.matches(foreign))
        foreign = complete; foreign.projectPath = root.appendingPathComponent("other").path; XCTAssertFalse(proof.matches(foreign))
        var held = StateReducer()
        var mismatched = stop(); mismatched.projectPath = root.appendingPathComponent("other").path
        _ = held.apply(mismatched)
        XCTAssertFalse(held.apply(complete), "same SID and turn cannot promote a different recorded project")
        XCTAssertEqual(held.aggregate, .neutral)
        let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONEncoder().encode(complete))
        XCTAssertNil(decoded.codexNativeTurnProof)
        let file = root.appendingPathComponent("rollout-" + sid + ".jsonl")
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
        XCTAssertFalse(proof.matches(complete))
        var reducer = StateReducer(); _ = reducer.apply(event(.started, turn: "new", at: 4))
        XCTAssertFalse(reducer.apply(stop(turn: "turn")))
        XCTAssertEqual(reducer.sessions[sid]?.turnID, "new")
    }
    func testRefusalMigrationPreservesIdentityTimesSeenAndDoesNotTouchLegacyOrOtherProviders() throws {
        var reducer = StateReducer(); _ = reducer.apply(event(.started, at: 0)); _ = reducer.apply(event(.completed))
        var original = try XCTUnwrap(reducer.sessions[sid]); original.codexOriginObservation = CodexOriginObservation(stage: .missingLocator, locatorPresent: false)
        var legacy = original; legacy.codexOriginObservation = nil
        var claude = original; claude.provider = .claude
        reducer = try registry([(sid, original), ("legacy", legacy), ("claude", claude)])
        let now = Date()
        XCTAssertTrue(reducer.migrateUnverifiedCodexCompletions(at: now))
        let migrated = try XCTUnwrap(reducer.sessions[sid])
        XCTAssertEqual(migrated.id, original.id); XCTAssertEqual(migrated.turnID, original.turnID)
        XCTAssertEqual(migrated.started, original.started); XCTAssertEqual(migrated.updated, original.updated)
        XCTAssertFalse(migrated.seen); XCTAssertEqual(migrated.state, .unknown)
        XCTAssertEqual(reducer.sessions["legacy"]?.state, .completed)
        XCTAssertEqual(reducer.sessions["claude"]?.state, .completed)
        XCTAssertFalse(reducer.migrateUnverifiedCodexCompletions(at: now))
        XCTAssertTrue(reducer.expireUnverifiedCodexCompletions(at: now.addingTimeInterval(86_401)))
        XCTAssertNil(reducer.sessions[sid]?.unverifiedCodexCompletion)
        XCTAssertEqual(reducer.sessions[sid]?.state, .unknown)
        XCTAssertFalse(reducer.sessions[sid]!.seen)
        XCTAssertFalse(reducer.visibleAttentionRows.contains { $0.id == sid })
    }
    @MainActor func testPersistedObservationBootstrapPromotesWithoutSeenAndCapIsBounded() throws {
        let (root, _, complete) = try rollout(); defer { try? FileManager.default.removeItem(at: root) }
        var reducer = StateReducer()
        var end = stop(); end.projectPath = root.path
        XCTAssertTrue(reducer.apply(end))
        let state = root.appendingPathComponent("state.json")
        try JSONEncoder().encode(reducer).write(to: state)
        let model = AppModel(inspectNotificationPermission: false, stateURL: state)
        XCTAssertEqual(model.aggregate, .neutral)
        model.accept(complete, historical: true)
        let promoted = try XCTUnwrap(model.sessions.first { $0.id == sid })
        XCTAssertEqual(promoted.state, .completed)
        XCTAssertEqual(promoted.updated, complete.at)
        XCTAssertFalse(promoted.seen)
        XCTAssertNil(promoted.unverifiedCodexCompletion)
        for index in 0..<205 {
            var observation = stop(at: Double(index + 10)); observation.sessionID = UUID().uuidString
            _ = reducer.apply(observation)
        }
        XCTAssertLessThanOrEqual(reducer.sessions.count, 200)
        XCTAssertEqual(reducer.aggregate, .neutral)
        XCTAssertTrue(reducer.visibleAttentionRows.isEmpty)
    }

    @MainActor func testStartupMigratesOnlyRefusalBackedCompletedSnapshotBeforePresentation() throws {
        let (root, _, _) = try rollout(); defer { try? FileManager.default.removeItem(at: root) }
        var reducer = StateReducer(); _ = reducer.apply(event(.completed))
        var session = try XCTUnwrap(reducer.sessions[sid])
        session.codexOriginObservation = CodexOriginObservation(stage: .missingLocator, locatorPresent: false)
        reducer = try registry([(sid, session)])
        let state = root.appendingPathComponent("startup.json")
        try JSONEncoder().encode(reducer).write(to: state)
        let model = AppModel(inspectNotificationPermission: false, stateURL: state)
        XCTAssertEqual(model.aggregate, .neutral)
        XCTAssertTrue(model.sessions.isEmpty)
    }

    func testDelayedUnverifiedStopCannotHideNewerSameTurnActivityAcrossRestart() throws {
        var reducer = StateReducer()
        XCTAssertTrue(reducer.apply(event(.started, at: 0)))
        XCTAssertTrue(reducer.apply(event(.activity, at: 3)))
        let updated = try XCTUnwrap(reducer.sessions[sid]).updated
        for persisted in [false, true] {
            if persisted { reducer = try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer)) }
            XCTAssertFalse(reducer.apply(stop(at: 2)))
            XCTAssertEqual(reducer.sessions[sid]?.updated, updated)
            XCTAssertEqual(reducer.sessions[sid]?.state, .running)
            XCTAssertNil(reducer.sessions[sid]?.unverifiedCodexCompletion)
            XCTAssertEqual(reducer.aggregate, .running)
            XCTAssertEqual(reducer.visibleAttentionRows.count, 1)
        }
        XCTAssertTrue(reducer.apply(stop(at: 4)))
        XCTAssertEqual(reducer.sessions[sid]?.state, .unknown)
        XCTAssertEqual(reducer.sessions[sid]?.updated, updated)
        XCTAssertEqual(reducer.aggregate, .neutral)
        XCTAssertTrue(reducer.visibleAttentionRows.isEmpty)
    }

}
