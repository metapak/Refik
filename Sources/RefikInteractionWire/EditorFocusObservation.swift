import Foundation

public struct EditorHostBinding: Codable, Equatable, Hashable {
    public let bundleID: String
    public let pid: Int32
    public let launchSeconds: UInt64
    public let launchMicros: UInt64
    public init(bundleID: String, pid: Int32, launchSeconds: UInt64, launchMicros: UInt64) {
        self.bundleID = bundleID; self.pid = pid; self.launchSeconds = launchSeconds; self.launchMicros = launchMicros
    }
}
public struct EditorFocusObservation: Codable, Equatable {
    public let windowID: String
    public let generation: String
    public let sequence: UInt64
    public let focused: Bool
    public let projectPath: String?
    public init(windowID: String, generation: String, sequence: UInt64, focused: Bool, projectPath: String?) {
        self.windowID = windowID; self.generation = generation; self.sequence = sequence
        self.focused = focused; self.projectPath = projectPath
    }
    public var isValid: Bool {
        UUID(uuidString: windowID) != nil && UUID(uuidString: generation) != nil && sequence > 0 &&
        (focused ? projectPath.map { $0.hasPrefix("/") && $0 != "/" && $0.count <= 4096 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) } == true : projectPath == nil)
    }
}

// A challenge is issued only after connection authentication. Its clock never
// leaves the receiver; senders echo just the opaque nonce and connection epoch.
public struct EditorFocusChallengeGate {
    public struct Timing { public let issued: Double; public let date: Date }
    private var pending: (nonce: String, timing: Timing)?
    public init() {}
    public mutating func issue(at now: Double, date: Date) -> String {
        let nonce = UUID().uuidString; pending = (nonce, Timing(issued: now, date: date)); return nonce
    }
    public mutating func consume(_ nonce: String?, at now: Double) -> Timing? {
        guard let pending, nonce == pending.nonce, now.isFinite, now >= pending.timing.issued,
              now - pending.timing.issued < 3 else { return nil }
        self.pending = nil; return pending.timing
    }
}
