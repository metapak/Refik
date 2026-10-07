import XCTest
@testable import refik

final class NativeAttentionMirrorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1000)
    private func event(_ kind: EventKind, turn: String = "turn", at time: Double, provider: Provider = .codex) -> CodexEvent {
        CodexEvent(sessionID: "a", turnID: turn, requestID: nil, kind: kind, source: .desktop,
                   title: "project", at: Date(timeIntervalSince1970: time), id: "\(turn):\(kind):\(time)", provider: provider)
    }
    private func reducer(provider: Provider = .codex) -> StateReducer {
        var result = StateReducer()
        _ = result.apply(event(.started, at: 800, provider: provider))
        _ = result.apply(event(.completed, at: 900, provider: provider))
        return result
    }
    private func snapshot(_ unread: Set<String>, identity: String = "opaque-account-hash", host: String = "opaque-local-host-hash",
                          auth: Double = 1, expiry: Double = 2000, sampled: Double = 1000) -> NativeAttentionSnapshot {
        NativeAttentionSnapshot(context: NativeAttentionContext(identity: identity, host: host,
            authGeneration: Date(timeIntervalSince1970: auth), expires: Date(timeIntervalSince1970: expiry)),
            unread: unread, observedAt: Date(timeIntervalSince1970: sampled))
    }
    private func observations(_ snapshot: NativeAttentionSnapshot?, reducer: StateReducer, at date: Date? = nil) -> [ProviderAttentionObservation] {
        NativeAttentionMirror.observations(snapshot, completions: reducer.providerAttentionCandidates.map(NativeCompletion.init), at: date ?? now)
    }
    private func fullSuppressedRegistry() -> StateReducer {
        var state = StateReducer()
        for index in 0..<200 {
            let id = "s\(index)"
            _ = state.apply(CodexEvent(sessionID: id, turnID: "turn", requestID: nil, kind: .started, source: .desktop,
                title: id, at: Date(timeIntervalSince1970: 100), id: "start-\(id)"))
            _ = state.apply(CodexEvent(sessionID: id, turnID: "turn", requestID: nil, kind: .completed, source: .desktop,
                title: id, at: Date(timeIntervalSince1970: 700 + Double(index)), id: "done-\(id)"))
        }
        _ = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now)
        return state
    }
    private func incomingStart(_ id: String = "incoming", turn: String = "new", time: Double = 1001) -> CodexEvent {
        CodexEvent(sessionID: id, turnID: turn, requestID: nil, kind: .started, source: .desktop,
            title: id, at: Date(timeIntervalSince1970: time), id: "start-\(id)-\(turn)")
    }
    func testDesktopMirrorCannotSuppressIDEOrUnknownOriginAndPreservesDesktop() throws {
        for host in [RuntimeHost.vscode, .unknown, .codexDesktop] {
            var state = StateReducer()
            for (kind, time) in [(EventKind.started, 800.0), (.completed, 900.0)] {
                var item = event(kind, at: time)
                item.runtime = RuntimeMetadata(id: "fixture", host: host)
                _ = state.apply(item)
            }
            let changed = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now)
            XCTAssertEqual(changed, host == .codexDesktop)
            XCTAssertEqual(state.sessions["a"]?.requestsResultAttention, host != .codexDesktop)
            XCTAssertEqual(state.sessions["a"]?.seen, false)
        }
        var legacy = completionSessionForMirror()
        XCTAssertTrue(legacy.supportsDesktopNativeAttention)
        legacy.editorOriginEvidence = .codexVSCodeRollout
        XCTAssertFalse(legacy.supportsDesktopNativeAttention)
        legacy.providerAttention = ProviderAttentionDisposition(turn: legacy.turnID, completed: legacy.updated,
            authority: "old-desktop-mirror", suppressedAt: now)
        XCTAssertTrue(legacy.requestsResultAttention, "old IDE suppression cannot hide a result after restart")
        legacy.editorOriginEvidence = nil
        legacy.verifiedEditorHost = "com.microsoft.VSCode"
        XCTAssertFalse(legacy.supportsDesktopNativeAttention)
    }
    private func completionSessionForMirror() -> Session {
        reducer().sessions["a"]!
    }
    func testEvictedIncorrectIDEMirrorRecoveryIsVisibleWithoutSeenAndCannotResurrect() throws {
        // Manufacture the persisted older-version disposition, not production events.
        var old = reducer()
        _ = old.reconcileProviderAttention(observations(snapshot([]), reducer: old), at: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["sessions"] = [:] as [String: Any]
        var history = try XCTUnwrap(object["nativeDismissalHistory"] as? [[String: Any]])
        var outcome = try XCTUnwrap(history[0]["session"] as? [String: Any])
        outcome["runtime"] = ["id": "rollout", "host": "vscode"]
        history[0]["session"] = outcome
        object["nativeDismissalHistory"] = history
        func reload(_ value: [String: Any]) throws -> StateReducer {
            var restored = try JSONDecoder().decode(StateReducer.self, from: JSONSerialization.data(withJSONObject: value))
            restored.markHistoricalRunningUnknown()
            return restored
        }
        let restored = try reload(object)
        XCTAssertEqual(restored.sessions["a"]?.seen, false)
        XCTAssertNil(restored.sessions["a"]?.providerAttention)
        XCTAssertEqual(restored.visibleAttentionRows.map(\.id), ["a"])
        XCTAssertEqual(restored.aggregate, .completed)

        var newer = reducer()
        _ = newer.apply(incomingStart("a", turn: "new"))
        var blocked = object
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(newer)) as? [String: Any])
        blocked["sessions"] = encoded["sessions"]
        XCTAssertEqual(try reload(blocked).sessions["a"]?.turnID, "new")

        var dismissed = object
        history[0]["providerAttention"] = nil
        dismissed["nativeDismissalHistory"] = history
        XCTAssertNil(try reload(dismissed).sessions["a"])

        var full = StateReducer()
        for i in 0..<200 { _ = full.apply(incomingStart("busy-\(i)", time: 1001 + Double(i))) }
        let fullObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        var capacity = object; capacity["sessions"] = fullObject["sessions"]
        let limited = try reload(capacity)
        XCTAssertEqual(limited.sessions.count, 200)
        XCTAssertNil(limited.sessions["a"], "active working slots cannot be displaced by recovery")
    }
    func testFullSuppressedRegistryAcceptsNewWorkAndEvictedResultRearmsFromBoundedArchive() throws {
        var state = fullSuppressedRegistry()
        XCTAssertEqual(state.sessions.count, 200); XCTAssertEqual(state.nativeDismissalHistory?.count, 100)
        XCTAssertEqual(state.aggregate, .neutral)
        XCTAssertTrue(state.apply(incomingStart()))
        XCTAssertNil(state.sessions["s0"]); XCTAssertEqual(state.sessions["incoming"]?.state, .running)
        let retained = try XCTUnwrap(state.providerAttentionCandidates.first(where: { $0.id == "s0" }))
        XCTAssertEqual(retained.turnID, "turn"); XCTAssertEqual(retained.updated, Date(timeIntervalSince1970: 700))
        XCTAssertEqual(retained.seen, false); XCTAssertNotNil(retained.providerAttention)
        let at = Date(timeIntervalSince1970: 1002)
        let sample = snapshot(["s0"], sampled: 1002)
        XCTAssertTrue(state.reconcileProviderAttention(observations(sample, reducer: state, at: at), at: at))
        XCTAssertEqual(state.sessions["s0"]?.state, .completed); XCTAssertNil(state.sessions["s0"]?.providerAttention)
        XCTAssertEqual(state.aggregate, .completed); XCTAssertEqual(state.sessions["incoming"]?.state, .running)
        XCTAssertEqual(state.sessions.count, 200); XCTAssertEqual(state.nativeDismissalHistory?.count, 100)
    }
    func testEvictedManualAcknowledgmentAndNewTurnNeverResurrectOldArchive() {
        for manual in [true, false] {
            var state = fullSuppressedRegistry()
            _ = state.apply(incomingStart())
            let old = observations(snapshot(["s0"], sampled: 1002), reducer: state, at: Date(timeIntervalSince1970: 1002))
            if manual { state.markSeen(["s0"]) }
            else { XCTAssertTrue(state.apply(incomingStart("s0", turn: "new-turn", time: 1002))) }
            XCTAssertFalse(state.reconcileProviderAttention(old, at: Date(timeIntervalSince1970: 1002)))
            XCTAssertFalse(state.providerAttentionCandidates.contains { $0.id == "s0" && $0.turnID == "turn" })
            XCTAssertFalse(state.apply(CodexEvent(sessionID: "s0", turnID: "turn", requestID: nil, kind: .completed,
                source: .desktop, title: nil, at: Date(timeIntervalSince1970: 700), id: "stale-replay")))
            if !manual { XCTAssertEqual(state.sessions["s0"]?.turnID, "new-turn"); XCTAssertEqual(state.sessions["s0"]?.state, .running) }
        }
    }
    @MainActor func testCapacityArchiveFailurePreservesFullWorkingStateUntilStorageCanCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state")
        let initial = fullSuppressedRegistry()
        try JSONEncoder().encode(initial).write(to: url)
        let model = AppModel(inspectNotificationPermission: false, stateURL: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        model.accept(incomingStart(), historical: false)
        XCTAssertEqual(model.aggregate, .neutral); XCTAssertFalse(model.sessions.contains { $0.id == "incoming" })
        try FileManager.default.removeItem(at: url)
        model.accept(incomingStart(), historical: false)
        XCTAssertEqual(model.aggregate, .running); XCTAssertTrue(model.sessions.contains { $0.id == "incoming" })
        let saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.sessions.count, 200); XCTAssertNil(saved.sessions["s0"])
        XCTAssertTrue(saved.providerAttentionCandidates.contains { $0.id == "s0" })
        XCTAssertEqual(saved.nativeDismissalHistory?.count, 100)
    }
    func testInitialAbsenceDelayedUnreadAndRemovalMirrorSameGenerationWithoutSeenOrDuplicateArchive() throws {
        var state = reducer()
        XCTAssertTrue(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
        XCTAssertEqual(state.aggregate, .neutral); XCTAssertTrue(state.visibleAttentionRows.isEmpty)
        XCTAssertEqual(state.sessions["a"]?.seen, false)
        XCTAssertEqual(state.nativeDismissalHistory?.first?.reason, "provider-not-requesting-attention")
        XCTAssertEqual(state.nativeDismissalHistory?.first?.session.state, .completed)
        XCTAssertNil(state.nativeDismissalHistory?.first?.session.providerAttention)
        XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
        XCTAssertTrue(state.reconcileProviderAttention(observations(snapshot(["a"]), reducer: state), at: now))
        XCTAssertEqual(state.aggregate, .completed); XCTAssertEqual(state.visibleAttentionRows.count, 1)
        XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot(["a"]), reducer: state), at: now))
        XCTAssertTrue(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
        XCTAssertEqual(state.nativeDismissalHistory?.count, 1)
        XCTAssertEqual(state.sessions["a"]?.updated, Date(timeIntervalSince1970: 900))
    }
    func testManualAcknowledgmentIsStickyAndNeverRearmed() {
        for initiallySuppressed in [true, false] {
            var state = reducer()
            if initiallySuppressed { _ = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now) }
            state.markSeen(["a"])
            XCTAssertNil(state.sessions["a"]?.providerAttention)
            for unread: Set<String> in [[], ["a"], []] {
                XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot(unread), reducer: state), at: now))
                XCTAssertEqual(state.sessions["a"]?.seen, true); XCTAssertEqual(state.aggregate, .neutral)
            }
        }
    }
    func testChangedAuthorityAndUnavailableExpiredOrStaleSamplesCannotChangeDisposition() {
        var state = reducer()
        _ = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now)
        let original = state.sessions["a"]?.providerAttention
        for changed in [snapshot(["a"], identity: "other"), snapshot(["a"], host: "other"), snapshot(["a"], auth: 2)] {
            XCTAssertFalse(state.reconcileProviderAttention(observations(changed, reducer: state), at: now))
            XCTAssertEqual(state.sessions["a"]?.providerAttention, original)
        }
        for invalid in [nil, snapshot(["a"], expiry: 1000), snapshot(["a"], sampled: 997), snapshot(["a"], sampled: 1001)] {
            XCTAssertTrue(observations(invalid, reducer: state).isEmpty)
            XCTAssertFalse(state.reconcileProviderAttention(observations(invalid, reducer: state), at: now))
        }
        XCTAssertTrue(state.reconcileProviderAttention(observations(snapshot(["a"]), reducer: state), at: now))
    }
    func testNewTurnInvalidatesSuppressionAndQueuedOldObservationCannotSuppressOrRestore() {
        var state = reducer()
        let oldAbsence = observations(snapshot([]), reducer: state)
        let oldUnread = observations(snapshot(["a"]), reducer: state)
        _ = state.reconcileProviderAttention(oldAbsence, at: now)
        XCTAssertTrue(state.apply(event(.started, turn: "new", at: 1001)))
        XCTAssertNil(state.sessions["a"]?.providerAttention)
        XCTAssertFalse(state.reconcileProviderAttention(oldUnread, at: now))
        XCTAssertFalse(state.reconcileProviderAttention(oldAbsence, at: now))
        XCTAssertEqual(state.aggregate, .running)
        _ = state.apply(event(.completed, turn: "new", at: 1002))
        XCTAssertFalse(state.reconcileProviderAttention(oldAbsence, at: now))
        XCTAssertEqual(state.aggregate, .completed)
    }
    func testPendingRunningAndOtherProvidersPreserveAttention() {
        for provider in [Provider.claude, .antigravity] {
            var state = reducer(provider: provider)
            XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
            XCTAssertEqual(state.aggregate, .completed)
        }
        var state = StateReducer()
        _ = state.apply(event(.started, at: 800))
        XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
        _ = state.apply(CodexEvent(sessionID: "a", turnID: "turn", requestID: "q", kind: .userQuestionObserved,
            source: .desktop, title: nil, at: Date(timeIntervalSince1970: 900), id: "question"))
        XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now))
        XCTAssertEqual(state.aggregate, .waiting)
    }
    func testSuppressedResultLeavesOtherRunningAndYellowPrioritiesAndFooterIntact() {
        var state = reducer()
        _ = state.apply(CodexEvent(sessionID: "b", turnID: "work", requestID: nil, kind: .started,
            source: .desktop, title: nil, at: Date(timeIntervalSince1970: 950), id: "work"))
        _ = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now)
        XCTAssertEqual(state.aggregate, .running); XCTAssertEqual(state.visibleAttentionRows.map(\.id), ["b"])
        XCTAssertEqual(state.attentionFooter, "1 çalışıyor")
        _ = state.apply(CodexEvent(sessionID: "b", turnID: "work", requestID: "q", kind: .userQuestionObserved,
            source: .desktop, title: nil, at: Date(timeIntervalSince1970: 960), id: "q"))
        XCTAssertEqual(state.aggregate, .waiting); XCTAssertEqual(state.attentionFooter, "1 bekliyor")
        _ = state.reconcileProviderAttention(observations(snapshot(["a"]), reducer: state), at: now)
        XCTAssertEqual(state.aggregate, .waiting); XCTAssertEqual(state.visibleAttentionRows.count, 2)
        XCTAssertEqual(state.attentionFooter, "1 bekliyor · 1 yeni sonuç")
    }
    func testSnapshotMustFollowCompletionAndReducerRechecksExactGeneration() {
        var state = reducer()
        XCTAssertTrue(observations(snapshot([], sampled: 900), reducer: state).isEmpty)
        let completion = NativeCompletion(thread: "a", turn: "wrong", completed: Date(timeIntervalSince1970: 900))
        XCTAssertFalse(state.reconcileProviderAttention([ProviderAttentionObservation(completion: completion,
            requestsAttention: false, authority: snapshot([]).context.authority, observedAt: now)], at: now))
        let wrongTime = NativeCompletion(thread: "a", turn: "turn", completed: Date(timeIntervalSince1970: 901))
        XCTAssertFalse(state.reconcileProviderAttention([ProviderAttentionObservation(completion: wrongTime,
            requestsAttention: false, authority: snapshot([]).context.authority, observedAt: now)], at: now))
        XCTAssertFalse(state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now.addingTimeInterval(3)))
        XCTAssertEqual(state.aggregate, .completed)
    }
    func testSuppressionArchiveRestartRestoresOnlyExactAuthorityAndDoesNotPersistCredentials() throws {
        var state = reducer()
        _ = state.reconcileProviderAttention(observations(snapshot([]), reducer: state), at: now)
        let data = try JSONEncoder().encode(state)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("opaque-account-hash")); XCTAssertFalse(text.contains("opaque-local-host-hash"))
        XCTAssertFalse(text.contains("access_token")); XCTAssertFalse(text.contains("authGeneration"))
        var restored = try JSONDecoder().decode(StateReducer.self, from: data)
        XCTAssertEqual(restored.aggregate, .neutral); XCTAssertEqual(restored.sessions["a"]?.seen, false)
        XCTAssertEqual(restored.nativeDismissalHistory?.count, 1)
        XCTAssertFalse(restored.reconcileProviderAttention(observations(snapshot(["a"], identity: "other"), reducer: restored), at: now))
        XCTAssertTrue(restored.reconcileProviderAttention(observations(snapshot(["a"]), reducer: restored), at: now))
        XCTAssertEqual(restored.aggregate, .completed)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sessions = try XCTUnwrap(legacy["sessions"] as? [String: [String: Any]])
        sessions["a"]?.removeValue(forKey: "providerAttention"); legacy["sessions"] = sessions
        let old = try JSONDecoder().decode(StateReducer.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.sessions["a"]?.providerAttention); XCTAssertEqual(old.aggregate, .completed)
    }
    @MainActor func testAtomicCommitFailurePreservesGreenAndSuccessfulCommitRecoversMirror() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("not-directory")
        try Data().write(to: blocked)
        let failed = AppModel(inspectNotificationPermission: false, stateURL: blocked.appendingPathComponent("state"))
        failed.accept(event(.started, at: 800), historical: false); failed.accept(event(.completed, at: 900), historical: false)
        let suppress = observations(snapshot([]), reducer: reducer())
        failed.reconcileProviderAttention(suppress, at: now)
        XCTAssertEqual(failed.aggregate, .completed)
        let url = root.appendingPathComponent("state")
        let model = AppModel(inspectNotificationPermission: false, stateURL: url)
        model.accept(event(.started, at: 800), historical: false); model.accept(event(.completed, at: 900), historical: false)
        model.reconcileProviderAttention(suppress, at: now)
        XCTAssertEqual(model.aggregate, .neutral)
        let restarted = AppModel(inspectNotificationPermission: false, stateURL: url)
        XCTAssertEqual(restarted.aggregate, .neutral)
        restarted.reconcileProviderAttention(observations(snapshot(["a"]), reducer: reducer()), at: now)
        XCTAssertEqual(restarted.aggregate, .completed)
        let saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.nativeDismissalHistory?.count, 1); XCTAssertEqual(saved.sessions["a"]?.seen, false)
    }
}
