import XCTest
import CoreGraphics
@testable import refik

final class ProjectFocusTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(first, second)
    }
    private func event(_ id: String, provider: Provider, kind: EventKind, path: String?, time: Double, turn: String = "turn") -> CodexEvent {
        var e = CodexEvent(sessionID: id, turnID: turn, requestID: kind == .userQuestionObserved ? "question" : nil,
            kind: kind, source: .unknown, title: "Same basename", at: Date(timeIntervalSince1970: time), id: UUID().uuidString)
        e.provider = provider; e.projectPath = path; return e
    }
    func testCanonicalIdentityResolvesSymlinkRepositoryRootAndLocalFileURLRejectsRemoteUnknown() throws {
        try fixture { first, second in
            let nested = first.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: first.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let link = second.appendingPathComponent("linked")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
            XCTAssertEqual(ProjectIdentity.canonical(link.path), first.resolvingSymlinksInPath().path)
            XCTAssertEqual(ProjectIdentity.canonical(nested.absoluteString), first.resolvingSymlinksInPath().path)
            XCTAssertEqual(ProjectIdentity.canonical("file://localhost" + nested.path), first.resolvingSymlinksInPath().path)
            for path in [nil, "first", "/", "file://remote" + nested.path, nested.path + "\n", "file:///tmp/%00", "/definitely/nonexistent/refik"] {
                XCTAssertNil(ProjectIdentity.canonical(path))
            }
        }
    }
    func testExactCurrentFocusAcknowledgesAllMatchingProvidersButNotOtherProjectsRunningOrQuestions() throws {
        try fixture { first, second in
            var reducer = StateReducer()
            for provider in [Provider.codex, .claude, .antigravity] {
                let id = provider.rawValue
                XCTAssertTrue(reducer.apply(event(id, provider: provider, kind: .started, path: first.path, time: 1)))
                XCTAssertTrue(reducer.apply(event(id, provider: provider, kind: .completed, path: first.path, time: 2)))
            }
            for (id, kind, path) in [("other", EventKind.completed, second.path), ("running", .started, first.path), ("waiting", .userQuestionObserved, first.path)] {
                _ = reducer.apply(event(id, provider: .claude, kind: .started, path: path, time: 1))
                if kind != .started { _ = reducer.apply(event(id, provider: .claude, kind: kind, path: path, time: 2)) }
            }
            var focus = ProjectFocusCorrelation()
            let path = try XCTUnwrap(focus.observe(ProjectFocusObservation(projectPath: first.path), at: Date(timeIntervalSince1970: 3)))
            XCTAssertTrue(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3)), "positive focus is sufficient at startup")
            for id in ["codex", "claude", "antigravity"] { XCTAssertEqual(reducer.sessions[id]?.seen, true) }
            for id in ["other", "running", "waiting"] { XCTAssertEqual(reducer.sessions[id]?.seen, false) }
            XCTAssertEqual(reducer.sessions["waiting"]?.state, .waitingUser)
            XCTAssertEqual(reducer.nativeDismissalHistory?.count, 3)
            XCTAssertEqual(Set(reducer.nativeDismissalHistory!.map(\.reason)), ["verified-project-focus"])
            XCTAssertFalse(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 4)))
            _ = reducer.apply(event("claude", provider: .claude, kind: .started, path: first.path, time: 5, turn: "new"))
            _ = reducer.apply(event("claude", provider: .claude, kind: .completed, path: first.path, time: 6, turn: "new"))
            XCTAssertTrue(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 7)), "new completion while still focused")
            XCTAssertEqual(reducer.nativeDismissalHistory?.count, 4)
        }
    }
    func testUnknownPathNeverUsesDisplayTitleAndNewTurnDoesNotInheritOldProject() throws {
        try fixture { first, second in
            var reducer = StateReducer()
            _ = reducer.apply(event("a", provider: .claude, kind: .started, path: first.path, time: 1))
            _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: first.path, time: 2))
            _ = reducer.apply(event("a", provider: .claude, kind: .started, path: nil, time: 3, turn: "new"))
            _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: nil, time: 4, turn: "new"))
            XCTAssertNil(reducer.sessions["a"]?.projectPath)
            XCTAssertFalse(reducer.dismissProject(ProjectIdentity.canonical(first.path)!, at: Date(timeIntervalSince1970: 5)))
            XCTAssertFalse(reducer.associateProject(event("a", provider: .claude, kind: .completed, path: second.path, time: 2, turn: "turn")))
            XCTAssertTrue(reducer.associateProject(event("a", provider: .claude, kind: .completed, path: second.path, time: 4, turn: "new")))
            XCTAssertFalse(reducer.dismissProject(ProjectIdentity.canonical(first.path)!, at: Date(timeIntervalSince1970: 5)))
            var focus = ProjectFocusCorrelation()
            XCTAssertNil(focus.observe(nil, at: Date()))
            XCTAssertNil(focus.observe(ProjectFocusObservation(projectPath: nil), at: Date()))
        }
    }
    private func window(_ id: Int, pid: Int = 99, title: String = "Cursor Agents", onScreen: Bool = true) -> [String: Any] {
        [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: 0,
         kCGWindowAlpha as String: 1, kCGWindowNumber as String: id,
         kCGWindowIsOnscreen as String: onScreen, kCGWindowName as String: title,
         kCGWindowBounds as String: CGRect(x: 0, y: 0, width: 900, height: 700).dictionaryRepresentation]
    }
    func testOrderedForegroundWindowIgnoresHiddenButNeverSkipsBlankTopWindow() throws {
        try fixture { first, second in
            let cursor = "com.todesktop.230313mzl4w4u92"
            let qa = window(13604, title: "\(first.path) — Cursor")
            let agents = window(13153)
            let hidden = window(14021, onScreen: false)
            let selected = try XCTUnwrap(ProjectFocusReader.foregroundWindow([hidden, qa, agents], appPID: 99))
            XCTAssertEqual(selected[kCGWindowNumber as String] as? Int, 13604)
            XCTAssertEqual(ProjectFocusReader.project(title: selected[kCGWindowName as String] as! String, bundleID: cursor), ProjectIdentity.canonical(first.path))
            let blankTop = try XCTUnwrap(ProjectFocusReader.foregroundWindow([agents, qa], appPID: 99))
            XCTAssertNil(ProjectFocusReader.project(title: blankTop[kCGWindowName as String] as! String, bundleID: cursor))
            let otherProject = window(2, title: "\(second.path) — Cursor")
            let twoProjects = try XCTUnwrap(ProjectFocusReader.foregroundWindow([otherProject, qa], appPID: 99))
            XCTAssertEqual(ProjectFocusReader.project(title: twoProjects[kCGWindowName as String] as! String, bundleID: cursor), ProjectIdentity.canonical(second.path))
            XCTAssertNil(ProjectFocusReader.foregroundWindow([window(3, pid: 100), qa], appPID: 99))
            XCTAssertNil(ProjectFocusReader.foregroundWindow([qa], appPID: 0))
            var noTitle = qa; noTitle.removeValue(forKey: kCGWindowName as String)
            let unavailable = try XCTUnwrap(ProjectFocusReader.foregroundWindow([noTitle, agents], appPID: 99))
            XCTAssertNil((unavailable[kCGWindowName as String] as? String).flatMap { ProjectFocusReader.project(title: $0, bundleID: cursor) })
        }
    }
    func testMalformedForemostWindowFailsClosedInsteadOfSelectingUnderlyingProject() {
        let valid = window(2)
        for key in [kCGWindowOwnerPID, kCGWindowLayer, kCGWindowAlpha, kCGWindowNumber, kCGWindowBounds, kCGWindowIsOnscreen] {
            var malformed = window(1); malformed.removeValue(forKey: key as String)
            XCTAssertNil(ProjectFocusReader.foregroundWindow([malformed, valid], appPID: 99), key as String)
        }
        for bounds in [CGRect.zero, CGRect(x: 0, y: 0, width: -1, height: 700), CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 700)] {
            var malformed = window(1); malformed[kCGWindowBounds as String] = bounds.dictionaryRepresentation
            XCTAssertNil(ProjectFocusReader.foregroundWindow([malformed, valid], appPID: 99))
        }
        var badAlpha = window(1); badAlpha[kCGWindowAlpha as String] = Double.nan
        XCTAssertNil(ProjectFocusReader.foregroundWindow([badAlpha, valid], appPID: 99))
        for (key, value) in [(kCGWindowOwnerPID, 99.5), (kCGWindowLayer, 0.5), (kCGWindowNumber, 1.5), (kCGWindowIsOnscreen, 2.0)] {
            var malformed = window(1); malformed[key as String] = value
            XCTAssertNil(ProjectFocusReader.foregroundWindow([malformed, valid], appPID: 99))
        }
        var badID = window(1); badID[kCGWindowNumber as String] = 0
        XCTAssertNil(ProjectFocusReader.foregroundWindow([badID, valid], appPID: 99))
    }
    func testReadableCursorTitleRequiresExactFullDirectoryAndCursorSuffix() throws {
        try fixture { first, second in
            let cursor = "com.todesktop.230313mzl4w4u92"
            let expected = ProjectIdentity.canonical(first.path)
            XCTAssertEqual(ProjectFocusReader.project(title: "fixture.txt — \(first.path) — Cursor", bundleID: cursor), expected)
            XCTAssertEqual(ProjectFocusReader.project(title: "\(first.path) — Cursor", bundleID: cursor), expected)
            XCTAssertEqual(ProjectFocusReader.project(title: "REFIK_PROJECT[\(first.path)]REFIK_END", bundleID: cursor), expected)
            XCTAssertNil(ProjectFocusReader.project(title: "fixture.txt — \(first.path) — Cursor", bundleID: "com.microsoft.VSCode"))
            let workspace = second.appendingPathComponent("many.code-workspace")
            try Data("{}".utf8).write(to: workspace)
            for title in ["first — Cursor", "fixture.txt — first — Cursor", "\(first.path) — Code",
                          "\(first.path) — \(second.path) — Cursor", "a — b — \(first.path) — Cursor",
                          "\(workspace.path) — Cursor", "file://remote\(first.path) — Cursor",
                          "\(first.path)\n — Cursor", "\(first.path)/missing — Cursor"] {
                XCTAssertNil(ProjectFocusReader.project(title: title, bundleID: cursor), title)
            }
            var reducer = StateReducer()
            _ = reducer.apply(event("cursor-qa", provider: .cursor, kind: .started, path: first.path, time: 1))
            _ = reducer.apply(event("cursor-qa", provider: .cursor, kind: .completed, path: first.path, time: 2))
            _ = reducer.apply(event("other-cursor", provider: .cursor, kind: .started, path: second.path, time: 1))
            _ = reducer.apply(event("other-cursor", provider: .cursor, kind: .completed, path: second.path, time: 2))
            let path = try XCTUnwrap(ProjectFocusReader.project(title: "fixture.txt — \(first.path) — Cursor", bundleID: cursor))
            XCTAssertTrue(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3)))
            XCTAssertEqual(reducer.sessions["cursor-qa"]?.seen, true)
            XCTAssertEqual(reducer.sessions["other-cursor"]?.seen, false)
        }
    }
    func testTerminalProofRequiresOneCompleteDescendantTTYAndForegroundGroup() {
        let app: Int32 = 50
        let shell = ForegroundTerminalProcess(pid: 51, parent: app, group: 51, foregroundGroup: 52, tty: "ttys001")
        let claude = ForegroundTerminalProcess(pid: 52, parent: 51, group: 52, foregroundGroup: 52, tty: "ttys001")
        XCTAssertEqual(TerminalProjectProof.foregroundPIDs(appPID: app, processes: [shell, claude]), [52])
        let second = ForegroundTerminalProcess(pid: 53, parent: app, group: 53, foregroundGroup: 53, tty: "ttys002")
        XCTAssertNil(TerminalProjectProof.foregroundPIDs(appPID: app, processes: [shell, claude, second]))
        XCTAssertNil(TerminalProjectProof.foregroundPIDs(appPID: app, processes: [shell]))
        XCTAssertNil(TerminalProjectProof.foregroundPIDs(appPID: 100, processes: [shell, claude]))
    }
    func testReparentedForegroundPeerIsIncludedAndConflictingOrMissingCwdKeepsAttention() throws {
        try fixture { first, second in
            let shell = ForegroundTerminalProcess(pid: 51, parent: 50, group: 51, foregroundGroup: 52, tty: "ttys001")
            let child = ForegroundTerminalProcess(pid: 52, parent: 51, group: 52, foregroundGroup: 52, tty: "ttys001")
            let peer = ForegroundTerminalProcess(pid: 53, parent: 1, group: 52, foregroundGroup: 52, tty: "ttys001")
            let processes = [shell, child, peer]
            XCTAssertEqual(TerminalProjectProof.foregroundPIDs(appPID: 50, processes: processes), [52, 53])
            let valid = TerminalProjectProof.snapshot(appPID: 50, processes: processes) { _ in first.path }
            XCTAssertEqual(valid?.members.count, 2)
            for missing in [false, true] {
                let proof = TerminalProjectProof.snapshot(appPID: 50, processes: processes) { $0 == 53 ? (missing ? nil : second.path) : first.path }
                XCTAssertNil(proof)
                var reducer = StateReducer()
                _ = reducer.apply(event("a", provider: .claude, kind: .started, path: first.path, time: 1))
                _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: first.path, time: 2))
                if let path = TerminalProjectProof.confirmedProject(valid, proof) { _ = reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3)) }
                XCTAssertEqual(reducer.sessions["a"]?.seen, false)
            }
        }
    }
    func testFullTerminalRecheckRejectsSamePIDCwdChangeLateTTYAndGroupChange() throws {
        try fixture { first, second in
            let shell = ForegroundTerminalProcess(pid: 51, parent: 50, group: 51, foregroundGroup: 51, tty: "ttys001")
            let initial = TerminalProjectProof.snapshot(appPID: 50, processes: [shell]) { _ in first.path }
            let changedCwd = TerminalProjectProof.snapshot(appPID: 50, processes: [shell]) { _ in second.path }
            let secondTTY = ForegroundTerminalProcess(pid: 52, parent: 50, group: 52, foregroundGroup: 52, tty: "ttys002")
            let changedGroup = ForegroundTerminalProcess(pid: 51, parent: 50, group: 99, foregroundGroup: 99, tty: "ttys001")
            let lateTTY = TerminalProjectProof.snapshot(appPID: 50, processes: [shell, secondTTY]) { _ in first.path }
            let lateGroup = TerminalProjectProof.snapshot(appPID: 50, processes: [changedGroup]) { _ in first.path }
            XCTAssertNotNil(initial)
            XCTAssertEqual(TerminalProjectProof.confirmedProject(initial, initial), ProjectIdentity.canonical(first.path))
            for changed in [changedCwd, lateTTY, lateGroup] {
                XCTAssertNil(TerminalProjectProof.confirmedProject(initial, changed))
                var reducer = StateReducer()
                _ = reducer.apply(event("a", provider: .claude, kind: .started, path: first.path, time: 1))
                _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: first.path, time: 2))
                if let path = TerminalProjectProof.confirmedProject(initial, changed) { _ = reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3)) }
                XCTAssertEqual(reducer.sessions["a"]?.seen, false)
            }
        }
    }
    func testPositiveProofCannotAcknowledgeCompletionAfterItsObservationOrStaleClock() throws {
        try fixture { first, _ in
            var reducer = StateReducer()
            _ = reducer.apply(event("a", provider: .claude, kind: .started, path: first.path, time: 1))
            _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: first.path, time: 2))
            let path = ProjectIdentity.canonical(first.path)!
            XCTAssertFalse(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3), observedAt: Date(timeIntervalSince1970: 1.5)))
            XCTAssertFalse(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 6), observedAt: Date(timeIntervalSince1970: 3)))
            XCTAssertFalse(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3), observedAt: Date(timeIntervalSince1970: 4)))
            XCTAssertEqual(reducer.sessions["a"]?.seen, false)
            XCTAssertTrue(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 3), observedAt: Date(timeIntervalSince1970: 2.5)))
            _ = reducer.apply(event("a", provider: .claude, kind: .started, path: first.path, time: 4, turn: "new"))
            _ = reducer.apply(event("a", provider: .claude, kind: .completed, path: first.path, time: 5, turn: "new"))
            XCTAssertFalse(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 5.5), observedAt: Date(timeIntervalSince1970: 4.5)))
            XCTAssertEqual(reducer.sessions["a"]?.seen, false)
            XCTAssertTrue(reducer.dismissProject(path, at: Date(timeIntervalSince1970: 6), observedAt: Date(timeIntervalSince1970: 5.5)))
        }
    }
    @MainActor func testLegacyNilProjectBackfillsExactDuplicateMetadataWithoutChangingOutcome() throws {
        try fixture { first, second in
            var reducer = StateReducer()
            let start = event("old", provider: .claude, kind: .started, path: nil, time: 1)
            var completed = event("old", provider: .claude, kind: .completed, path: nil, time: 2)
            _ = reducer.apply(start); _ = reducer.apply(completed)
            let url = first.appendingPathComponent("legacy.json")
            try JSONEncoder().encode(reducer).write(to: url)
            let app = AppModel(inspectNotificationPermission: false, stateURL: url)
            var wrong = completed; wrong.turnID = "other"; wrong.projectPath = second.path
            app.accept(wrong, historical: false)
            var saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
            XCTAssertNil(saved.sessions["old"]?.projectPath)
            completed.projectPath = first.path
            app.accept(completed, historical: true)
            saved = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
            XCTAssertEqual(saved.sessions["old"]?.projectPath, ProjectIdentity.canonical(first.path))
            XCTAssertEqual(saved.sessions["old"]?.state, .completed)
            XCTAssertEqual(saved.sessions["old"]?.updated, Date(timeIntervalSince1970: 2))
            XCTAssertEqual(saved.sessions["old"]?.seen, false)
            XCTAssertEqual(app.aggregate, .completed)
            app.dismissProject(ProjectIdentity.canonical(first.path)!, at: Date(timeIntervalSince1970: 3))
            XCTAssertEqual(app.aggregate, .neutral)
        }
    }
    @MainActor func testProjectDismissalCommitFailurePreservesAttentionAndSuccessfulCommitRetainsOutcome() throws {
        try fixture { first, _ in
            let bad = first.appendingPathComponent("directory")
            try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
            let app = AppModel(inspectNotificationPermission: false, stateURL: bad)
            app.accept(event("a", provider: .claude, kind: .started, path: first.path, time: 1), historical: false)
            app.accept(event("a", provider: .claude, kind: .completed, path: first.path, time: 2), historical: false)
            app.dismissProject(ProjectIdentity.canonical(first.path)!, at: Date(timeIntervalSince1970: 3))
            XCTAssertEqual(app.sessions.first { $0.id == "a" }?.seen, false)
            let url = first.appendingPathComponent("state.json"), good = AppModel(inspectNotificationPermission: false, stateURL: url)
            good.accept(event("a", provider: .claude, kind: .started, path: first.path, time: 1), historical: false)
            good.accept(event("a", provider: .claude, kind: .completed, path: first.path, time: 2), historical: false)
            good.dismissProject(ProjectIdentity.canonical(first.path)!, at: Date(timeIntervalSince1970: 3))
            let restored = AppModel(inspectNotificationPermission: false, stateURL: url)
            XCTAssertEqual(restored.aggregate, .neutral)
            XCTAssertEqual(try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url)).sessions["a"]?.seen, true)
            XCTAssertEqual(try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url)).nativeDismissalHistory?.first?.session.seen, false)
        }
    }
}
