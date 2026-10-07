import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class CodexHookOriginTests: XCTestCase {
    private let session = "01a10505-88e2-7e32-a501-c60b2215d50f"
    private let parent = "01a08671-ed27-7ba3-b946-3a602b2e4fad"
    private let helper = URL(fileURLWithPath: "/owned/refikHook")
    private let bundled = URL(fileURLWithPath: "/bundle/refikHook")
    private final class Source {
        var time: Double = 100
        var trusted = true
        var path = "/owned/refikHook"
        var operations: AntigravityTerminalOrigin.Operations {
            .init(peer: { _ in 10 }, process: { _ in .init(pid: 10, parent: 11, uid: getuid(), seconds: 1, micros: 2, path: self.path) },
                  file: { _ in nil }, signed: { _, _, _ in false }, helperMatches: { _, _ in self.trusted }, now: { self.time })
        }
    }
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let sessions = root.appendingPathComponent("sessions"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try body(sessions, project, sessions.appendingPathComponent("rollout-" + session + ".jsonl"))
    }
    private func header(_ file: URL, project: URL, source: Any = "vscode", origin: String = "codex_work_desktop", id: String? = nil, extra: [String: Any] = [:]) throws {
        var payload: [String: Any] = ["id": id ?? session, "cwd": project.path, "source": source, "originator": origin, "cli_version": "0.159.2"]
        payload.merge(extra) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "timestamp": "2026-10-04T03:51:00.000Z", "payload": payload])
        try (data + Data([10])).write(to: file); _ = chmod(file.path, 0o600)
    }
    private func event(_ project: URL, file: URL?) -> CodexEvent {
        CodexEvent(sessionID: session, turnID: "turn", requestID: nil, kind: .completed,
                   source: .unknown, title: "QA", at: Date(timeIntervalSince1970: 100), id: UUID().uuidString,
                   provider: .codex, projectPath: project.path, transcriptPath: file?.path,
                   runtime: RuntimeMetadata(id: "hook:codex:bundled-cli", host: .unknown, version: "0.159.2"))
    }
    private func binding(_ source: Source, event: CodexEvent, root: URL) -> CodexHookOrigin.Binding? {
        CodexHookOrigin.validate(CodexHookOrigin.capturePublisher(0, helper: helper, operations: source.operations),
            event: event, helper: helper, bundledHelper: bundled, roots: [root], operations: source.operations)
    }
    func testDiagnosticReportsFiniteMissingLocatorAndValidatedBindingWithoutChangingAdmission() throws {
        try fixture { root, project, file in
            let source = Source(); try header(file, project: project)
            var stages: [HookOriginDiagnostic.Stage] = []
            let publisher = CodexHookOrigin.capturePublisher(0, helper: helper, operations: source.operations)
            XCTAssertNil(CodexHookOrigin.validate(publisher, event: event(project, file: nil), helper: helper, bundledHelper: bundled,
                roots: [root], operations: source.operations, diagnostic: { stages.append($0) }))
            XCTAssertNotNil(CodexHookOrigin.validate(publisher, event: event(project, file: file), helper: helper, bundledHelper: bundled,
                roots: [root], operations: source.operations, diagnostic: { stages.append($0) }))
            XCTAssertEqual(stages, [.missingLocator, .desktopBound])
        }
    }
    func testValidatedDesktopHeaderEnablesExistingUnreadReconciliationOnlyForExactSession() throws {
        try fixture { root, project, file in
            try header(file, project: project)
            let source = Source(); var current = event(project, file: file)
            let proof = try XCTUnwrap(binding(source, event: current, root: root))
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &current, now: source.time))
            XCTAssertEqual(current.source, .desktop); XCTAssertEqual(current.runtime?.host, .codexDesktop)
            var other = event(project, file: nil); other.sessionID = parent
            var reducer = StateReducer(); _ = reducer.apply(current); _ = reducer.apply(other)
            let native = try XCTUnwrap(reducer.sessions[session]), unknown = try XCTUnwrap(reducer.sessions[parent])
            let sampled = current.at.addingTimeInterval(1)
            let context = NativeAttentionContext(identity: "fixture", host: "local", authGeneration: sampled, expires: sampled.addingTimeInterval(10))
            let snapshot = NativeAttentionSnapshot(context: context, unread: [], observedAt: sampled)
            let observations = NativeAttentionMirror.observations(snapshot, completions: [NativeCompletion(native), NativeCompletion(unknown)], at: sampled)
            XCTAssertTrue(reducer.reconcileProviderAttention(observations, at: sampled))
            XCTAssertNotNil(reducer.sessions[session]?.providerAttention)
            XCTAssertNil(reducer.sessions[parent]?.providerAttention)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions[session]).seen)
            XCTAssertFalse(try XCTUnwrap(reducer.sessions[parent]).seen)
        }
    }
    func testKnownIDECLIAndConflictingOriginClassificationPreservesProvider() throws {
        try fixture { root, project, file in
            let source = Source()
            for (declared, origin, expected) in [("vscode", "codex_vscode", RuntimeHost.vscode), ("cli", "codex-tui", .terminal), ("exec", "codex_work_desktop", .terminal)] {
                try header(file, project: project, source: declared, origin: origin)
                var value = event(project, file: file)
                let proof = try XCTUnwrap(binding(source, event: value, root: root))
                XCTAssertTrue(CodexHookOrigin.apply(proof, to: &value, now: source.time))
                XCTAssertEqual(value.runtime?.host, expected); XCTAssertEqual(value.provider, .codex)
            }
            try header(file, project: project, origin: "unknown-origin")
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            try header(file, project: project, source: "cli", origin: "codex_vscode")
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
        }
    }
    func testMissingLocatorUntrustedPeerForeignRootUUIDAndCwdReject() throws {
        try fixture { root, project, file in
            let source = Source(); try header(file, project: project)
            XCTAssertNil(binding(source, event: event(project, file: nil), root: root))
            source.path = "/foreign/helper"
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            source.path = helper.path; source.trusted = false
            XCTAssertNil(binding(source, event: event(project, file: file), root: root)); source.trusted = true
            XCTAssertNil(binding(source, event: event(project, file: file), root: project))
            try header(file, project: project, id: parent)
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            try header(file, project: root)
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
        }
    }
    func testOnlyExplicitValidatedThreadSpawnParentSuppressesChildWithoutParentMutation() throws {
        try fixture { root, project, file in
            let source = Source()
            try header(file, project: project, source: ["subagent": ["thread_spawn": ["parent_thread_id": parent, "depth": 1]]])
            var child = event(project, file: file)
            let proof = try XCTUnwrap(binding(source, event: child, root: root))
            XCTAssertEqual(proof.parentSessionID, parent)
            XCTAssertFalse(CodexHookOrigin.apply(proof, to: &child, now: source.time))
            XCTAssertEqual(child.source, .unknown)
            try header(file, project: project, source: ["subagent": ["thread_spawn": ["parent_thread_id": "not-a-uuid"]]])
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            try header(file, project: project, source: ["subagent": "unknown-shape"])
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            try header(file, project: project, extra: ["parent_thread_id": parent])
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
        }
    }
    func testValidatedChildAppendAndQueueExpiryStaySuppressedButForeignIdentityDoesNot() throws {
        try fixture { root, project, file in
            let source = Source()
            try header(file, project: project, source: ["subagent": ["thread_spawn": ["parent_thread_id": parent]]])
            let child = event(project, file: file)
            let proof = try XCTUnwrap(binding(source, event: child, root: root))
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
            var current = child
            XCTAssertFalse(CodexHookOrigin.apply(proof, to: &current, now: source.time + 30))
            var reducer = StateReducer()
            XCTAssertTrue(reducer.apply(CodexEvent(sessionID: parent, turnID: "parent-turn", requestID: nil, kind: .started,
                source: .desktop, title: "QA", at: child.at, id: "parent-start")))
            if CodexHookOrigin.apply(proof, to: &current, now: source.time + 30) { _ = reducer.apply(current) }
            XCTAssertEqual(reducer.sessions[parent]?.state, .running); XCTAssertEqual(reducer.sessions[parent]?.seen, false)
            XCTAssertNil(reducer.sessions[session])
            var foreign = child; foreign.sessionID = parent
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time + 30))
            foreign = child; foreign.turnID = "new-turn"
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time))
            foreign = child; foreign.projectPath = root.path
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time))
            foreign = child; foreign.runtime = RuntimeMetadata(id: "foreign-runtime", host: .unknown)
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time))
            XCTAssertEqual(current.source, .unknown)
        }
    }
    func testVerifiedReplayEnrichesUnknownOriginWithoutChangingTerminalGenerationAndWireCannotForgeProof() throws {
        try fixture { root, project, file in
            let source = Source(); try header(file, project: project)
            var reducer = StateReducer(); let original = event(project, file: nil)
            XCTAssertTrue(reducer.apply(original))
            let first = try XCTUnwrap(reducer.sessions[session])
            var enriched = event(project, file: file)
            let binding = try XCTUnwrap(self.binding(source, event: enriched, root: root))
            XCTAssertTrue(CodexHookOrigin.apply(binding, to: &enriched, now: source.time))
            XCTAssertTrue(reducer.apply(enriched))
            let upgraded = try XCTUnwrap(reducer.sessions[session])
            XCTAssertEqual(upgraded.runtime?.host, .codexDesktop); XCTAssertEqual(upgraded.source, .desktop)
            XCTAssertEqual(upgraded.updated, first.updated); XCTAssertEqual(upgraded.started, first.started)
            XCTAssertEqual(upgraded.turnID, first.turnID); XCTAssertEqual(upgraded.seen, first.seen)
            var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(enriched)) as! [String: Any]
            XCTAssertNil(raw["verifiedCodexOriginHost"])
            raw["verifiedCodexOriginHost"] = "codexDesktop"
            let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: raw))
            XCTAssertNil(decoded.verifiedCodexOriginHost)
            var forged = StateReducer(); XCTAssertTrue(forged.apply(original))
            XCTAssertFalse(forged.apply(decoded)); XCTAssertEqual(forged.sessions[session]?.source, .unknown)
        }
    }
    func testSymlinkWritableOversizedIncompleteAndNonHeaderFileReject() throws {
        try fixture { root, project, file in
            let source = Source(); try header(file, project: project)
            let link = root.appendingPathComponent("alias-" + session + ".jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            XCTAssertNil(binding(source, event: event(project, file: link), root: root))
            _ = chmod(file.path, 0o622)
            XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            _ = chmod(file.path, 0o600)
            for bytes in [Data(repeating: 65, count: 256 * 1024 + 2), Data("{}".utf8), Data("{}\n".utf8)] {
                try bytes.write(to: file)
                XCTAssertNil(binding(source, event: event(project, file: file), root: root))
            }
        }
    }
    func testReplacementAndQueueExpiryCannotCommitStaleClassification() throws {
        try fixture { root, project, file in
            let source = Source(); try header(file, project: project)
            var value = event(project, file: file)
            let proof = try XCTUnwrap(binding(source, event: value, root: root))
            var foreign = value; foreign.sessionID = parent
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time))
            XCTAssertEqual(foreign.source, .unknown)
            foreign = value; foreign.turnID = "foreign-turn"
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &foreign, now: source.time))
            XCTAssertEqual(foreign.source, .unknown)
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &value, now: 104))
            XCTAssertEqual(value.source, .unknown)
            try header(file, project: project, origin: "codex_vscode")
            XCTAssertTrue(CodexHookOrigin.apply(proof, to: &value, now: 100))
            XCTAssertEqual(value.runtime?.host, .unknown)
        }
    }
}
