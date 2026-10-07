import Foundation
import Darwin

// Each command is born in its own group. Never signal an inherited group or
// a normal GUI editor; the unreaped leader reserves the group's identity.
enum EditorFocusProcessRunner {
    struct Limits {
        var duration: TimeInterval = 30
        var grace: TimeInterval = 0.5
        var reap: TimeInterval = 1
        var outputBytes: Int = 65_536
        // Test-only snapshot race injection; production always reads native identity.
        var snapshotIdentityUnavailable: ((Int32) -> Bool)? = nil
    }
    static func run(_ executable: URL, _ arguments: [String], limits: Limits = Limits()) -> EditorFocusInstaller.Result {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refik-extension-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return .init(success: false, output: "", failure: .preparation) }
        var removeDirectory = true
        defer { if removeDirectory { try? FileManager.default.removeItem(at: directory) } }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return .init(success: false, output: "", failure: .preparation) }
        let input = descriptors[0], output = descriptors[1]
        defer { close(input) }
        guard fcntl(input, F_SETFL, O_NONBLOCK) == 0 else { close(output); return .init(success: false, output: "", failure: .preparation) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { close(output); return .init(success: false, output: "", failure: .preparation) }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { close(output); return .init(success: false, output: "", failure: .preparation) }
        defer { posix_spawnattr_destroy(&attributes) }
        // Close the pipe's read end before assigning explicit stdin: GUI launches
        // may have closed fd0, so descriptors must not be assumed to start at 3.
        let setup = [posix_spawn_file_actions_addclose(&actions, input),
                     posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
                     posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO),
                     posix_spawn_file_actions_addchdir_np(&actions, directory.path),
                     posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
                     posix_spawnattr_setpgroup(&attributes, 0)]
        if output > STDERR_FILENO { _ = posix_spawn_file_actions_addclose(&actions, output) }
        guard setup.allSatisfy({ $0 == 0 }) else { close(output); return .init(success: false, output: "", failure: .preparation) }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["HOME=" + NSHomeDirectory(), "PATH=/usr/bin:/bin"]
        let env = environment.map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) }; env.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { args in env.withUnsafeBufferPointer { variables in
            posix_spawn(&pid, executable.path, &actions, &attributes, args.baseAddress!, variables.baseAddress!)
        } }
        close(output)
        guard error == 0, pid > 1 else { return .init(success: false, output: "", failure: .launch) }
        struct Identity: Equatable {
            let pid: Int32, seconds: UInt64, micros: UInt64
        }
        func identity(_ child: Int32) -> Identity? {
            var value = proc_bsdinfo()
            guard child > 1, proc_pidinfo(child, PROC_PIDTBSDINFO, 0, &value, Int32(MemoryLayout.size(ofValue: value))) == MemoryLayout.size(ofValue: value), value.pbi_uid == getuid() else { return nil }
            return Identity(pid: child, seconds: value.pbi_start_tvsec, micros: value.pbi_start_tvusec)
        }
        var captured: [Int32: Identity] = [:], captureIncomplete = false
        func captureChildren() {
            for parent in [pid] + Array(captured.keys) where parent == pid || captured[parent] == identity(parent) {
                var children = [Int32](repeating: 0, count: 64)
                let count = proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<Int32>.size))
                if count < 0 || count >= children.count * MemoryLayout<Int32>.size { captureIncomplete = true }
                for child in children where child > 1 {
                    if limits.snapshotIdentityUnavailable?(child) != true, let value = identity(child), captured.count < 64 { captured[child] = value }
                    else { captureIncomplete = true }
                }
            }
        }
        let started = ProcessInfo.processInfo.systemUptime
        var bytes = Data(), failure: EditorFocusInstaller.Failure = .none
        var info = siginfo_t(), ended = false, eof = false, reservationLost = false, readFailed = false
        func poll() {
            captureChildren()
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<16 {
                let n = read(input, &buffer, buffer.count)
                if n > 0 {
                    let remaining = max(0, limits.outputBytes - bytes.count)
                    bytes.append(contentsOf: buffer.prefix(min(n, remaining)))
                    if n > remaining { failure = .outputLimit; break }
                } else {
                    if n == 0 { eof = true }
                    else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { readFailed = true; failure = .cleanupBlocked }
                    break
                }
            }
            info = siginfo_t()
            let waited = waitid(P_PID, UInt32(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if waited == 0, info.si_pid == pid { ended = true }
            else if waited != 0 && errno != EINTR { reservationLost = true; failure = .cleanupBlocked }
        }
        while !ended && failure == .none {
            poll()
            if ProcessInfo.processInfo.systemUptime - started >= limits.duration { failure = .timeout; break }
            if !ended { Thread.sleep(forTimeInterval: 0.01) }
        }
        if reservationLost {
            removeDirectory = false
            return .init(success: false, output: "", failure: .cleanupBlocked, cleanupUncertain: true)
        }
        if failure != .none {
            // pid remains unreaped, so its process group cannot be reused.
            _ = kill(-pid, SIGTERM)
            let grace = ProcessInfo.processInfo.systemUptime + limits.grace
            while ProcessInfo.processInfo.systemUptime < grace && !reservationLost { poll(); Thread.sleep(forTimeInterval: 0.01) }
            if !reservationLost { _ = kill(-pid, SIGKILL) }
            let reapDeadline = ProcessInfo.processInfo.systemUptime + limits.reap
            while !ended && !reservationLost && ProcessInfo.processInfo.systemUptime < reapDeadline { poll(); Thread.sleep(forTimeInterval: 0.01) }
        } else {
            poll()
        }
        // A child holding the output pipe is not proven gone. Retain its cwd;
        // detached processes are not hunted or treated as cleanup-complete.
        let remainingChildren = captured.values.contains { identity($0.pid) == $0 }
        if !eof || readFailed || remainingChildren || captureIncomplete { removeDirectory = false }
        guard ended && !reservationLost else { removeDirectory = false; return .init(success: false, output: "", failure: .cleanupBlocked, cleanupUncertain: true) }
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { removeDirectory = false; return .init(success: false, output: "", failure: .cleanupBlocked, cleanupUncertain: true) }
        if failure == .none {
            failure = info.si_code == CLD_EXITED ? (info.si_status == 0 ? .none : .nonzeroExit) : .signal
            // Snapshot races/live detached children affect cwd cleanup, not a
            // fully captured and reaped successful command. Incomplete output
            // remains unusable even when the leader exited successfully.
            if !eof || readFailed { failure = .cleanupBlocked }
        }
        return .init(success: failure == .none, output: String(data: bytes, encoding: .utf8) ?? "", failure: failure, elapsedMS: Int((ProcessInfo.processInfo.systemUptime - started) * 1000), terminationCode: Int(info.si_status), processPID: pid, cleanupUncertain: !removeDirectory, outputEOF: eof, remainingChildren: remainingChildren, captureIncomplete: captureIncomplete, outputReadFailed: readFailed, leaderReaped: true)
    }
}
