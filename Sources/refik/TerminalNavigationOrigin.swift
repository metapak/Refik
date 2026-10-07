import Foundation
import Darwin
import RefikInteractionWire

// Navigation only: never an attention, request, or provider-origin proof.
// Adapted public tab-link/actual-running-bundle approach; notices are in
// THIRD_PARTY_NOTICES.md. No process environment is inspected here.
struct TerminalNavigationTarget: Codable, Equatable {
    let bundleID: String
    let ancestors: [AntigravityTerminalOrigin.ProcessIdentity]
    let sourceFile: AntigravityTerminalOrigin.FileIdentity
    let terminalFile: AntigravityTerminalOrigin.FileIdentity
    let tabToken: String?
}

enum TerminalNavigationOrigin {
    typealias Operations = AntigravityTerminalOrigin.Operations
    struct Capture {
        let ancestors: [AntigravityTerminalOrigin.ProcessIdentity]
        let issuedAt: Double
    }
    struct Binding {
        let target: TerminalNavigationTarget
        let sessionID: String, turnID: String, eventID: String
        let provider: Provider, kind: EventKind
        let issuedAt: Double
    }
    static func capture(_ socket: Int32, helper: URL, operations: Operations = AntigravityTerminalOrigin.live, diagnostic: (TerminalNavigationDiagnostic.Stage) -> Void = { _ in }) -> Capture? {
        guard let pid = operations.peer(socket), let peer = operations.process(pid) else { diagnostic(.capturePeerMissing); return nil }
        guard peer.uid == getuid(), peer.realUID == getuid(), peer.path == helper.path else { diagnostic(.capturePeerMismatch); return nil }
        var ancestors: [AntigravityTerminalOrigin.ProcessIdentity] = []
        var next = peer.parent
        for _ in 0..<12 {
            guard next != 1 else { diagnostic(.captureReachedRoot); return nil }
            guard let p = operations.process(next), p.parent != p.pid else { diagnostic(.captureProcessUnavailable); return nil }
            let login = p.uid == 0 && p.realUID == getuid() && p.path == "/usr/bin/login" &&
                operations.signed(URL(fileURLWithPath: p.path), "com.apple.login", nil)
            guard (p.uid == getuid() && p.realUID == getuid()) || login else { diagnostic(.captureOwnershipRejected); return nil }
            ancestors.append(p)
            if AntigravityTerminalOrigin.terminalHosts.contains(where: { $0.binary == p.path }) {
                diagnostic(.captureReady)
                return Capture(ancestors: ancestors, issuedAt: operations.now())
            }
            next = p.parent
        }
        diagnostic(.captureTerminalMissing); return nil
    }
    static func validTabToken(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 100,
              value.range(of: "^w[0-9]+t[0-9]+p[0-9]+:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    static func bind(_ capture: Capture?, event: CodexEvent, helper: URL, bundledHelper: URL,
                     operations: Operations = AntigravityTerminalOrigin.live, diagnostic: (TerminalNavigationDiagnostic.Stage) -> Void = { _ in }) -> Binding? {
        guard let capture else { diagnostic(.bindNoCapture); return nil }
        guard [.codex, .claude, .antigravity].contains(event.provider), event.verifiedEditorHost == nil,
              event.runtime?.host != .vscode, event.runtime?.host != .codexDesktop else { diagnostic(.bindOriginPriority); return nil }
        guard operations.now() - capture.issuedAt >= 0, operations.now() - capture.issuedAt <= 3 else { diagnostic(.bindExpired); return nil }
        guard operations.helperMatches(helper, bundledHelper) else { diagnostic(.bindHelperMismatch); return nil }
        guard let terminal = capture.ancestors.last,
              let host = AntigravityTerminalOrigin.terminalHosts.first(where: { $0.binary == terminal.path }),
              operations.signed(host.application, host.bundleID, host.team) else { diagnostic(.bindTerminalSignature); return nil }
        guard let sourceIndex = capture.ancestors.firstIndex(where: {
                  let path = URL(fileURLWithPath: $0.path)
                  return path.lastPathComponent == (event.provider == .antigravity ? "agy" : event.provider.rawValue) ||
                    event.provider == .claude && $0.path.contains("/claude/versions/")
              }), sourceIndex < capture.ancestors.count - 1 else { diagnostic(.bindSourceMissing); return nil }
        guard let sourceFile = operations.file(URL(fileURLWithPath: capture.ancestors[sourceIndex].path)),
              let terminalFile = operations.file(URL(fileURLWithPath: terminal.path)) else { diagnostic(.bindFilesUnavailable); return nil }
        guard capture.ancestors.allSatisfy({ operations.process($0.pid) == $0 }) else { diagnostic(.bindAncestryChanged); return nil }
        diagnostic(.bindReady)
        let target = TerminalNavigationTarget(bundleID: host.bundleID,
            ancestors: Array(capture.ancestors[sourceIndex...]), sourceFile: sourceFile, terminalFile: terminalFile,
            tabToken: host.bundleID == "com.googlecode.iterm2" ? validTabToken(event.navigationTabToken) : nil)
        return Binding(target: target, sessionID: event.sessionID, turnID: event.turnID, eventID: event.id,
            provider: event.provider, kind: event.kind, issuedAt: capture.issuedAt)
    }
    static func apply(_ binding: Binding?, to event: inout CodexEvent, operations: Operations = AntigravityTerminalOrigin.live, diagnostic: (TerminalNavigationDiagnostic.Stage) -> Void = { _ in }) {
        event.terminalNavigation = nil
        event.terminalNavigationIssuedAt = nil
        guard let binding, event.sessionID == binding.sessionID, event.turnID == binding.turnID,
              event.id == binding.eventID, event.provider == binding.provider, event.kind == binding.kind else { diagnostic(.applyIdentityMismatch); return }
        guard event.verifiedEditorHost == nil, event.runtime?.host != .vscode, event.runtime?.host != .codexDesktop else { diagnostic(.applyOriginPriority); return }
        guard operations.now() - binding.issuedAt >= 0, operations.now() - binding.issuedAt <= 3 else { diagnostic(.applyExpired); return }
        guard tabURL(binding.target, operations: operations) != nil || sourceCurrent(binding.target, operations: operations) else { diagnostic(.applySourceInvalid); return }
        diagnostic(.applied)
        event.terminalNavigation = binding.target
        event.terminalNavigationIssuedAt = binding.issuedAt
    }
    static func application(_ target: TerminalNavigationTarget, operations: Operations = AntigravityTerminalOrigin.live) -> URL? {
        guard let terminal = target.ancestors.last,
              let host = AntigravityTerminalOrigin.terminalHosts.first(where: { $0.bundleID == target.bundleID && $0.binary == terminal.path }),
              operations.process(terminal.pid) == terminal,
              operations.file(URL(fileURLWithPath: terminal.path)) == target.terminalFile,
              operations.signed(host.application, host.bundleID, host.team) else { return nil }
        return host.application
    }
    static func sourceCurrent(_ target: TerminalNavigationTarget, operations: Operations = AntigravityTerminalOrigin.live) -> Bool {
        guard let source = target.ancestors.first, application(target, operations: operations) != nil,
              operations.file(URL(fileURLWithPath: source.path)) == target.sourceFile else { return false }
        return target.ancestors.allSatisfy {
            operations.process($0.pid) == $0 && ($0.path != "/usr/bin/login" ||
                operations.signed(URL(fileURLWithPath: $0.path), "com.apple.login", nil))
        }
    }
    static func tabURL(_ target: TerminalNavigationTarget, operations: Operations = AntigravityTerminalOrigin.live) -> URL? {
        guard target.bundleID == "com.googlecode.iterm2", let token = validTabToken(target.tabToken),
              sourceCurrent(target, operations: operations) else { return nil }
        return URL(string: "iterm2:reveal?sessionid=" + token)
    }
}
