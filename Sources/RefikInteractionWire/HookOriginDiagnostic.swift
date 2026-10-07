import Foundation
import Darwin

// Explicit, short-lived diagnostic only. Fixed fields exclude provider content.
public enum HookOriginDiagnostic {
    public enum Event: String, Codable {
        case SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, Stop, SessionEnd, SubagentStart, SubagentStop, other
        public init(name: String) { self = Event(rawValue: name) ?? .other }
    }
    public enum Stage: String, Codable {
        case helperInput, publisherMissing, invalidSession, expiredCapture, helperMismatch, missingLocator, invalidProject
        case invalidLocator, unsafeDirectory, openFailed, unsafeFile, invalidHeader, identityMismatch, fileChanged
        case unknownMetadata, desktopBound, editorBound, terminalBound, childBound, applied, applicationInvalidated, childSuppressed
    }
    public struct Sample: Codable {
        public let stage: Stage
        public let event: Event?
        public let agentID: String?
        public let sessionID: String?, turnID: String?
        public let locatorPresent: Bool?, agentIDPresent: Bool?, agentTypePresent: Bool?, parentIDPresent: Bool?
        public let timestamp: Date
        public init(stage: Stage, sessionID: String, turnID: String, event: Event? = nil, locatorPresent: Bool? = nil,
                    agentIDPresent: Bool? = nil, agentTypePresent: Bool? = nil, parentIDPresent: Bool? = nil, agentID: String? = nil, timestamp: Date = Date()) {
            self.stage = stage
            self.event = event
            self.agentID = agentID.flatMap { UUID(uuidString: $0)?.uuidString }
            self.sessionID = UUID(uuidString: sessionID)?.uuidString
            self.turnID = UUID(uuidString: turnID)?.uuidString
            self.locatorPresent = locatorPresent; self.agentIDPresent = agentIDPresent
            self.agentTypePresent = agentTypePresent; self.parentIDPresent = parentIDPresent; self.timestamp = timestamp
        }
    }
    public static func record(_ sample: Sample, directory: URL, now: Date = Date()) {
        let marker = directory.appendingPathComponent("origin-diagnostics.enabled")
        var info = stat()
        guard lstat(marker.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { return }
        let age = now.timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) - Double(info.st_mtimespec.tv_nsec) / 1e9
        guard age >= 0, age < 120 else { return }
        let path = directory.appendingPathComponent("origin-diagnostics.jsonl").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }; defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { return }; defer { _ = flock(fd, LOCK_UN) }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size <= 64 * 1024 else { return }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count, data.filter({ $0 == 10 }).count < 60 else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let row = try? encoder.encode(sample) else { return }
        _ = HookWire.writeData(row + Data([10]), fd: fd)
    }
}
