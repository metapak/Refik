import Foundation
import Darwin
import Security
import CryptoKit

// Receiver-local proof. It cannot be decoded from a provider payload.
enum AntigravityTerminalOrigin {
    struct ProcessIdentity: Equatable, Codable {
        let pid: Int32, parent: Int32, uid: UInt32
        let realUID: UInt32
        let seconds: UInt64, micros: UInt64
        let path: String
        init(pid: Int32, parent: Int32, uid: UInt32, realUID: UInt32? = nil, seconds: UInt64, micros: UInt64, path: String) {
            self.pid = pid; self.parent = parent; self.uid = uid; self.realUID = realUID ?? uid
            self.seconds = seconds; self.micros = micros; self.path = path
        }
    }
    struct FileIdentity: Equatable, Codable {
        let device: Int32, inode: UInt64, size: Int64
        let seconds: Int64, nanos: Int64
    }
    struct Capture {
        fileprivate let ancestors: [ProcessIdentity]
        fileprivate let cliFile: FileIdentity
        fileprivate let cliExecutable: URL
        fileprivate let issuedAt: Double
        fileprivate let terminalHost: TerminalHost
        fileprivate let loginFile: FileIdentity?
    }
    struct TerminalHost {
        let application: URL, executable: String, bundleID: String, team: String?
        var binary: String { application.appendingPathComponent("Contents/MacOS/" + executable).path }
    }
    struct Operations {
        var peer: (Int32) -> Int32?
        var process: (Int32) -> ProcessIdentity?
        var file: (URL) -> FileIdentity?
        var signed: (URL, String, String?) -> Bool
        var helperMatches: (URL, URL) -> Bool
        var now: () -> Double = { ProcessInfo.processInfo.systemUptime }
    }
    static let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agy")
    static let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    static var terminalBinary: String { terminal.appendingPathComponent("Contents/MacOS/Terminal").path }
    static let terminalHosts = [
        TerminalHost(application: terminal, executable: "Terminal", bundleID: "com.apple.Terminal", team: nil),
        TerminalHost(application: URL(fileURLWithPath: "/Applications/iTerm.app"), executable: "iTerm2", bundleID: "com.googlecode.iterm2", team: "H7V7XYVQ7D")
    ]
    static func application(for bundleID: String, operations: Operations = live) -> URL? {
        guard let host = terminalHosts.first(where: { $0.bundleID == bundleID }),
              operations.signed(host.application, host.bundleID, host.team) else { return nil }
        return host.application
    }

    // The updater renames a still-running signed CLI to agy.<Unix nanos>.old.
    // Only that closed name beside the canonical installation is a candidate;
    // file ownership, identity and Google's signature are still mandatory.
    static func isCLIExecutable(_ path: String) -> Bool {
        if path == cli.path { return true }
        let prefix = cli.path + ".", suffix = ".old"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return false }
        let stamp = path.dropFirst(prefix.count).dropLast(suffix.count)
        return stamp.utf8.count == 19 && stamp.first != "0" && stamp.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func capture(_ socket: Int32, helper: URL, operations: Operations = live) -> Capture? {
        guard let peer = operations.peer(socket), let publisher = operations.process(peer),
              publisher.uid == getuid(), publisher.path == helper.path else { return nil }
        var pid = publisher.parent
        var cliAncestors: [ProcessIdentity] = []
        var loginFile: FileIdentity?
        for _ in 0..<12 {
            guard let current = operations.process(pid), current.parent != pid else { return nil }
            let owned = current.uid == getuid() && current.realUID == getuid()
            // macOS login retains the user's real UID while running with root
            // privileges. Only this Apple-signed intermediate may cross UID.
            let login = !cliAncestors.isEmpty && current.uid == 0 && current.realUID == getuid() &&
                current.path == "/usr/bin/login" && operations.signed(URL(fileURLWithPath: current.path), "com.apple.login", nil)
            guard owned || login else { return nil }
            if login {
                guard let file = operations.file(URL(fileURLWithPath: current.path)) else { return nil }
                loginFile = file
            }
            if isCLIExecutable(current.path) { cliAncestors = [current] }
            else if !cliAncestors.isEmpty { cliAncestors.append(current) }
            if let host = terminalHosts.first(where: { $0.binary == current.path }) {
                guard cliAncestors.count >= 2, let producer = cliAncestors.first else { return nil }
                let executable = URL(fileURLWithPath: producer.path)
                guard let file = operations.file(executable) else { return nil }
                return Capture(ancestors: cliAncestors, cliFile: file, cliExecutable: executable,
                    issuedAt: operations.now(), terminalHost: host, loginFile: loginFile)
            }
            pid = current.parent
        }
        return nil
    }
    static func isCurrent(_ capture: Capture, operations: Operations = live) -> Bool {
        let age = operations.now() - capture.issuedAt
        guard age >= 0, age <= 3, operations.file(capture.cliExecutable) == capture.cliFile else { return false }
        if let loginFile = capture.loginFile {
            guard operations.file(URL(fileURLWithPath: "/usr/bin/login")) == loginFile else { return false }
        }
        return capture.ancestors.allSatisfy { operations.process($0.pid) == $0 }
    }
    static func verify(_ capture: Capture?, helper: URL, bundledHelper: URL, operations: Operations = live) -> Capture? {
        guard let capture, isCurrent(capture, operations: operations),
              operations.helperMatches(helper, bundledHelper),
              operations.signed(capture.cliExecutable, "cli", "EQHXZ8M8AV"),
              operations.signed(capture.terminalHost.application, capture.terminalHost.bundleID, capture.terminalHost.team),
              capture.loginFile == nil || operations.signed(URL(fileURLWithPath: "/usr/bin/login"), "com.apple.login", nil),
              isCurrent(capture, operations: operations) else { return nil }
        return capture
    }
    static func apply(_ capture: Capture?, to event: inout CodexEvent, operations: Operations = live) {
        guard event.provider == .antigravity else { return }
        event.verifiedTerminalHost = nil
        // Signed editor ancestry takes precedence over an embedded terminal.
        if let editor = event.verifiedEditorHost {
            let host: RuntimeHost
            switch editor {
            case "com.microsoft.VSCode": host = .vscode
            case "com.google.antigravity-ide": host = .antigravity
            case "com.todesktop.230313mzl4w4u92": host = .cursor
            case "com.exafunction.windsurf": host = .windsurf
            default: host = .unknown
            }
            event.runtime = RuntimeMetadata(id: "hook:antigravity:editor:" + editor, host: host)
        } else if let capture, isCurrent(capture, operations: operations), let cli = capture.ancestors.first {
            event.runtime = RuntimeMetadata(id: "hook:antigravity:terminal:\(cli.pid):\(cli.seconds):\(cli.micros)", host: .terminal)
            event.verifiedTerminalHost = capture.terminalHost.bundleID
        } else {
            event.runtime = RuntimeMetadata(id: "hook:antigravity:unknown", host: .unknown)
        }
    }
    static let live = Operations(peer: { fd in
        var uid: uid_t = 0, gid: gid_t = 0, pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0,
              size == MemoryLayout<pid_t>.size else { return nil }
        return pid
    }, process: { pid in
        var info = proc_bsdinfo(); var path = [CChar](repeating: 0, count: 4096)
        guard pid > 1, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) != MemoryLayout.size(ofValue: info) {
            // PROC_PIDTBSDINFO denies the root login wrapper to a normal user.
            // The public KERN_PROC_PID snapshot exposes its immutable identity.
            guard executable == "/usr/bin/login" else { return nil }
            var snapshot = kinfo_proc(), mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var size = MemoryLayout.size(ofValue: snapshot)
            guard sysctl(&mib, UInt32(mib.count), &snapshot, &size, nil, 0) == 0,
                  size == MemoryLayout.size(ofValue: snapshot), snapshot.kp_proc.p_pid == pid,
                  snapshot.kp_eproc.e_ucred.cr_uid == 0, snapshot.kp_eproc.e_pcred.p_ruid == getuid(),
                  snapshot.kp_proc.p_starttime.tv_sec > 0 else { return nil }
            return ProcessIdentity(pid: pid, parent: Int32(snapshot.kp_eproc.e_ppid), uid: snapshot.kp_eproc.e_ucred.cr_uid,
                realUID: snapshot.kp_eproc.e_pcred.p_ruid, seconds: UInt64(snapshot.kp_proc.p_starttime.tv_sec),
                micros: UInt64(snapshot.kp_proc.p_starttime.tv_usec), path: executable)
        }
        return ProcessIdentity(pid: pid, parent: Int32(info.pbi_ppid), uid: info.pbi_uid, realUID: info.pbi_ruid,
            seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec, path: executable)
    }, file: { url in
        var info = stat()
        // No symlink aliases, writable executables, or foreign ownership.
        guard url.resolvingSymlinksInPath().path == url.path, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() || info.st_uid == 0,
              info.st_mode & 0o022 == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
            seconds: Int64(info.st_mtimespec.tv_sec), nanos: Int64(info.st_mtimespec.tv_nsec))
    }, signed: { url, identifier, team in
        var code: SecStaticCode?; var requirement: SecRequirement?
        let rule = team.map { "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\($0)\"" }
            ?? "anchor apple and identifier \"\(identifier)\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }, helperMatches: { helper, bundled in
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o700, let actual = try? Data(contentsOf: helper),
              let expected = try? Data(contentsOf: bundled) else { return false }
        return SHA256.hash(data: actual) == SHA256.hash(data: expected)
    })
}
