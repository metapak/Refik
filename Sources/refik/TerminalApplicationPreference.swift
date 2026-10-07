import Foundation
import CryptoKit

// Explicit user choice for opening an application, never session-origin proof.
enum TerminalApplicationPreference: String, Codable, CaseIterable {
    case none, terminal, iTerm2
    var label: String {
        switch self { case .none: return "Seçilmedi"; case .terminal: return "Terminal"; case .iTerm2: return "iTerm2" }
    }
    struct Receipt: Equatable {
        let application: URL
        let bundleID: String
        let file: AntigravityTerminalOrigin.FileIdentity
    }
    func validated(operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live) -> Receipt? {
        guard self != .none,
              let host = AntigravityTerminalOrigin.terminalHosts.first(where: { $0.bundleID == (self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2") }),
              operations.signed(host.application, host.bundleID, host.team),
              let file = operations.file(URL(fileURLWithPath: host.binary)) else { return nil }
        return Receipt(application: host.application, bundleID: host.bundleID, file: file)
    }
    func matches(_ receipt: Receipt, operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live) -> Bool {
        validated(operations: operations) == receipt
    }
    func sourceMatches(_ receipt: Receipt, operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live) -> Bool {
        guard self != .none, let host = AntigravityTerminalOrigin.terminalHosts.first(where: {
            $0.bundleID == (self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2")
        }), host.application == receipt.application, host.bundleID == receipt.bundleID else { return false }
        return operations.file(URL(fileURLWithPath: host.binary)) == receipt.file
    }
    // Called off the main queue. Reuse only this click's first validation.
    func prepareOpening(_ first: Receipt? = nil, operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live) -> Receipt? {
        guard let receipt = first ?? validated(operations: operations), matches(receipt, operations: operations) else { return nil }
        return receipt
    }
    static func eligible(_ session: Session) -> Bool {
        [.codex, .claude, .antigravity].contains(session.provider) && session.runtime?.host == .terminal && session.verifiedEditorHost == nil
    }
}

struct TerminalOpeningSnapshot: Equatable {
    let sessionID: String, provider: Provider, turnID: String
    let runtime: RuntimeMetadata?
    let source: String
    let editor: String?, terminal: String?
    let target: TerminalNavigationTarget?
    let choice: TerminalApplicationPreference
    init(_ session: Session, choice: TerminalApplicationPreference) {
        sessionID = session.id; provider = session.provider; turnID = session.turnID
        runtime = session.runtime; source = session.source.rawValue
        editor = session.verifiedEditorHost; terminal = session.verifiedTerminalHost
        target = session.terminalNavigation; self.choice = choice
    }
    func matches(_ session: Session, choice: TerminalApplicationPreference) -> Bool {
        self == TerminalOpeningSnapshot(session, choice: choice)
    }
}

// Own bounded preferences only. No origin or attention evidence is stored.
struct SessionTerminalChoices: Codable {
    private var values: [String: TerminalApplicationPreference] = [:]
    static let limit = 128
    var count: Int { values.count }
    init() {}
    private static func validKey(_ key: String) -> Bool {
        let parts = key.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count == 2 && ["codex", "claude", "antigravity"].contains(String(parts[0])) &&
            parts[1].count == 64 && parts[1].allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func key(for session: Session) -> String? {
        guard TerminalApplicationPreference.eligible(session), !session.id.isEmpty, session.id.utf8.count <= 512 else { return nil }
        return session.provider.rawValue + "|" + SHA256.hash(data: Data(session.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func choice(for session: Session) -> TerminalApplicationPreference {
        guard let key = Self.key(for: session) else { return .none }
        return values[key] ?? .none
    }
    @discardableResult mutating func set(_ choice: TerminalApplicationPreference, for session: Session) -> Bool {
        guard let key = Self.key(for: session) else { return false }
        if choice == .none { values.removeValue(forKey: key); return true }
        if values[key] == nil, values.count >= Self.limit, let oldest = values.keys.sorted().first { values.removeValue(forKey: oldest) }
        values[key] = choice; return true
    }
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: String].self)
        for key in raw.keys.sorted() where Self.validKey(key) {
            guard values.count < Self.limit else { break }
            if let value = raw[key].flatMap(TerminalApplicationPreference.init(rawValue:)), value != .none { values[key] = value }
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values.mapValues(\.rawValue))
    }
}
