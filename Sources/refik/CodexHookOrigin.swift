import Foundation
import Darwin
import RefikInteractionWire

// A locator is untrusted. Only a captured installed helper plus a validated
// local rollout header can contribute source classification.
enum CodexHookOrigin {
    struct Publisher {
        fileprivate let capturedAt: Double
    }
    struct Binding {
        let source: CodexSource
        let host: RuntimeHost
        let parentSessionID: String?
        fileprivate let file: URL
        fileprivate let identity: stat
        fileprivate let capturedAt: Double
        fileprivate let sessionID: String, turnID: String, eventID: String, project: String
        fileprivate let inputProject: String?, kind: EventKind, inputRuntimeID: String?
    }
    static func capturePublisher(_ fd: Int32, helper: URL,
                                 operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live) -> Publisher? {
        guard let pid = operations.peer(fd), let peer = operations.process(pid),
              peer.uid == getuid(), peer.path == helper.path else { return nil }
        return Publisher(capturedAt: operations.now())
    }
    static func validate(_ publisher: Publisher?, event: CodexEvent, helper: URL, bundledHelper: URL,
                         roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")],
                         operations: AntigravityTerminalOrigin.Operations = AntigravityTerminalOrigin.live,
                         diagnostic: ((HookOriginDiagnostic.Stage) -> Void)? = nil) -> Binding? {
        var stage = HookOriginDiagnostic.Stage.publisherMissing
        defer { diagnostic?(stage) }
        guard let publisher else { return nil }
        stage = .invalidSession
        guard event.provider == .codex, UUID(uuidString: event.sessionID) != nil else { return nil }
        stage = .expiredCapture
        guard operations.now() - publisher.capturedAt >= 0, operations.now() - publisher.capturedAt <= 3 else { return nil }
        stage = .helperMismatch
        guard operations.helperMatches(helper, bundledHelper) else { return nil }
        stage = .missingLocator
        guard let locator = event.transcriptPath, !locator.isEmpty, locator.count <= 4096, !locator.contains("\0") else { return nil }
        stage = .invalidProject
        guard let project = canonicalDirectory(event.projectPath) else { return nil }
        let file = URL(fileURLWithPath: locator).standardizedFileURL
        stage = .invalidLocator
        guard file.path == locator, file.resolvingSymlinksInPath().path == file.path,
              file.pathExtension == "jsonl", file.lastPathComponent.contains(event.sessionID),
              let root = roots.first(where: { file.path.hasPrefix($0.standardizedFileURL.path + "/") }),
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().path else { return nil }
        var directory = file.deletingLastPathComponent()
        stage = .unsafeDirectory
        while true {
            var info = stat()
            guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { return nil }
            if directory.path == root.path { break }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        stage = .openFailed
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var before = stat(), after = stat(), current = stat()
        stage = .unsafeFile
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_mode & 0o022 == 0, before.st_nlink == 1 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 256 * 1024 + 1)
        let count = read(fd, &bytes, bytes.count)
        stage = .invalidHeader
        guard count > 0, let newline = bytes.prefix(count).firstIndex(of: 10), newline <= 256 * 1024,
              let record = try? JSONSerialization.jsonObject(with: Data(bytes[..<newline])) as? [String: Any],
              record["type"] as? String == "session_meta", let metadata = record["payload"] as? [String: Any] else { return nil }
        stage = .identityMismatch
        guard metadata["id"] as? String == event.sessionID, canonicalDirectory(metadata["cwd"] as? String) == project else { return nil }
        stage = .fileChanged
        guard fstat(fd, &after) == 0, lstat(file.path, &current) == 0,
              sameFile(before, after), sameFile(before, current),
              operations.now() - publisher.capturedAt <= 3 else { return nil }
        if let source = metadata["source"] as? [String: Any],
           let subagent = source["subagent"] as? [String: Any],
           let spawn = subagent["thread_spawn"] as? [String: Any],
           let parent = spawn["parent_thread_id"] as? String, UUID(uuidString: parent) != nil,
           parent != event.sessionID, metadata["parent_thread_id"] == nil || metadata["parent_thread_id"] as? String == parent {
            stage = .childBound
            return Binding(source: .unknown, host: .unknown, parentSessionID: parent, file: file, identity: before, capturedAt: publisher.capturedAt,
                sessionID: event.sessionID, turnID: event.turnID, eventID: event.id, project: project,
                inputProject: event.projectPath, kind: event.kind, inputRuntimeID: event.runtime?.id)
        }
        stage = .unknownMetadata
        guard metadata["subagent"] == nil, metadata["parent_thread_id"] == nil,
              let source = metadata["source"] as? String, let origin = metadata["originator"] as? String else { return nil }
        let host = RolloutAdapter.hostForMetadata(source: source, origin: origin, version: metadata["cli_version"] as? String)
        guard host != .unknown else { return nil }
        stage = host == .codexDesktop ? .desktopBound : host == .vscode ? .editorBound : .terminalBound
        return Binding(source: host == .terminal ? .cli : .desktop, host: host, parentSessionID: nil, file: file, identity: before, capturedAt: publisher.capturedAt,
            sessionID: event.sessionID, turnID: event.turnID, eventID: event.id, project: project,
            inputProject: event.projectPath, kind: event.kind, inputRuntimeID: event.runtime?.id)
    }
    static func apply(_ binding: Binding, to event: inout CodexEvent,
                      now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        var current = stat()
        guard event.provider == .codex, event.sessionID == binding.sessionID, event.turnID == binding.turnID,
              event.id == binding.eventID, event.projectPath == binding.inputProject,
              event.kind == binding.kind, event.runtime?.id == binding.inputRuntimeID else { return true }
        // The child identity was proven at receipt. Natural append/queue delay
        // cannot transform this immutable event into independent attention.
        guard binding.parentSessionID == nil else { return false }
        // Queue delay/file replacement invalidates classification, while the
        // original observational event remains unknown rather than lost.
        guard canonicalDirectory(event.projectPath) == binding.project,
              now >= binding.capturedAt, now - binding.capturedAt <= 3,
              binding.file.resolvingSymlinksInPath().path == binding.file.path,
              lstat(binding.file.path, &current) == 0, sameFile(binding.identity, current) else { return true }
        event.source = binding.source
        event.verifiedCodexOriginHost = binding.host
        if var runtime = event.runtime { runtime.host = binding.host; event.runtime = runtime }
        else { event.runtime = RuntimeMetadata(id: "codex-rollout:" + binding.source.rawValue + ":" + event.sessionID, host: binding.host) }
        return true
    }
    private static func canonicalDirectory(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return nil }
        return url.path
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
