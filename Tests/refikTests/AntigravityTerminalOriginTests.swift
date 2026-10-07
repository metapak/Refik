import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class AntigravityTerminalOriginTests: XCTestCase {
    private typealias Origin = AntigravityTerminalOrigin
    private let helper = URL(fileURLWithPath: "/owned/refikHook")
    private let bundled = URL(fileURLWithPath: "/bundle/refikHook")
    private final class Fixture {
        var processes: [Int32: Origin.ProcessIdentity] = [:]
        var file: Origin.FileIdentity? = .init(device: 1, inode: 2, size: 3, seconds: 4, nanos: 5)
        var helperMatches = true, cliSigned = true, terminalSigned = true, loginSigned = true
        var time: Double = 100
        init(iTerm: Bool = false) {
            func node(_ pid: Int32, _ parent: Int32, _ path: String) -> Origin.ProcessIdentity {
                .init(pid: pid, parent: parent, uid: getuid(), seconds: UInt64(pid), micros: 1, path: path)
            }
            processes[10] = node(10, 11, "/owned/refikHook")
            processes[11] = node(11, 12, "/bin/sh")
            processes[12] = node(12, 13, Origin.cli.path)
            processes[13] = node(13, 14, "/bin/zsh")
            processes[14] = node(14, 1, iTerm ? Origin.terminalHosts[1].binary : Origin.terminalBinary)
        }
        var operations: Origin.Operations {
            .init(peer: { _ in 10 }, process: { self.processes[$0] }, file: { _ in self.file },
                  signed: { _, identifier, team in
                      if identifier == "cli" { return team == "EQHXZ8M8AV" && self.cliSigned }
                      if identifier == "com.apple.login" { return team == nil && self.loginSigned }
                      return ((identifier == "com.apple.Terminal" && team == nil) ||
                              (identifier == "com.googlecode.iterm2" && team == "H7V7XYVQ7D")) && self.terminalSigned
                  }, helperMatches: { _, _ in self.helperMatches }, now: { self.time })
        }
    }
    private func input(_ session: String = "cli") -> CodexEvent {
        CodexEvent(sessionID: "antigravity:" + session, turnID: "turn", requestID: nil, kind: .completed,
                   source: .unknown, title: "QA", at: Date(), id: UUID().uuidString, provider: .antigravity,
                   runtime: RuntimeMetadata(id: "payload-claimed", host: .antigravity, version: "1.2.16"))
    }
    func testOptInExistingUpdatedCLIUsesActualSignedProducerAndTerminalChain() throws {
        guard let pid = ProcessInfo.processInfo.environment["REFIK_TEST_EXISTING_AG_UPDATER_PID"].flatMap(Int32.init) else { throw XCTSkip("explicit existing-process read-only source check") }
        let current = try XCTUnwrap(Origin.live.process(pid))
        XCTAssertNotEqual(current.path, Origin.cli.path)
        XCTAssertTrue(Origin.isCLIExecutable(current.path))
        XCTAssertNotNil(Origin.live.file(URL(fileURLWithPath: current.path)))
        XCTAssertTrue(Origin.live.signed(URL(fileURLWithPath: current.path), "cli", "EQHXZ8M8AV"))
        // Substitute only the publisher seam; every producer/parent/terminal
        // identity, signature, file and helper comparison below uses live reads.
        let stable = HookInstaller.helperDestination
        let bundled = URL(fileURLWithPath: "/Applications/refik.app/Contents/MacOS/refikHook")
        var operations = Origin.live
        operations.peer = { _ in -99 }
        let liveProcess = operations.process
        operations.process = { id in
            id == -99 ? .init(pid: -99, parent: pid, uid: getuid(), seconds: 1, micros: 1, path: stable.path) : liveProcess(id)
        }
        let capture = try XCTUnwrap(Origin.capture(0, helper: stable, operations: operations))
        let proof = try XCTUnwrap(Origin.verify(capture, helper: stable, bundledHelper: bundled, operations: operations))
        var event = input(); Origin.apply(proof, to: &event, operations: operations)
        XCTAssertEqual(event.runtime?.host, .terminal)
        XCTAssertEqual(event.verifiedTerminalHost, "com.googlecode.iterm2")
        XCTAssertNil(event.terminalNavigation)
        print("REFIK_AG_UPDATER_READONLY signedProducer=true unchangedPublicChain=true host=iTerm2 syntheticPublisherSeam=true")
    }
    func testSignedUpdaterRenamedProducerRemainsBoundToActualTerminalHost() throws {
        for iTerm in [false, true] {
            let f = Fixture(iTerm: iTerm)
            let renamed = Origin.cli.path + ".1791381419993688000.old"
            f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: renamed)
            var operations = f.operations
            var checkedPaths: [String] = []
            let originalSigned = operations.signed
            operations.signed = { url, id, team in
                if id == "cli" { checkedPaths.append(url.path) }
                return originalSigned(url, id, team)
            }
            let capture = try XCTUnwrap(Origin.capture(0, helper: helper, operations: operations))
            let proof = try XCTUnwrap(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: operations))
            XCTAssertEqual(checkedPaths, [renamed], "verify the executing signed file, not the replacement installation")
            var event = input(); Origin.apply(proof, to: &event, operations: operations)
            XCTAssertEqual(event.runtime?.host, .terminal)
            XCTAssertEqual(event.verifiedTerminalHost, iTerm ? "com.googlecode.iterm2" : "com.apple.Terminal")
            XCTAssertNil(event.terminalNavigation)
            f.cliSigned = false
            XCTAssertNil(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: operations))
            f.cliSigned = true
            f.file = .init(device: 1, inode: 999, size: 3, seconds: 4, nanos: 5)
            XCTAssertNil(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: operations))
        }
    }
    func testUpdaterAliasRejectsOpenNamesDirectoriesAndUntrustedFiles() throws {
        for path in [Origin.cli.path + ".old", Origin.cli.path + ".123.old", Origin.cli.path + ".179138141999368800x.old", Origin.cli.path + ".0179138141999368800.old", Origin.cli.path + ".1791381419993688000.old/child", "/foreign/agy.1791381419993688000.old"] {
            XCTAssertFalse(Origin.isCLIExecutable(path))
            let f = Fixture(); f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: path)
            XCTAssertNil(Origin.capture(0, helper: helper, operations: f.operations))
        }
        let f = Fixture(); let path = Origin.cli.path + ".1791381419993688000.old"
        f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: path)
        f.file = nil
        XCTAssertNil(Origin.capture(0, helper: helper, operations: f.operations), "symlink/writable/foreign file refusal from secure file validator")
        f.file = .init(device: 1, inode: 2, size: 3, seconds: 4, nanos: 5)
        let captured = try XCTUnwrap(Origin.capture(0, helper: helper, operations: f.operations))
        f.processes[13] = .init(pid: 13, parent: 99, uid: getuid(), seconds: 13, micros: 1, path: "/bin/zsh")
        XCTAssertNil(Origin.verify(captured, helper: helper, bundledHelper: bundled, operations: f.operations))
    }
    func testAuthenticatedCLICaptureRoutesTerminalAndPreservesCompletion() throws {
        let fixture = Fixture()
        let capture = try XCTUnwrap(Origin.capture(0, helper: helper, operations: fixture.operations))
        let proof = try XCTUnwrap(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: fixture.operations))
        var event = input(); Origin.apply(proof, to: &event, operations: fixture.operations)
        XCTAssertEqual(event.runtime?.host, .terminal)
        XCTAssertEqual(event.verifiedTerminalHost, "com.apple.Terminal")
        XCTAssertNil(event.runtime?.version, "payload version is not verified version evidence")
        var reducer = StateReducer(); _ = reducer.apply(event)
        let session = try XCTUnwrap(reducer.sessions[event.sessionID])
        XCTAssertEqual(session.state, .completed); XCTAssertFalse(session.seen)
        let route = SessionRouting.route(for: session)
        XCTAssertEqual(route.bundleID, "com.apple.Terminal")
        XCTAssertFalse(route.exact); XCTAssertNil(route.url)
        XCTAssertEqual(route.label, "Uygulamayı aç")
    }
    func testPayloadHostDoesNotAuthorizeRoutingAndIDEHasPrecedence() throws {
        var event = input(); Origin.apply(nil, to: &event)
        XCTAssertEqual(event.runtime?.host, .unknown)
        var reducer = StateReducer(); _ = reducer.apply(event)
        XCTAssertTrue(SessionRouting.route(for: try XCTUnwrap(reducer.sessions[event.sessionID])).bundleID.isEmpty)
        let fixture = Fixture()
        let proof = Origin.verify(Origin.capture(0, helper: helper, operations: fixture.operations), helper: helper, bundledHelper: bundled, operations: fixture.operations)
        event.verifiedEditorHost = "com.microsoft.VSCode"
        Origin.apply(proof, to: &event, operations: fixture.operations)
        XCTAssertEqual(event.runtime?.host, .vscode)
        event.verifiedEditorHost = "com.google.antigravity-ide"
        Origin.apply(proof, to: &event, operations: fixture.operations)
        XCTAssertEqual(event.runtime?.host, .antigravity)
    }
    func testPeerPathCLIPathForeignUIDMissingAndCyclicAncestorsReject() {
        for mutation in 0..<5 {
            let f = Fixture()
            let original = f.processes[mutation == 0 ? 10 : 12]!
            switch mutation {
            case 0: f.processes[10] = .init(pid: 10, parent: 11, uid: getuid(), seconds: 10, micros: 1, path: "/foreign/refikHook")
            case 1: f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 12, micros: 1, path: "/lookalike/agy")
            case 2: f.processes[12] = .init(pid: 12, parent: 13, uid: getuid() + 1, seconds: 12, micros: 1, path: original.path)
            case 3: f.processes.removeValue(forKey: 13)
            default: f.processes[12] = .init(pid: 12, parent: 12, uid: getuid(), seconds: 12, micros: 1, path: original.path)
            }
            XCTAssertNil(Origin.capture(0, helper: helper, operations: f.operations))
        }
    }
    func testHelperBytesSignatureAndFileValidationFailClosed() throws {
        for failure in 0..<4 {
            let f = Fixture(); let capture = try XCTUnwrap(Origin.capture(0, helper: helper, operations: f.operations))
            switch failure {
            case 0: f.helperMatches = false
            case 1: f.cliSigned = false
            case 2: f.terminalSigned = false
            default: f.file = nil
            }
            XCTAssertNil(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: f.operations))
        }
    }
    func testPIDReuseExitReparentAndBinaryChangeInvalidateBeforeDelivery() throws {
        for mutation in 0..<5 {
            let f = Fixture(); let proof = try XCTUnwrap(Origin.verify(Origin.capture(0, helper: helper, operations: f.operations), helper: helper, bundledHelper: bundled, operations: f.operations))
            switch mutation {
            case 0: f.processes[12] = .init(pid: 12, parent: 13, uid: getuid(), seconds: 99, micros: 1, path: Origin.cli.path)
            case 1: f.processes.removeValue(forKey: 14)
            case 2: f.processes[13] = .init(pid: 13, parent: 99, uid: getuid(), seconds: 13, micros: 1, path: "/bin/zsh")
            case 3: f.file = .init(device: 1, inode: 99, size: 3, seconds: 4, nanos: 5)
            default: f.time += 4
            }
            var event = input(); Origin.apply(proof, to: &event, operations: f.operations)
            XCTAssertEqual(event.runtime?.host, .unknown)
        }
    }
    func testNormalShortLivedPublisherExitDoesNotInvalidateLivingSource() throws {
        let f = Fixture()
        let capture = try XCTUnwrap(Origin.capture(0, helper: helper, operations: f.operations))
        // The authenticated publisher can exit after the capture receipt.
        f.processes.removeValue(forKey: 10); f.processes.removeValue(forKey: 11)
        let proof = try XCTUnwrap(Origin.verify(capture, helper: helper, bundledHelper: bundled, operations: f.operations))
        var event = input(); Origin.apply(proof, to: &event, operations: f.operations)
        XCTAssertEqual(event.runtime?.host, .terminal)
    }
    func testITermOriginPersistsExactApplicationAndWireCannotForgeIt() throws {
        let f = Fixture(iTerm: true)
        let proof = try XCTUnwrap(Origin.verify(Origin.capture(0, helper: helper, operations: f.operations), helper: helper, bundledHelper: bundled, operations: f.operations))
        var event = input(); Origin.apply(proof, to: &event, operations: f.operations)
        XCTAssertEqual(event.verifiedTerminalHost, "com.googlecode.iterm2")
        var receiver = AntigravityHookReceiver()
        let observation = try JSONDecoder().decode(AntigravityHookObservation.self, from: Data(#"{"phase":"Stop","conversationID":"cli","hasError":false,"fullyIdle":true}"#.utf8))
        let events = receiver.events(event, observation: observation)
        var reducer = StateReducer(); for normalized in events { _ = reducer.apply(normalized) }
        let session = try XCTUnwrap(reducer.sessions[event.sessionID])
        let restored = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.verifiedTerminalHost, "com.googlecode.iterm2")
        let route = SessionRouting.route(for: restored)
        let installed = Origin.application(for: "com.googlecode.iterm2")
        XCTAssertEqual(route.bundleID, installed == nil ? "" : "com.googlecode.iterm2")
        XCTAssertFalse(route.exact); XCTAssertNil(route.url); XCTAssertFalse(restored.seen)
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertNil(wire["verifiedTerminalHost"])
        wire["verifiedTerminalHost"] = "com.googlecode.iterm2"
        let decoded = try JSONDecoder().decode(CodexEvent.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertNil(decoded.verifiedTerminalHost)
        var legacy = restored; legacy.verifiedTerminalHost = nil
        XCTAssertTrue(SessionRouting.route(for: legacy).bundleID.isEmpty)
        XCTAssertNil(Origin.application(for: "foreign.app", operations: f.operations))
    }
    func testSimultaneousEditorAndCLIEventsCannotExchangeHostProof() throws {
        let f = Fixture(); let proof = try XCTUnwrap(Origin.verify(Origin.capture(0, helper: helper, operations: f.operations), helper: helper, bundledHelper: bundled, operations: f.operations))
        var cli = input("cli"), ide = input("ide")
        ide.verifiedEditorHost = "com.google.antigravity-ide"
        Origin.apply(proof, to: &cli, operations: f.operations); Origin.apply(nil, to: &ide, operations: f.operations)
        var reducer = StateReducer(); _ = reducer.apply(cli); _ = reducer.apply(ide)
        XCTAssertEqual(reducer.sessions[cli.sessionID]?.runtime?.host, .terminal)
        XCTAssertEqual(reducer.sessions[ide.sessionID]?.runtime?.host, .antigravity)
        XCTAssertFalse(try XCTUnwrap(reducer.sessions[cli.sessionID]).seen)
        XCTAssertFalse(try XCTUnwrap(reducer.sessions[ide.sessionID]).seen)
    }
    func testLiveFilePolicyRejectsSymlinkAndWritableExecutable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("agy"), link = root.appendingPathComponent("alias")
        try Data("fixture".utf8).write(to: file); _ = chmod(file.path, 0o700)
        XCTAssertNotNil(Origin.live.file(file))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertNil(Origin.live.file(link))
        _ = chmod(file.path, 0o722); XCTAssertNil(Origin.live.file(file))
    }
    func testRootLoginBridgePreservesExactTerminalAndRejectsForeignIdentity() throws {
        for iTerm in [false, true] {
            let f = Fixture(iTerm: iTerm)
            f.processes[13] = .init(pid: 13, parent: 15, uid: getuid(), seconds: 13, micros: 1, path: "/bin/zsh")
            f.processes[15] = .init(pid: 15, parent: 14, uid: 0, realUID: getuid(), seconds: 15, micros: 1, path: "/usr/bin/login")
            let proof = try XCTUnwrap(Origin.verify(Origin.capture(0, helper: helper, operations: f.operations), helper: helper, bundledHelper: bundled, operations: f.operations))
            var event = input(); Origin.apply(proof, to: &event, operations: f.operations)
            XCTAssertEqual(event.verifiedTerminalHost, iTerm ? "com.googlecode.iterm2" : "com.apple.Terminal")
            for mutation in 0..<5 {
                f.processes[15] = .init(pid: 15, parent: 14, uid: 0, realUID: mutation == 0 ? getuid() + 1 : getuid(),
                    seconds: mutation == 3 ? 99 : 15, micros: 1, path: mutation == 1 ? "/foreign/login" : "/usr/bin/login")
                f.loginSigned = mutation != 2
                if mutation == 4 { f.processes[15] = .init(pid: 15, parent: 14, uid: 1, realUID: getuid(), seconds: 15, micros: 1, path: "/usr/bin/login") }
                if mutation == 3 {
                    Origin.apply(proof, to: &event, operations: f.operations)
                    XCTAssertEqual(event.runtime?.host, .unknown)
                } else {
                    XCTAssertNil(Origin.capture(0, helper: helper, operations: f.operations))
                }
            }
        }
    }
    func testActualPublicLoginSnapshotWhenExistingTerminalChainIsAvailable() throws {
        // Read public process identities only; never launch a shell/provider.
        let requested = ProcessInfo.processInfo.environment["REFIK_TEST_EXISTING_LOGIN_PID"].flatMap(Int32.init)
        var own = AntigravityTerminalOrigin.live.process(requested ?? getpid())
        XCTAssertNotNil(own)
        var found = false
        for _ in 0..<20 {
            guard let current = own else { break }
            if current.path == "/usr/bin/login" {
                XCTAssertEqual(current.uid, 0); XCTAssertEqual(current.realUID, getuid())
                XCTAssertGreaterThan(current.seconds, 0)
                XCTAssertTrue(Origin.live.signed(URL(fileURLWithPath: current.path), "com.apple.login", nil))
                XCTAssertEqual(Origin.live.process(current.pid), current)
                found = true; break
            }
            own = Origin.live.process(current.parent)
        }
        if requested != nil { XCTAssertTrue(found, "explicit existing login snapshot must exercise the native fallback") }
        if let cliPID = ProcessInfo.processInfo.environment["REFIK_TEST_EXISTING_AGY_PID"].flatMap(Int32.init) {
            var operations = Origin.live
            let nativeProcess = operations.process
            let stable = HookInstaller.helperDestination
            operations.peer = { _ in -99 }
            operations.process = { pid in
                if pid == -99 { return .init(pid: pid, parent: cliPID, uid: getuid(), seconds: 1, micros: 1, path: stable.path) }
                return nativeProcess(pid)
            }
            // Only the peer resolver is injected. Every source ancestor, file,
            // UID/launch identity and signature is the actual installed chain.
            let captured = try XCTUnwrap(Origin.capture(0, helper: stable, operations: operations))
            let proof = try XCTUnwrap(Origin.verify(captured, helper: stable,
                bundledHelper: URL(fileURLWithPath: "/Applications/refik.app/Contents/MacOS/refikHook"), operations: operations))
            var observed = input(); Origin.apply(proof, to: &observed, operations: operations)
            XCTAssertEqual(observed.runtime?.host, .terminal)
            XCTAssertEqual(observed.verifiedTerminalHost, "com.googlecode.iterm2")
        }
    }
}
