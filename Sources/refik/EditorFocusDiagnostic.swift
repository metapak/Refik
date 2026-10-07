import Foundation
import Darwin
import RefikInteractionWire

// Explicitly enabled, bounded metadata for the isolated live acceptance task.
// No titles, prompts, credentials, raw project paths, or other session IDs.
final class EditorFocusDiagnostic {
    struct Target {
        let sessionID: String, host: String, project: String
        init?(environment: [String: String], qaRoot: String = "/tmp/refik-live-qa-20261002") {
            let keys = ["REFIK_EDITOR_FOCUS_DIAGNOSTIC_SESSION", "REFIK_EDITOR_FOCUS_DIAGNOSTIC_HOST", "REFIK_EDITOR_FOCUS_DIAGNOSTIC_ROOT"]
            let custom = keys.contains { environment[$0] != nil }
            let id = custom ? environment[keys[0]] : "cursor:7eb9cb67-bf85-424b-9f86-be370af66716"
            let host = custom ? environment[keys[1]] : "com.todesktop.230313mzl4w4u92"
            let raw = custom ? environment[keys[2]] : qaRoot + "/cursor"
            guard let id, id.count <= 100,
                  UUID(uuidString: id) != nil || (id.hasPrefix("cursor:") && UUID(uuidString: String(id.dropFirst(7))) != nil),
                  let host, ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"].contains(host),
                  let project = ProjectIdentity.canonical(raw),
                  let qa = ProjectIdentity.canonical(qaRoot),
                  project.hasPrefix(qa + "/") else { return nil }
            sessionID = id; self.host = host; self.project = project
        }
    }
    let target: Target?

    struct Record: Codable {
        let receiver: EditorFocusReceiver.Diagnostic
        let cursorForeground: Bool
        let qaTerminal: Bool
        let qaOriginMatches: Bool
        let qaProjectMatches: Bool
        let qaEligible: Bool
        let candidateProjectMatches: Bool
        let qaSeen: Bool
        var foregroundHostMatch = false
        var leaseFresh = false
        var generationMatch = false
        var commitResult = false
    }
    private struct Line: Encodable { let uptime: Double; let record: Record }
    let enabled: Bool
    private let output: URL
    private let started: Double
    private var last = -Double.infinity
    private var samples = 0
    init(enabled: Bool = ProcessInfo.processInfo.environment["REFIK_EDITOR_FOCUS_DIAGNOSTICS"] == "1",
         output: URL = URL(fileURLWithPath: "/tmp/refik-editor-focus-live-diagnostic-20261003.jsonl"),
         started: Double = HookWire.uptime,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         qaRoot: String = "/tmp/refik-live-qa-20261002") {
        target = Target(environment: environment, qaRoot: qaRoot)
        self.enabled = enabled && target != nil && started.isFinite; self.output = output; self.started = started
    }
    func record(_ record: Record, at monotonic: Double) {
        guard enabled, monotonic.isFinite, monotonic >= started, monotonic - started < 120,
              samples < 60, monotonic - last >= 2,
              let bytes = try? JSONEncoder().encode(Line(uptime: monotonic, record: record)), bytes.count < 4096 else { return }
        let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_size < 128 * 1024 else { return }
        if HookWire.writeData(bytes + Data([10]), fd: fd) { samples += 1; last = monotonic }
    }
}
