import Foundation
import Darwin
import Security

// Passive presentation metadata only. This never grants an interactive channel.
public enum VSCodeHookHost {
    public struct Metadata {
        public let executable: URL
        public let version: String
    }
    static let application = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")
    static var executable: URL { application.appendingPathComponent("Contents/MacOS/Code") }

    public static func currentEmitter() -> Metadata? {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info),
                  info.pbi_uid == getuid(), info.pbi_ppid != UInt32(pid) else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                let candidate = URL(fileURLWithPath: String(cString: path))
                if candidate.resolvingSymlinksInPath().path == executable.path {
                    return verifiedApplication(executable: candidate)
                }
            }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }

    static func verifiedApplication(executable candidate: URL) -> Metadata? {
        guard candidate.resolvingSymlinksInPath().path == executable.path else { return nil }
        var info = stat()
        guard lstat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid() || info.st_uid == 0, info.st_mode & 0o022 == 0,
              let bundle = Bundle(url: application),
              bundle.bundleIdentifier == "com.microsoft.VSCode",
              bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "Code",
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty, version.count <= 80 else { return nil }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.microsoft.VSCode\" and certificate leaf[subject.OU] = \"UBF8T346G9\""
        guard SecStaticCodeCreateWithPath(application as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { return nil }
        return Metadata(executable: executable, version: version)
    }
}
