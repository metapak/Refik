import Foundation
import AppKit
import CoreGraphics

// Project identity comes from provider cwd and exact foreground workspace paths.
// Display labels are never identity. Local file URLs are allowed; remote URLs are not.
enum ProjectIdentity {
    static func canonical(_ raw: String?) -> String? {
        guard var path = raw, !path.isEmpty, path.count <= 4096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if path.hasPrefix("file:") {
            guard let url = URL(string: path), url.isFileURL,
                  url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        }
        guard path.hasPrefix("/"), path != "/",
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        var directory: ObjCBool = false
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
        var ancestor = url
        while ancestor.path != "/" {
            if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { return ancestor.path }
            ancestor.deleteLastPathComponent()
        }
        return url.path
    }
}
struct ProjectFocusObservation {
    let projectPath: String?
    var appPID: Int32 = 0
    var windowID: UInt32 = 0
    var editor = false
    var observedAt = Date()
}
struct ProjectFocusCorrelation {
    mutating func reset() {}
    mutating func observe(_ observation: ProjectFocusObservation?, at now: Date) -> String? {
        observation?.projectPath.flatMap(ProjectIdentity.canonical)
    }
}
struct ForegroundTerminalProcess: Equatable {
    let pid: Int32
    let parent: Int32
    let group: Int32
    let foregroundGroup: Int32
    let tty: String
}
enum TerminalProjectProof {
    // A single visible terminal window is insufficient with several tabs/ttys.
    // Consider every descendant process/tty, rather than only known projects.
    static func foregroundPIDs(appPID: Int32, processes: [ForegroundTerminalProcess]) -> [Int32]? {
        var descendants: Set<Int32> = [appPID]
        var previousCount = -1
        while descendants.count != previousCount {
            previousCount = descendants.count
            for process in processes where descendants.contains(process.parent) { descendants.insert(process.pid) }
        }
        let attached = processes.filter { descendants.contains($0.pid) && $0.tty != "??" && !$0.tty.isEmpty }
        guard Set(attached.map(\.tty)).count == 1,
              Set(attached.map(\.foregroundGroup)).count == 1,
              let foreground = attached.first?.foregroundGroup, foreground > 0 else { return nil }
        guard let tty = attached.first?.tty else { return nil }
        let active = processes.filter { $0.group == foreground }
        // Descendants establish tty ownership; the complete foreground group
        // includes peers reparented to launchd, not only app descendants.
        guard !active.isEmpty, active.allSatisfy({ $0.tty == tty && $0.foregroundGroup == foreground }),
              Set(active.map(\.pid)).count == active.count else { return nil }
        return active.map(\.pid).sorted()

    }
}
struct TerminalFocusSnapshot: Equatable {
    let members: [ForegroundTerminalProcess]
    let projects: [Int32: String]
}
extension TerminalProjectProof {
    static func snapshot(appPID: Int32, processes: [ForegroundTerminalProcess], cwd: (Int32) -> String?) -> TerminalFocusSnapshot? {
        guard let pids = foregroundPIDs(appPID: appPID, processes: processes), pids.count <= 32 else { return nil }
        let members = processes.filter { pids.contains($0.pid) }.sorted { $0.pid < $1.pid }
        var projects: [Int32: String] = [:]
        for pid in pids {
            guard let project = ProjectIdentity.canonical(cwd(pid)) else { return nil }
            projects[pid] = project
        }
        guard Set(projects.values).count == 1 else { return nil }
        return TerminalFocusSnapshot(members: members, projects: projects)
    }
    static func confirmedProject(_ first: TerminalFocusSnapshot?, _ second: TerminalFocusSnapshot?) -> String? {
        guard let first, let second, first == second else { return nil }
        return first.projects.values.first
    }
}
final class ProjectFocusReader: @unchecked Sendable {
    static let titlePrefix = "REFIK_PROJECT["
    static let titleSuffix = "]REFIK_END"
    static let titleSetting = "REFIK_PROJECT[${rootPath}]REFIK_END"
    static let cursorTitleSetting = "${activeEditorShort}${separator}${rootPath}${separator}${appName}"
    static func project(title: String) -> String? {
        guard title.hasPrefix(titlePrefix), title.hasSuffix(titleSuffix) else { return nil }
        return ProjectIdentity.canonical(String(title.dropFirst(titlePrefix.count).dropLast(titleSuffix.count)))
    }
    static func project(title: String, bundleID: String) -> String? {
        if let explicit = project(title: title) { return explicit }
        guard bundleID == "com.todesktop.230313mzl4w4u92" else { return nil }
        // This public window.title format ends with the full workspace path and
        // app name. Never identify a project from the editor filename/basename.
        let parts = title.components(separatedBy: " — ")
        guard (2...3).contains(parts.count), parts.last == "Cursor",
              let raw = parts.dropLast().last, raw.hasPrefix("/"),
              !raw.hasSuffix(".code-workspace"),
              parts.dropLast(2).allSatisfy({ !$0.hasPrefix("/") }),
              let canonical = ProjectIdentity.canonical(raw) else { return nil }
        return canonical
    }
    static func foregroundWindow(_ windows: [[String: Any]], appPID: Int32) -> [String: Any]? {
        guard appPID > 0 else { return nil }
        // CGWindow.h documents optionOnScreenOnly as front-to-back. Select the
        // foremost normal window before interpreting its title; a blank Agents
        // window must never expose a project window underneath as active.
        for window in windows {
            guard let onScreen = window[kCGWindowIsOnscreen as String] as? NSNumber,
                  onScreen.doubleValue == 0 || onScreen.doubleValue == 1 else { return nil }
            if !onScreen.boolValue { continue }
            guard let layer = window[kCGWindowLayer as String] as? NSNumber,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  layer.doubleValue.isFinite, layer.doubleValue == Double(layer.intValue),
                  alpha.doubleValue.isFinite, (0...1).contains(alpha.doubleValue) else { return nil }
            if layer.intValue != 0 || alpha.doubleValue == 0 { continue }
            guard let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  owner.doubleValue == Double(appPID),
                  let number = window[kCGWindowNumber as String] as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue == Double(number.uint32Value),
                  number.int64Value > 0, number.uint64Value <= UInt32.max,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rawWidth = bounds["Width"] as? NSNumber, let rawHeight = bounds["Height"] as? NSNumber,
                  rawWidth.doubleValue.isFinite, rawHeight.doubleValue.isFinite,
                  rawWidth.doubleValue > 0, rawHeight.doubleValue > 0,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            return window
        }
        return nil
    }
    func observation() -> ProjectFocusObservation? {
        // Date the proof at the beginning of sampling, conservatively excluding
        // completions that arrive during any queued process/cwd reads.
        let sampledAt = Date()
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleIdentifier else { return nil }
        let editors: Set<String> = ["com.google.antigravity", "com.google.antigravity-ide", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
        guard editors.contains(bundle) || terminals.contains(bundle) else { return ProjectFocusObservation(projectPath: nil) }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        guard let window = Self.foregroundWindow(windows, appPID: app.processIdentifier) else { return nil }
        if editors.contains(bundle) {
            guard let title = window[kCGWindowName as String] as? String else { return nil }
            return ProjectFocusObservation(projectPath: Self.project(title: title, bundleID: bundle), appPID: app.processIdentifier,
                windowID: (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0, editor: true, observedAt: sampledAt)
        }
        guard var observation = terminal(appPID: app.processIdentifier) else { return nil }
        observation.observedAt = sampledAt
        observation.appPID = app.processIdentifier
        observation.windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
        return observation
    }
    func isCurrent(_ observation: ProjectFocusObservation) -> Bool {
        guard observation.appPID != 0, observation.windowID != 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == observation.appPID,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        guard let window = Self.foregroundWindow(windows, appPID: observation.appPID),
              (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == observation.windowID else { return false }
        if observation.editor {
            guard let title = window[kCGWindowName as String] as? String,
                  let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
            return Self.project(title: title, bundleID: bundle) == observation.projectPath
        }
        return true
    }
    private func processInventory() -> [ForegroundTerminalProcess]? {
        guard let text = command("/bin/ps", ["-axo", "pid=,ppid=,pgid=,tpgid=,tty="]) else { return nil }
        let lines = text.split(separator: "\n")
        let processes = lines.compactMap { line -> ForegroundTerminalProcess? in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 5, let pid = Int32(parts[0]), let parent = Int32(parts[1]),
                  let group = Int32(parts[2]), let foreground = Int32(parts[3]) else { return nil }
            return ForegroundTerminalProcess(pid: pid, parent: parent, group: group, foregroundGroup: foreground, tty: String(parts[4]))
        }
        return processes.count == lines.count ? processes : nil
    }
    private func terminalSnapshot(appPID: Int32, deadline: Date) -> TerminalFocusSnapshot? {
        guard Date() < deadline, let processes = processInventory(),
              let snapshot = TerminalProjectProof.snapshot(appPID: appPID, processes: processes, cwd: { pid in
                  guard Date() < deadline,
                        let output = self.command("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
                        let cwd = output.split(separator: "\n").first(where: { $0.hasPrefix("n/") }) else { return nil }
                  return String(cwd.dropFirst())
              }), Date() < deadline, let rechecked = processInventory(),
              let pids = TerminalProjectProof.foregroundPIDs(appPID: appPID, processes: rechecked),
              rechecked.filter({ pids.contains($0.pid) }).sorted(by: { $0.pid < $1.pid }) == snapshot.members else { return nil }
        return snapshot
    }
    private func terminal(appPID: Int32) -> ProjectFocusObservation? {
        let deadline = Date().addingTimeInterval(2)
        let first = terminalSnapshot(appPID: appPID, deadline: deadline)
        // Re-read every cwd as well as the complete tty/group/member identity.
        // Equal PIDs alone cannot prove a shell has not changed projects.
        let second = terminalSnapshot(appPID: appPID, deadline: deadline)
        guard Date() < deadline, let project = TerminalProjectProof.confirmedProject(first, second) else { return nil }
        return ProjectFocusObservation(projectPath: project)
    }
    private func command(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // These are fixed, read-only OS metadata commands; enforce a short bound.
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: deadline)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); deadline.cancel()
        guard process.terminationStatus == 0, bytes.count <= 1024 * 1024 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
}
