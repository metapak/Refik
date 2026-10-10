import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class TerminalNavigationTests: XCTestCase {
    private let helper = URL(fileURLWithPath: "/owned/refikHook")
    private let bundled = URL(fileURLWithPath: "/bundle/refikHook")
    private let token = "w1t2p3:01234567-89AB-CDEF-0123-456789ABCDEF"
    private final class Fixture {
        var processes: [Int32: AntigravityTerminalOrigin.ProcessIdentity] = [:]
        var time: Double = 100
        var signed = true, helperMatches = true, cliSigned = true
        var signatureChecks = 0
        var file: AntigravityTerminalOrigin.FileIdentity? = .init(device: 1, inode: 2, size: 3, seconds: 4, nanos: 5)
        init(_ provider: Provider = .codex, iTerm: Bool = true) {
            func p(_ pid: Int32, _ parent: Int32, _ path: String) -> AntigravityTerminalOrigin.ProcessIdentity {
                .init(pid: pid, parent: parent, uid: getuid(), seconds: UInt64(pid), micros: 1, path: path)
            }
            processes[10] = p(10, 11, "/owned/refikHook")
            processes[11] = p(11, 12, "/bin/sh")
            processes[12] = p(12, 13, "/owned/" + (provider == .antigravity ? "agy" : provider.rawValue))
            processes[13] = p(13, 14, "/bin/zsh")
            processes[14] = p(14, 1, AntigravityTerminalOrigin.terminalHosts[iTerm ? 1 : 0].binary)
        }
        var operations: TerminalNavigationOrigin.Operations {
            .init(peer: { _ in 10 }, process: { self.processes[$0] }, file: { _ in self.file },
                  signed: { _, id, team in
                      self.signatureChecks += 1
                      if id == "cli" { return self.cliSigned && team == "EQHXZ8M8AV" }
                      return self.signed && ((id == "com.googlecode.iterm2" && team == "H7V7XYVQ7D") || id == "com.apple.Terminal" && team == nil)
                  },
                  helperMatches: { _, _ in self.helperMatches }, now: { self.time })
        }
    }
    private func event(_ provider: Provider = .codex) -> CodexEvent {
        .init(sessionID: "session", turnID: "turn", requestID: nil, kind: .started, source: .unknown,
              title: "QA", at: Date(timeIntervalSince1970: 100), id: "event", provider: provider,
              runtime: .init(id: "existing-request-runtime", host: .unknown))
    }
    private func binding(_ f: Fixture, _ event: CodexEvent) throws -> TerminalNavigationOrigin.Binding {
        try XCTUnwrap(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations),
            event: event, helper: helper, bundledHelper: bundled, operations: f.operations))
    }
    func testCaptureDistinguishesDetachedChainFromUnavailableProcessWithoutMintingTarget() {
        let detached = Fixture()
        detached.processes[12] = .init(pid: 12, parent: 1, uid: getuid(), seconds: 12, micros: 1, path: "/owned/codex")
        var stages: [TerminalNavigationDiagnostic.Stage] = []
        XCTAssertNil(TerminalNavigationOrigin.capture(0, helper: helper, operations: detached.operations, diagnostic: { stages.append($0) }))
        XCTAssertEqual(stages, [.captureReachedRoot])
        let raced = Fixture(); raced.processes.removeValue(forKey: 12)
        stages.removeAll()
        XCTAssertNil(TerminalNavigationOrigin.capture(0, helper: helper, operations: raced.operations, diagnostic: { stages.append($0) }))
        XCTAssertEqual(stages, [.captureProcessUnavailable])
    }
    func testExplicitTerminalPreferenceOpensOnlyChosenApplicationWithoutOriginOrAttentionChanges() throws {
        let f = Fixture()
        for provider in [Provider.codex, .claude, .antigravity] {
            var e = event(provider); e.runtime?.host = .terminal
            var state = StateReducer(); _ = state.apply(e)
            let s = try XCTUnwrap(state.sessions[e.sessionID])
            let unset = SessionRouting.route(for: s, terminalOperations: f.operations)
            XCTAssertTrue(unset.chooseTerminal); XCTAssertEqual(unset.label, "Terminal uygulamasını seç")
            for choice in [TerminalApplicationPreference.terminal, .iTerm2] {
                let route = SessionRouting.route(for: s, terminalOperations: f.operations, terminalPreference: choice)
                XCTAssertEqual(route.bundleID, choice == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2")
                XCTAssertEqual(route.manualTerminal, choice); XCTAssertFalse(route.chooseTerminal); XCTAssertNil(route.url)
                XCTAssertEqual(route.applicationURL, choice.validated(operations: f.operations)?.application)
            }
            XCTAssertNil(s.terminalNavigation); XCTAssertFalse(s.seen); XCTAssertEqual(s.state, .running)
        }
    }
    private func terminalSession(_ id: String, provider: Provider = .codex) -> Session {
        var s = Session(id: id, turnID: "turn", source: .cli, title: "same project", state: .waitingUser, started: Date(), updated: Date())
        s.provider = provider; s.runtime = .init(id: "runtime", host: .terminal)
        return s
    }
    func testSessionChoicesSeparateSimultaneousTerminalsProvidersAndPreserveChoiceAcrossTurns() throws {
        let f = Fixture(); var choices = SessionTerminalChoices()
        let first = terminalSession("first"), second = terminalSession("second")
        let claude = terminalSession("first", provider: .claude)
        XCTAssertTrue(choices.set(.terminal, for: first)); XCTAssertTrue(choices.set(.iTerm2, for: second))
        XCTAssertEqual(choices.choice(for: claude), .none)
        XCTAssertTrue(choices.set(.iTerm2, for: claude))
        XCTAssertEqual(choices.choice(for: first), .terminal); XCTAssertEqual(choices.choice(for: second), .iTerm2)
        for (session, bundle) in [(first, "com.apple.Terminal"), (second, "com.googlecode.iterm2"), (claude, "com.googlecode.iterm2")] {
            let route = SessionRouting.route(for: session, terminalOperations: f.operations, terminalPreference: choices.choice(for: session))
            XCTAssertEqual(route.bundleID, bundle); XCTAssertNil(route.url); XCTAssertFalse(session.seen)
            XCTAssertEqual(session.state, .waitingUser); XCTAssertNil(session.terminalNavigation)
        }
        var next = first; next.turnID = "next"; next.title = "different project title"
        XCTAssertEqual(choices.choice(for: next), .terminal)
        next.runtime?.host = .vscode; XCTAssertEqual(choices.choice(for: next), .none)
        XCTAssertTrue(choices.set(.none, for: second)); XCTAssertEqual(choices.choice(for: second), .none)
        XCTAssertEqual(choices.choice(for: first), .terminal)
    }
    func testManualOpenReusesOnlyCurrentClickReceiptAndStillPerformsTwoSignatureChecks() throws {
        let f = Fixture(); let s = terminalSession("latency")
        let route = SessionRouting.route(for: s, terminalOperations: f.operations, terminalPreference: .iTerm2)
        XCTAssertEqual(f.signatureChecks, 1)
        let receipt = try XCTUnwrap(TerminalApplicationPreference.iTerm2.prepareOpening(route.manualTerminalReceipt, operations: f.operations))
        XCTAssertEqual(f.signatureChecks, 2)
        XCTAssertTrue(TerminalApplicationPreference.iTerm2.sourceMatches(receipt, operations: f.operations))
        XCTAssertEqual(f.signatureChecks, 2, "main-queue identity recheck performs no expensive signature scan")
        f.file = .init(device: 1, inode: 777, size: 3, seconds: 4, nanos: 5)
        XCTAssertFalse(TerminalApplicationPreference.iTerm2.sourceMatches(receipt, operations: f.operations))
        XCTAssertNil(TerminalApplicationPreference.iTerm2.prepareOpening(receipt, operations: f.operations))
        f.signed = false
        XCTAssertNil(TerminalApplicationPreference.iTerm2.prepareOpening(receipt, operations: f.operations))
    }
    func testQueuedTerminalOpenSnapshotRejectsNewTurnPreferenceAndVerifiedRouteChanges() {
        let s = terminalSession("latency")
        let snapshot = TerminalOpeningSnapshot(s, choice: .iTerm2)
        XCTAssertTrue(snapshot.matches(s, choice: .iTerm2))
        XCTAssertFalse(snapshot.matches(s, choice: .terminal))
        var next = s; next.turnID = "new turn"
        XCTAssertFalse(snapshot.matches(next, choice: .iTerm2))
        next = s; next.runtime = .init(id: "different-runtime", host: .terminal)
        XCTAssertFalse(snapshot.matches(next, choice: .iTerm2))
        next = s; next.verifiedEditorHost = "com.microsoft.VSCode"
        XCTAssertFalse(snapshot.matches(next, choice: .iTerm2))
        next = s; next.verifiedTerminalHost = "com.apple.Terminal"
        XCTAssertFalse(snapshot.matches(next, choice: .iTerm2))
        XCTAssertFalse(snapshot.matches(terminalSession("other"), choice: .iTerm2))
    }
    func testSessionChoicesBoundedClosedHashKeysAndUnknownValuesFailClosedWithoutGlobalMigration() throws {
        var choices = SessionTerminalChoices()
        for n in 0...128 { XCTAssertTrue(choices.set(.terminal, for: terminalSession("session-\(n)"))) }
        XCTAssertEqual(choices.count, 128); XCTAssertEqual(choices.choice(for: terminalSession("session-128")), .terminal)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let roundtrip = try JSONDecoder().decode(SessionTerminalChoices.self, from: encoder.encode(choices))
        XCTAssertEqual(try encoder.encode(roundtrip), try encoder.encode(choices))
        let privateID = terminalSession("/private/session|identifier")
        XCTAssertTrue(choices.set(.iTerm2, for: privateID))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(choices)) as? [String: String])
        XCTAssertFalse(raw.keys.contains { $0.contains("/private/") })
        XCTAssertTrue(raw.keys.allSatisfy { $0.hasPrefix("codex|") && $0.utf8.count == 70 })
        XCTAssertFalse(choices.set(.terminal, for: terminalSession("")))
        XCTAssertFalse(choices.set(.terminal, for: terminalSession(String(repeating: "a", count: 513))))
        let key = try XCTUnwrap(SessionTerminalChoices.key(for: privateID))
        let invalid: [String: Any] = ["mascot": "stern", "terminalApplication": "iTerm2", "terminalApplications": [key: "future-app", "/arbitrary/path": "terminal"]]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: invalid))
        XCTAssertEqual(decoded.mascot, "stern"); XCTAssertEqual(decoded.terminalApplication, .iTerm2)
        XCTAssertEqual(decoded.terminalApplications.count, 0)
        XCTAssertEqual(decoded.terminalApplications.choice(for: privateID), .none)
        XCTAssertTrue(SessionRouting.route(for: privateID, terminalPreference: decoded.terminalApplications.choice(for: privateID)).chooseTerminal)
    }
    func testManualChoiceMissingOrReplacedApplicationFailsValidationAndUnknownHostsDoNotOfferChoice() throws {
        let f = Fixture(); let receipt = try XCTUnwrap(TerminalApplicationPreference.terminal.validated(operations: f.operations))
        f.file = .init(device: 1, inode: 999, size: 3, seconds: 4, nanos: 5)
        XCTAssertNotEqual(TerminalApplicationPreference.terminal.validated(operations: f.operations), receipt)
        XCTAssertFalse(TerminalApplicationPreference.terminal.matches(receipt, operations: f.operations))
        f.file = nil
        XCTAssertNil(TerminalApplicationPreference.terminal.validated(operations: f.operations))
        XCTAssertFalse(TerminalApplicationPreference.terminal.matches(receipt, operations: f.operations))
        var e = event(); e.runtime?.host = .terminal
        var state = StateReducer(); _ = state.apply(e)
        var s = try XCTUnwrap(state.sessions[e.sessionID])
        XCTAssertTrue(SessionRouting.route(for: s, terminalOperations: f.operations, terminalPreference: .terminal).chooseTerminal)
        for host in [RuntimeHost.unknown, .codexDesktop, .vscode] {
            s.runtime?.host = host
            let route = SessionRouting.route(for: s, codexRoutingVerified: false, terminalOperations: f.operations, terminalPreference: .terminal)
            XCTAssertFalse(route.chooseTerminal); XCTAssertNil(route.manualTerminal)
        }
        f.file = receipt.file; f.signed = false
        XCTAssertNil(TerminalApplicationPreference.terminal.validated(operations: f.operations))
    }
    func testVerifiedTerminalRoutePrecedesManualPreferenceAndPreferencesRemainBackwardCompatible() throws {
        let f = Fixture(); var e = event(); e.runtime?.host = .terminal; e.navigationTabToken = token
        TerminalNavigationOrigin.apply(try binding(f, e), to: &e, operations: f.operations)
        var state = StateReducer(); _ = state.apply(e)
        let s = try XCTUnwrap(state.sessions[e.sessionID])
        let route = SessionRouting.route(for: s, terminalOperations: f.operations, terminalPreference: .terminal)
        XCTAssertEqual(route.url?.absoluteString, "iterm2:reveal?sessionid=" + token)
        XCTAssertNil(route.manualTerminal); XCTAssertFalse(route.chooseTerminal)
        let old = try JSONDecoder().decode(Preferences.self, from: Data("{\"mascot\":\"stern\"}".utf8))
        XCTAssertEqual(old.terminalApplication, .none); XCTAssertEqual(old.mascot, "stern")
        let unknown = try JSONDecoder().decode(Preferences.self, from: Data("{\"mascot\":\"stern\",\"terminalApplication\":\"future-app\"}".utf8))
        XCTAssertEqual(unknown.terminalApplication, .none); XCTAssertEqual(unknown.mascot, "stern")
        var selected = old; selected.terminalApplication = .iTerm2
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(selected)).terminalApplication, .iTerm2)
    }
    func testManualApplicationPolicyLeavesPendingQuestionAndSessionIdentityUntouched() throws {
        let f = Fixture()
        let e = CodexEvent(sessionID: "waiting", turnID: "turn", requestID: "request", kind: .userQuestionObserved,
            source: .cli, title: "QA", at: Date(), id: "question", provider: .claude,
            runtime: .init(id: "cli", host: .terminal))
        var state = StateReducer(); _ = state.apply(e)
        let s = try XCTUnwrap(state.sessions[e.sessionID])
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(s)
        let route = SessionRouting.route(for: s, terminalOperations: f.operations, terminalPreference: .terminal)
        let receipt = try XCTUnwrap(route.manualTerminal?.validated(operations: f.operations))
        XCTAssertTrue(TerminalApplicationPreference.terminal.matches(receipt, operations: f.operations))
        XCTAssertFalse(route.exact); XCTAssertEqual(s.state, .waitingUser); XCTAssertFalse(s.seen)
        XCTAssertEqual(s.pending, ["request"]); XCTAssertNil(s.terminalNavigation)
        XCTAssertEqual(try encoder.encode(try XCTUnwrap(state.sessions[e.sessionID])), before)
    }
    func testThreeProvidersAttestITermTargetWithoutChangingRuntimeOrSeen() throws {
        for provider in [Provider.codex, .claude, .antigravity] {
            let f = Fixture(provider); var e = event(provider); e.navigationTabToken = token
            let b = try binding(f, e)
            f.processes.removeValue(forKey: 10) // helper's normal exit is not source exit
            TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
            XCTAssertEqual(e.runtime?.id, "existing-request-runtime")
            var state = StateReducer(); XCTAssertTrue(state.apply(e))
            let s = try XCTUnwrap(state.sessions[e.sessionID])
            let route = SessionRouting.route(for: s, terminalOperations: f.operations)
            XCTAssertEqual(route.bundleID, "com.googlecode.iterm2")
            XCTAssertEqual(route.url?.absoluteString, "iterm2:reveal?sessionid=" + token)
            XCTAssertFalse(s.seen)
            XCTAssertEqual(SessionPresentation.hostLabel(s, terminalOperations: f.operations), "iTerm2")
            let saved = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s))
            XCTAssertEqual(SessionRouting.route(for: saved, terminalOperations: f.operations), route)
        }
    }
    func testAntigravitySignedUpdaterAliasKeepsOnlyAttestedTerminalAndTab() throws {
        for iTerm in [false, true] {
            let f = Fixture(.antigravity, iTerm: iTerm)
            let alias = AntigravityTerminalOrigin.cli.path + ".1791381419993688000.old"
            f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: alias)
            var e = event(.antigravity); e.navigationTabToken = token
            let b = try binding(f, e)
            TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
            let target = try XCTUnwrap(e.terminalNavigation)
            XCTAssertEqual(target.bundleID, iTerm ? "com.googlecode.iterm2" : "com.apple.Terminal")
            XCTAssertEqual(target.tabToken, iTerm ? token : nil)
            XCTAssertEqual(TerminalNavigationOrigin.tabURL(target, operations: f.operations)?.absoluteString,
                           iTerm ? "iterm2:reveal?sessionid=" + token : nil)
            f.file = .init(device: 1, inode: 999, size: 3, seconds: 4, nanos: 5)
            TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
            XCTAssertNil(e.terminalNavigation)
        }
    }
    func testAntigravityUpdaterAliasRejectsMalformedForeignUnsignedOrChangedChain() throws {
        let alias = AntigravityTerminalOrigin.cli.path + ".1791381419993688000.old"
        for path in [AntigravityTerminalOrigin.cli.path + ".123.old", AntigravityTerminalOrigin.cli.path + ".0179138141999368800.old", "/foreign/agy.1791381419993688000.old", alias + "/child"] {
            let f = Fixture(.antigravity)
            f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: path)
            XCTAssertNil(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations), event: event(.antigravity), helper: helper, bundledHelper: bundled, operations: f.operations))
        }
        for mode in 0..<4 {
            let f = Fixture(.antigravity)
            f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: alias)
            let capture = TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations)
            if mode == 0 { f.cliSigned = false }
            if mode == 1 { f.helperMatches = false }
            if mode == 2 { f.file = nil }
            if mode == 3 { f.processes[13] = .init(pid: 13, parent: 99, uid: getuid(), seconds: 13, micros: 1, path: "/bin/zsh") }
            XCTAssertNil(TerminalNavigationOrigin.bind(capture, event: event(.antigravity), helper: helper, bundledHelper: bundled, operations: f.operations))
        }
        let replaced = Fixture(.antigravity)
        replaced.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: alias)
        var operations = replaced.operations
        let signed = operations.signed
        operations.signed = { url, id, team in
            if id == "cli" { replaced.file = .init(device: 1, inode: 999, size: 3, seconds: 4, nanos: 5) }
            return signed(url, id, team)
        }
        XCTAssertNil(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: operations), event: event(.antigravity), helper: helper, bundledHelper: bundled, operations: operations))
    }
    func testTerminalAppOnlyAndLegacyRuntimeDoesNotGuessAppleTerminal() throws {
        let f = Fixture(iTerm: false); var e = event(); e.navigationTabToken = token
        TerminalNavigationOrigin.apply(try binding(f, e), to: &e, operations: f.operations)
        var state = StateReducer(); _ = state.apply(e)
        var s = try XCTUnwrap(state.sessions[e.sessionID])
        XCTAssertEqual(SessionRouting.route(for: s, terminalOperations: f.operations).bundleID, "com.apple.Terminal")
        XCTAssertNil(SessionRouting.route(for: s, terminalOperations: f.operations).url)
        XCTAssertEqual(SessionPresentation.hostLabel(s, terminalOperations: f.operations), "Terminal")
        s.terminalNavigation = nil; s.runtime?.host = .terminal
        XCTAssertTrue(SessionRouting.route(for: s, terminalOperations: f.operations).bundleID.isEmpty)
    }
    func testFormatAndUnattestedWireFieldsCannotMintTarget() throws {
        for invalid in ["restart", "w1t2p3:", token + "&command=whoami", "iterm2:reveal?sessionid=" + token, String(repeating: "a", count: 101)] {
            XCTAssertNil(TerminalNavigationOrigin.validTabToken(invalid))
        }
        XCTAssertEqual(TerminalNavigationOrigin.validTabToken(token), token)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event())) as? [String: Any])
        json["terminalNavigation"] = ["bundleID": "com.googlecode.iterm2", "tabToken": token]
        json["navigationTabToken"] = token
        var decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.terminalNavigation)
        TerminalNavigationOrigin.apply(nil, to: &decoded)
        XCTAssertNil(decoded.terminalNavigation)
    }
    func testForeignUIDSignatureHelperMismatchPIDReuseExpiryAndWrongEventReject() throws {
        let foreign = Fixture()
        foreign.processes[11] = .init(pid: 11, parent: 12, uid: getuid() + 1, seconds: 11, micros: 1, path: "/bin/sh")
        XCTAssertNil(TerminalNavigationOrigin.capture(0, helper: helper, operations: foreign.operations))
        for mismatch in [true, false] {
            let f = Fixture(); if mismatch { f.helperMatches = false } else { f.signed = false }
            XCTAssertNil(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations), event: event(), helper: helper, bundledHelper: bundled, operations: f.operations))
        }
        for mode in 0..<3 {
            let f = Fixture(); var e = event(); let b = try binding(f, e)
            if mode == 0 { f.time += 4 }
            if mode == 1 { f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 99, micros: 1, path: "/owned/codex") }
            if mode == 2 { e.turnID = "other" }
            TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
            XCTAssertNil(e.terminalNavigation)
        }
    }
    func testEditorAndDesktopPrecedenceAndStaleTabFallsBackWithoutRetargeting() throws {
        let f = Fixture(); var e = event(); e.navigationTabToken = token
        let b = try binding(f, e)
        e.verifiedEditorHost = "com.microsoft.VSCode"
        TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
        XCTAssertNil(e.terminalNavigation)
        var state = StateReducer(); _ = state.apply(e)
        XCTAssertEqual(SessionPresentation.hostLabel(try XCTUnwrap(state.sessions[e.sessionID]), terminalOperations: f.operations), "VS Code")
        let editorRoute = SessionRouting.route(for: try XCTUnwrap(state.sessions[e.sessionID]), terminalOperations: f.operations, terminalPreference: .terminal)
        XCTAssertNil(editorRoute.manualTerminal); XCTAssertFalse(editorRoute.chooseTerminal)
        e.verifiedEditorHost = nil; e.runtime?.host = .codexDesktop
        XCTAssertNil(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations), event: e, helper: helper, bundledHelper: bundled, operations: f.operations))
        e.runtime?.host = .unknown
        TerminalNavigationOrigin.apply(b, to: &e, operations: f.operations)
        let target = try XCTUnwrap(e.terminalNavigation)
        f.processes.removeValue(forKey: 12)
        XCTAssertNotNil(TerminalNavigationOrigin.application(target, operations: f.operations))
        XCTAssertNil(TerminalNavigationOrigin.tabURL(target, operations: f.operations))
        f.processes.removeValue(forKey: 14)
        XCTAssertNil(TerminalNavigationOrigin.application(target, operations: f.operations))
    }
    func testMetadataBindingFileReplacementAndSourceProviderMismatchReject() throws {
        let f = Fixture(); let e = event(); let b = try binding(f, e)
        var otherProvider = e; otherProvider.provider = .claude
        TerminalNavigationOrigin.apply(b, to: &otherProvider, operations: f.operations)
        XCTAssertNil(otherProvider.terminalNavigation)
        for key in ["session", "event"] {
            var other = e
            if key == "session" { other.sessionID = "foreign" }
            else { other = CodexEvent(sessionID: e.sessionID, turnID: e.turnID, requestID: nil, kind: e.kind,
                source: e.source, title: e.title, at: e.at, id: "foreign", provider: e.provider) }
            TerminalNavigationOrigin.apply(b, to: &other, operations: f.operations)
            XCTAssertNil(other.terminalNavigation)
        }
        f.file = .init(device: 1, inode: 999, size: 3, seconds: 4, nanos: 5)
        var replaced = e; TerminalNavigationOrigin.apply(b, to: &replaced, operations: f.operations)
        XCTAssertNil(replaced.terminalNavigation)
        XCTAssertNil(TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(0, helper: helper, operations: f.operations),
            event: event(.claude), helper: helper, bundledHelper: bundled, operations: f.operations))
    }
    func testTargetDoesNotSurviveNewTurnWithoutNewReceiptOrCreateUnverifiedLabel() throws {
        let f = Fixture(); var e = event(.claude)
        let claude = Fixture(.claude)
        TerminalNavigationOrigin.apply(try binding(claude, e), to: &e, operations: claude.operations)
        var state = StateReducer(); _ = state.apply(e)
        XCTAssertNotNil(state.sessions[e.sessionID]?.terminalNavigation)
        var next = event(.claude); next.turnID = "next"
        next = CodexEvent(sessionID: e.sessionID, turnID: next.turnID, requestID: nil, kind: .started, source: .unknown,
            title: "QA", at: e.at.addingTimeInterval(1), id: "next", provider: .claude)
        XCTAssertTrue(state.apply(next))
        XCTAssertNil(state.sessions[e.sessionID]?.terminalNavigation)
        var s = try XCTUnwrap(state.sessions[e.sessionID]); s.terminalNavigation = try binding(f, event()).target
        f.processes.removeValue(forKey: 14)
        XCTAssertEqual(SessionPresentation.hostLabel(s, terminalOperations: f.operations), "Uygulama")
        XCTAssertTrue(SessionRouting.route(for: s, terminalOperations: f.operations).bundleID.isEmpty)
    }
    func testActualNormalizerDoesNotForwardProviderSuppliedTabOrTarget() throws {
        let binary = URL(fileURLWithPath: ".build/debug/refikHook", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("helper not built") }
        let p = Process(); p.executableURL = binary; p.arguments = ["--normalize", "codex"]
        let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); p.terminationHandler = { _ in done.signal() }
        try p.run()
        let body: [String: Any] = ["hook_event_name": "Stop", "session_id": "s", "turn_id": "t",
            "navigationTabToken": token, "terminalNavigation": ["bundleID": "com.googlecode.iterm2"]]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: body))
        try input.fileHandleForWriting.close()
        guard done.wait(timeout: .now() + 2) == .success else { p.terminate(); XCTFail("bounded helper exit"); return }
        XCTAssertEqual(p.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try output.fileHandleForReading.readToEnd() ?? Data()) as? [String: Any])
        XCTAssertNil(json["navigationTabToken"]); XCTAssertNil(json["terminalNavigation"])
    }
    @MainActor func testMainqueueRejectsStaleTargetAndPublicDispatchDoesNotClearWaiting() throws {
        let f = Fixture(.claude); var e = event(.claude)
        TerminalNavigationOrigin.apply(try binding(f, e), to: &e, operations: f.operations)
        XCTAssertNotNil(e.terminalNavigation)
        let app = AppModel(inspectNotificationPermission: false)
        app.accept(e, historical: false)
        XCTAssertNil(app.sessions.first?.terminalNavigation, "a stale/nonlive source cannot be admitted on main queue")
        let waiting = CodexEvent(sessionID: "question", turnID: "turn", requestID: "request", kind: .userQuestionObserved,
            source: .desktop, title: "QA", at: Date(), id: "question", provider: .codex,
            runtime: .init(id: "desktop", host: .codexDesktop))
        app.accept(waiting, historical: false)
        let session = try XCTUnwrap(app.sessions.first { $0.id == "question" })
        app.open(session) { _ in true }
        XCTAssertFalse(app.sessions.first { $0.id == "question" }!.seen)
        XCTAssertEqual(app.sessions.first { $0.id == "question" }!.pending, ["request"])
        XCTAssertEqual(app.aggregate, .waiting)
    }
}
