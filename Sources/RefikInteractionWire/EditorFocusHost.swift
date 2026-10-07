import Foundation
import Darwin
import Security
import CryptoKit

public enum EditorFocusHost {
    public struct Installation {
        public let name: String, bundleID: String, executable: String, team: String, cli: String
        public var application: URL { URL(fileURLWithPath: "/Applications/\(name).app") }
        public var binary: URL { application.appendingPathComponent("Contents/MacOS/\(executable)") }
        public var command: URL { application.appendingPathComponent("Contents/Resources/app/bin/\(cli)") }
    }
    public static let installations: [Installation] = [
        Installation(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", executable: "Code", team: "UBF8T346G9", cli: "code"),
        Installation(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92", executable: "Cursor", team: "VDXQ22DGB9", cli: "cursor"),
        Installation(name: "Devin", bundleID: "com.exafunction.windsurf", executable: "Devin", team: "83Z2LHX6XW", cli: "devin-desktop"),
        Installation(name: "Antigravity IDE", bundleID: "com.google.antigravity-ide", executable: "Electron", team: "EQHXZ8M8AV", cli: "antigravity-ide"),
        Installation(name: "Windsurf", bundleID: "com.exafunction.windsurf", executable: "Windsurf", team: "83Z2LHX6XW", cli: "windsurf")
    ]
    public static func verified(_ host: Installation) -> Bool {
        var info = stat()
        guard lstat(host.binary.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
              let bundle = Bundle(url: host.application), bundle.bundleIdentifier == host.bundleID,
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == host.executable else { return false }
        var code: SecStaticCode?; var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"\(host.bundleID)\" and certificate leaf[subject.OU] = \"\(host.team)\""
        guard SecStaticCodeCreateWithPath(host.application as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess
    }
    private static func process(_ pid: Int32) -> (proc_bsdinfo, String)? {
        var info = proc_bsdinfo(); var path = [CChar](repeating: 0, count: 4096)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
              info.pbi_uid == getuid(), proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return (info, URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path)
    }
    public static func ancestor(of child: Int32) -> EditorHostBinding? {
        var pid = child
        for _ in 0..<12 {
            guard let (info, path) = process(pid), info.pbi_ppid != UInt32(pid) else { return nil }
            if let host = installations.first(where: { $0.binary.path == path }), verified(host) {
                return EditorHostBinding(bundleID: host.bundleID, pid: pid, launchSeconds: info.pbi_start_tvsec, launchMicros: info.pbi_start_tvusec)
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
    public static func isCurrent(_ binding: EditorHostBinding) -> Bool {
        guard let (info, path) = process(binding.pid) else { return false }
        return info.pbi_start_tvsec == binding.launchSeconds && info.pbi_start_tvusec == binding.launchMicros &&
            installations.contains { $0.bundleID == binding.bundleID && $0.binary.path == path }
    }
    // Capture the native chain while a one-shot publisher is still alive.
    // Signature and helper-byte checks may finish after its capture receipt.
    public struct PeerCapture {
        fileprivate let host: Installation
        fileprivate let binding: EditorHostBinding
    }
    public static func capturePeer(_ fd: Int32, helper: URL) -> PeerCapture? {
        var uid: uid_t = 0; var gid: gid_t = 0; var pid: pid_t = 0; var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
              getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, size == MemoryLayout<pid_t>.size,
              let (_, path) = process(pid), path == helper.path else { return nil }
        for _ in 0..<12 {
            guard let (info, path) = process(pid), info.pbi_ppid != UInt32(pid) else { return nil }
            if let host = installations.first(where: { $0.binary.path == path }) {
                return PeerCapture(host: host, binding: EditorHostBinding(bundleID: host.bundleID, pid: pid,
                    launchSeconds: info.pbi_start_tvsec, launchMicros: info.pbi_start_tvusec))
            }
            pid = Int32(info.pbi_ppid)
        }
        return nil
    }
    public static func verifyPeer(_ capture: PeerCapture?, helper: URL, bundledHelper: URL) -> EditorHostBinding? {
        guard let capture else { return nil }
        var info = stat()
        guard lstat(helper.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o700,
              let actual = try? Data(contentsOf: helper), let bundled = try? Data(contentsOf: bundledHelper),
              SHA256.hash(data: actual) == SHA256.hash(data: bundled), verified(capture.host),
              isCurrent(capture.binding) else { return nil }
        return capture.binding
    }
    public static func peer(_ fd: Int32, helper: URL, bundledHelper: URL) -> EditorHostBinding? {
        verifyPeer(capturePeer(fd, helper: helper), helper: helper, bundledHelper: bundledHelper)
    }
}
