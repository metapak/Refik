import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class EditorFocusTests: XCTestCase {
    let host = EditorHostBinding(bundleID: "com.todesktop.230313mzl4w4u92", pid: 99, launchSeconds: 10, launchMicros: 20)
    func fixture(_ body: (URL, URL) throws -> Void) throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), second = first.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: first) }; try body(first, second)
    }
    func observation(_ window: String, _ generation: String, _ sequence: UInt64, focused: Bool = true, root: String? = "/tmp") -> EditorFocusObservation {
        EditorFocusObservation(windowID: window, generation: generation, sequence: sequence, focused: focused, projectPath: focused ? root : nil)
    }
    func event(_ id: String, kind: EventKind, path: String, time: Double, host: String?, turn: String = "turn") -> CodexEvent {
        var e = CodexEvent(sessionID: id, turnID: turn, requestID: nil, kind: kind, source: .cli, title: "QA", at: Date(timeIntervalSince1970: time), id: UUID().uuidString)
        e.provider = .claude; e.projectPath = path; e.verifiedEditorHost = host; return e
    }
    func testLeaseBlurDisconnectReplayAndRetiredEpochCannotOverwriteReplacement() throws {
        try fixture { first, _ in
            let receiver = EditorFocusReceiver(), window = UUID().uuidString, gen = UUID().uuidString, a = UUID().uuidString, b = UUID().uuidString
            func send(_ epoch: String, _ seq: UInt64, _ focused: Bool = true) { receiver.receive(epoch: epoch, host: host, observation: observation(window, gen, seq, focused: focused, root: first.path), at: 10, date: Date(timeIntervalSince1970: 10)) }
            func proof(_ now: Double = 11) -> Bool {receiver.withProof(at: now, foreground: {_ in true}, currentHost: {_ in true}) {_ in true}}
            send(a, 1); XCTAssertTrue(proof()); XCTAssertFalse(proof(15)); XCTAssertFalse(proof(9))
            send(a, 2, false); send(a, 1); XCTAssertFalse(proof(), "replay must not restore focus")
            send(a, 3); send(b, 4); send(a, 5, false); XCTAssertTrue(proof(), "old epoch cannot blur its replacement")
            receiver.receive(epoch: a, host: host, observation: nil, at: 11, date: Date(timeIntervalSince1970: 10)); XCTAssertTrue(proof())
            send(b, 5, false); XCTAssertFalse(proof()); send(b, 6); XCTAssertTrue(proof())
            receiver.receive(epoch: b, host: host, observation: nil, at: 11, date: Date(timeIntervalSince1970: 10)); XCTAssertFalse(proof())
        }
    }
    func testOverlappingWindowsHostForegroundLaunchAndCanonicalFailuresRefuseProof() throws {
        try fixture { first, second in
            let receiver = EditorFocusReceiver(), epoch = UUID().uuidString, other = UUID().uuidString
            receiver.receive(epoch: epoch, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: first.path), at: 10, date: Date(timeIntervalSince1970: 10))
            XCTAssertFalse(receiver.withProof(at: 11, foreground: {_ in false}, currentHost: {_ in true}) {_ in XCTFail(); return true})
            XCTAssertFalse(receiver.withProof(at: 11, foreground: {_ in true}, currentHost: {_ in false}) {_ in XCTFail(); return true})
            receiver.receive(epoch: other, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: second.path), at: 10, date: Date(timeIntervalSince1970: 10))
            XCTAssertFalse(receiver.withProof(at: 11, foreground: {_ in true}, currentHost: {_ in true}) {_ in XCTFail(); return true})
            receiver.reset()
            receiver.receive(epoch: epoch, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: first.appendingPathComponent("missing").path), at: 10, date: Date(timeIntervalSince1970: 10))
            XCTAssertFalse(receiver.withProof(at: 11, foreground: {_ in true}, currentHost: {_ in true}) {_ in XCTFail(); return true})
        }
    }
    func testFreshProofAcknowledgesOnlyVerifiedStableHostExactProjectTerminalGenerationWithoutLegacyTitle() throws {
        try fixture { first, second in
            let link = first.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
            var reducer = StateReducer()
            for (id, root, origin) in [("real-claude", second.path, host.bundleID as String?), ("unknown", second.path, nil), ("other-project", first.path, host.bundleID), ("other-host", second.path, "com.microsoft.VSCode")] {
                _ = reducer.apply(event(id, kind: .started, path: root, time: 1, host: origin)); _ = reducer.apply(event(id, kind: .completed, path: root, time: 2, host: origin))
            }
            let receiver = EditorFocusReceiver(), window = UUID().uuidString, generation = UUID().uuidString, epoch = UUID().uuidString
            let legacyProof: ProjectFocusObservation? = nil
            XCTAssertNil(legacyProof)
            receiver.receive(epoch: epoch, host: host, observation: observation(window, generation, 1, root: link.path), at: 3, date: Date(timeIntervalSince1970: 3))
            XCTAssertTrue(receiver.withProof(at: 3, foreground: {_ in true}, currentHost: {_ in true}) { proof in
                reducer.dismissProject(proof.project, at: Date(timeIntervalSince1970: 3), observedAt: proof.observedAt, editorHost: proof.host.bundleID)
            })
            XCTAssertEqual(reducer.sessions["real-claude"]?.provider, .claude)
            XCTAssertEqual(reducer.sessions["real-claude"]?.seen, true)
            for id in ["unknown", "other-project", "other-host"] {XCTAssertEqual(reducer.sessions[id]?.seen, false)}
            XCTAssertEqual(reducer.nativeDismissalHistory?.first?.reason, "verified-editor-focus")
            _ = reducer.apply(event("real-claude", kind: .started, path: second.path, time: 4, host: host.bundleID, turn: "new"))
            _ = reducer.apply(event("real-claude", kind: .completed, path: second.path, time: 5, host: host.bundleID, turn: "new"))
            XCTAssertFalse(receiver.withProof(at: 5, foreground: {_ in true}, currentHost: {_ in true}) { proof in
                reducer.dismissProject(proof.project, at: Date(timeIntervalSince1970: 5), observedAt: proof.observedAt, editorHost: proof.host.bundleID)
            }, "proof predating the new completion must not acknowledge it")
            receiver.receive(epoch: epoch, host: host, observation: observation(window, generation, 2, root: link.path), at: 6, date: Date(timeIntervalSince1970: 6))
            XCTAssertTrue(receiver.withProof(at: 6, foreground: {_ in true}, currentHost: {_ in true}) { proof in reducer.dismissProject(proof.project, at: Date(timeIntervalSince1970: 6), observedAt: proof.observedAt, editorHost: proof.host.bundleID) })
            let loaded = try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer))
            XCTAssertEqual(loaded.sessions["real-claude"]?.verifiedEditorHost, host.bundleID)
            XCTAssertEqual(loaded.nativeDismissalHistory?.count, 2)
        }
    }
    func testFocusedWindowsInOtherNativeHostsDoNotBlockVerifiedForegroundHost() throws {
        try fixture { root, _ in
            let receiver = EditorFocusReceiver(), epoch = UUID().uuidString
            let other = EditorHostBinding(bundleID: "com.microsoft.VSCode", pid: 100, launchSeconds: 11, launchMicros: 20)
            receiver.receive(epoch: epoch, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: root.path), at: 3, date: Date(timeIntervalSince1970: 3))
            receiver.receive(epoch: UUID().uuidString, host: other, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: root.path), at: 3, date: Date(timeIntervalSince1970: 3))
            XCTAssertTrue(receiver.withProof(at: 3, foreground: {$0 == self.host}, currentHost: {_ in true}) { $0.host == self.host })
            XCTAssertTrue(receiver.withProof(at: 3, foreground: {$0 == other}, currentHost: {_ in true}) { $0.host == other })
            XCTAssertFalse(receiver.withProof(at: 3, foreground: {_ in false}, currentHost: {_ in true}) {_ in XCTFail(); return true})
            XCTAssertFalse(receiver.withProof(at: 3, foreground: {$0 == self.host}, currentHost: {_ in false}) {_ in XCTFail(); return true})
            receiver.receive(epoch: UUID().uuidString, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: root.path), at: 3, date: Date(timeIntervalSince1970: 3))
            XCTAssertFalse(receiver.withProof(at: 3, foreground: {$0 == self.host}, currentHost: {_ in true}) {_ in XCTFail("same foreground host still has ambiguous windows"); return true})
        }
    }
    func testForegroundAndLaunchAreRecheckedBeforeCommitAndDiagnosticIsAfterUnlock() throws {
        try fixture { root, _ in
            let receiver = EditorFocusReceiver()
            receiver.receive(epoch: UUID().uuidString, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: root.path), at: 3, date: Date(timeIntervalSince1970: 3))
            var checks = 0, reported = false
            XCTAssertFalse(receiver.withProof(at: 3, foreground: {_ in checks += 1; return checks == 1}, currentHost: {_ in true}, diagnose: { snapshot in
                XCTAssertTrue(receiver.hasConnection)
                XCTAssertEqual(snapshot.reason, "foreground-or-launch-changed"); reported = true
            }) {_ in XCTFail("foreground changed before commit"); return true})
            XCTAssertTrue(reported)
            checks = 0
            XCTAssertFalse(receiver.withProof(at: 3, foreground: {_ in true}, currentHost: {_ in checks += 1; return checks == 1}) {_ in XCTFail("launch changed before commit"); return true})
        }
    }
    func testOptInDiagnosticIsDefaultOffBoundedPrivateAndContainsOnlyTypedMetadata() throws {
        try fixture { root, project in
            let environment = ["REFIK_EDITOR_FOCUS_DIAGNOSTIC_SESSION": UUID().uuidString, "REFIK_EDITOR_FOCUS_DIAGNOSTIC_HOST": "com.todesktop.230313mzl4w4u92", "REFIK_EDITOR_FOCUS_DIAGNOSTIC_ROOT": project.path]
            let output = root.appendingPathComponent("diagnostic.jsonl")
            let record = EditorFocusDiagnostic.Record(receiver: .init(), cursorForeground: false, qaTerminal: true, qaOriginMatches: true, qaProjectMatches: true, qaEligible: false, candidateProjectMatches: false, qaSeen: false)
            EditorFocusDiagnostic(enabled: false, output: output, started: 10, environment: environment, qaRoot: root.path).record(record, at: 11)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            let logger = EditorFocusDiagnostic(enabled: true, output: output, started: 10, environment: environment, qaRoot: root.path)
            logger.record(record, at: 9)
            for i in 0..<65 { logger.record(record, at: 10 + Double(i * 2)); logger.record(record, at: 10 + Double(i * 2) + 0.1) }
            let bytes = try Data(contentsOf: output), lines = String(decoding: bytes, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(lines.count, 60)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            for forbidden in ["projectPath", "sessionID", "turnID", "token", "prompt", "title", "body", "password"] { XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("\"" + forbidden + "\"")) }
            let link = root.appendingPathComponent("symlink.jsonl")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: output)
            EditorFocusDiagnostic(enabled: true, output: link, started: 10, environment: environment, qaRoot: root.path).record(record, at: 11)
            XCTAssertEqual(try Data(contentsOf: output), bytes)
        }
    }
    func testDiagnosticTargetRejectsPartialForeignUnsafeAndNonfiniteParameters() throws {
        try fixture { root, project in
            let keys = ["REFIK_EDITOR_FOCUS_DIAGNOSTIC_SESSION", "REFIK_EDITOR_FOCUS_DIAGNOSTIC_HOST", "REFIK_EDITOR_FOCUS_DIAGNOSTIC_ROOT"]
            let environment = [keys[0]: "01a0ffd6-b269-75a0-84d7-6f012ef9c235", keys[1]: "com.microsoft.VSCode", keys[2]: project.path]
            XCTAssertNotNil(EditorFocusDiagnostic.Target(environment: environment, qaRoot: root.path))
            XCTAssertNil(EditorFocusDiagnostic.Target(environment: [:], qaRoot: root.appendingPathComponent("missing").path))
            // Default allowlist still refuses a private fixture outside its fixed QA root.
            XCTAssertNil(EditorFocusDiagnostic.Target(environment: environment))
            let cursor = root.appendingPathComponent("cursor")
            try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: false)
            XCTAssertEqual(EditorFocusDiagnostic.Target(environment: [:], qaRoot: root.path)?.host, "com.todesktop.230313mzl4w4u92")
            for (key, value) in [(keys[0], "invalid"), (keys[1], "unknown.host"), (keys[2], "/workspace/sample-user"), (keys[2], "file://remote/qa")] {
                var invalid = environment; invalid[key] = value
                XCTAssertNil(EditorFocusDiagnostic.Target(environment: invalid, qaRoot: root.path))
                XCTAssertFalse(EditorFocusDiagnostic(enabled: true, started: 10, environment: invalid, qaRoot: root.path).enabled)
            }
            XCTAssertNil(EditorFocusDiagnostic.Target(environment: [keys[0]: environment[keys[0]]!], qaRoot: root.path))
            XCTAssertFalse(EditorFocusDiagnostic(enabled: true, started: .nan, environment: environment, qaRoot: root.path).enabled)
            XCTAssertFalse(EditorFocusDiagnostic(enabled: false, started: 10, environment: environment, qaRoot: root.path).enabled)
            let file = root.appendingPathComponent("target.jsonl")
            let logger = EditorFocusDiagnostic(enabled: true, output: file, started: 10, environment: environment, qaRoot: root.path)
            var record = EditorFocusDiagnostic.Record(receiver: .init(), cursorForeground: false, qaTerminal: true, qaOriginMatches: true, qaProjectMatches: true, qaEligible: true, candidateProjectMatches: true, qaSeen: false)
            record.foregroundHostMatch = true; record.leaseFresh = true; record.generationMatch = true
            logger.record(record, at: 11)
            logger.record(record, at: .infinity); logger.record(record, at: 130)
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(text.split(separator: "\n").count, 1)
            for value in environment.values { XCTAssertFalse(text.contains(value)) }
            XCTAssertTrue(text.contains("foregroundHostMatch")); XCTAssertTrue(text.contains("commitResult"))
        }
    }
    func testNormalizedNativeReceiversPreserveVerifiedOriginThroughReducerEligibilityAndAck() throws {
        try fixture { root, _ in
            for provider in [Provider.copilot, .antigravity] {
                let bundle = provider == .copilot ? "com.microsoft.VSCode" : "com.google.antigravity-ide"
                let binding = EditorHostBinding(bundleID: bundle, pid: 99, launchSeconds: 10, launchMicros: 20)
                for origin in [bundle as String?, nil, "foreign.editor"] {
                    var reducer = StateReducer(), vscode = VSCodeHookReceiver(), ag = AntigravityHookReceiver()
                    for terminal in [false, true] {
                        var input = event("unused", kind: terminal ? .completed : .activity, path: root.path, time: terminal ? 2 : 1, host: origin)
                        input.provider = provider; input.sessionID = provider == .copilot ? "copilot:session" : "antigravity:conversation"
                        input.runtime = RuntimeMetadata(id: "native-runtime", host: provider == .copilot ? .vscode : .unknown, version: "1")
                        let events: [CodexEvent]
                        if provider == .copilot {
                            let payload: [String: Any] = ["phase": terminal ? "Stop" : "UserPromptSubmit", "sessionID": "session"]
                            let observation = try JSONDecoder().decode(VSCodeHookObservation.self, from: JSONSerialization.data(withJSONObject: payload))
                            events = vscode.events(input, observation: observation)
                        } else {
                            let payload: [String: Any] = ["phase": terminal ? "Stop" : "PreInvocation", "conversationID": "conversation", "invocationNum": 0, "fullyIdle": true, "hasError": false]
                            let observation = try JSONDecoder().decode(AntigravityHookObservation.self, from: JSONSerialization.data(withJSONObject: payload))
                            events = ag.events(input, observation: observation)
                        }
                        XCTAssertFalse(events.isEmpty)
                        for normalized in events { XCTAssertEqual(normalized.verifiedEditorHost, origin); _ = reducer.apply(normalized) }
                    }
                    var eligibility = EditorFocusEligibility(); eligibility.observe(reducer, at: 3)
                    let receiver = EditorFocusReceiver()
                    receiver.receive(epoch: UUID().uuidString, host: binding, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: root.path), at: 4, date: Date(timeIntervalSince1970: 4))
                    let acknowledged = receiver.withProof(at: 4, foreground: {_ in true}, currentHost: {_ in true}) { proof in
                        reducer.dismissProject(proof.project, at: Date(timeIntervalSince1970: 4), observedAt: proof.observedAt, editorHost: proof.host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: proof.issuedMonotonic))
                    }
                    XCTAssertEqual(acknowledged, origin == bundle)
                    XCTAssertEqual(reducer.sessions.values.first?.seen, origin == bundle)
                    XCTAssertEqual(reducer.sessions.values.first?.provider, provider)
                }
            }
        }
    }
    func testRootChangeRevokesOldProjectBeforeDelayedFreshProof() throws {
        try fixture { a, b in
            let receiver = EditorFocusReceiver(), epoch = UUID().uuidString, window = UUID().uuidString, gen = UUID().uuidString
            receiver.receive(epoch: epoch, host: host, observation: observation(window, gen, 1, root: a.path), at: 3, date: Date(timeIntervalSince1970: 3))
            XCTAssertTrue(receiver.withProof(at: 3, foreground: {_ in true}, currentHost: {_ in true}) {$0.project == a.path})
            receiver.receive(epoch: epoch, host: host, observation: observation(window, gen, 2, focused: false), at: 4, date: Date(timeIntervalSince1970: 4))
            XCTAssertFalse(receiver.withProof(at: 4, foreground: {_ in true}, currentHost: {_ in true}) {_ in XCTFail("old A cannot acknowledge during the delayed challenge"); return true})
            receiver.receive(epoch: epoch, host: host, observation: observation(window, gen, 3, root: b.path), at: 5, date: Date(timeIntervalSince1970: 5))
            XCTAssertTrue(receiver.withProof(at: 5, foreground: {_ in true}, currentHost: {_ in true}) {$0.project == b.path})
        }
    }
    func testManagedEditorNeverInvokesLegacyReaderAndNotificationRunsAfterLeaseUnlock() throws {
        try fixture { first, _ in
            let receiver = EditorFocusReceiver(), epoch = UUID().uuidString
            receiver.receive(epoch: epoch, host: host, observation: observation(UUID().uuidString, UUID().uuidString, 1, root: first.path), at: 3, date: Date(timeIntervalSince1970: 3))
            var legacyCalls = 0, notifications = 0
            let managed: Set<String> = [host.bundleID]
            if EditorFocusReceiver.permitsLegacyReader(foregroundBundleID: host.bundleID, managedHosts: managed) { legacyCalls += 1 }
            XCTAssertEqual(legacyCalls, 0)
            XCTAssertTrue(receiver.acknowledge(at: 3, foreground: {_ in true}, currentHost: {_ in true}, commit: {_ in true}, afterCommit: {
                XCTAssertTrue(receiver.hasConnection, "reacquiring the lease lock after commit must be safe")
                notifications += 1
            }))
            XCTAssertEqual(notifications, 1)
            receiver.receive(epoch: epoch, host: host, observation: nil, at: 4, date: Date())
            XCTAssertFalse(EditorFocusReceiver.permitsLegacyReader(foregroundBundleID: host.bundleID, managedHosts: managed), "disconnect must not quietly enable the title fallback")
            XCTAssertTrue(EditorFocusReceiver.permitsLegacyReader(foregroundBundleID: "com.apple.Terminal", managedHosts: managed))
            XCTAssertFalse(EditorFocusReceiver.permitsLegacyReader(foregroundBundleID: nil, managedHosts: managed))
        }
    }
    func testNewTurnDoesNotInheritOriginAndExactLiveHookBackfillDoesNotAlterOutcome() throws {
        try fixture { first, _ in
            var reducer = StateReducer()
            _ = reducer.apply(event("qa", kind: .started, path: first.path, time: 1, host: host.bundleID))
            _ = reducer.apply(event("qa", kind: .completed, path: first.path, time: 2, host: host.bundleID))
            _ = reducer.apply(event("qa", kind: .started, path: first.path, time: 3, host: nil, turn: "next"))
            _ = reducer.apply(event("qa", kind: .completed, path: first.path, time: 4, host: nil, turn: "next"))
            XCTAssertNil(reducer.sessions["qa"]?.verifiedEditorHost)
            XCTAssertFalse(reducer.associateEditorHost(event("qa", kind: .completed, path: first.path, time: 4, host: host.bundleID)))
            XCTAssertTrue(reducer.associateEditorHost(event("qa", kind: .completed, path: first.path, time: 4, host: host.bundleID, turn: "next")))
            XCTAssertEqual(reducer.sessions["qa"]?.state, .completed); XCTAssertEqual(reducer.sessions["qa"]?.seen, false)
        }
    }
    func testCompletionEligibilityUsesReceiverMonotonicBoundaryAndExactGenerationNotWallClock() throws {
        try fixture { root, _ in
            var reducer = StateReducer(), eligibility = EditorFocusEligibility()
            _ = reducer.apply(event("qa", kind: .started, path: root.path, time: 1, host: host.bundleID))
            _ = reducer.apply(event("qa", kind: .completed, path: root.path, time: 2, host: host.bundleID))
            eligibility.observe(reducer, at: 20)
            XCTAssertFalse(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 100), observedAt: Date(timeIntervalSince1970: 100), editorHost: host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: 19)), "even a future wall-clock proof cannot predate completion eligibility")
            let previous = eligibility.eligible(afterChallenge: 21)
            _ = reducer.apply(event("qa", kind: .started, path: root.path, time: 3, host: host.bundleID, turn: "new"))
            _ = reducer.apply(event("qa", kind: .completed, path: root.path, time: 4, host: host.bundleID, turn: "new"))
            eligibility.observe(reducer, at: 22)
            XCTAssertFalse(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 100), observedAt: Date(timeIntervalSince1970: 100), editorHost: host.bundleID, eligibleEditorGenerations: previous))
            XCTAssertTrue(eligibility.eligible(afterChallenge: 22).isEmpty)
            XCTAssertTrue(reducer.dismissProject(root.path, at: Date(timeIntervalSince1970: 100), observedAt: Date(timeIntervalSince1970: 100), editorHost: host.bundleID, eligibleEditorGenerations: eligibility.eligible(afterChallenge: 23)))
        }
    }
    func testServerChallengeSingleUseReplacementExpiryAndCompletionTimeBoundary() {
        var gate = EditorFocusChallengeGate()
        let first = gate.issue(at: 10, date: Date(timeIntervalSince1970: 10))
        XCTAssertNil(gate.consume("forged", at: 11)); XCTAssertNil(gate.consume(first, at: 9))
        XCTAssertEqual(gate.consume(first, at: 11)?.issued, 10); XCTAssertNil(gate.consume(first, at: 11))
        let old = gate.issue(at: 12, date: Date(timeIntervalSince1970: 12))
        let replacement = gate.issue(at: 13, date: Date(timeIntervalSince1970: 13))
        XCTAssertNil(gate.consume(old, at: 13)); XCTAssertEqual(gate.consume(replacement, at: 14)?.date, Date(timeIntervalSince1970: 13))
        let expired = gate.issue(at: 15, date: Date(timeIntervalSince1970: 15))
        XCTAssertNil(gate.consume(expired, at: 18))
    }
    func testObservationRejectsAmbiguousMalformedFieldsAndNonHelperPeerCannotClaimNativeHost() {
        XCTAssertFalse(EditorFocusObservation(windowID: "fake", generation: UUID().uuidString, sequence: 1, focused: true, projectPath: "/tmp").isValid)
        XCTAssertFalse(observation(UUID().uuidString, UUID().uuidString, 0).isValid)
        XCTAssertFalse(EditorFocusObservation(windowID: UUID().uuidString, generation: UUID().uuidString, sequence: 1, focused: false, projectPath: "/tmp").isValid)
        XCTAssertFalse(observation(UUID().uuidString, UUID().uuidString, 1, root: "/tmp\n").isValid)
        var pair = [Int32](repeating: -1, count: 2); XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[0]); close(pair[1]) }
        XCTAssertNil(EditorFocusHost.peer(pair[0], helper: URL(fileURLWithPath: "/untrusted/refikHook"), bundledHelper: URL(fileURLWithPath: "/untrusted/refikHook")))
    }
    func testPassiveHelperReceiptHandshakeRemainsBoundedAndPreservesPayloadAndOutput() throws {
        try fixture { root, _ in
            let candidates = [".build/out/Products/Debug/refikHook", ".build/debug/refikHook"]
            let helper = try XCTUnwrap(candidates.map { URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent($0) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
            let socketURL = root.appendingPathComponent("events.sock")
            let listener = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(listener, 0)
            defer { close(listener) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketURL.path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { p in p.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in for (i,b) in bytes.enumerated() {chars[i] = CChar(bitPattern:b)}; chars[bytes.count] = 0 } }
            XCTAssertEqual(withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
            XCTAssertEqual(chmod(socketURL.path, 0o600), 0); XCTAssertEqual(listen(listener, 1), 0)
            let delivered = expectation(description: "supported helper receipt protocol")
            DispatchQueue.global().async {
                let peer = accept(listener, nil, nil); guard peer >= 0 else { XCTFail(); return }
                defer { close(peer) }; HookWire.timeout(peer, seconds: 2)
                guard let payload = HookWire.receive(peer, requireNewline: true, deadline: HookWire.uptime + 2),
                      let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { XCTFail(); return }
                XCTAssertEqual(object["sessionID"] as? String, "claude:receipt-qa")
                XCTAssertEqual(object["kind"] as? String, "sessionEnded")
                XCTAssertTrue(HookWire.send(HookFrame(type: "origin-captured"), fd: peer))
                XCTAssertNil(HookWire.receive(peer, deadline: HookWire.uptime + 2), "helper closes after bounded receipt without extra payload")
                delivered.fulfill()
            }
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = helper; process.arguments = ["claude", "Stop"]
            process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "REFIK_DATA_DIR": root.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(#"{"session_id":"receipt-qa","prompt_id":"turn","hook_event_name":"Stop"}"#.utf8)); try input.fileHandleForWriting.close()
            wait(for: [delivered], timeout: 3)
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { process.terminate(); XCTFail("receipt helper failed to exit within its bound") }
            process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual((try output.fileHandleForReading.readToEnd())?.count ?? 0, 0)
        }
    }
    func testAuthenticatedFocusClaimFromNonHelperSocketPeerRejectedAndWireOriginClaimStripped() throws {
        try fixture { first, _ in
            let socketURL = first.appendingPathComponent("events.sock"), tokenURL = first.appendingPathComponent("token")
            let delivered = expectation(description: "raw event delivered without forged origin")
            let focus = expectation(description: "unverified peer cannot publish focus"); focus.isInverted = true
            let bridge = HookBridge(socketURL: socketURL, tokenURL: tokenURL, onEditorFocus: {_,_,_,_,_ in focus.fulfill()}, onEvent: { e in
                XCTAssertNil(e.verifiedEditorHost); delivered.fulfill()
            })
            bridge.start(); defer { bridge.stop() }
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: socketURL.path) { Thread.sleep(forTimeInterval: 0.01) }
            func connectClient() throws -> Int32 {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0)
                var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(socketURL.path.utf8)
                withUnsafeMutablePointer(to: &address.sun_path) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in for (i,b) in bytes.enumerated() {chars[i] = CChar(bitPattern:b)}; chars[bytes.count] = 0 } }
                let result = withUnsafePointer(to: &address) {ptr in ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }}
                XCTAssertEqual(result, 0); HookWire.timeout(fd, seconds: 1); return fd
            }
            let claim = try connectClient(); defer {close(claim)}
            XCTAssertTrue(HookWire.send(HookFrame(type: "editor-focus-connect", token: try XCTUnwrap(HookWire.secret(tokenURL))), fd: claim))
            XCTAssertNil(HookWire.receive(claim, requireNewline: true, deadline: HookWire.uptime + 1))
            let raw = try connectClient(); defer {close(raw)}
            var e = event("qa", kind: .started, path: first.path, time: 1, host: "com.microsoft.VSCode")
            e.provider = .claude
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            XCTAssertTrue(HookWire.writeData(try encoder.encode(e) + Data([10]), fd: raw))
            wait(for: [delivered, focus], timeout: 0.3)
        }
    }
    func testInstallerPreservesForeignAndRefusesUnownedCollisionFailureAndOnlyRemovesOwnExtension() throws {
        let first = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".refik-installer-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: first) }
        let authored = first.appendingPathComponent("extension"), root = first.appendingPathComponent("extensions")
        let installed = root.appendingPathComponent("refik.editor-focus-0.1.0")
        for directory in [authored, root] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let manifest = ["name": "editor-focus", "publisher": "refik", "version": "0.1.0", "main": "extension.js"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: authored.appendingPathComponent("package.json"))
        try Data("owned script".utf8).write(to: authored.appendingPathComponent("extension.js"))
        try Data("owned readme".utf8).write(to: authored.appendingPathComponent("readme.md"))
        let archive = first.appendingPathComponent("own.vsix"), receipts = first.appendingPathComponent("receipts.json"), settings = first.appendingPathComponent("settings.json")
        XCTAssertTrue(EditorFocusInstaller.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", authored.path, archive.path]).success)
        let foreign = Data("foreign settings and Claude runtime pins".utf8); try foreign.write(to: settings)
        try JSONEncoder().encode(["foreign-app": "foreign-receipt"]).write(to: receipts)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipts.path)
        let installation = EditorFocusHost.installations[0]; var extensions: Set<String> = ["foreign.tool@1.0"]
        var commands: [[String]] = []
        let runner: EditorFocusInstaller.Runner = { _, args in
            commands.append(args)
            if args.first == "--install-extension" {
                extensions.insert("refik.editor-focus@0.1.0")
                try! FileManager.default.copyItem(at: authored, to: installed)
                try! JSONSerialization.data(withJSONObject: [["identifier": ["id": "refik.editor-focus"], "version": "0.1.0", "location": ["scheme": "file", "fsPath": installed.path]]]).write(to: root.appendingPathComponent("extensions.json"))
            }
            if args.first == "--uninstall-extension" {
                extensions.remove("refik.editor-focus@0.1.0")
                try! FileManager.default.removeItem(at: installed)
                try! JSONSerialization.data(withJSONObject: []).write(to: root.appendingPathComponent("extensions.json"))
            }
            return .init(success: true, output: extensions.sorted().joined(separator: "\n"))
        }
        let result = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: runner, extensionRoot: { _ in root }, executableAvailable: { _ in true })
        XCTAssertTrue(result.contains("bağlantı kurulu")); XCTAssertTrue(extensions.contains("foreign.tool@1.0"))
        XCTAssertNotNil(EditorFocusInstaller.adoptionProof(root: root, archive: archive))
        var records = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipts))
        XCTAssertNotNil(records[installation.application.path]); XCTAssertEqual(records["foreign-app"], "foreign-receipt")
        XCTAssertEqual(try Data(contentsOf: settings), foreign); XCTAssertFalse(commands.flatMap {$0}.contains("--force"))
        let validReceipt = try Data(contentsOf: receipts)
        let script = installed.appendingPathComponent("extension.js")
        let metadata = root.appendingPathComponent("extensions.json")
        let originalScript = try Data(contentsOf: script), originalMetadata = try Data(contentsOf: metadata)
        for mode in 0..<3 {
            if mode == 0 { try Data("replaced script".utf8).write(to: script) }
            if mode == 1 {
                try JSONSerialization.data(withJSONObject: [["identifier": ["id": "refik.editor-focus"], "version": "9.0.0", "location": ["scheme": "file", "fsPath": installed.path]]]).write(to: metadata)
            }
            if mode == 2 {
                var mismatched = records; mismatched[installation.application.path] = "different-checksum"
                try JSONEncoder().encode(mismatched).write(to: receipts)
            }
            let receiptBefore = try Data(contentsOf: receipts), scriptBefore = try Data(contentsOf: script), metadataBefore = try Data(contentsOf: metadata)
            var attempted: [[String]] = []
            let refusal = EditorFocusInstaller.configure(enabled: false, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: { _, args in
                attempted.append(args)
                return .init(success: true, output: "refik.editor-focus@" + (mode == 1 ? "9.0.0" : "0.1.0"))
            }, extensionRoot: { _ in root }, executableAvailable: { _ in true })
            XCTAssertTrue(refusal.contains("korunuyor"))
            XCTAssertFalse(attempted.contains { $0.first == "--uninstall-extension" })
            XCTAssertEqual(try Data(contentsOf: receipts), receiptBefore)
            XCTAssertEqual(try Data(contentsOf: script), scriptBefore)
            XCTAssertEqual(try Data(contentsOf: metadata), metadataBefore)
            try originalScript.write(to: script); try originalMetadata.write(to: metadata); try validReceipt.write(to: receipts)
        }
        let removed = EditorFocusInstaller.configure(enabled: false, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: runner, extensionRoot: { _ in root }, executableAvailable: { _ in true })
        XCTAssertTrue(removed.contains("kaldırıldı")); XCTAssertEqual(extensions, ["foreign.tool@1.0"])
        records = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipts))
        XCTAssertEqual(records, ["foreign-app": "foreign-receipt"]); XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path))
        try validReceipt.write(to: receipts); commands = []
        let absent = EditorFocusInstaller.configure(enabled: false, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: runner, extensionRoot: { _ in root }, executableAvailable: { _ in true })
        XCTAssertTrue(absent.contains("kaldırıldı"))
        XCTAssertFalse(commands.contains { $0.first == "--uninstall-extension" })
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipts)), ["foreign-app": "foreign-receipt"])
        let preservedReceipt = try Data(contentsOf: receipts)
        extensions.insert("refik.editor-focus@0.1.0"); commands = []
        let collision = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: runner, extensionRoot: { _ in root }, executableAvailable: { _ in true })
        XCTAssertTrue(collision.contains("korunuyor")); XCTAssertEqual(commands, [["--list-extensions", "--show-versions"]])
        XCTAssertEqual(try Data(contentsOf: receipts), preservedReceipt)
        extensions.remove("refik.editor-focus@0.1.0")
        let failure = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipts, installations: [installation], verified: {_ in true}, runner: {_,_ in .init(success:false,output: "policy")}, extensionRoot: { _ in root }, executableAvailable: { _ in true })
        XCTAssertTrue(failure.contains("okunamadı")); XCTAssertEqual(try Data(contentsOf: receipts), preservedReceipt)
        XCTAssertEqual(try Data(contentsOf: settings), foreign)
    }
}
