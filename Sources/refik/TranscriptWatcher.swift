import Foundation
import CoreServices
import Darwin
import CryptoKit

// Avoid Foundation's broad attribute/xattr lookup during frequent polling.
private struct RolloutFileSnapshot {
    let size: UInt64, identity: UInt64, modified: Date
    let type: mode_t
    init?(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_size >= 0 else { return nil }
        identity = UInt64(info.st_ino)
        type = info.st_mode & S_IFMT
        size = UInt64(info.st_size)
        // Match Foundation file dates without rounding nanoseconds at Unix-epoch magnitude.
        modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
            .addingTimeInterval(Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }
}

// Internal, non-wire evidence produced only by a validated local rollout.
struct CodexCLIQuestionProof {
    let sessionID: String, projectPath: String, turnID: String, runtimeID: String
    private let file: URL, inode: UInt64
    fileprivate init(sessionID: String, projectPath: String, turnID: String, runtimeID: String, file: URL, inode: UInt64) {
        self.sessionID = sessionID; self.projectPath = projectPath; self.turnID = turnID; self.runtimeID = runtimeID; self.file = file; self.inode = inode
    }
    var fileStillValid: Bool {
        var info = stat()
        return lstat(file.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFREG && UInt64(info.st_ino) == inode
    }
    func matches(_ event: CodexEvent) -> Bool {
        fileStillValid && event.provider == .codex && event.source == .cli && event.runtime?.host == .terminal &&
        event.sessionID == sessionID && event.turnID == turnID && event.runtime?.id == runtimeID &&
        event.projectPath == projectPath && event.kind == .userQuestionObserved &&
        event.requestSnapshot?.identity.sessionID == sessionID && event.requestSnapshot?.identity.turnID == turnID &&
        event.requestSnapshot?.identity.runtimeID == runtimeID &&
        event.requestSnapshot?.identity.generation.hasPrefix("cli-native:" + turnID + ":") == true
    }
}

// Receiver-independent local lifecycle proof; never serialized over the hook wire.
struct CodexNativeTurnProof {
    let sessionID: String, turnID: String, projectPath: String
    let source: CodexSource, runtime: RuntimeMetadata
    let started: Date, nativeCompleted: Date?
    private let file: URL, inode: UInt64, headerDigest: Data
    private let fileSize: Int64, fileModifiedSeconds: Int, fileModifiedNanoseconds: Int
    fileprivate init?(event: CodexEvent, started: Date, file: URL, root: URL) {
        var before = stat()
        guard lstat(file.path, &before) == 0, before.st_uid == getuid(), before.st_mode & S_IFMT == S_IFREG else { return nil }
        guard event.provider == .codex, [.started, .completed].contains(event.kind),
              UUID(uuidString: event.sessionID) != nil, !event.turnID.isEmpty,
              let path = ProjectIdentity.canonical(event.projectPath), let runtime = event.runtime,
              runtime.host != .unknown, file.path == file.resolvingSymlinksInPath().path,
              file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              file.lastPathComponent.contains(event.sessionID),
              let bytes = Self.header(file), let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              payload["id"] as? String == event.sessionID, ProjectIdentity.canonical(payload["cwd"] as? String) == path,
              payload["subagent"] == nil, payload["parent_thread_id"] == nil,
              payload["agent_path"] == nil || payload["agent_path"] as? String == "",
              RolloutAdapter.hostForMetadata(source: payload["source"] as? String, origin: payload["originator"] as? String, version: payload["cli_version"] as? String) == runtime.host,
              event.source == (runtime.host == .terminal ? .cli : .desktop), started <= event.at else { return nil }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              before.st_ino == info.st_ino, before.st_size == info.st_size,
              before.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { return nil }
        self.sessionID = event.sessionID; self.turnID = event.turnID; self.projectPath = path
        self.source = event.source; self.runtime = runtime; self.started = started
        self.nativeCompleted = event.kind == .completed ? event.at : nil
        self.file = file; self.inode = UInt64(info.st_ino); self.headerDigest = Data(SHA256.hash(data: bytes))
        self.fileSize = info.st_size; self.fileModifiedSeconds = info.st_mtimespec.tv_sec; self.fileModifiedNanoseconds = info.st_mtimespec.tv_nsec
    }
    private static func header(_ file: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 256 * 1024), let end = bytes.firstIndex(of: 10) else { return nil }
        return Data(bytes[..<end])
    }
    func matches(_ event: CodexEvent) -> Bool {
        var info = stat()
        guard event.provider == .codex, [.started, .completed].contains(event.kind), event.sessionID == sessionID, event.turnID == turnID,
              ProjectIdentity.canonical(event.projectPath) == projectPath,
              (event.at >= started || (event.codexOriginObservation?.stage == .missingLocator &&
               event.at.timeIntervalSince1970 == floor(started.timeIntervalSince1970))),
              file.path == file.resolvingSymlinksInPath().path, lstat(file.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_ino) == inode,
              info.st_size == fileSize, info.st_mtimespec.tv_sec == fileModifiedSeconds, info.st_mtimespec.tv_nsec == fileModifiedNanoseconds,
              let bytes = Self.header(file), Data(SHA256.hash(data: bytes)) == headerDigest else { return false }
        return true
    }
}

// Each adapter is confined to its owning watcher/recovery queue.
private final class RolloutDates {
    private let fractional: ISO8601DateFormatter = {
        let value = ISO8601DateFormatter()
        value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value
    }()
    private let whole = ISO8601DateFormatter()
    func date(_ raw: String) -> Date? { fractional.date(from: raw) ?? whole.date(from: raw) }
}

// Adapter for observed Codex 0.153.4 / Desktop 26.924 local rollout JSONL.
// This private format can change; unsupported records are ignored.
struct RolloutAdapter {
    private let dates = RolloutDates()
    static func hostForMetadata(source: String?, origin: String?, version: String? = nil) -> RuntimeHost {
        if source == "vscode", origin == "codex-tui", version == "0.160.1" { return .terminal }
        if source == "vscode", origin == "codex_vscode" { return .vscode }
        if source == "vscode", origin == "Codex Desktop" || origin == "codex_work_desktop" { return .codexDesktop }
        if ["exec", "cli", "interactive"].contains(source ?? ""), origin != "codex_vscode" { return .terminal }
        return .unknown
    }
    var rolloutFile: URL?
    var rolloutRoot: URL?
    private struct MetadataIdentity: Equatable {
        let id: String, root: String, source: String, origin: String
    }
    private var metadataIdentity: MetadataIdentity?
    private var metadataTime: Date?
    private var metadataInvalidatedActiveTurn = false
    private func validatedMetadataIdentity(_ object: [String: Any]) -> MetadataIdentity? {
        guard let file = rolloutFile, let root = rolloutRoot,
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              file.lastPathComponent.hasSuffix("-" + id + ".jsonl"),
              file.standardizedFileURL.path == file.resolvingSymlinksInPath().path,
              file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              payload["subagent"] == nil, payload["parent_thread_id"] == nil,
              payload["agent_path"] == nil || payload["agent_path"] as? String == "",
              let cwd = ProjectIdentity.canonical(payload["cwd"] as? String),
              let source = payload["source"] as? String,
              let origin = payload["originator"] as? String,
              (source == "vscode" && ["codex_vscode", "codex_work_desktop", "Codex Desktop"].contains(origin)) ||
              (Self.validCLIQuestionMetadata(source: source, origin: origin, version: payload["cli_version"] as? String) && metadataTimestamp(object) != nil) else { return nil }
        var info = stat()
        guard lstat(file.standardizedFileURL.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return nil }
        return MetadataIdentity(id: id, root: cwd, source: source, origin: origin)
    }
    private func metadataTimestamp(_ object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        return dates.date(raw)
    }
    func preservesMetadataRefresh(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return preservesMetadataRefresh(object)
    }
    func preservesMetadataRefresh(_ object: [String: Any]) -> Bool {
        guard let existing = metadataIdentity, validatedMetadataIdentity(object) == existing,
              let at = metadataTimestamp(object), at >= (metadataTime ?? .distantPast),
              at >= (lastNativeTimestamp ?? .distantPast) else { return false }
        return true
    }
    var sessionID = ""
    var title = "Codex oturumu"
    var source: CodexSource = .unknown
    var isSubagent = false
    var projectPath: String?
    private var runtimeHost: RuntimeHost = .unknown
    private var chatName: String?
    private var questionTurn: String?
    private var nativeQuestions: [String: PendingRequestSnapshot] = [:]
    private var activeTurnID: String?
    private var activeStartedAt: Date?
    private var lastNativeTimestamp: Date?
    private var retiredTurns: Set<String> = []
    var currentTurnID: String? { activeTurnID }
    private static func validCLIQuestionMetadata(source: String, origin: String, version: String?) -> Bool {
        origin == "codex-tui" && ((source == "cli" && version == "0.153.4") || (source == "vscode" && version == "0.160.1"))
    }
    private var validatedCLIQuestionHost: Bool {
        runtimeHost == .terminal && !isSubagent && metadataIdentity?.origin == "codex-tui" && metadataIdentity != nil
    }
    var cliQuestionProof: CodexCLIQuestionProof? {
        guard let metadata = metadataIdentity, validatedCLIQuestionHost,
              !isSubagent, runtimeHost == .terminal, metadata.id == sessionID, metadata.root == projectPath,
              let turn = activeTurnID, let file = rolloutFile else { return nil }
        var info = stat(); guard lstat(file.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else { return nil }
        return CodexCLIQuestionProof(sessionID: sessionID, projectPath: metadata.root, turnID: turn, runtimeID: questionRuntime.id, file: file, inode: UInt64(info.st_ino))
    }
    private var orderedBlockingHost: Bool {
        runtimeHost == .vscode || validatedCLIQuestionHost
    }
    var pendingCLIQuestions: [PendingRequestSnapshot] { cliQuestionProof == nil ? [] : Array(blockingQuestions.values) + pendingNativeAsyncSnapshots }
    func orderedNativeQuestionTurn(_ line: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        return orderedNativeQuestionTurn(object)
    }
    func orderedNativeQuestionTurn(_ object: [String: Any]) -> String? {
        guard orderedBlockingHost, let turn = activeTurnID, let started = activeStartedAt,
              object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "function_call", let name = payload["name"] as? String,
              ["request_user_input", "request_user_input_async"].contains(name),
              let call = payload["call_id"] as? String, !call.isEmpty, call.count <= 100,
              !closedBlockingCalls.contains(call), let raw = object["timestamp"] as? String else { return nil }
        guard let at = dates.date(raw),
              at >= started, at >= (lastNativeTimestamp ?? started) else { return nil }
        return turn
    }
    private var blockingQuestions: [String: PendingRequestSnapshot] = [:]
    private var nativeAsyncCalls: [String: Set<String>] = [:]
    var pendingNativeAsyncSnapshots: [PendingRequestSnapshot] { nativeAsyncCalls.values.flatMap { $0 }.compactMap { nativeQuestions[$0] } }
    private var closedBlockingCalls: Set<String> = []
    var hasPendingBlockingQuestion: Bool { !blockingQuestions.isEmpty || !nativeAsyncCalls.isEmpty }

    private var questionRuntime: RuntimeMetadata {
        RuntimeMetadata(id: "codex-rollout:" + source.rawValue + ":" + sessionID,
                        host: runtimeHost, version: nil, chatName: chatName)
    }

    mutating func parse(_ line: Data) -> CodexEvent? {
        parseEvents(line).first
    }

    // Only accepted, structured question items count; tool call text and ordinary
    // assistant prose are not evidence that a user request is pending.
    mutating func parseEvents(_ line: Data) -> [CodexEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        return parseEvents(object)
    }
    mutating func parseEvents(_ object: [String: Any]) -> [CodexEvent] {
        if let events = nativeAsyncCallEvents(object) { return events }
        if let events = blockingQuestionEvents(object) { return events }
        if let events = questionEvents(object) { return events }
        return parseLifecycle(object).map { [$0] } ?? []
    }

    // Captured VS Code 0.159.2: call/ACK is observe-only; ACK is not a reply.
    private mutating func nativeAsyncCallEvents(_ object: [String: Any]) -> [CodexEvent]? {
        guard let turn = orderedNativeQuestionTurn(object),
              let payload = object["payload"] as? [String: Any],
              payload["name"] as? String == "request_user_input_async",
              let call = payload["call_id"] as? String else { return nil }
        guard nativeAsyncCalls[call] == nil, nativeAsyncCalls.count < 16,
              let raw = payload["arguments"] as? String, raw.utf8.count <= 200_000,
              let data = raw.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bodies = args["questions"] as? [[String: Any]], (1...4).contains(bodies.count),
              let time = object["timestamp"] as? String else { return [] }
        guard let at = dates.date(time) else { return [] }
        var snapshots: [PendingRequestSnapshot] = []
        for (index, body) in bodies.enumerated() {
            guard let title = body["title"] as? String, !title.isEmpty,
                  let options = body["options"] as? [String], (2...4).contains(options.count),
                  let question = nativeQuestion(body, index: index),
                  let bytes = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", call, index]),
                  let key = String(data: bytes, encoding: .utf8) else { return [] }
            let identity = RequestIdentity(provider: .codex, runtimeID: questionRuntime.id, sessionID: sessionID,
                turnID: turn, requestID: key, generation: (runtimeHost == .terminal ? "cli-native:" : "vscode-async:") + turn + ":" + call + ":" + String(index))
            let snapshot = PendingRequestSnapshot(identity: identity, kind: .question, question: QuestionRequestBody(questions: [question]), observedAt: at)
            guard snapshot.isValid else { return [] }; snapshots.append(snapshot)
        }
        nativeAsyncCalls[call] = Set(snapshots.map(\.id)); lastNativeTimestamp = at
        return snapshots.map { snapshot in
            nativeQuestions[snapshot.id] = snapshot
            var event = CodexEvent(sessionID: sessionID, turnID: turn, requestID: snapshot.id, kind: .userQuestionObserved,
                source: source, title: title, at: at, id: "rollout:" + sessionID + ":" + turn + ":async:" + snapshot.id,
                fidelity: .derived, projectPath: projectPath, runtime: questionRuntime)
            event.requestSnapshot = snapshot
            event.capabilities = RuntimeCapabilities(provider: .codex, runtimeID: questionRuntime.id, version: runtimeHost == .terminal ? "0.160.1" : "0.159.2",
                evidence: [CapabilityEvidence(capability: .observeQuestions, support: .live, source: "Observed VS Code async call"),
                           CapabilityEvidence(capability: .answerQuestions, support: .unsupported, source: "Refik direct reply is disabled")])
            return event
        }
    }

    private mutating func questionEvents(_ object: [String: Any]) -> [CodexEvent]? {
        guard !isSubagent, !sessionID.isEmpty,
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], payload["type"] as? String == "item_completed",
              let turn = payload["turn_id"] as? String, !turn.isEmpty,
              let item = payload["item"] as? [String: Any], let itemID = item["id"] as? String,
              let raw = object["timestamp"] as? String else { return nil }
        guard let time = dates.date(raw) else { return [] }
        if orderedBlockingHost {
            guard turn == activeTurnID, time >= (activeStartedAt ?? .distantFuture), time >= (lastNativeTimestamp ?? .distantFuture) else { return [] }
        }
        let runtime = questionRuntime
        func event(_ request: String, _ kind: EventKind) -> CodexEvent {
            let e = CodexEvent(sessionID: sessionID, turnID: turn, requestID: request, kind: kind,
                source: source, title: title, at: time,
                id: "rollout:\(sessionID):\(turn):\(kind.rawValue):\(request)",
                detail: kind == .userQuestionObserved ? "Yapılandırılmış kullanıcı sorusu yanıt bekliyor" : nil,
                fidelity: .derived, projectPath: projectPath, runtime: runtime)
            return e
        }
        if orderedBlockingHost, item["type"] as? String == "AgentMessage",
           let call = (item["call_id"] as? String) ?? (item["id"] as? String),
           nativeAsyncCalls[call] != nil || closedBlockingCalls.contains(call) { return [] }
        if item["type"] as? String == "AgentMessage", item["delivery"] as? String == "async",
           let questions = item["questions"] as? [[String: Any]], !questions.isEmpty, questions.count <= 64 {
            if questionTurn == nil { questionTurn = turn }
            var result: [CodexEvent] = []
            for index in questions.indices {
                guard let bytes = try? JSONSerialization.data(withJSONObject: ["request_user_input_async", itemID, index], options: [.fragmentsAllowed]),
                      let key = String(data: bytes, encoding: .utf8), key.count <= 160 else { continue }
                var observed = event(key, .userQuestionObserved)
                if let question = nativeQuestion(questions[index], index: index) {
                    let identity = RequestIdentity(provider: .codex, runtimeID: runtime.id, sessionID: sessionID,
                        turnID: turn, requestID: key, generation: "native:" + turn + ":" + itemID + ":" + String(index))
                    let snapshot = PendingRequestSnapshot(identity: identity, kind: .question,
                        question: QuestionRequestBody(questions: [question]), observedAt: time)
                    if snapshot.isValid {
                        nativeQuestions[key] = snapshot
                        observed.requestSnapshot = snapshot
                        observed.capabilities = RuntimeCapabilities(provider: .codex, runtimeID: runtime.id, version: "unknown",
                            evidence: [CapabilityEvidence(capability: .observeQuestions, support: .documented,
                                source: "Observed accepted local rollout question item"),
                                CapabilityEvidence(capability: .answerQuestions, support: .unsupported,
                                source: "Desktop response transport has not been verified")])
                    }
                }
                result.append(observed)
            }
            return result
        }
        guard item["type"] as? String == "UserMessage",
              let content = item["content"] as? [[String: Any]], content.count == 1,
              content[0]["type"] as? String == "text", let text = content[0]["text"] as? String else { return nil }
        let opening = "<send_user_message_question_reply>", closing = "</send_user_message_question_reply>"
        let envelope = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard envelope.hasPrefix(opening), envelope.hasSuffix(closing) else { return [] }
        let body = String(envelope.dropFirst(opening.count).dropLast(closing.count))
        guard let bytes = body.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: bytes) else { return [] }
        let replies = (parsed as? [[String: Any]]) ?? (parsed as? [String: Any]).map { [$0] } ?? []
        return replies.compactMap { reply in
            guard let key = reply["questionItemId"] as? String, let bytes = key.data(using: .utf8),
                  let identity = try? JSONSerialization.jsonObject(with: bytes) as? [Any], identity.count == 3,
                  identity[0] as? String == "request_user_input_async", identity[1] is String,
                  let index = identity[2] as? Int, index >= 0,
                  let canonical = try? JSONSerialization.data(withJSONObject: identity),
                  let request = String(data: canonical, encoding: .utf8) else { return nil }
            if orderedBlockingHost, nativeQuestions[request]?.identity.turnID != activeTurnID { return nil }
            var resolved = event(request, .requestResolved)
            if let current = nativeQuestions[request], current.identity.turnID == turn {
                resolved.requestUpdate = RequestLifecycleUpdate(identity: current.identity, lifecycle: .resolved)
                if let call = identity[1] as? String, nativeAsyncCalls[call]?.contains(request) == true {
                    nativeAsyncCalls[call]?.remove(request); nativeQuestions.removeValue(forKey: request)
                    if nativeAsyncCalls[call]?.isEmpty == true { nativeAsyncCalls.removeValue(forKey: call); closedBlockingCalls.insert(call) }
                    lastNativeTimestamp = time
                }
            }
            return resolved
        }
    }

    // Native VS Code blocking question calls use the captured 0.160.0 shape.
    // Async accepted ACKs are intentionally handled separately and never resolve these.
    private mutating func blockingQuestionEvents(_ object: [String: Any]) -> [CodexEvent]? {
        guard orderedBlockingHost, let turn = activeTurnID,
              object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
              let call = payload["call_id"] as? String, !call.isEmpty, call.count <= 100,
              let rawTime = object["timestamp"] as? String else { return nil }
        guard let at = dates.date(rawTime) else { return [] }
        guard let started = activeStartedAt, at >= started, at >= (lastNativeTimestamp ?? started) else { return [] }
        let runtime = questionRuntime
        func event(_ kind: EventKind, request: PendingRequestSnapshot) -> CodexEvent {
            CodexEvent(sessionID: sessionID, turnID: request.identity.turnID, requestID: request.id, kind: kind,
                source: source, title: title, at: at,
                id: "rollout:\(sessionID):\(request.identity.turnID):\(kind.rawValue):\(call)",
                fidelity: .derived, projectPath: projectPath, runtime: runtime)
        }
        if payload["type"] as? String == "function_call", payload["name"] as? String == "request_user_input" {
            guard !closedBlockingCalls.contains(call), blockingQuestions[call] == nil, blockingQuestions.count < 16, closedBlockingCalls.count < 256,
                  let raw = payload["arguments"] as? String, raw.utf8.count <= 200_000,
                  let bytes = raw.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let bodies = args["questions"] as? [[String: Any]], (1...4).contains(bodies.count) else { return [] }
            var questions: [StructuredQuestion] = []
            for (index, body) in bodies.enumerated() {
                guard let id = body["id"] as? String, !id.isEmpty, id.count <= 100,
                      let prompt = body["question"] as? String, !prompt.isEmpty,
                      let header = body["header"] as? String, header.count <= 12,
                      let options = body["options"] as? [[String: Any]], (2...4).contains(options.count),
                      options.allSatisfy({ ($0["label"] as? String)?.isEmpty == false && $0["description"] is String }),
                      let question = nativeQuestion(body, index: index) else { return [] }
                questions.append(question)
            }
            guard Set(questions.map(\.id)).count == questions.count,
                  let keyData = try? JSONSerialization.data(withJSONObject: ["request_user_input", call]),
                  let key = String(data: keyData, encoding: .utf8) else { return [] }
            let identity = RequestIdentity(provider: .codex, runtimeID: runtime.id, sessionID: sessionID,
                turnID: turn, requestID: key, generation: (runtimeHost == .terminal ? "cli-native:" : "vscode-native:") + turn + ":" + call)
            let request = PendingRequestSnapshot(identity: identity, kind: .question,
                question: QuestionRequestBody(questions: questions), observedAt: at)
            guard request.isValid else { return [] }
            blockingQuestions[call] = request
            lastNativeTimestamp = at
            var observed = event(.userQuestionObserved, request: request)
            observed.requestSnapshot = request
            observed.capabilities = RuntimeCapabilities(provider: .codex, runtimeID: runtime.id, version: runtimeHost == .terminal ? "0.153.4" : "0.160.0",
                evidence: [CapabilityEvidence(capability: .observeQuestions, support: .live, source: runtimeHost == .terminal ? "Observed Codex CLI native request_user_input rollout" : "Observed VS Code Codex native request_user_input rollout"),
                           CapabilityEvidence(capability: .answerQuestions, support: .unsupported, source: "Refik direct reply is not enabled")])
            return [observed]
        }
        guard payload["type"] as? String == "function_call_output", let request = blockingQuestions[call],
              at >= request.observedAt, request.identity.turnID == turn,
              let raw = payload["output"] as? String, raw.utf8.count <= 200_000, let bytes = raw.data(using: .utf8),
              let output = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(output.keys) == ["answers"], let answers = output["answers"] as? [String: Any],
              Set(answers.keys) == Set(request.question?.questions.map(\.id) ?? []),
              !answers.isEmpty, answers.values.allSatisfy({ value in
                  guard let body = value as? [String: Any], Set(body.keys) == ["answers"], let values = body["answers"] as? [String],
                        !values.isEmpty, values.count <= 50 else { return false }
                  return values.allSatisfy { !$0.isEmpty && $0.count <= 10_000 }
              }) else { return nil }
        blockingQuestions.removeValue(forKey: call); closedBlockingCalls.insert(call)
        lastNativeTimestamp = at
        var resolved = event(.requestResolved, request: request)
        resolved.requestUpdate = RequestLifecycleUpdate(identity: request.identity, lifecycle: .resolved)
        return [resolved]
    }

    // Support the observed title/options-string shape and explicit richer
    // structured fields. Unsupported/malformed bodies retain legacy ID-only
    // observation rather than inventing question text from assistant prose.
    private func nativeQuestion(_ body: [String: Any], index: Int) -> StructuredQuestion? {
        guard let prompt = (body["question"] as? String) ?? (body["title"] as? String),
              !prompt.isEmpty, prompt.count <= 10_000,
              let rawOptions = body["options"] as? [Any], rawOptions.count <= 50 else { return nil }
        var options: [QuestionOption] = []
        for (offset, value) in rawOptions.enumerated() {
            if let label = value as? String, !label.isEmpty, label.count <= 2_000 {
                options.append(QuestionOption(id: String(offset), label: label))
            } else if let object = value as? [String: Any], let label = object["label"] as? String,
                      !label.isEmpty, label.count <= 2_000 {
                options.append(QuestionOption(id: object["id"] as? String ?? String(offset), label: label,
                    description: object["description"] as? String))
            } else { return nil }
        }
        for key in ["multiple", "multiSelect", "custom", "allowFreeform"] where body[key] != nil {
            guard let value = body[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        }
        return StructuredQuestion(id: body["id"] as? String ?? String(index), prompt: prompt,
            header: body["header"] as? String, options: options,
            allowsFreeform: (body["custom"] as? Bool) ?? (body["allowFreeform"] as? Bool) ?? true,
            allowsMultipleSelection: (body["multiple"] as? Bool) ?? (body["multiSelect"] as? Bool) ?? false)
    }

    private mutating func parseLifecycle(_ object: [String: Any]) -> CodexEvent? {
        let outer = object["type"] as? String ?? ""
        guard let payload = object["payload"] as? [String: Any] ?? (outer == "session_meta" ? [:] : nil) else { return nil }
        if outer == "session_meta" {
            if preservesMetadataRefresh(object) { metadataTime = metadataTimestamp(object); return nil }
            metadataInvalidatedActiveTurn = activeTurnID != nil
            metadataIdentity = validatedMetadataIdentity(object); metadataTime = metadataTimestamp(object)
            nativeQuestions.removeAll(); nativeAsyncCalls.removeAll(); questionTurn = nil
            activeTurnID = nil; activeStartedAt = nil; lastNativeTimestamp = nil; retiredTurns.removeAll(); blockingQuestions.removeAll(); closedBlockingCalls.removeAll()
            runtimeHost = .unknown; source = .unknown; chatName = nil
            sessionID = payload["id"] as? String ?? sessionID
            projectPath = ProjectIdentity.canonical(payload["cwd"] as? String)
            title = ProjectLabel.resolve(explicit: payload["project_name"] as? String, cwd: payload["cwd"] as? String, title: payload["title"] as? String)
            let origin = payload["originator"] as? String
            let declaredSource = payload["source"] as? String
            runtimeHost = Self.hostForMetadata(source: declaredSource, origin: origin, version: payload["cli_version"] as? String)
            if let name = payload["title"] as? String, !name.isEmpty { chatName = String(name.prefix(100)) }
            // originator is shared by the packaged CLI and Desktop on this host.
            // The observed source field distinguishes exec from the Desktop view.
            if let start = payload["source"] as? String {
                if start == "exec" || start == "cli" || start == "interactive" {
                    source = .cli
                }
                else if start == "vscode" { source = runtimeHost == .terminal ? .cli : origin == "codex-tui" ? .unknown : .desktop }
            } else if let start = payload["source"] as? [String: Any], start["subagent"] != nil {
                isSubagent = true
            }
            return nil
        }
        if isSubagent { return nil }
        guard outer == "event_msg", let type = payload["type"] as? String,
              let turn = payload["turn_id"] as? String, !sessionID.isEmpty else { return nil }
        let rawTime = object["timestamp"] as? String ?? ""
        guard let timestamp = dates.date(rawTime) else { return nil }
        let kind: EventKind
        var detail: String? = nil
        var suffix = type
        switch type {
        case "task_started":
            if orderedBlockingHost {
                guard !turn.isEmpty, turn.count <= 160, !retiredTurns.contains(turn), turn != activeTurnID,
                      timestamp > (lastNativeTimestamp ?? .distantPast), retiredTurns.count < 256 else { return nil }
                if let previous = activeTurnID { retiredTurns.insert(previous) }
                // Retain call tombstones as superseded, never answered.
                closedBlockingCalls.formUnion(blockingQuestions.keys)
                closedBlockingCalls.formUnion(nativeAsyncCalls.keys)
                nativeAsyncCalls.removeAll()
                blockingQuestions.removeAll()
            }
            metadataInvalidatedActiveTurn = false
            activeTurnID = turn; activeStartedAt = timestamp; lastNativeTimestamp = timestamp
            kind = .started
            if questionTurn != turn { nativeQuestions.removeAll(); questionTurn = turn }
        case "task_complete":
            guard !metadataInvalidatedActiveTurn, !hasPendingBlockingQuestion else { return nil }
            if orderedBlockingHost {
                guard turn == activeTurnID, timestamp >= (lastNativeTimestamp ?? .distantFuture) else { return nil }
                lastNativeTimestamp = timestamp
            }
            kind = .completed
        case "turn_aborted":
            if orderedBlockingHost {
                guard turn == activeTurnID, timestamp >= (lastNativeTimestamp ?? .distantFuture) else { return nil }
                lastNativeTimestamp = timestamp
            }
            if cliQuestionProof != nil {
                closedBlockingCalls.formUnion(blockingQuestions.keys)
                closedBlockingCalls.formUnion(nativeAsyncCalls.keys)
                nativeAsyncCalls.removeAll()
                nativeQuestions.removeAll()
                blockingQuestions.removeAll()
            }
            kind = .interrupted
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], let itemType = item["type"] as? String else { return nil }
            let safeLabel: String
            switch itemType {
            case "CommandExecution": safeLabel = "komut çalıştırıldı"
            case "FileChange": safeLabel = "dosya değişikliği işlendi"
            case "McpToolCall", "Extension": safeLabel = "araç çağrısı tamamlandı"
            case "SubAgentActivity": safeLabel = "alt ajan adımı tamamlandı"
            default: return nil
            }
            kind = .activity
            detail = "Son doğrulanan adım: \(safeLabel)"
            suffix += ":\(item["id"] as? String ?? UUID().uuidString)"
        default: return nil
        }
        var event = CodexEvent(sessionID: sessionID, turnID: turn, requestID: nil, kind: kind,
            source: source, title: title, at: timestamp, id: "rollout:\(sessionID):\(turn):\(suffix)", detail: detail)
        event.fidelity = .derived
        event.projectPath = projectPath
        event.runtime = questionRuntime
        if [.started, .completed].contains(kind), activeTurnID == turn,
           let started = activeStartedAt, let file = rolloutFile, let root = rolloutRoot {
            event.codexNativeTurnProof = CodexNativeTurnProof(event: event, started: started, file: file, root: root)
        }
        return event
    }
}

struct JSONLLineBuffer {
    private(set) var partial = Data()
    private(set) var overflowed = false
    mutating func append(_ bytes: Data) -> [Data] {
        appendFiltered(bytes) { _ in true }
    }
    mutating func appendFiltered(_ bytes: Data, where keep: (Data.SubSequence) -> Bool) -> [Data] {
        var joined = partial
        joined.append(bytes)
        var lines: [Data] = []
        var start = joined.startIndex
        for end in joined.indices where joined[end] == 10 {
            let line = joined[start..<end]
            if keep(line) { lines.append(Data(line)) }
            start = joined.index(after: end)
        }
        partial = Data(joined[start...])
        if partial.count > 1_000_000 { partial.removeAll(); overflowed = true }
        return lines
    }
}

// Metadata-only proof of a root Desktop turn in one continuously consumed file.
struct RolloutCompletionProof {
    let completion: NativeCompletion
    let started: Date
    let cwd: String
}
struct RolloutCompletionTracker {
    private var session = ""
    private var cwd = ""
    private var validRoot = false
    private var start: CodexEvent?
    private var startOffset: UInt64 = 0
    private(set) var proof: RolloutCompletionProof?
    private let generation = UUID().uuidString
    mutating func metadata(_ line: Data) {
        guard line.range(of: Data("\"session_meta\"".utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        metadata(object)
    }
    mutating func metadata(_ object: [String: Any]) {
        guard object["type"] as? String == "session_meta" else { return }
        start = nil; proof = nil; validRoot = false
        guard let p = object["payload"] as? [String: Any],
              let id = p["id"] as? String, !id.isEmpty,
              let path = p["cwd"] as? String, path.hasPrefix("/"),
              let origin = p["originator"] as? String, origin == "codex_work_desktop",
              p["source"] as? String == "vscode",
              (p["agent_path"] == nil || p["agent_path"] as? String == ""),
              p["subagent"] == nil, p["parent_thread_id"] == nil else { return }
        session = id; cwd = URL(fileURLWithPath: path).standardizedFileURL.path; validRoot = true
    }
    mutating func validateLifecycle(_ line: Data, events: [CodexEvent]) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        validateLifecycle(object, events: events)
    }
    mutating func validateLifecycle(_ object: [String: Any], events: [CodexEvent]) {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String,
              type.hasPrefix("task_") || type.hasPrefix("turn_") else { return }
        if !["task_started", "task_complete", "turn_aborted"].contains(type) || events.isEmpty {
            start = nil; proof = nil
        }
    }
    mutating func event(_ event: CodexEvent, offset: UInt64) {
        guard validRoot, event.sessionID == session, event.source == .desktop else { proof = nil; start = nil; return }
        if event.kind == .started {
            if let previous = start, event.at <= previous.at { start = nil; proof = nil; return }
            start = event; startOffset = offset; proof = nil
        } else if event.kind == .completed {
            guard proof == nil, let start, start.turnID == event.turnID, event.at > start.at else { proof = nil; self.start = nil; return }
            let completion = NativeCompletion(thread: session, turn: event.turnID, completed: event.at,
                proofGeneration: "\(generation):\(startOffset):\(offset)")
            proof = RolloutCompletionProof(completion: completion, started: start.at, cwd: cwd)
        } else if event.kind == .interrupted || event.kind == .unknownEvent || event.turnID != start?.turnID {
            proof = nil; start = nil
        }
    }
}

// Validate an oversized record without retaining its text. Short strings and
// JSON structure form a bounded skeleton; Foundation validates its grammar.
// Every discarded string byte is still checked, including UTF-8 and escapes.
struct RecoveryJSONRecord {
    private var skeleton = Data()
    private var token = Data()
    private var inString = false
    private var longString = false
    private var escape = 0
    private var hexDigits = 0
    private var scalar = 0
    private var highSurrogate = false
    private var utf8Remaining = 0
    private var utf8Min: UInt8 = 0x80
    private var utf8Max: UInt8 = 0xbf
    private var depth = 0
    private var previousSyntax: UInt8?
    private(set) var valid = true
    mutating func append(_ bytes: Data.SubSequence) {
        for byte in bytes {
            guard valid else { return }
            if inString {
                if !longString {
                    token.append(byte)
                    if token.count > 512 { token.removeAll(keepingCapacity: true); longString = true }
                }
                if utf8Remaining > 0 {
                    guard byte >= utf8Min && byte <= utf8Max else { valid = false; return }
                    utf8Remaining -= 1; utf8Min = 0x80; utf8Max = 0xbf
                } else if escape == 2 {
                    let digit: Int
                    switch byte {
                    case 48...57: digit = Int(byte - 48)
                    case 65...70: digit = Int(byte - 55)
                    case 97...102: digit = Int(byte - 87)
                    default: valid = false; return
                    }
                    scalar = scalar * 16 + digit; hexDigits += 1
                    if hexDigits == 4 {
                        if highSurrogate {
                            guard (0xdc00...0xdfff).contains(scalar) else { valid = false; return }
                            highSurrogate = false; escape = 0
                        } else if (0xd800...0xdbff).contains(scalar) { highSurrogate = true; escape = 3 }
                        else {
                            guard !(0xdc00...0xdfff).contains(scalar) else { valid = false; return }
                            escape = 0
                        }
                    }
                } else if escape == 3 {
                    guard byte == 92 else { valid = false; return }; escape = 4
                } else if escape == 1 || escape == 4 {
                    if byte == 117 { escape = 2; hexDigits = 0; scalar = 0 }
                    else if escape == 1 && [UInt8(34), 92, 47, 98, 102, 110, 114, 116].contains(byte) { escape = 0 }
                    else { valid = false; return }
                } else if byte == 34 {
                    inString = false; previousSyntax = 34
                    skeleton.append(longString ? Data("\"\"".utf8) : token)
                    token.removeAll(keepingCapacity: true)
                } else if byte == 92 { escape = 1 }
                else if byte < 32 { valid = false; return }
                else if byte >= 128 {
                    switch byte {
                    case 0xc2...0xdf: utf8Remaining = 1
                    case 0xe0: utf8Remaining = 2; utf8Min = 0xa0
                    case 0xe1...0xec, 0xee...0xef: utf8Remaining = 2
                    case 0xed: utf8Remaining = 2; utf8Max = 0x9f
                    case 0xf0: utf8Remaining = 3; utf8Min = 0x90
                    case 0xf1...0xf3: utf8Remaining = 3
                    case 0xf4: utf8Remaining = 3; utf8Max = 0x8f
                    default: valid = false; return
                    }
                }
            } else if byte == 34 {
                inString = true; longString = false; token = Data([byte])
            } else {
                // Foundation permits trailing commas; recovery must not.
                if (byte == 125 || byte == 93) && previousSyntax == 44 { valid = false; return }
                if ![UInt8(32), 9, 13].contains(byte) { previousSyntax = byte }
                // Compress whitespace while retaining token boundaries.
                if [UInt8(32), 9, 13].contains(byte) {
                    if skeleton.last != 32 { skeleton.append(32) }
                } else { skeleton.append(byte) }
                if byte == 123 || byte == 91 { depth += 1 }
                if byte == 125 || byte == 93 { depth -= 1 }
                if depth < 0 || depth > 128 { valid = false; return }
            }
            if skeleton.count > 1_000_000 { valid = false; return }
        }
    }
    var isCompaction: Bool {
        guard valid, !inString, depth == 0,
              let object = try? JSONSerialization.jsonObject(with: skeleton) as? [String: Any] else { return false }
        return object["type"] as? String == "compacted"
    }
}

private struct FileCursor {
    var offset: UInt64 = 0
    var lines = JSONLLineBuffer()
    var adapter = RolloutAdapter()
    var completionTracker = RolloutCompletionTracker()
    var completionRecoveryRequired = false
    var completionRecoveryOffset: UInt64?
    var completionRecoveryToken: UUID?
    var recoveredCompletionProof: RolloutCompletionProof?
    var editorOrigin: CodexEditorOriginProof?
    var originTurnID: String?
    var unresolvedNativeQuestion = false
    var identity: UInt64 = 0
    var modified = Date.distantPast
}

private func rolloutCallback(_ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?,
                             _ count: Int, _ paths: UnsafeMutableRawPointer,
                             _ flags: UnsafePointer<FSEventStreamEventFlags>, _ ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    let changed = Set((0..<count).map { String(cString: names[$0]) })
    Unmanaged<TranscriptWatcher>.fromOpaque(info).takeUnretainedValue().scan(changedPaths: changed)
}

private func canonicalPath(_ path: String) -> String {
    guard let resolved = path.withCString({ realpath($0, nil) }) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

final class TranscriptWatcher {
    private struct Candidate {
        let url: URL
        let modified: Date
        let size: UInt64
        let identity: UInt64
    }
    private let root: URL
    private let queue = DispatchQueue(label: "refik.rollouts", qos: .utility)
    private let completionRecoveryQueue = DispatchQueue(label: "refik.rollout-proof-recovery", qos: .utility)
    private var stream: FSEventStreamRef?
    private var healthTimer: DispatchSourceTimer?
    private var appendTimer: DispatchSourceTimer?
    private var pollPosition = 0
    private var cursors: [String: FileCursor] = [:]
    private let onEvent: (CodexEvent, Bool) -> Void
    private let onEditorOrigin: (CodexEvent, CodexEditorOriginProof) -> Void
    private let onEditorOriginBlocked: (String, EditorFocusBlockReason, String) -> Void
    private let onHistoricalEditorCompletion: (CodexEditorOriginProof, CodexEvent) -> Void
    private let onCLIQuestion: (CodexEvent, Bool, CodexCLIQuestionProof) -> Void
    private let onCLIPendingRecovery: (CodexCLIQuestionProof, [PendingRequestSnapshot]) -> Void
    private let onNativeAsyncPendingRecovery: (CodexEditorOriginProof, [PendingRequestSnapshot]) -> Void
    private let onEditorOriginReplayed: (CodexEvent, CodexEditorOriginProof) -> Void
    private let onEditorOriginTurnStarted: (CodexEvent, CodexEditorOriginProof) -> Void
    private let onBootstrapDone: () -> Void
    private let onHealth: (Bool) -> Void
    private var reportedHealth: Bool?
    private var bootstrapping = true
    private var startedAt = Date()
    private var streamRunning = false
    private let lifecycleMarkers = [Data("\"task_started\"".utf8), Data("\"task_complete\"".utf8), Data("\"turn_aborted\"".utf8), Data("\"task_".utf8)]
    private let activityMarker = Data("\"item_completed\"".utf8)
    private let sessionMetaMarker = Data("\"session_meta\"".utf8)

    init(root: URL, onEvent: @escaping (CodexEvent, Bool) -> Void,
         onBootstrapDone: @escaping () -> Void, onHealth: @escaping (Bool) -> Void,
         onEditorOrigin: @escaping (CodexEvent, CodexEditorOriginProof) -> Void = { _, _ in },
         onEditorOriginBlocked: @escaping (String, EditorFocusBlockReason, String) -> Void = { _, _, _ in },
         onHistoricalEditorCompletion: @escaping (CodexEditorOriginProof, CodexEvent) -> Void = { _, _ in },
         onNativeAsyncPendingRecovery: @escaping (CodexEditorOriginProof, [PendingRequestSnapshot]) -> Void = { _, _ in },
         onEditorOriginReplayed: @escaping (CodexEvent, CodexEditorOriginProof) -> Void = { _, _ in },
         onEditorOriginTurnStarted: @escaping (CodexEvent, CodexEditorOriginProof) -> Void = { _, _ in },
         onCLIQuestion: @escaping (CodexEvent, Bool, CodexCLIQuestionProof) -> Void = { _, _, _ in },
         onCLIPendingRecovery: @escaping (CodexCLIQuestionProof, [PendingRequestSnapshot]) -> Void = { _, _ in }) {
        self.onCLIQuestion = onCLIQuestion; self.onCLIPendingRecovery = onCLIPendingRecovery
        self.onEditorOrigin = onEditorOrigin
        self.onEditorOriginBlocked = onEditorOriginBlocked
        self.onEditorOriginTurnStarted = onEditorOriginTurnStarted
        self.onEditorOriginReplayed = onEditorOriginReplayed
        self.onNativeAsyncPendingRecovery = onNativeAsyncPendingRecovery
        self.onHistoricalEditorCompletion = onHistoricalEditorCompletion
        self.root = root; self.onEvent = onEvent; self.onBootstrapDone = onBootstrapDone; self.onHealth = onHealth
    }
    func start() {
        let launchTime = Date()
        queue.async { [self] in
            self.startedAt = launchTime
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            self.stream = FSEventStreamCreate(nil, rolloutCallback, &context,
                [self.root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
            if let stream = self.stream {
                FSEventStreamSetDispatchQueue(stream, self.queue)
                self.streamRunning = FSEventStreamStart(stream)
                if !self.streamRunning { self.reportHealth(false) }
            } else { self.reportHealth(false) }
            self.scan()
            self.bootstrapping = false
            self.onBootstrapDone()
            // FSEvents can deliver writes to an open rollout much later than
            // the bytes become readable. Poll only bounded known files so a
            // matching answer does not depend on a later writer notification.
            let appendTimer = DispatchSource.makeTimerSource(queue: self.queue)
            appendTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
            appendTimer.setEventHandler { [weak self] in self?.scanKnownFiles() }
            self.appendTimer = appendTimer; appendTimer.resume()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                var directory: ObjCBool = false
                if !FileManager.default.fileExists(atPath: self.root.path, isDirectory: &directory) ||
                   !directory.boolValue || !FileManager.default.isReadableFile(atPath: self.root.path) {
                    self.reportHealth(false)
                }
            }
            self.healthTimer = timer; timer.resume()
        }
    }
    // Snapshot only fully consumed, unchanged regular files. Pending append,
    // replacement, deletion, or read failure cannot furnish completion proof.
    func completionProofs() -> [RolloutCompletionProof] {
        queue.sync {
            guard reportedHealth == true else { return [] }
            return Array(cursors.keys).compactMap { path in
                guard var cursor = cursors[path], cursor.lines.partial.isEmpty,
                      let snapshot = RolloutFileSnapshot(path), snapshot.type == S_IFREG,
                      snapshot.size == cursor.offset, snapshot.modified == cursor.modified,
                      snapshot.identity == cursor.identity,
                      cursor.identity != 0 else { return nil }
                if cursor.completionRecoveryRequired || cursor.lines.overflowed {
                    // A historical oversized record cannot permanently poison a
                    // later complete turn. Reconstruct only within a bounded,
                    // stable file snapshot; the ordinary overflow guard remains.
                    if cursor.completionRecoveryOffset != cursor.offset {
                        if cursor.completionRecoveryToken == nil {
                            let token = UUID(); cursor.completionRecoveryToken = token
                            cursors[path] = cursor
                            let snapshot = cursor
                            completionRecoveryQueue.async { [weak self] in
                                guard let self else { return }
                                let proof = self.boundedCompletionProof(URL(fileURLWithPath: path), size: snapshot.offset, identity: snapshot.identity, modified: snapshot.modified)
                                self.queue.async {
                                    guard var current = self.cursors[path], current.completionRecoveryToken == token else { return }
                                    current.completionRecoveryToken = nil
                                    if current.offset == snapshot.offset && current.identity == snapshot.identity && current.modified == snapshot.modified {
                                        current.recoveredCompletionProof = proof
                                        current.completionRecoveryOffset = snapshot.offset
                                    }
                                    self.cursors[path] = current
                                }
                            }
                        }
                        return nil
                    }
                    return cursor.recoveredCompletionProof
                }
                return cursor.completionTracker.proof
            }
        }
    }
    // Internal status also lets deterministic callers await cache preparation;
    // querying proofs itself never performs the bounded history scan.
    var completionRecoveryPending: Bool {
        queue.sync { cursors.values.contains { $0.completionRecoveryToken != nil } }
    }
    func boundedCompletionProof(_ file: URL, size: UInt64, identity: UInt64, modified: Date) -> RolloutCompletionProof? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let headerBytes = try? handle.read(upToCount: 256 * 1024),
              let headerEnd = headerBytes.firstIndex(of: 10) else { return nil }
        let header = Data(headerBytes[..<headerEnd])
        guard let headerObject = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
              headerObject["type"] as? String == "session_meta",
              let headerPayload = headerObject["payload"] as? NSDictionary else { return nil }
        var tracker = RolloutCompletionTracker(), adapter = RolloutAdapter()
        adapter.rolloutFile = file; adapter.rolloutRoot = root
        tracker.metadata(headerObject); _ = adapter.parseEvents(headerObject)
        // Bound I/O independently of record size. The usual 8 MiB tail can
        // begin inside a compaction much larger than that tail. Scan complete
        // records in chunks, retaining at most 1 MiB of any ordinary record.
        let count = min(size, UInt64(64 * 1024 * 1024)), offset = size - count
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        var position = offset, discardingFragment = offset > 0, unresolvedQuestion = false
        var line = Data(), oversized = false, validation = RecoveryJSONRecord()
        func resetContinuity() {
            unresolvedQuestion = false
            tracker = RolloutCompletionTracker(); tracker.metadata(headerObject)
            adapter = RolloutAdapter(); adapter.rolloutFile = file; adapter.rolloutRoot = root
            _ = adapter.parseEvents(headerObject)
        }
        while position < size {
            let chunkSize = Int(min(UInt64(256 * 1024), size - position))
            guard let chunk = try? handle.read(upToCount: chunkSize), chunk.count == chunkSize else { return nil }
            var begin = chunk.startIndex
            for end in chunk.indices where chunk[end] == 10 {
                let piece = chunk[begin..<end]; begin = chunk.index(after: end)
                if discardingFragment { discardingFragment = false; continue }
                if !oversized && line.count + piece.count <= 1_000_000 { line.append(piece) }
                else {
                    if !oversized { validation.append(line); line.removeAll(keepingCapacity: true) }
                    oversized = true; validation.append(piece)
                }
                defer { line.removeAll(keepingCapacity: true); oversized = false; validation = RecoveryJSONRecord() }
                if oversized {
                    // Only fully validated top-level compaction can bridge a
                    // start/end pair. Nested lifecycle-like strings are text.
                    if !validation.isCompaction { resetContinuity() }
                    continue
                }
                guard !line.isEmpty else { continue }
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    resetContinuity(); continue
                }
                if object["type"] as? String == "session_meta" {
                    guard let payload = object["payload"] as? NSDictionary, payload.isEqual(headerPayload) else { return nil }
                    tracker.metadata(object)
                }
                if Self.isNativeQuestionCall(object) { unresolvedQuestion = true }
                let events = adapter.parseEvents(object)
                tracker.validateLifecycle(object, events: events)
                for event in events {
                    if event.kind == .started { unresolvedQuestion = false }
                    if event.kind == .requestResolved && !adapter.hasPendingBlockingQuestion { unresolvedQuestion = false }
                    tracker.event(event, offset: position + UInt64(end))
                }
            }
            if begin < chunk.endIndex && !discardingFragment {
                let piece = chunk[begin...]
                if !oversized && line.count + piece.count <= 1_000_000 { line.append(piece) }
                else {
                    if !oversized { validation.append(line); line.removeAll(keepingCapacity: true) }
                    oversized = true; validation.append(piece)
                }
            }
            position += UInt64(chunk.count)
            if position == size && chunk.last != 10 { return nil }
        }
        guard !unresolvedQuestion, !adapter.hasPendingBlockingQuestion,
              let proof = tracker.proof,
              let after = RolloutFileSnapshot(file.path), after.type == S_IFREG,
              after.size == size, after.modified == modified, after.identity == identity else { return nil }
        return proof
    }
    func reconcile(changedPaths: Set<String>? = nil) { queue.async { self.scan(changedPaths: changedPaths) } }
    func stop() {
        queue.async {
            self.healthTimer?.cancel(); self.healthTimer = nil
            self.appendTimer?.cancel(); self.appendTimer = nil
            if let s = self.stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); self.stream = nil }
            self.streamRunning = false
        }
    }
    private func reportHealth(_ healthy: Bool) {
        if reportedHealth != healthy { reportedHealth = healthy; onHealth(healthy) }
    }
    // Runs on the watcher queue. Recent files receive every poll; rotating the
    // remainder bounds each pass while retaining recovery for quieter files.
    func scanKnownFiles() {
        let recent = cursors.sorted {
            $0.value.modified == $1.value.modified ? $0.key < $1.key : $0.value.modified > $1.value.modified
        }.prefix(32).map(\.key)
        let others = cursors.keys.filter { !recent.contains($0) }.sorted()
        var paths = Set(recent)
        if !others.isEmpty {
            for index in 0..<min(32, others.count) { paths.insert(others[(pollPosition + index) % others.count]) }
            pollPosition = (pollPosition + min(32, others.count)) % others.count
        }
        if !paths.isEmpty { scan(changedPaths: paths) }
    }
    func scan(changedPaths: Set<String>? = nil) {
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: root.path) else {
            reportHealth(false); return
        }
        // File notifications already identify the changed rollout. Enumerating
        // the entire history for every append can queue seconds of metadata work
        // ahead of a small answer, especially while many agents are writing.
        let keys: [URLResourceKey] = []
        var urls: [URL] = []
        if let changedPaths {
            let base = canonicalPath(root.path)
            for path in Set(changedPaths.map(canonicalPath)).sorted() {
                guard path == base || path.hasPrefix(base + "/") else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    cursors.removeValue(forKey: path); continue
                }
                let url = URL(fileURLWithPath: path)
                if isDirectory.boolValue {
                    if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
                        urls.append(contentsOf: enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" })
                    }
                } else if url.pathExtension == "jsonl" { urls.append(url) }
            }
        } else {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                reportHealth(false); return
            }
            urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        }
        let recent = Date().addingTimeInterval(-2 * 24 * 3600)
        var candidates: [Candidate] = []
        for url in Set(urls) {
            guard let snapshot = RolloutFileSnapshot(url.path) else { continue }
            let modified = snapshot.modified
            // Modification dates only bound historical discovery. A live path can
            // belong to a long-running turn in an older rollout.
            if changedPaths == nil && modified < recent { continue }
            candidates.append(Candidate(url: url, modified: modified, size: snapshot.size, identity: snapshot.identity))
        }
        candidates.sort { $0.modified > $1.modified }
        let selected: [Candidate]
        if let changedPaths {
            // Live paths are never subject to the historical bootstrap cap.
            let normalized = Set(changedPaths.map(canonicalPath))
            selected = candidates.filter { candidate in
                let path = canonicalPath(candidate.url.path)
                return normalized.contains { changed in path == changed || path.hasPrefix(changed + "/") }
            }
        } else if bootstrapping { selected = Array(candidates.prefix(30)) }
        else {
            // Recovery checks known files incrementally, with bounded discovery of
            // new files when a filesystem notification was lost.
            let recentPaths = Set(candidates.prefix(30).map { $0.url.path })
            selected = candidates.filter { recentPaths.contains($0.url.path) || cursors[$0.url.path] != nil }
        }
        var hadReadError = false
        var bootstrapBudget = 64 * 1024 * 1024
        let historicalBootstrap = bootstrapping && changedPaths == nil
        for candidate in selected {
            if historicalBootstrap && bootstrapBudget <= 0 { break }
            do {
                let readBytes = try read(candidate, initialLimit: min(8 * 1024 * 1024, bootstrapBudget),
                                         fullInitial: changedPaths != nil)
                if historicalBootstrap { bootstrapBudget -= readBytes }
            } catch { hadReadError = true }
        }
        // Retain cursors for old rollouts that are still receiving live events.
        if changedPaths == nil { cursors = cursors.filter { FileManager.default.fileExists(atPath: $0.key) } }
        reportHealth(!hadReadError && (stream == nil || streamRunning))
    }
    private func read(_ candidate: Candidate, initialLimit: Int, fullInitial: Bool) throws -> Int {
        let path = candidate.url.path
        var cursor = cursors[path] ?? FileCursor()
        let rotated = candidate.size < cursor.offset ||
            (cursor.identity != 0 && candidate.identity != 0 && cursor.identity != candidate.identity)
        if rotated { cursor = FileCursor() }
        if candidate.size == cursor.offset { return 0 }
        let handle = try FileHandle(forReadingFrom: candidate.url)
        defer { try? handle.close() }
        cursor.identity = candidate.identity
        cursor.modified = candidate.modified
        var bytes = Data()
        if cursor.offset == 0 && fullInitial {
            // Preserve the entire first-seen history, but yield between bounded
            // reads so a large rollout cannot hold up another file's live reply.
            let chunk = try handle.read(upToCount: min(4 * 1024 * 1024, Int(candidate.size))) ?? Data()
            cursor.offset += UInt64(chunk.count)
            consume(chunk, cursor: &cursor, file: candidate.url)
            cursors[path] = cursor
            if cursor.offset < candidate.size { queue.async { self.scan(changedPaths: [path]) } }
            return chunk.count
        }
        if cursor.offset == 0 {
            let header = try handle.read(upToCount: 256 * 1024) ?? Data()
            if let newline = header.firstIndex(of: 10) {
                let line = Data(header[..<newline])
                _ = cursor.adapter.parse(line); cursor.completionTracker.metadata(line)
                cursor.editorOrigin = CodexEditorOriginProof(metadata: line, file: candidate.url, root: root)
            }
            let count = min(Int(candidate.size), initialLimit)
            var start = candidate.size - UInt64(count)
            try handle.seek(toOffset: start)
            bytes = try handle.read(upToCount: count) ?? Data()
            var total = bytes.count
            while start > 0 && !containsLifecycle(bytes) && total < initialLimit {
                // A long live turn may have begun before the first tail window.
                // The bounded search brings its latest lifecycle event into view.
                let extra = min(2 * 1024 * 1024, initialLimit - total, Int(start))
                if extra == 0 { break }
                try handle.seek(toOffset: start - UInt64(extra))
                let previous = try handle.read(upToCount: extra) ?? Data()
                bytes = previous + bytes
                total += previous.count
                start -= UInt64(previous.count)
                if previous.isEmpty { break }
            }
            let actualStart = candidate.size - UInt64(bytes.count)
            if actualStart > 0 {
                cursor.completionRecoveryRequired = true
                if let newline = bytes.firstIndex(of: 10) { bytes = Data(bytes[bytes.index(after: newline)...]) }
                else { bytes.removeAll() }
            }
            cursor.offset = candidate.size
            consume(bytes, cursor: &cursor, file: candidate.url)
            cursors[path] = cursor
            return total + header.count
        }
        try handle.seek(toOffset: cursor.offset)
        bytes = try handle.read(upToCount: min(Int(candidate.size - cursor.offset), 4 * 1024 * 1024)) ?? Data()
        cursor.offset += UInt64(bytes.count)
        consume(bytes, cursor: &cursor, file: candidate.url)
        cursors[path] = cursor
        if cursor.offset < candidate.size { queue.async { self.scan(changedPaths: [path]) } }
        return bytes.count
    }
    private func containsLifecycle(_ bytes: Data) -> Bool {
        if lifecycleMarkers.contains(where: { bytes.range(of: $0) != nil }) { return true }
        // A turn_id key occurs in ordinary activity records; it is not lifecycle.
        let prefix = Data("\"turn_".utf8), identityKey = Data("\"turn_id\"".utf8)
        var remaining = bytes
        while let range = remaining.range(of: prefix) {
            if !remaining[range.lowerBound...].starts(with: identityKey) { return true }
            remaining = Data(remaining[range.upperBound...])
        }
        return false
    }
    static func isAsyncNativeQuestionCall(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == "function_call" && payload["name"] as? String == "request_user_input_async"
    }
    static func isNativeQuestionCall(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return isNativeQuestionCall(object)
    }
    private static func isNativeQuestionCall(_ object: [String: Any]) -> Bool {
        guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any] else { return false }
        return payload["type"] as? String == "function_call" && ["request_user_input_async", "request_user_input"].contains(payload["name"] as? String ?? "")
    }
    private func consume(_ bytes: Data, cursor: inout FileCursor, file: URL) {
        cursor.adapter.rolloutFile = file; cursor.adapter.rolloutRoot = root
        let relevantLines = cursor.lines.appendFiltered(bytes) { line in
            containsLifecycle(line) || line.range(of: activityMarker) != nil ||
                line.range(of: sessionMetaMarker) != nil ||
                line.range(of: Data("request_user_input".utf8)) != nil ||
                line.range(of: Data("function_call_output".utf8)) != nil
        }
        for line in relevantLines {
            if line.count > 1_000_000 {
                cursor.completionRecoveryRequired = true
                cursor.completionTracker = RolloutCompletionTracker(); cursor.editorOrigin = nil; continue
            }
            if line.range(of: sessionMetaMarker) != nil, !cursor.adapter.preservesMetadataRefresh(line) {
                cursor.editorOrigin = CodexEditorOriginProof(metadata: line, file: file, root: root)
                cursor.originTurnID = nil; cursor.unresolvedNativeQuestion = false
            }
            if let proof = cursor.editorOrigin, let turn = cursor.adapter.orderedNativeQuestionTurn(line) {
                if Self.isAsyncNativeQuestionCall(line) { cursor.unresolvedNativeQuestion = true }
                onEditorOriginBlocked(proof.sessionID, Self.isAsyncNativeQuestionCall(line) ? .codexAsyncQuestionUnresolved : .codexBlockingQuestionUnresolved, turn)
            }
            cursor.completionTracker.metadata(line)
            let events = cursor.adapter.parseEvents(line)
            let lifecycle = containsLifecycle(line)
            if lifecycle { cursor.completionTracker.validateLifecycle(line, events: events) }
            if lifecycle && events.isEmpty &&
                (try? JSONSerialization.jsonObject(with: line)) == nil {
                cursor.completionTracker = RolloutCompletionTracker()
            }
            for event in events {
                cursor.completionTracker.event(event, offset: cursor.offset)
                if event.at < startedAt, event.kind == .completed, !cursor.unresolvedNativeQuestion,
                   !cursor.adapter.hasPendingBlockingQuestion, cursor.originTurnID == event.turnID,
                   let proof = cursor.editorOrigin { onHistoricalEditorCompletion(proof, event) }
                if event.kind == .userQuestionObserved, let proof = cursor.adapter.cliQuestionProof, proof.matches(event) {
                    onCLIQuestion(event, event.at < startedAt, proof)
                } else { onEvent(event, event.at < startedAt) }
                if event.kind == .requestResolved, event.requestUpdate?.identity.generation.hasPrefix("vscode-async:") == true,
                   cursor.adapter.pendingNativeAsyncSnapshots.isEmpty { cursor.unresolvedNativeQuestion = false }
                if event.kind == .started {
                    cursor.originTurnID = event.turnID
                    cursor.unresolvedNativeQuestion = false
                    if let proof = cursor.editorOrigin { onEditorOriginTurnStarted(event, proof) }
                }
                if event.at < startedAt, !cursor.unresolvedNativeQuestion,
                   !cursor.adapter.hasPendingBlockingQuestion, cursor.originTurnID == event.turnID,
                   [.requestResolved, .completed].contains(event.kind), let proof = cursor.editorOrigin {
                    onEditorOriginReplayed(event, proof)
                }
                if event.at >= startedAt, !cursor.unresolvedNativeQuestion, !cursor.adapter.hasPendingBlockingQuestion, cursor.originTurnID == event.turnID,
                   let proof = cursor.editorOrigin { onEditorOrigin(event, proof) }
            }
        }
        if let proof = cursor.adapter.cliQuestionProof, !cursor.adapter.pendingCLIQuestions.isEmpty {
            onCLIPendingRecovery(proof, cursor.adapter.pendingCLIQuestions)
        }
        if let proof = cursor.editorOrigin, !cursor.adapter.pendingNativeAsyncSnapshots.isEmpty {
            onNativeAsyncPendingRecovery(proof, cursor.adapter.pendingNativeAsyncSnapshots)
        }
    }
}
