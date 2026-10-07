import Foundation
import Darwin
import RefikInteractionWire

enum BridgePath {
    static var directory: URL {
        LegacyMigration.dataOverride.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik", isDirectory: true)
    }
    static var socket: URL { directory.appendingPathComponent("events.sock") }
    static var token: URL { directory.appendingPathComponent("signal.token") }
}

final class HookBridge: InteractionResponseTransport {
    private let queue = DispatchQueue(label: "refik.socket", qos: .utility)
    private let clients = DispatchQueue(label: "refik.socket.clients", qos: .utility, attributes: .concurrent)
    private let delivery = DispatchQueue(label: "refik.socket.delivery", qos: .utility)
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var accepted: Set<Int32> = []
    private var channels: [String: Channel] = [:]
    private var epoch = UUID().uuidString
    private let socketURL: URL
    private let tokenURL: URL
    private let monotonicNow: () -> Double
    private let onEvent: (CodexEvent) -> Void
    private let onInteraction: ((CodexEvent, String) -> Void)?
    private let onInvalidation: ((RequestIdentity) -> Void)?
    private let onAntigravityObservation: ((CodexEvent, AntigravityHookObservation) -> Void)?
    private let onVSCodeObservation: ((CodexEvent, VSCodeHookObservation) -> Void)?
    private let onEditorFocus: ((String, EditorHostBinding, EditorFocusObservation?, Double, Date) -> Void)?
    private var rateLimiter = ManualRateLimiter()
    private final class Channel {
        let fd: Int32; let wire: HookIdentity; let request: PendingRequestSnapshot; let expires: Double
        var actionID: String?; var acknowledged = false
        let done = DispatchSemaphore(value: 0)
        init(fd: Int32, wire: HookIdentity, request: PendingRequestSnapshot, expires: Double) {
            self.fd = fd; self.wire = wire; self.request = request; self.expires = expires
        }
    }
    enum TransportError: Error { case unavailable, invalidResponse }
    init(socketURL: URL = BridgePath.socket, tokenURL: URL = BridgePath.token,
         monotonicNow: @escaping () -> Double = { HookWire.uptime },
         onInteraction: ((CodexEvent, String) -> Void)? = nil,
         onInvalidation: ((RequestIdentity) -> Void)? = nil,
         onAntigravityObservation: ((CodexEvent, AntigravityHookObservation) -> Void)? = nil,
         onVSCodeObservation: ((CodexEvent, VSCodeHookObservation) -> Void)? = nil,
         onEditorFocus: ((String, EditorHostBinding, EditorFocusObservation?, Double, Date) -> Void)? = nil,
         onEvent: @escaping (CodexEvent) -> Void) {
        self.socketURL = socketURL; self.tokenURL = tokenURL; self.onEvent = onEvent; self.monotonicNow = monotonicNow
        self.onInteraction = onInteraction; self.onInvalidation = onInvalidation
        self.onAntigravityObservation = onAntigravityObservation
        self.onVSCodeObservation = onVSCodeObservation
        self.onEditorFocus = onEditorFocus
    }
    func start() {
        queue.async {
            let directory = self.socketURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !FileManager.default.fileExists(atPath: self.tokenURL.path) {
                let secret = UUID().uuidString + UUID().uuidString
                let tokenFD = Darwin.open(self.tokenURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                if tokenFD >= 0 { _ = HookWire.writeData(Data(secret.utf8), fd: tokenFD); close(tokenFD) }
            }
            guard HookWire.secret(self.tokenURL) != nil else { return }
            if FileManager.default.fileExists(atPath: self.socketURL.path) {
                guard HookWire.secureFile(self.socketURL, socket: true) else { return }
                _ = unlink(self.socketURL.path)
            }
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { return }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(self.socketURL.path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(s); return }
            withUnsafeMutablePointer(to: &address.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
                    for (i, b) in bytes.enumerated() { chars[i] = CChar(bitPattern: b) }; chars[bytes.count] = 0
                }
            }
            let bound = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0 else { close(s); return }
            _ = chmod(self.socketURL.path, 0o600)
            guard listen(s, 32) == 0 else { close(s); return }
            self.lock.lock(); self.fd = s; self.epoch = UUID().uuidString; self.lock.unlock()
            while true {
                let c = accept(s, nil, nil)
                guard c >= 0 else { break }
                self.lock.lock()
                let admitted = self.fd == s && self.accepted.count < 48 && self.accepted.count - self.channels.count < 32
                if admitted { self.accepted.insert(c) }
                self.lock.unlock()
                guard admitted else { close(c); continue }
                self.clients.async { self.handle(c) }
            }
            self.lock.lock(); if self.fd == s { self.fd = -1 }; self.lock.unlock()
            close(s); _ = unlink(self.socketURL.path)
        }
    }
    private func traceNavigation(_ stage: TerminalNavigationDiagnostic.Stage) {
        TerminalNavigationDiagnostic.record(.init(stage), directory: socketURL.deletingLastPathComponent())
    }
    private func handle(_ c: Int32) {
        defer { lock.lock(); accepted.remove(c); lock.unlock(); close(c) }
        let capturedOrigin = EditorFocusHost.capturePeer(c, helper: HookInstaller.helperDestination)
        let capturedTerminal = AntigravityTerminalOrigin.capture(c, helper: HookInstaller.helperDestination)
        let capturedNavigation = TerminalNavigationOrigin.capture(c, helper: HookInstaller.helperDestination, diagnostic: { self.traceNavigation($0) })
        let capturedPublisher = CodexHookOrigin.capturePublisher(c, helper: HookInstaller.helperDestination)
        HookWire.timeout(c, seconds: 0.5)
        guard let bytes = HookWire.receive(c, deadline: monotonicNow() + 0.5, now: monotonicNow) else { return }
        if let hello = try? JSONDecoder().decode(HookFrame.self, from: bytes) {
            guard hello.protocolVersion == HookWire.protocolVersion else { return }
            guard bytes.last == 10 else { return }
            if hello.type == "editor-focus-connect" { handleEditorFocus(hello, fd: c); return }
            if hello.type == "request" { handleInteractive(hello, fd: c); return }
            if hello.type == "observation" {
                if capturedOrigin != nil || capturedTerminal != nil { _ = HookWire.send(HookFrame(type: "origin-captured"), fd: c) }
                if let observation = hello.vscodeObservation {
                    guard hello.antigravityObservation == nil, let secret = HookWire.secret(tokenURL), hello.token == secret,
                          observation.isValid, let payload = hello.payload else { return }
                    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                    guard var event = try? decoder.decode(CodexEvent.self, from: payload), event.provider == .copilot,
                          event.sessionID == "copilot:" + observation.sessionID, event.runtime?.host == .vscode,
                          event.runtime?.id.isEmpty == false else { return }
                    bindEditorOrigin(&event, capture: capturedOrigin)
                    event.capabilities = nil; event.requestSnapshot = nil
                    delivery.async {
                        if let callback = self.onVSCodeObservation { callback(event, observation) }
                        else { self.onEvent(event) }
                    }
                    return
                }
                guard let secret = HookWire.secret(tokenURL), hello.token == secret,
                      let observation = hello.antigravityObservation, observation.isValid,
                      let payload = hello.payload else { return }
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                guard var event = try? decoder.decode(CodexEvent.self, from: payload), event.provider == .antigravity,
                      event.sessionID == "antigravity:" + observation.conversationID,
                      event.runtime?.id.isEmpty == false, event.requestID == nil, event.requestSnapshot == nil else { return }
                bindEditorOrigin(&event, capture: capturedOrigin)
                let terminalProof = AntigravityTerminalOrigin.verify(capturedTerminal,
                    helper: HookInstaller.helperDestination,
                    bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"))
                let navigation = TerminalNavigationOrigin.bind(capturedNavigation, event: event,
                    helper: HookInstaller.helperDestination, bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"), diagnostic: { self.traceNavigation($0) })
                event.capabilities = nil
                delivery.async {
                    AntigravityTerminalOrigin.apply(terminalProof, to: &event)
                    TerminalNavigationOrigin.apply(navigation, to: &event, diagnostic: { self.traceNavigation($0) })
                    if let callback = self.onAntigravityObservation { callback(event, observation) }
                    else { self.onEvent(event) }
                }
            }
            return
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var event = try? decoder.decode(CodexEvent.self, from: bytes) else { return }
        if capturedOrigin != nil || capturedPublisher != nil { _ = HookWire.send(HookFrame(type: "origin-captured"), fd: c) }
        bindEditorOrigin(&event, capture: capturedOrigin)
        // The AG receiver owns step generations; unframed traffic must not
        // bypass its authenticated observation gate and clear pending state.
        if event.provider == .antigravity, onAntigravityObservation != nil { return }
        if event.provider == .copilot, event.runtime?.host == .vscode, onVSCodeObservation != nil { return }
        // Passive traffic cannot advertise an actionable response channel.
        event.capabilities = nil
        var codexOriginStage: HookOriginDiagnostic.Stage = .publisherMissing
        let codexBinding = event.provider == .codex ? CodexHookOrigin.validate(capturedPublisher, event: event,
            helper: HookInstaller.helperDestination, bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"), diagnostic: { stage in
                codexOriginStage = stage
                HookOriginDiagnostic.record(.init(stage: stage, sessionID: event.sessionID, turnID: event.turnID,
                    locatorPresent: event.transcriptPath != nil), directory: self.socketURL.deletingLastPathComponent())
            }) : nil
        let validationStage = codexOriginStage
        let navigation = TerminalNavigationOrigin.bind(capturedNavigation, event: event,
            helper: HookInstaller.helperDestination, bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"), diagnostic: { self.traceNavigation($0) })
        delivery.async {
            var codexOriginStage = validationStage
            if let binding = codexBinding {
                let deliver = CodexHookOrigin.apply(binding, to: &event)
                let stage: HookOriginDiagnostic.Stage = !deliver ? .childSuppressed : event.runtime?.host == binding.host && event.source == binding.source ? .applied : .applicationInvalidated
                HookOriginDiagnostic.record(.init(stage: stage, sessionID: event.sessionID, turnID: event.turnID), directory: self.socketURL.deletingLastPathComponent())
                codexOriginStage = stage
                if !deliver { return }
            }
            if event.provider == .codex {
                event.codexOriginObservation = CodexOriginObservation(stage: codexOriginStage, locatorPresent: event.transcriptPath != nil)
            }
            TerminalNavigationOrigin.apply(navigation, to: &event, diagnostic: { self.traceNavigation($0) })
            if event.provider == .watch || event.provider == .signal {
                guard event.authToken == HookWire.secret(self.tokenURL), event.authToken != nil,
                      self.rateLimiter.accept(event.sessionID, at: Date()) else { return }
            }
            self.onEvent(event)
        }
    }
    private func bindEditorOrigin(_ event: inout CodexEvent, capture: EditorFocusHost.PeerCapture?) {
        event.verifiedEditorHost = EditorFocusHost.verifyPeer(capture, helper: HookInstaller.helperDestination,
            bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"))?.bundleID
    }
    private func handleEditorFocus(_ hello: HookFrame, fd: Int32) {
        guard let callback = onEditorFocus, let token = HookWire.secret(tokenURL), hello.token == token,
              let host = EditorFocusHost.peer(fd, helper: HookInstaller.helperDestination,
                bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook")) else { return }
        let connection = UUID().uuidString
        guard HookWire.send(HookFrame(type: "editor-focus-ready", epoch: connection), fd: fd) else { return }
        defer { callback(connection, host, nil, monotonicNow(), Date()) }
        var window: String?; var generation: String?; var sequence: UInt64 = 0
        var challenges = EditorFocusChallengeGate()
        while let bytes = HookWire.receive(fd, requireNewline: true, deadline: monotonicNow() + 5, now: monotonicNow) {
            guard let frame = try? JSONDecoder().decode(HookFrame.self, from: bytes),
                  frame.protocolVersion == HookWire.protocolVersion, frame.epoch == connection,
                  EditorFocusHost.isCurrent(host) else { return }
            if frame.type == "editor-focus-poll" {
                let nonce = challenges.issue(at: monotonicNow(), date: Date())
                guard HookWire.send(HookFrame(type: "editor-focus-challenge", epoch: connection, actionID: nonce), fd: fd) else { return }
                continue
            }
            guard ["editor-focus", "editor-focus-blur"].contains(frame.type),
                  let observation = frame.editorFocus, observation.isValid else { return }
            guard observation.sequence > sequence else { continue }
            guard window == nil || (window == observation.windowID && generation == observation.generation) else { return }
            let issued: Double, date: Date
            if frame.type == "editor-focus-blur" {
                guard !observation.focused else { return }
                issued = monotonicNow(); date = Date()
            } else {
                guard let timing = challenges.consume(frame.actionID, at: monotonicNow()) else { continue }
                issued = timing.issued; date = timing.date
            }
            window = observation.windowID; generation = observation.generation; sequence = observation.sequence
            callback(connection, host, observation, issued, date)
        }
    }
    private func handleInteractive(_ hello: HookFrame, fd: Int32) {
        guard let onInteraction, let token = HookWire.secret(tokenURL), hello.token == token,
              let identity = hello.identity, let bytes = hello.payload,
              !identity.requestToken.isEmpty, UUID(uuidString: identity.hookInstance) != nil,
              ["claude", "codex"].contains(identity.provider) else { return }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard var event = try? decoder.decode(CodexEvent.self, from: bytes), let request = event.requestSnapshot,
              request.isValid, request.lifecycle == .pending,
              request.identity.provider == event.provider, request.identity.sessionID == event.sessionID,
              request.identity.requestID == event.requestID, request.identity.turnID == event.turnID,
              event.runtime?.id == identity.runtimeID, HookRuntimeContract.supports(provider: identity.provider, version: event.runtime?.version),
              identity.provider == event.provider.rawValue, identity.runtimeID == request.identity.runtimeID,
              identity.sessionID == event.sessionID, identity.requestID == event.requestID,
              request.identity.generation == identity.hookInstance,
              request.identity.turnID == (identity.providerTurnID ?? "hook:" + identity.hookInstance),
              (event.provider == .claude || request.kind == .permission) else { return }
        bindEditorOrigin(&event, capture: EditorFocusHost.capturePeer(fd, helper: HookInstaller.helperDestination))
        let navigation = TerminalNavigationOrigin.bind(TerminalNavigationOrigin.capture(fd, helper: HookInstaller.helperDestination, diagnostic: { self.traceNavigation($0) }), event: event,
            helper: HookInstaller.helperDestination, bundledHelper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"), diagnostic: { self.traceNavigation($0) })
        let lease = min(HookWire.maxLease, hello.lease ?? 0)
        guard lease > 0 else { return }
        let channelID = UUID().uuidString
        let channel = Channel(fd: fd, wire: identity, request: request, expires: monotonicNow() + lease)
        lock.lock()
        guard channels.count < 16, self.fd >= 0 else { lock.unlock(); return }
        let currentEpoch = epoch
        channels[channelID] = channel
        lock.unlock()
        defer {
            lock.lock(); channels.removeValue(forKey: channelID); let didAck = channel.acknowledged; lock.unlock()
            channel.done.signal()
            if !didAck { delivery.async { self.onInvalidation?(request.identity) } }
        }
        guard HookWire.send(HookFrame(type: "ready", identity: identity, epoch: currentEpoch, lease: lease), fd: fd) else { return }
        event.capabilities?.responseChannelID = channelID
        delivery.async {
            TerminalNavigationOrigin.apply(navigation, to: &event, diagnostic: { self.traceNavigation($0) })
            onInteraction(event, channelID)
        }
        HookWire.timeout(fd, seconds: lease)
        guard let ack = HookWire.frame(fd, deadline: channel.expires, now: monotonicNow), ack.type == "consumed", ack.identity == identity, ack.epoch == currentEpoch else { return }
        lock.lock()
        channel.acknowledged = channel.actionID != nil && ack.actionID == channel.actionID
        lock.unlock()
    }
    func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt {
        try await withCheckedThrowingContinuation { continuation in
            clients.async {
                self.lock.lock()
                guard let channel = self.channels[channelID], channel.expires > self.monotonicNow(), channel.actionID == nil else {
                    self.lock.unlock(); continuation.resume(throwing: TransportError.unavailable); return
                }
                guard response.isValid(for: channel.request), let payload = try? JSONEncoder().encode(response) else {
                    self.lock.unlock(); continuation.resume(throwing: TransportError.invalidResponse); return
                }
                let action = UUID().uuidString; channel.actionID = action; let currentEpoch = self.epoch
                let sendFD = dup(channel.fd)
                self.lock.unlock()
                if !HookWire.send(HookFrame(type: "decision", identity: channel.wire, epoch: currentEpoch, actionID: action, payload: payload), fd: sendFD) {
                    shutdown(sendFD, SHUT_RDWR)
                }
                if sendFD >= 0 { close(sendFD) }
                _ = channel.done.wait(timeout: .now() + max(0, channel.expires - self.monotonicNow()))
                self.lock.lock(); let acknowledged = channel.acknowledged; self.lock.unlock()
                continuation.resume(returning: ResponseReceipt(identity: response.identity, lifecycle: acknowledged ? .submitted : .deliveryUnknown))
            }
        }
    }
    func revoke(channelID: String) { resumeNative(channelID: channelID) }
    func hasLiveChannel(_ channelID: String, identity: RequestIdentity) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let channel = channels[channelID] else { return false }
        return channel.request.identity == identity && channel.expires > monotonicNow() && channel.actionID == nil
    }
    @discardableResult func resumeNative(channelID: String, identity: RequestIdentity) -> Bool {
        lock.lock()
        guard let channel = channels[channelID], channel.request.identity == identity,
              channel.actionID == nil, channel.expires > monotonicNow() else { lock.unlock(); return false }
        channels.removeValue(forKey: channelID); lock.unlock()
        shutdown(channel.fd, SHUT_RDWR)
        return true
    }
    func resumeNative(channelID: String) {
        lock.lock(); let channel = channels.removeValue(forKey: channelID); lock.unlock()
        if let channel { shutdown(channel.fd, SHUT_RDWR) }
    }
    func stop() {
        lock.lock(); let s = fd; fd = -1; let all = accepted; channels.removeAll(); lock.unlock()
        for c in all { shutdown(c, SHUT_RDWR) }
        if s >= 0 { shutdown(s, SHUT_RDWR) }
    }
}

struct ManualRateLimiter {
    private var globalStart = Date.distantPast
    private var globalCount = 0
    private var entities: [String: (Date, Int)] = [:]
    mutating func accept(_ entity: String, at now: Date) -> Bool {
        if now.timeIntervalSince(globalStart) >= 1 {
            globalStart = now; globalCount = 0
            entities = entities.filter { now.timeIntervalSince($0.value.0) < 1 }
        }
        let current = entities[entity]
        let count = current.map { now.timeIntervalSince($0.0) < 1 ? $0.1 : 0 } ?? 0
        guard globalCount < 60, count < 12, entities.count < 256 || current != nil else { return false }
        globalCount += 1
        entities[entity] = (now, count + 1)
        return true
    }
}


enum HookInstaller {
    // Every in-process settings mutation shares this lock. Repair delegates to
    // setEnabled while holding it, hence recursion is intentional.
    private static let mutationLock = NSRecursiveLock()
    struct RuntimeVersionProbe {
        let executable: URL
        let version: String
    }
    // Read-only public CLI probe. The caller must verify that this version's
    // documented hook contract is supported before passing its version to install.
    static func probeRuntimeVersion(_ provider: Provider) async -> RuntimeVersionProbe? {
        guard provider == .codex || provider == .claude else { return nil }
        return await Task.detached(priority: .utility) {
            let search = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin").split(separator: ":")
            guard let executable = search.map({ URL(fileURLWithPath: String($0)).appendingPathComponent(provider.rawValue) })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else { return nil }
            let process = Process(); process.executableURL = executable; process.arguments = ["--version"]
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let finished = DispatchSemaphore(value: 0); process.terminationHandler = { _ in finished.signal() }
            do { try process.run() } catch { return nil }
            guard finished.wait(timeout: .now() + 2) == .success else { process.terminate(); return nil }
            guard process.terminationStatus == 0,
                  let bytes = try? output.fileHandleForReading.read(upToCount: 4096),
                  let text = String(data: bytes, encoding: .utf8),
                  let version = HookRuntimeContract.parseVersionOutput(text) else { return nil }
            return RuntimeVersionProbe(executable: executable, version: version)
        }.value
    }

    static var helperDestination: URL { BridgePath.directory.appendingPathComponent("refikHook") }
    static var cliDestination: URL { BridgePath.directory.appendingPathComponent("refikCLI") }
    static func configuration(_ provider: Provider) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch provider {
        case .codex: return home.appendingPathComponent(".codex/hooks.json")
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        case .antigravity: return home.appendingPathComponent(".gemini/config/hooks.json")
        case .cursor: return home.appendingPathComponent(".cursor/hooks.json")
        case .windsurf: return home.appendingPathComponent(".codeium/windsurf/hooks.json")
        case .copilot:
            let base = ProcessInfo.processInfo.environment["COPILOT_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".copilot")
            return base.appendingPathComponent("hooks/refik.json")
        default: return home.appendingPathComponent(".config/refik/unused.json")
        }
    }
    static var configuration: URL { configuration(.codex) }
    static let codexLifecycleEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PreToolUse", "PostToolUse", "Stop", "Interrupt", "SessionEnd"]
    static let codexIdentityEvents = ["SubagentStart", "SubagentStop"]
    static let codexEvents = codexLifecycleEvents + codexIdentityEvents
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest", "Notification", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionDenied", "Stop", "StopFailure", "SessionEnd"]
    static let antigravityEvents = ["PreInvocation", "PostInvocation", "PreToolUse", "PostToolUse", "Stop"]
    // Cursor prepermission events deliberately omitted: empty stdout can block.
    static let cursorEvents = ["sessionStart", "sessionEnd", "postToolUse", "postToolUseFailure", "afterShellExecution", "afterMCPExecution", "afterFileEdit", "afterAgentResponse", "afterAgentThought", "stop"]
    static let windsurfEvents = ["pre_read_code", "post_read_code", "pre_write_code", "post_write_code", "pre_run_command", "post_run_command", "pre_mcp_tool_use", "post_mcp_tool_use", "pre_user_prompt", "post_cascade_response"]
    static let copilotEvents = ["sessionStart", "sessionEnd", "userPromptSubmitted", "preToolUse", "postToolUse", "postToolUseFailure", "agentStop", "errorOccurred", "permissionRequest", "notification"]
    @discardableResult static func ensureHelper(destination: URL? = nil, bundled: URL? = nil) throws -> Bool {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let manager = FileManager.default
        let source = bundled ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook")
        let target = destination ?? helperDestination
        guard manager.isExecutableFile(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
        if AntigravityTerminalOrigin.live.helperMatches(target, source) { return false }
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.deletingLastPathComponent().path)
        try Data(contentsOf: source).write(to: target, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        guard AntigravityTerminalOrigin.live.helperMatches(target, source) else { throw CocoaError(.fileWriteUnknown) }
        return true
    }
    static func installed(_ provider: Provider = .codex) -> Bool {
        let path = configuration(provider)
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if provider == .antigravity { return hasOwnedObserver(root, helper: helperDestination) }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        if [.cursor, .windsurf, .copilot].contains(provider) {
            return hooks.values.contains { value in
                (value as? [[String: Any]])?.contains { entry in
                    LegacyMigration.ownsCommand(entry["command"] as? String ?? entry["bash"] as? String ?? "", executable: helperDestination)
                } ?? false
            }
        }
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { handler in
                    LegacyMigration.ownsCommand(handler["command"] as? String ?? "", executable: helperDestination)
                } ?? false
            } ?? false
        }
    }
    // Upgrade an existing complete installation; never enable a partial or
    // explicitly disabled configuration during startup.
    @discardableResult static func repairExistingClaude(at override: URL? = nil, helper: URL? = nil, beforeRepair: (() -> Void)? = nil) throws -> Bool {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let url = override ?? configuration(.claude), commandPath = helper ?? helperDestination
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let original = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        if let value = root["disableAllHooks"] {
            guard let disabled = value as? NSNumber, CFGetTypeID(disabled) == CFBooleanGetTypeID() else { throw CocoaError(.fileReadCorruptFile) }
            if disabled.boolValue { return false }
        }
        guard let hooks = root["hooks"] as? [String: Any] else {
            if root["hooks"] != nil { throw CocoaError(.fileReadCorruptFile) }
            return false
        }
        var present = Set<String>()
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            for entry in entries {
                guard let handlers = entry["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                if handlers.contains(where: { LegacyMigration.ownsCommand($0["command"] as? String ?? "", executable: commandPath) }) { present.insert(event) }
            }
        }
        guard Set(claudeEvents.filter { $0 != "PermissionDenied" }).isSubset(of: present) else { return false }
        try setEnabled(true, provider: .claude, at: url, helper: commandPath, expectedOriginal: original, beforeReplacement: beforeRepair)
        return try Data(contentsOf: url) != original
    }
    static func setEnabled(_ enabled: Bool) throws { try setEnabled(enabled, provider: .codex) }
    // Only an explicit install/repair may opt a verified local Claude runtime
    // into blocking reply hooks. Startup repair preserves the previous choice.
    @discardableResult static func setExplicitlyEnabled(_ enabled: Bool, provider: Provider, at url: URL? = nil,
        helper: URL? = nil, expectedOriginal: Data? = nil,
        claudeCandidates: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"), URL(fileURLWithPath: "/usr/local/bin/claude")],
        operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live,
        probe: (URL) -> String? = HookRuntimeContract.probe) throws -> Bool {
        var version: String?
        if enabled && provider == .claude {
            for candidate in claudeCandidates {
                let executable = candidate.resolvingSymlinksInPath()
                guard let before = operations.file(executable),
                      operations.signed(executable, "com.anthropic.claude-code", "Q6L2SF6YDW"),
                      let found = probe(executable),
                      operations.file(executable) == before,
                      candidate.resolvingSymlinksInPath() == executable,
                      HookRuntimeContract.supports(provider: "claude", version: found) else { continue }
                version = found; break
            }
        }
        // An unsupported explicit repair must also remove an obsolete pin.
        try setEnabled(enabled, provider: provider, at: url, helper: helper,
            runtimeVersion: provider == .claude && enabled ? version ?? "" : nil,
            expectedOriginal: expectedOriginal)
        return version != nil
    }
    @discardableResult static func repairExistingCodexIdentityObservers(at override: URL? = nil, helper: URL? = nil) throws -> Bool {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let url = override ?? configuration(.codex), commandPath = helper ?? helperDestination
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let original = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        if let value = root["disableAllHooks"] {
            guard let disabled = value as? NSNumber, CFGetTypeID(disabled) == CFBooleanGetTypeID() else { throw CocoaError(.fileReadCorruptFile) }
            if disabled.boolValue { return false }
        }
        guard var hooks = root["hooks"] as? [String: Any] else { return false }
        var owned = Set<String>()
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            for entry in entries {
                guard let handlers = entry["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                if handlers.contains(where: { LegacyMigration.ownsCommand($0["command"] as? String ?? "", executable: commandPath) }) { owned.insert(event) }
            }
        }
        guard Set(codexLifecycleEvents).isSubset(of: owned) else { return false }
        let quoted = "'" + commandPath.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        var changed = false
        for event in codexIdentityEvents where !owned.contains(event) {
            var entries = hooks[event] as? [[String: Any]] ?? []
            entries.append(["hooks": [["type": "command", "command": "\(quoted) codex \(event)", "timeout": 1]]])
            hooks[event] = entries; changed = true
        }
        guard changed else { return false }
        root["hooks"] = hooks
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard try Data(contentsOf: url) == original else { throw CocoaError(.fileWriteFileExists) }
        let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".refik-backup-" + UUID().uuidString)
        try FileManager.default.copyItem(at: url, to: backup)
        guard try Data(contentsOf: url) == original else { throw CocoaError(.fileWriteFileExists) }
        try output.write(to: url, options: .atomic)
        return true
    }
    static func hasOwnedObserver(_ root: [String: Any], helper: URL) -> Bool {
        guard let observer = root["refik-observer"] as? [String: Any] else { return false }
        return antigravityEvents.contains { event in
            (observer[event] as? [[String: Any]])?.contains { item in
                LegacyMigration.ownsCommand(item["command"] as? String ?? "", executable: helper) ||
                (item["hooks"] as? [[String: Any]])?.contains {
                    LegacyMigration.ownsCommand($0["command"] as? String ?? "", executable: helper)
                } == true
            } ?? false
        }
    }
    static func setEnabled(_ enabled: Bool, provider: Provider, at override: URL? = nil, helper: URL? = nil, runtimeVersion: String? = nil, runtimeHost: RuntimeHost = .unknown, expectedOriginal: Data? = nil, beforeReplacement: (() -> Void)? = nil) throws {
        mutationLock.lock(); defer { mutationLock.unlock() }
        guard [.codex, .claude, .antigravity, .cursor, .windsurf, .copilot].contains(provider) else { throw CocoaError(.fileReadUnsupportedScheme) }
        let url = override ?? configuration(provider)
        let manager = FileManager.default
        let original = manager.fileExists(atPath: url.path) ? try Data(contentsOf: url) : Data("{}".utf8)
        if let expectedOriginal, original != expectedOriginal { throw CocoaError(.fileWriteFileExists) }
        guard var root = try JSONSerialization.jsonObject(with: original) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        let originalObject = root as NSDictionary
        let commandPath = helper ?? helperDestination
        var retainedClaudeSuffix = ""
        if provider == .claude {
            // Malformed foreign entries must survive untouched. Reject before
            // writing helper/configuration instead of silently dropping them.
            if let value = root["hooks"] {
                guard let hooks = value as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
                var ownedSuffixes = Set<String>()
                for (event, value) in hooks {
                    guard let entries = value as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                    for entry in entries {
                        guard let handlers = entry["hooks"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
                        for handler in handlers {
                            guard let command = handler["command"] as? String,
                                  claudeEvents.contains(event), LegacyMigration.ownsCommand(command, executable: commandPath) else { continue }
                            guard runtimeVersion == nil else { continue }
                            let prefixes = [LegacyMigration.quoted(commandPath.path) + " ", commandPath.path + " "]
                            guard let prefix = prefixes.first(where: command.hasPrefix) else { continue }
                            let remainder = String(command.dropFirst(prefix.count))
                            let base = "claude " + event
                            if remainder == base { ownedSuffixes.insert(""); continue }
                            let marker = base + " --interactive --runtime-version="
                            guard remainder.hasPrefix(marker) else { throw CocoaError(.fileReadCorruptFile) }
                            let version = String(remainder.dropFirst(marker.count))
                            guard HookRuntimeContract.supports(provider: "claude", version: version) else { throw CocoaError(.fileReadCorruptFile) }
                            ownedSuffixes.insert(" --interactive --runtime-version=" + version)
                        }
                    }
                }
                guard ownedSuffixes.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
                retainedClaudeSuffix = ownedSuffixes.first ?? ""
            }
        }
        if enabled && helper == nil {
            try ensureHelper()
            if provider == .claude {
                let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikCLI")
                guard manager.isExecutableFile(atPath: cli.path) else { throw CocoaError(.fileNoSuchFile) }
                try Data(contentsOf: cli).write(to: cliDestination, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cliDestination.path)
            }
        }
        let versionSuffix: String
        if HookRuntimeContract.supports(provider: provider.rawValue, version: runtimeVersion), let runtimeVersion,
           runtimeVersion.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$", options: .regularExpression) != nil {
            versionSuffix = " --interactive --runtime-version=" + runtimeVersion
        } else { versionSuffix = provider == .claude && runtimeVersion == nil ? retainedClaudeSuffix : "" }
        let quoted = "'" + commandPath.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        if expectedOriginal == nil {
            LegacyMigration.migrateStatusLineKey(&root)
            LegacyMigration.removeLegacyAntigravity(&root)
        }
        if [.cursor, .windsurf, .copilot].contains(provider) {
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let events = provider == .cursor ? cursorEvents : provider == .windsurf ? windsurfEvents : copilotEvents
            for name in events {
                var entries = hooks[name] as? [[String: Any]] ?? []
                entries.removeAll { LegacyMigration.ownsCommand($0["command"] as? String ?? $0["bash"] as? String ?? "", executable: commandPath) }
                if enabled {
                    let command = "\(quoted) \(provider.rawValue) \(name)"
                    if provider == .copilot { entries.append(["type": "command", "bash": command, "timeoutSec": 1]) }
                    else if provider == .windsurf { entries.append(["command": command, "show_output": false]) }
                    else { entries.append(["command": command, "timeout": 1]) }
                }
                if entries.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = entries }
            }
            root["hooks"] = hooks
            if provider != .windsurf { root["version"] = 1 }
        } else if provider == .antigravity {
            LegacyMigration.removeObserverCommands(&root, key: "refik-observer") {
                LegacyMigration.ownsCommand($0, executable: commandPath)
            }
            if enabled {
                var entry = root["refik-observer"] as? [String: Any] ?? [:]
                entry["enabled"] = true
                for event in antigravityEvents {
                    let handler: [String: Any] = ["type": "command", "command": "\(quoted) antigravity \(event)", "timeout": 1]
                    var items = entry[event] as? [[String: Any]] ?? []
                    if event == "PreToolUse" || event == "PostToolUse" {
                        items.append(["matcher": "*", "hooks": [handler]])
                    } else { items.append(handler) }
                    entry[event] = items
                }
                root["refik-observer"] = entry
            }
        } else {
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            let events = provider == .codex ? codexEvents : claudeEvents
            for name in events {
                var entries = hooks[name] as? [[String: Any]] ?? []
                entries = entries.compactMap { entry in
                    guard var handlers = entry["hooks"] as? [[String: Any]] else { return entry }
                    handlers.removeAll {
                        let command = $0["command"] as? String ?? ""
                        return LegacyMigration.ownsCommand(command, executable: commandPath) || LegacyMigration.ownsLegacyHook(command)
                    }
                    if handlers.isEmpty { return nil }
                    var edited = entry; edited["hooks"] = handlers; return edited
                }
                if enabled {
                    // Cursor may import these Claude commands; strict signed
                    // emitter validation takes over one second on a cold read.
                    let suffix = provider == .codex && codexIdentityEvents.contains(name) ? "" : versionSuffix
                    let handler: [String: Any] = ["type": "command", "command": "\(quoted) \(provider.rawValue) \(name)\(suffix)", "timeout": (!suffix.isEmpty && (name == "PermissionRequest" || provider == .claude && name == "PreToolUse")) ? 130 : (provider == .claude ? 3 : 1)]
                    entries.append(["hooks": [handler]])
                }
                if entries.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = entries }
            }
            root["hooks"] = hooks
            if provider == .claude && helper == nil {
                if enabled {
                    if root["refikOriginalStatusLine"] == nil {
                        let originalStatus = root["statusLine"] as? [String: Any]
                        if originalStatus == nil || originalStatus?["type"] as? String == "command" {
                            root["refikOriginalStatusLine"] = originalStatus ?? NSNull()
                        }
                    }
                    if let saved = root["refikOriginalStatusLine"] {
                        let command = (saved as? [String: Any])?["command"] as? String ?? ""
                        let encoded = Data(command.utf8).base64EncodedString()
                        let cliQuoted = "'" + cliDestination.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
                        root["statusLine"] = ["type": "command", "command": "\(cliQuoted) statusline \(encoded)"]
                    }
                } else if let saved = root["refikOriginalStatusLine"] {
                    let command = (root["statusLine"] as? [String: Any])?["command"] as? String ?? ""
                    if LegacyMigration.ownsCommand(command, executable: cliDestination) {
                        root.removeValue(forKey: "refikOriginalStatusLine")
                        if saved is NSNull { root.removeValue(forKey: "statusLine") }
                        else { root["statusLine"] = saved }
                    }
                }
            }
        }
        if provider == .claude, (root as NSDictionary).isEqual(originalObject) { return }
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        _ = try JSONSerialization.jsonObject(with: output)
        if original == output { return }
        if let expectedOriginal, try Data(contentsOf: url) != expectedOriginal { throw CocoaError(.fileWriteFileExists) }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if manager.fileExists(atPath: url.path) {
            let backup = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".refik-backup-" + UUID().uuidString)
            try manager.copyItem(at: url, to: backup)
        }
        if let expectedOriginal, try Data(contentsOf: url) != expectedOriginal { throw CocoaError(.fileWriteFileExists) }
        beforeReplacement?()
        try output.write(to: url, options: .atomic)
        guard let persisted = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: persisted)) != nil else { throw CocoaError(.fileWriteUnknown) }
    }
}
