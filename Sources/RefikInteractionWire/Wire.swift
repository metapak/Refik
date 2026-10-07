import Foundation
import Darwin

public struct HookIdentity: Codable, Equatable {
    public var provider: String
    public var runtimeID: String
    public var sessionID: String
    public var providerTurnID: String?
    public var requestID: String
    public var hookInstance: String
    public var requestToken: String
    public init(provider: String, runtimeID: String, sessionID: String, providerTurnID: String?, requestID: String, hookInstance: String, requestToken: String) {
        self.provider = provider; self.runtimeID = runtimeID; self.sessionID = sessionID; self.providerTurnID = providerTurnID
        self.requestID = requestID; self.hookInstance = hookInstance; self.requestToken = requestToken
    }
}
public struct HookFrame: Codable {
    public var protocolVersion: Int
    public var type: String
    public var token: String?
    public var identity: HookIdentity?
    public var epoch: String?
    public var actionID: String?
    public var payload: Data?
    public var lease: Double?
    public var antigravityObservation: AntigravityHookObservation?
    public var vscodeObservation: VSCodeHookObservation?
    public var editorFocus: EditorFocusObservation?
    public init(type: String, protocolVersion: Int = HookWire.protocolVersion, token: String? = nil, identity: HookIdentity? = nil, epoch: String? = nil, actionID: String? = nil, payload: Data? = nil, lease: Double? = nil, antigravityObservation: AntigravityHookObservation? = nil, vscodeObservation: VSCodeHookObservation? = nil, editorFocus: EditorFocusObservation? = nil) {
        self.protocolVersion = protocolVersion; self.type = type; self.token = token; self.identity = identity; self.epoch = epoch; self.actionID = actionID; self.payload = payload; self.lease = lease
        self.antigravityObservation = antigravityObservation
        self.vscodeObservation = vscodeObservation
        self.editorFocus = editorFocus
    }
}
public enum HookWire {
    public static let protocolVersion = 1
    public static var uptime: Double { ProcessInfo.processInfo.systemUptime }
    public static let limit = 65_536
    public static let maxLease: Double = 120
    public static func secureFile(_ url: URL, socket: Bool = false) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o600 else { return false }
        return info.st_mode & S_IFMT == (socket ? S_IFSOCK : S_IFREG)
    }
    public static func secret(_ url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size > 0, info.st_size <= 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 257)
        let n = read(fd, &bytes, bytes.count)
        guard n > 0, n <= 256 else { return nil }
        return String(bytes: bytes.prefix(n), encoding: .utf8)
    }
    public static func timeout(_ fd: Int32, seconds: Double) {
        let micros = Int64(ceil(max(0.000_001, seconds) * 1_000_000))
        var value = timeval(tv_sec: Int(micros / 1_000_000), tv_usec: Int32(micros % 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    public static func writeData(_ data: Data, fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return false }; offset += n
            }
            return true
        }
    }
    public static func send(_ frame: HookFrame, fd: Int32) -> Bool {
        guard let bytes = try? JSONEncoder().encode(frame), bytes.count < limit else { return false }
        return writeData(bytes + Data([10]), fd: fd)
    }
    // One-byte framing prevents consuming bytes belonging to a following message.
    public static func receive(_ fd: Int32, requireNewline: Bool = false, deadline: Double? = nil, now: () -> Double = { uptime }) -> Data? {
        var result = Data(); var byte: UInt8 = 0
        while result.count < limit {
            if let deadline {
                let remaining = deadline - now()
                guard remaining > 0 else { return nil }
                timeout(fd, seconds: remaining)
            }
            let n = Darwin.read(fd, &byte, 1)
            if n < 0 && errno == EINTR { continue }
            guard n == 1 else { return requireNewline || result.isEmpty ? nil : result }
            if byte == 10 { result.append(byte); return result }
            result.append(byte)
        }
        return nil
    }
    public static func frame(_ fd: Int32, deadline: Double? = nil, now: () -> Double = { uptime }) -> HookFrame? {
        guard let data = receive(fd, requireNewline: true, deadline: deadline, now: now) else { return nil }
        guard let frame = try? JSONDecoder().decode(HookFrame.self, from: data), frame.protocolVersion == protocolVersion else { return nil }
        return frame
    }
}


public enum HookRuntimeContract {
    public static func supports(provider: String, version: String?) -> Bool {
        guard let version else { return false }
        return provider == "claude" ? version == "2.1.287" : provider == "codex" && ["0.153.4", "0.159.2"].contains(version)
    }
    public struct Emitter {
        public let executable: URL
        public let version: String
    }
    // Only public process executable/parent metadata is inspected. No argv,
    // environment, application IPC, or process memory is read.
    public static func emitter(provider: String) -> Emitter? {
        guard ["codex", "claude"].contains(provider) else { return nil }
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid(), info.pbi_ppid != UInt32(pid) else { return nil }
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                let path = String(cString: pathBuffer)
                let url = URL(fileURLWithPath: path)
                let candidate = url.lastPathComponent == provider || provider == "claude" && path.contains("/claude/versions/")
                if candidate {
                    guard let version = probe(url), supports(provider: provider, version: version) else { return nil }
                    return Emitter(executable: url, version: version)
                }
            }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }
    public static func parseVersionOutput(_ text: String) -> String? {
        let fields = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let token: String
        if fields.count == 1 { token = fields[0] }
        else if fields.count == 2 && fields[0] == "codex-cli" { token = fields[1] }
        else if fields.count == 3 && fields[1] == "(Claude" && fields[2] == "Code)" { token = fields[0] }
        else { return nil }
        // Preserve the entire SemVer token: prerelease/build variants never
        // silently inherit the stable version's supported contract.
        let pattern = "^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\\+[0-9A-Za-z.-]+)?$"
        guard token.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return token
    }
    public static func probe(_ url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0 else { return nil }
        let process = Process(); process.executableURL = url; process.arguments = ["--version"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0); process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return nil }
        guard done.wait(timeout: .now() + 1) == .success else { process.terminate(); return nil }
        guard process.terminationStatus == 0, let data = try? pipe.fileHandleForReading.read(upToCount: 1024),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return parseVersionOutput(text)
    }
}
