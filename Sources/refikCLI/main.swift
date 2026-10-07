import Foundation
import Darwin
import CryptoKit

private let directory = (ProcessInfo.processInfo.environment["REFIK_DATA_DIR"] ?? ProcessInfo.processInfo.environment["MASCOTMET_DATA_DIR"]).map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik")
private var childPID: pid_t = 0
private var forwardInterrupt = true
private func forward(_ signalNumber: Int32) {
    // A terminal sends Ctrl-C to the entire foreground process group. In that
    // case the child already received SIGINT; forwarding would deliver it twice.
    if signalNumber == SIGINT && !forwardInterrupt { return }
    if childPID > 0 { _ = kill(childPID, signalNumber) }
}
private func report(_ fields: [String: Any]) {
    guard let token = try? String(contentsOf: directory.appendingPathComponent("signal.token"), encoding: .utf8) else { return }
    var payload = fields
    payload["authToken"] = token
    payload["at"] = ISO8601DateFormatter().string(from: Date())
    if payload["id"] == nil { payload["id"] = UUID().uuidString }
    payload["source"] = "unknown"
    if payload["fidelity"] == nil { payload["fidelity"] = "manual" }
    guard let bytes = try? JSONSerialization.data(withJSONObject: payload), bytes.count <= 8192 else { return }
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else { return }
    var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
    _ = setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(directory.appendingPathComponent("events.sock").path.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { close(socketFD); return }
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: path.count + 1) { chars in
            for (i, byte) in path.enumerated() { chars[i] = CChar(bitPattern: byte) }
            chars[path.count] = 0
        }
    }
    let connected = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected == 0 { _ = bytes.withUnsafeBytes { write(socketFD, $0.baseAddress, bytes.count) } }
    close(socketFD)
}
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("refik: \(message)\n".utf8))
    exit(64)
}
private func watch(_ arguments: [String]) -> Never {
    guard !arguments.isEmpty else { fail("watch <komut> [argümanlar]") }
    let id = "watch:" + UUID().uuidString
    let title = URL(fileURLWithPath: arguments[0]).lastPathComponent.prefix(100)
    let base: [String: Any] = ["sessionID": id, "turnID": id, "provider": "watch", "title": String(title)]
    var start = base; start["kind"] = "started"; report(start)
    let strings = arguments.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    var argv = strings + [nil]
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    sigemptyset(&defaults); sigaddset(&defaults, SIGINT); sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGHUP)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF))
    var pid: pid_t = 0
    let spawnError = argv.withUnsafeMutableBufferPointer { posix_spawnp(&pid, strings[0]!, nil, &attributes, $0.baseAddress!, environ) }
    if spawnError != 0 {
        var failed = base; failed["kind"] = "failed"; failed["detail"] = "Komut başlatılamadı (\(spawnError))"; report(failed)
        exit(spawnError == ENOENT ? 127 : 126)
    }
    childPID = pid
    forwardInterrupt = !(isatty(STDIN_FILENO) == 1 && tcgetpgrp(STDIN_FILENO) == getpgrp())
    signal(SIGINT, forward); signal(SIGTERM, forward); signal(SIGHUP, forward)
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 { if errno != EINTR { break } }
    childPID = 0
    var finish = base
    if (status & 0x7f) == 0 {
        let code = (status >> 8) & 0xff
        finish["kind"] = code == 0 ? "completed" : "failed"
        finish["detail"] = "Çıkış kodu \(code)"
        report(finish); exit(code)
    }
    let number = status & 0x7f
    finish["kind"] = "interrupted"
    finish["detail"] = "Sinyal \(number)"
    report(finish); exit(128 + number)
}
private func signalCommand(_ arguments: [String]) -> Never {
    guard let rawID = arguments.first, !rawID.isEmpty, rawID.count <= 100 else { fail("signal <kimlik> [--label metin] [--progress 0..1] [--waiting|--done|--failed|--drop]") }
    let id = "signal:" + rawID
    var kind = "started", label = rawID, detail = "", progress: Double?, ttl: Double?
    var index = 1
    while index < arguments.count {
        let flag = arguments[index]
        switch flag {
        case "--waiting": kind = "permissionObserved"
        case "--done": kind = "completed"
        case "--failed": kind = "failed"
        case "--drop": kind = "dropped"
        case "--working": kind = "started"
        case "--label", "--detail", "--progress", "--ttl":
            index += 1
            guard index < arguments.count else { fail("\(flag) için değer gerekli") }
            let value = arguments[index]
            switch flag {
            case "--label": label = value
            case "--detail": detail = value
            case "--progress": progress = Double(value)
            default: ttl = Double(value)
            }
        default: fail("tanınmayan seçenek: \(flag)")
        }
        index += 1
    }
    guard label.count <= 100, detail.count <= 500,
          progress.map({ (0...1).contains($0) }) ?? true,
          ttl.map({ (1...86_400).contains($0) }) ?? true else { fail("sınır dışında değer") }
    var payload: [String: Any] = ["sessionID": id, "turnID": id, "provider": "signal", "title": label, "kind": kind]
    if !detail.isEmpty { payload["detail"] = detail }
    if let progress { payload["progress"] = progress }
    if let ttl { payload["ttl"] = ttl }
    if kind == "permissionObserved" { payload["requestID"] = "manual" }
    let canonical = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    let digest = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    payload["id"] = "signal:\(rawID):\(digest)"
    report(payload); exit(0)
}
// Forward only documented statusline fields through the existing authenticated
// signal channel. The app owns interval identity across short-lived invocations.
private func antigravityStatusline(_ input: Data) {
    guard let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          root["product"] as? String == "antigravity",
          let conversation = (root["conversation_id"] as? String) ?? (root["session_id"] as? String),
          !conversation.isEmpty, conversation.count <= 160,
          let workspace = root["workspace"] as? [String: Any],
          let path = workspace["project_dir"] as? String, path.hasPrefix("/"), path.count <= 4096,
          let state = root["agent_state"] as? String,
          ["idle", "thinking", "working", "tool_use", "initializing"].contains(state),
          let tasks = root["task_count"] as? NSNumber, CFGetTypeID(tasks) != CFBooleanGetTypeID(),
          tasks.doubleValue.isFinite, tasks.doubleValue.rounded() == tasks.doubleValue,
          (0...1_000_000).contains(tasks.doubleValue) else { return }
    var payload: [String: Any] = ["conversationID": conversation, "projectDirectory": path,
        "agentState": state, "taskCount": tasks.intValue]
    if let version = root["version"] as? String, version.count <= 100 { payload["version"] = version }
    if let pending = root["tool_confirmation_pending"] {
        guard let bool = pending as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { return }
        payload["toolConfirmationPending"] = bool.boolValue
    }
    var quotas: [String: Any] = [:]
    for (key, value) in ((root["quota"] as? [String: Any]) ?? [:]).prefix(100) {
        guard !key.isEmpty, key.count <= 100, let bucket = value as? [String: Any] else { continue }
        var sanitized: [String: Any] = [:]
        for (raw, normalized) in [("remaining_fraction", "remainingFraction"), ("reset_in_seconds", "resetInSeconds")] {
            if let number = bucket[raw] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                sanitized[normalized] = number.doubleValue
            }
        }
        if let reset = bucket["reset_time"] as? String, reset.count <= 100 { sanitized["resetTime"] = reset }
        quotas[key] = sanitized
    }
    payload["quota"] = quotas
    // Hashing keeps the authenticated outer signal ID within existing bounds.
    let id = SHA256.hash(data: Data(conversation.utf8)).map { String(format: "%02x", $0) }.joined()
    report(["sessionID": "signal:agy-statusline:" + id, "turnID": "statusline", "provider": "signal",
        "kind": "unknownEvent", "fidelity": "official", "antigravityStatusline": payload])
}
private func statusline(_ arguments: [String]) -> Never {
    var originalArguments = arguments
    var provider = "claude"
    if originalArguments.first == "--provider" {
        guard originalArguments.count >= 2, ["claude", "antigravity"].contains(originalArguments[1]) else { fail("statusline --provider claude|antigravity [önceki-komut-base64]") }
        provider = originalArguments[1]; originalArguments.removeFirst(2)
    }
    let input = (try? FileHandle.standardInput.read(upToCount: 262_144)) ?? Data()
    if provider == "antigravity" { antigravityStatusline(input) }
    if provider == "claude", let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
       let limits = object["rate_limits"] as? [String: Any] {
        for (key, label) in [("five_hour", "5 saat"), ("seven_day", "7 gün"), ("spend_limit", "Harcama")] {
            guard let window = limits[key] as? [String: Any],
                  let percent = window["used_percentage"] as? Double, (0...100).contains(percent),
                  let reset = window["resets_at"] as? TimeInterval,
                  reset > Date().timeIntervalSince1970 else { continue }
            report(["sessionID": "usage:claude:\(key)", "turnID": "usage", "provider": "claude",
                    "kind": "usage", "detail": "used", "title": label, "progress": percent / 100,
                    "ttl": min(86_400, reset - Date().timeIntervalSince1970),
                    "resetAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: reset)), "fidelity": "official"])
        }
    }
    guard let encoded = originalArguments.first, let data = Data(base64Encoded: encoded),
          let command = String(data: data, encoding: .utf8), !command.isEmpty else { exit(0) }
    let original = Process()
    original.executableURL = URL(fileURLWithPath: "/bin/sh")
    original.arguments = ["-c", command]
    let stdin = Pipe()
    original.standardInput = stdin
    original.standardOutput = FileHandle.standardOutput
    original.standardError = FileHandle.standardError
    do { try original.run() } catch { exit(127) }
    stdin.fileHandleForWriting.write(input)
    try? stdin.fileHandleForWriting.close()
    original.waitUntilExit()
    exit(original.terminationReason == .exit ? original.terminationStatus : 128 + original.terminationStatus)
}
@main struct refikCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "watch": watch(Array(arguments.dropFirst()))
        case "signal": signalCommand(Array(arguments.dropFirst()))
        case "statusline": statusline(Array(arguments.dropFirst()))
        case "--help", "help": print("refik watch <komut…>\nrefik signal <kimlik> [--label metin] [--progress 0..1] [--waiting|--working|--done|--failed|--drop]\nrefik statusline [--provider claude|antigravity] [önceki-komut-base64]")
        default: fail("watch veya signal komutu bekleniyor")
        }
    }
}
