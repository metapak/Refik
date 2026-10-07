import Foundation
import Darwin

// Explicit process-only opt-in. Rows contain finite stages and one presence bit.
public enum TerminalNavigationDiagnostic {
    public static let lifetime: TimeInterval = 600
    public enum Stage: String, Codable {
        case armed, helperInvoked, capturePeerMissing, capturePeerMismatch, captureProcessUnavailable, captureOwnershipRejected, captureReachedRoot, captureTerminalMissing, captureReady
        case bindNoCapture, bindOriginPriority, bindExpired, bindHelperMismatch, bindTerminalSignature, bindSourceMissing, bindFilesUnavailable, bindAncestryChanged, bindReady
        case applyIdentityMismatch, applyOriginPriority, applyExpired, applySourceInvalid, applied
        case mainHistorical, mainExpired, mainSourceInvalid, mainAccepted
    }
    public struct Sample: Codable {
        public let stage: Stage
        public let tabPresent: Bool?
        public let timestamp: Date
        public init(_ stage: Stage, tabPresent: Bool? = nil, timestamp: Date = Date()) {
            self.stage = stage; self.tabPresent = tabPresent; self.timestamp = timestamp
        }
    }
    private struct Marker: Codable { let epoch: UUID; let started: Date }
    private static func safeDirectory(_ directory: URL) -> Bool {
        guard directory.path == directory.resolvingSymlinksInPath().path else { return false }
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o777 == 0o700
    }
    private static func markerURL(_ directory: URL) -> URL { directory.appendingPathComponent("navigation-diagnostics.enabled") }
    private static func safeFile(_ fd: Int32) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1
    }
    private static func marker(_ directory: URL, now: Date) -> Marker? {
        guard safeDirectory(directory) else { return nil }
        let fd = open(markerURL(directory).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { return nil }; defer { _ = flock(fd, LOCK_UN) }
        guard safeFile(fd) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 1025)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 1024, let value = try? JSONDecoder().decode(Marker.self, from: Data(bytes.prefix(count))),
              now.timeIntervalSince(value.started) >= 0, now.timeIntervalSince(value.started) < lifetime else { return nil }
        return value
    }
    @discardableResult public static func arm(directory: URL, now: Date = Date()) -> UUID? {
        guard now.timeIntervalSince1970.isFinite, safeDirectory(directory) else { return nil }
        let fd = open(markerURL(directory).path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }; defer { _ = flock(fd, LOCK_UN) }
        guard safeFile(fd) else { return nil }
        let value = Marker(epoch: UUID(), started: now)
        guard let data = try? JSONEncoder().encode(value), ftruncate(fd, 0) == 0,
              HookWire.writeData(data, fd: fd) else { return nil }
        return value.epoch
    }
    public static func disarm(directory: URL, epoch: UUID) {
        guard safeDirectory(directory) else { return }
        let path = markerURL(directory).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }; defer { _ = flock(fd, LOCK_UN) }
        guard safeFile(fd) else { return }
        var bytes = [UInt8](repeating: 0, count: 1025); let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 1024, let value = try? JSONDecoder().decode(Marker.self, from: Data(bytes.prefix(count))), value.epoch == epoch else { return }
        var opened = stat(), current = stat()
        guard fstat(fd, &opened) == 0, lstat(path, &current) == 0, opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { return }
        _ = unlink(path)
    }
    public static func record(_ sample: Sample, directory: URL, now: Date = Date()) {
        guard sample.timestamp.timeIntervalSince1970.isFinite, let active = marker(directory, now: now) else { return }
        let path = directory.appendingPathComponent("navigation-diagnostics-" + active.epoch.uuidString + ".jsonl").path
        let fd = open(path, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { return }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }; defer { _ = flock(fd, LOCK_UN) }
        var info = stat()
        guard safeFile(fd), fstat(fd, &info) == 0, info.st_size <= 32 * 1024,
              marker(directory, now: now)?.epoch == active.epoch else { return }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard count == data.count, data.filter({ $0 == 10 }).count < 60 else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let row = try? encoder.encode(sample), row.count <= 512 else { return }
        _ = HookWire.writeData(row + Data([10]), fd: fd)
    }
}
