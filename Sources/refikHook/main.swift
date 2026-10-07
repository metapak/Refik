import Foundation
import Darwin
import CryptoKit
import CoreFoundation
import RefikInteractionWire

if CommandLine.arguments.dropFirst().first == "--editor-focus-stream" { editorFocusStream() }

// The helper reads the app-owned short-lived marker; no inherited opt-in flag
// is needed and only presence of our own tab value is recorded.
if CommandLine.arguments.dropFirst().first != "--normalize" {
    let diagnostics = (ProcessInfo.processInfo.environment["REFIK_DATA_DIR"] ?? ProcessInfo.processInfo.environment["MASCOTMET_DATA_DIR"]).map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik")
    TerminalNavigationDiagnostic.record(.init(.helperInvoked, tabPresent: ProcessInfo.processInfo.environment["ITERM_SESSION_ID"] != nil), directory: diagnostics)
}

// Observer hooks never write to stdout/stderr and never decide permissions.
func boundedInput(limit: Int = 65_536) -> Data? {
    var result = Data()
    while result.count <= limit {
        guard let chunk = try? FileHandle.standardInput.read(upToCount: min(4096, limit + 1 - result.count)) else { return result }
        if chunk.isEmpty { return result }
        result.append(chunk)
    }
    return nil
}
guard let input = boundedInput(),
      let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
let args = CommandLine.arguments
let normalizationTest = args.count > 1 && args[1] == "--normalize"
let configuredProvider = args.count > (normalizationTest ? 2 : 1) ? args[normalizationTest ? 2 : 1] : "codex"
// Imported Claude commands can run inside Cursor. Preserve genuine Claude
// ancestry (including Claude launched in Cursor's terminal), otherwise require
// the exact signed Cursor application before assigning its provider identity.
let cursorCompatibility = configuredProvider == "claude" && CursorHookHost.isCompatibilityPayload(object)
let authenticClaude = cursorCompatibility && !normalizationTest && HookRuntimeContract.emitter(provider: "claude") != nil
let cursorEmitter = cursorCompatibility && !normalizationTest && !authenticClaude ? CursorHookHost.currentEmitter() : nil
guard let provider = CursorHookHost.provider(configured: configuredProvider,
    compatibilityPayload: cursorCompatibility,
    authenticClaude: authenticClaude, emitter: cursorEmitter) else { exit(0) }
let name = object["hook_event_name"] as? String ?? object["event_name"] as? String ?? object["agent_action_name"] as? String ?? (args.count > (normalizationTest ? 3 : 2) ? args[normalizationTest ? 3 : 2] : "")
let session = (object["session_id"] as? String ?? object["sessionId"] as? String ?? object["conversationId"] as? String ?? object["conversation_id"] as? String ?? object["trajectory_id"] as? String ?? "").prefix(160)
guard !session.isEmpty else { exit(0) }
// prompt_id is Claude's documented prompt scope; turn_id remains legacy support.
let turnFields = provider == "claude" ? ["prompt_id", "turn_id"] : provider == "cursor" ? ["generation_id"] : provider == "windsurf" ? ["execution_id"] : ["turn_id"]
let suppliedTurn = turnFields.compactMap { object[$0] as? String }.first { !$0.isEmpty && $0.count <= 160 }
func strictBoolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}
func validQuestionInput(_ value: Any?) -> Bool {
    guard let input = value as? [String: Any], let questions = input["questions"] as? [[String: Any]],
          (1...4).contains(questions.count), Set(questions.compactMap { $0["question"] as? String }).count == questions.count else { return false }
    return questions.allSatisfy { question in
        guard let text = question["question"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let header = question["header"] as? String, header.count <= 12,
              let options = question["options"] as? [[String: Any]], (2...4).contains(options.count),
              (question["multiSelect"] == nil || strictBoolean(question["multiSelect"]) != nil) else { return false }
        return options.allSatisfy { ($0["label"] as? String)?.isEmpty == false && ($0["description"] as? String) != nil }
    }
}
let questionTool = provider == "claude" && object["tool_name"] as? String == "AskUserQuestion"
let questionToolID = (object["tool_use_id"] as? String).flatMap { !$0.isEmpty && $0.count <= 100 ? $0 : nil }

let missingTurnIdentity = suppliedTurn?.isEmpty != false
let turn = (missingTurnIdentity ? String(session) : suppliedTurn!).prefix(160)
if provider == "codex", ["SubagentStart", "SubagentStop"].contains(name) {
    if !normalizationTest {
        let diagnostics = (ProcessInfo.processInfo.environment["REFIK_DATA_DIR"] ?? ProcessInfo.processInfo.environment["MASCOTMET_DATA_DIR"]).map { URL(fileURLWithPath: $0) } ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik")
        HookOriginDiagnostic.record(.init(stage: .helperInput, sessionID: String(session), turnID: String(turn), event: .init(name: name),
            locatorPresent: object["agent_transcript_path"] != nil, agentIDPresent: object["agent_id"] != nil,
            agentTypePresent: object["agent_type"] != nil, agentID: object["agent_id"] as? String), directory: diagnostics)
    }
    // Identity observations never create parent/child completion or attention.
    exit(0)
}
// Receiver pending state is already scoped to canonical turn identity. A hash
// must still correlate missing-turn PermissionRequest with keyed tool payloads.
let correlationTurn = provider == "codex" ? "" : String(turn)
let eventKind: String?
// Only an exact boolean continuation signal suppresses Stop. It is not a
// completion and must not resolve another pending interaction.
if provider == "claude", name == "Stop", strictBoolean(object["stop_hook_active"]) == true { exit(0) }
let claudeInputNotification = provider == "claude" && name == "Notification" &&
    ["elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(object["notification_type"] as? String ?? "")
switch (provider, name) {
case (_, "sessionStart"), (_, "session_start"), (_, "beforeSubmitPrompt"), (_, "pre_user_prompt"), (_, "userPromptSubmitted"), (_, "SessionStart"), (_, "UserPromptSubmit"), (_, "PreInvocation"): eventKind = "started"
case (_, "afterAgentThought"), (_, "afterAgentResponse"), (_, "afterFileEdit"), (_, "preToolUse"), (_, "pre_run_command"), (_, "pre_mcp_tool_use"), (_, "pre_read_code"), (_, "pre_write_code"), ("antigravity", "PreToolUse"), (_, "PostInvocation"): eventKind = "activity"
case ("claude", "PreToolUse"):
    eventKind = questionTool && questionToolID != nil && validQuestionInput(object["tool_input"]) ? "userQuestionObserved" : "activity"
case (_, "PreToolUse"): eventKind = "requestResolved"
case (_, "permissionRequest"), (_, "PermissionRequest"): eventKind = "permissionObserved"
case (_, "afterShellExecution"), (_, "afterMCPExecution"), (_, "postToolUse"), (_, "post_run_command"), (_, "post_mcp_tool_use"), (_, "post_read_code"), (_, "post_write_code"), (_, "PostToolUse"), (_, "PostToolUseFailure"): eventKind = "requestResolved"
case ("claude", "PermissionDenied"):
    // This event is an auto-mode tool denial, not a manually answered dialog.
    // Resolve only the exact matching tool request; never every permission.
    eventKind = object["permission_mode"] as? String == "auto" ? "requestResolved" : "unknownEvent"
case (_, "agentStop"), (_, "stop"), (_, "post_cascade_response"), (_, "Stop"), (_, "PostInvocationComplete"): eventKind = "completed"
case (_, "errorOccurred"), (_, "ErrorOccurred"), (_, "StopFailure"): eventKind = "failed"
case (_, "Interrupt"): eventKind = "interrupted"
case (_, "sessionEnd"), (_, "session_end"), (_, "SessionEnd"): eventKind = "sessionEnded"
case (_, "Notification") where object["notification_type"] as? String == "permission_prompt": eventKind = "permissionObserved"
case ("claude", "Notification") where claudeInputNotification: eventKind = "userQuestionObserved"
case ("claude", "Notification") where ["idle_prompt", "auth_success"].contains(object["notification_type"] as? String ?? ""): exit(0)
default: eventKind = name.isEmpty ? nil : "unknownEvent"
}
guard var kind = eventKind else { exit(0) }
// Session existence is not a submitted turn. A Desktop hook without a turn ID
// cannot manufacture one from the thread ID; recovery resolves its real identity.
if provider == "codex", (object["turn_id"] as? String)?.isEmpty != false,
   name == "SessionStart" || name == "UserPromptSubmit" { kind = "unknownEvent" }
if provider == "claude", name == "SessionStart" { kind = "unknownEvent" }
if provider == "antigravity", name == "Stop" {
    let error = object["error"] as? String
    let reason = object["terminationReason"] as? String
    if reason == "error" || error?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { kind = "failed" }
    else if reason == "max_steps_exceeded" { kind = "interrupted" }
    else if let idle = strictBoolean(object["fullyIdle"]), object["error"] == nil || error != nil {
        if !idle { kind = "activity" }
        else { kind = ["model_stop", "NO_TOOL_CALL"].contains(reason ?? "") ? "completed" : "sessionEnded" }
    } else { kind = "sessionEnded" }
    // Invocation and execution sequence numbers describe different lifecycles;
    // neither is used as a fabricated shared turn identity.
}
if provider == "claude", name == "Stop" {
    let tasks = object["background_tasks"] as? [Any]
    let crons = object["session_crons"] as? [Any]
    if tasks == nil || crons == nil { kind = "sessionEnded" }
    else if !(tasks?.isEmpty ?? true) || !(crons?.isEmpty ?? true) { kind = "activity" }
}
// PermissionRequest has no tool_use_id in the published Codex and Claude schemas.
// Never merge two such prompts or clear one from an unrelated tool event.
let correlation = ["request_id", "tool_use_id"].compactMap { object[$0] as? String }
    .first { !$0.isEmpty && $0.count <= 100 }
let correlatedID = correlation.map { value -> String in
    let agent = object["agent_id"] as? String ?? ""
    let scoped = "\(provider):\(session):\(correlationTurn):\(agent):\(value)"
    return "hook:" + SHA256.hash(data: Data(scoped.utf8)).map { String(format: "%02x", $0) }.joined()
}
let requestMatchKey: String? = {
    guard !questionTool, kind == "permissionObserved" || kind == "requestResolved",
          let tool = object["tool_name"] as? String, !tool.isEmpty,
          let toolInput = object["tool_input"],
          let canonical = try? JSONSerialization.data(withJSONObject: toolInput, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
    let agent = object["agent_id"] as? String ?? ""
    var scoped = Data("\(provider):\(session):\(correlationTurn):\(agent):\(tool):".utf8)
    scoped.append(canonical)
    return "tool:" + SHA256.hash(data: scoped).map { String(format: "%02x", $0) }.joined()
}()
let request: String?
if questionTool, let toolID = questionToolID,
   kind == "userQuestionObserved" || (kind == "requestResolved" && ["PostToolUse", "PostToolUseFailure"].contains(name)) {
    let agent = object["agent_id"] as? String ?? ""
    let scoped = "\(provider):\(session):\(correlationTurn):\(agent):question:\(toolID)"
    request = "question:" + SHA256.hash(data: Data(scoped.utf8)).map { String(format: "%02x", $0) }.joined()
} else if kind == "userQuestionObserved", claudeInputNotification {
    request = "fallback:\(UUID().uuidString)"
} else if kind == "permissionObserved" {
    if correlatedID == nil && name == "Notification" { request = "fallback:\(UUID().uuidString)" }
    else { request = correlatedID ?? "unmatched:\(UUID().uuidString)" }
} else if kind == "requestResolved" {
    request = correlatedID
} else { request = nil }
let cwd = object["cwd"] as? String ?? (object["tool_info"] as? [String: Any])?["cwd"] as? String ?? (object["workspacePaths"] as? [String] ?? object["workspace_roots"] as? [String])?.first ?? ""
let title = String(URL(fileURLWithPath: cwd).lastPathComponent.prefix(100))
let stamp = ISO8601DateFormatter().string(from: Date())
let id = questionTool && request != nil && ["userQuestionObserved", "requestResolved"].contains(kind) ? "\(kind):\(request!)" : UUID().uuidString
var payload: [String: Any] = ["sessionID": provider == "codex" ? String(session) : "\(provider):\(session)", "turnID": String(turn), "requestID": request ?? (NSNull() as Any),
    "kind": kind, "source": "unknown", "title": title, "at": stamp, "id": id,
    "provider": provider, "fidelity": "official"]
let exactCwd: String? = {
    if let cwd = object["cwd"] as? String { return cwd }
    let roots = [object["workspacePaths"], object["workspace_roots"]].compactMap { $0 as? [String] }
    guard !roots.isEmpty, roots.allSatisfy({ $0.count == 1 }),
          Set(roots.compactMap(\.first)).count == 1 else { return nil }
    return roots.first?.first
}()
if let exactCwd, !exactCwd.isEmpty && exactCwd.count <= 4096 { payload["projectPath"] = exactCwd }
if provider == "codex", let locator = object["transcript_path"] as? String,
   !locator.isEmpty, locator.count <= 4096, !locator.contains("\0") { payload["transcriptPath"] = locator }
if (provider == "codex" || provider == "claude"), missingTurnIdentity { payload["missingTurnIdentity"] = true }
if kind == "failed" { payload["detail"] = "Sağlayıcı hata bildirdi" }
if kind == "permissionObserved" && correlation == nil {
    payload["detail"] = "İzin istemi görüldü; sağlayıcı çözülme kimliği vermiyor"
}
if kind == "permissionObserved" || kind == "userQuestionObserved" { payload["ttl"] = 600 }
if kind == "userQuestionObserved" {
    payload["detail"] = claudeInputNotification ? "Sağlayıcı kullanıcı girdisi bekliyor; soru ayrıntıları verilmedi" : "Yapılandırılmış kullanıcı sorusu yanıt bekliyor"
}
if let requestMatchKey { payload["requestMatchKey"] = requestMatchKey }
if kind == "unknownEvent" { payload["detail"] = "Bilinmeyen olay: " + String(name.prefix(60)) }
let instance = UUID().uuidString
let verifiedVersion = args.first { $0.hasPrefix("--runtime-version=") }.map { String($0.dropFirst("--runtime-version=".count)) }.flatMap { $0.count <= 80 && !$0.isEmpty ? $0 : nil }
let emitter = args.contains("--interactive") && HookRuntimeContract.supports(provider: provider, version: verifiedVersion) ? HookRuntimeContract.emitter(provider: provider) : nil
let copilotDesktop = provider == "copilot" && !normalizationTest ? CopilotDesktopHost.currentEmitter() : nil
let vscodeEmitter = provider == "copilot" && !normalizationTest && VSCodeHookPhase(rawValue: name) != nil ? VSCodeHookHost.currentEmitter() : nil
let interactive = emitter != nil && args.contains("--interactive") && !normalizationTest && ((provider == "claude" && name == "PreToolUse" && kind == "userQuestionObserved") || (["claude", "codex"].contains(provider) && name == "PermissionRequest" && object["tool_name"] as? String != nil))
let explicitHost: String? = nil // Configuration does not prove the emitting host.
let host = provider == "cursor" ? "cursor" : provider == "windsurf" ? "windsurf" : provider == "copilot" ? (copilotDesktop != nil ? "githubCopilotDesktop" : vscodeEmitter != nil ? "vscode" : "unknown") : (explicitHost ?? "unknown")
let runtimeID = "hook:" + provider + ":" + (emitter?.executable.path ?? copilotDesktop?.executable.path ?? vscodeEmitter?.executable.path ?? host)
let runtimeVersion = cursorEmitter?.version ?? object["cursor_version"] as? String ?? emitter?.version ?? copilotDesktop?.version ?? vscodeEmitter?.version
let antigravityObservation = provider == "antigravity" ? AntigravityHookObservation.parse(object, phase: name) : nil
let vscodeObservation = provider == "copilot" && (vscodeEmitter != nil || normalizationTest) ? VSCodeHookObservation.parse(object, phase: name) : nil

var runtime: [String: Any] = ["id": runtimeID, "host": host]
if let runtimeVersion { runtime["version"] = runtimeVersion }
payload["runtime"] = runtime
// Only our own inherited value is forwarded, never a provider body field.
// The receiver still requires installed-helper and terminal ancestry proof.
if !normalizationTest, let tab = ProcessInfo.processInfo.environment["ITERM_SESSION_ID"], tab.utf8.count <= 100 {
    payload["navigationTabToken"] = tab
}
let deliveryTurn = suppliedTurn ?? "hook:" + instance
var wireIdentity: HookIdentity? = nil
if !normalizationTest && (interactive || kind == "userQuestionObserved" && questionTool) {
    let deliveryRequest = request ?? "invocation:" + instance
    payload["turnID"] = deliveryTurn; payload["requestID"] = deliveryRequest
    payload.removeValue(forKey: "missingTurnIdentity")
    if suppliedTurn == nil { payload["requestTurnScope"] = "hookInvocation" }
    let identity: [String: Any] = ["provider": provider, "runtimeID": runtimeID, "sessionID": payload["sessionID"]!, "turnID": deliveryTurn, "requestID": deliveryRequest, "generation": instance]
    let capability = kind == "userQuestionObserved" ? "answerQuestions" : "respondToPermissions"
    if interactive { payload["capabilities"] = ["provider": provider, "runtimeID": runtimeID, "version": runtimeVersion!,
        "evidence": [["capability": capability, "support": "live", "source": "authenticated-hook-invocation"]]] }
    var snapshot: [String: Any] = ["identity": identity, "kind": kind == "userQuestionObserved" ? "question" : "permission", "lifecycle": "pending", "observedAt": stamp, "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(HookWire.maxLease))]
    if kind == "userQuestionObserved", let toolInput = object["tool_input"] as? [String: Any], let questions = toolInput["questions"] as? [[String: Any]] {
        snapshot["question"] = ["questions": questions.enumerated().map { index, question -> [String: Any] in
            let options = question["options"] as? [[String: Any]] ?? []
            return ["id": "q" + String(index), "prompt": question["question"]!, "header": question["header"]!,
                "allowsFreeform": true, "allowsMultipleSelection": strictBoolean(question["multiSelect"]) ?? false,
                "options": options.enumerated().map { i, option in ["id": "o" + String(i), "label": option["label"]!, "description": option["description"]!] }]
        }]
    } else {
        let toolName = object["tool_name"] as? String ?? "Tool"
        let command = (object["tool_input"] as? [String: Any])?["command"] as? String
        let action = String((toolName + (command.map { ": " + $0 } ?? "")).prefix(2000))
        snapshot["permission"] = ["requestedAction": action, "scope": "Bu araç çağrısı",
            "explanation": (object["tool_input"] as? [String: Any])?["description"] as? String ?? "Sağlayıcı izin istiyor"]
    }
    if suppliedTurn == nil { snapshot["turnScope"] = "hookInvocation" }
    payload["requestSnapshot"] = snapshot
    if interactive { wireIdentity = HookIdentity(provider: provider, runtimeID: runtimeID, sessionID: payload["sessionID"] as! String, providerTurnID: suppliedTurn, requestID: deliveryRequest, hookInstance: instance, requestToken: UUID().uuidString + UUID().uuidString) }
}
if normalizationTest, let observation = antigravityObservation,
   let encoded = try? JSONEncoder().encode(observation), let value = try? JSONSerialization.jsonObject(with: encoded) {
    payload["antigravityObservation"] = value
}
if normalizationTest, let observation = vscodeObservation,
   let encoded = try? JSONEncoder().encode(observation), let value = try? JSONSerialization.jsonObject(with: encoded) {
    payload["vscodeObservation"] = value
}
guard let data = try? JSONSerialization.data(withJSONObject: payload), data.count < HookWire.limit / 2 else { exit(0) }
if normalizationTest { FileHandle.standardOutput.write(data); exit(0) }
let directory = (ProcessInfo.processInfo.environment["REFIK_DATA_DIR"] ?? ProcessInfo.processInfo.environment["MASCOTMET_DATA_DIR"]).map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik")
let path = directory.appendingPathComponent("events.sock").path
guard HookWire.secureFile(URL(fileURLWithPath: path), socket: true) else { exit(0) }
let sock = socket(AF_UNIX, SOCK_STREAM, 0)
guard sock >= 0 else { exit(0) }
var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
_ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
let bytes = Array(path.utf8)
guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(sock); exit(0) }
withUnsafeMutablePointer(to: &address.sun_path) { ptr in
    ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
        for (index, byte) in bytes.enumerated() { chars[index] = CChar(bitPattern: byte) }
        chars[bytes.count] = 0
    }
}
let connected = withUnsafePointer(to: &address) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
var sent = false
if connected == 0, let identity = wireIdentity {
    guard let secret = HookWire.secret(directory.appendingPathComponent("signal.token")) else { close(sock); exit(0) }
    HookWire.timeout(sock, seconds: 1)
    guard HookWire.send(HookFrame(type: "request", token: secret, identity: identity, payload: data, lease: HookWire.maxLease), fd: sock),
          let ready = HookWire.frame(sock, deadline: HookWire.uptime + 1), ready.type == "ready", ready.identity == identity, let epoch = ready.epoch,
          let lease = ready.lease, lease > 0, lease <= HookWire.maxLease else { close(sock); exit(0) }
    HookWire.timeout(sock, seconds: lease)
    guard let decision = HookWire.frame(sock, deadline: HookWire.uptime + lease), decision.type == "decision", decision.identity == identity,
          decision.epoch == epoch, let actionID = decision.actionID, UUID(uuidString: actionID) != nil,
          let responseData = decision.payload, let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
          let responseIdentity = response["identity"] as? [String: Any],
          NSDictionary(dictionary: responseIdentity).isEqual(to: (payload["requestSnapshot"] as! [String: Any])["identity"] as! [String: Any]) else { close(sock); exit(0) }
    var specific: [String: Any] = ["hookEventName": name]
    if name == "PermissionRequest" {
        guard response["answers"] == nil, let behavior = response["permissionDecision"] as? String, ["allow", "deny"].contains(behavior) else { close(sock); exit(0) }
        specific["decision"] = ["behavior": behavior]
    } else {
        guard response["permissionDecision"] == nil, let answers = response["answers"] as? [[String: Any]],
              var updated = object["tool_input"] as? [String: Any], let questions = updated["questions"] as? [[String: Any]],
              answers.count == questions.count, Set(questions.compactMap { $0["question"] as? String }).count == questions.count else { close(sock); exit(0) }
        var nativeAnswers: [String: String] = [:]
        for (index, question) in questions.enumerated() {
            guard let answer = answers.first(where: { $0["questionID"] as? String == "q" + String(index) }), let optionIDs = answer["optionIDs"] as? [String],
                  Set(optionIDs).count == optionIDs.count, (strictBoolean(question["multiSelect"]) == true || optionIDs.count <= 1),
                  let options = question["options"] as? [[String: Any]] else { close(sock); exit(0) }
            var labels: [String] = []
            for optionID in optionIDs {
                guard optionID.hasPrefix("o"), let i = Int(optionID.dropFirst()), options.indices.contains(i), optionID == "o" + String(i), let label = options[i]["label"] as? String else { close(sock); exit(0) }
                labels.append(label)
            }
            if let text = answer["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { labels.append(text) }
            guard !labels.isEmpty else { close(sock); exit(0) }
            nativeAnswers[question["question"] as! String] = labels.joined(separator: ", ")
        }
        updated["answers"] = nativeAnswers; specific["updatedInput"] = updated; specific["permissionDecision"] = "allow"
    }
    guard let output = try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": specific]), output.count < HookWire.limit else { close(sock); exit(0) }
    _ = signal(SIGPIPE, SIG_IGN)
    guard HookWire.writeData(output + Data([10]), fd: STDOUT_FILENO) else { close(sock); exit(0) }
    sent = HookWire.send(HookFrame(type: "consumed", identity: identity, epoch: epoch, actionID: actionID), fd: sock)
} else if connected == 0, let observation = antigravityObservation {
    if let secret = HookWire.secret(directory.appendingPathComponent("signal.token")) {
        sent = HookWire.send(HookFrame(type: "observation", token: secret, payload: data, antigravityObservation: observation), fd: sock)
    }
} else if connected == 0, let observation = vscodeObservation {
    if let secret = HookWire.secret(directory.appendingPathComponent("signal.token")) {
        sent = HookWire.send(HookFrame(type: "observation", token: secret, payload: data, vscodeObservation: observation), fd: sock)
    }
} else if connected == 0 { sent = HookWire.writeData(data + Data([10]), fd: sock) }
// Stay alive only through the receiver's cheap native process capture. The
// receiver performs expensive installed-code verification after this receipt.
if sent, wireIdentity == nil {
    _ = HookWire.frame(sock, deadline: HookWire.uptime + 0.25, now: { HookWire.uptime })
}
// Opt-in, bounded metadata-only delivery diagnostics; never serialize raw payloads.
if FileManager.default.fileExists(atPath: directory.appendingPathComponent("diagnostics-enabled").path) {
    let log = directory.appendingPathComponent("hook-metadata.jsonl")
    let metadata: [String: Any] = ["event": String(name.prefix(60)), "session_id": String(session),
        "turn_id": String(turn), "cwd": String(cwd.prefix(1024)), "timestamp": stamp, "delivered": sent]
    if let row = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
        let fd = Darwin.open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        if fd >= 0 {
            _ = flock(fd, LOCK_EX)
            var info = stat()
            if fstat(fd, &info) == 0 && info.st_size > 256 * 1024 { _ = ftruncate(fd, 0) }
            _ = (row + Data([10])).withUnsafeBytes { write(fd, $0.baseAddress, row.count + 1) }
            _ = flock(fd, LOCK_UN); close(fd)
        }
    }
}
close(sock)
if provider == "codex", !normalizationTest {
    HookOriginDiagnostic.record(.init(stage: .helperInput, sessionID: String(session), turnID: String(turn), event: .init(name: name),
        locatorPresent: object["transcript_path"] != nil, agentIDPresent: object["agent_id"] != nil,
        agentTypePresent: object["agent_type"] != nil, parentIDPresent: object["parent_thread_id"] != nil), directory: directory)
}
