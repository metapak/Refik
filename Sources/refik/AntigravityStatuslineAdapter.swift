import Foundation

// A sanitized statusline sample, not a transcript or an executable API request.
struct AntigravityQuotaStatus: Codable, Equatable {
    var remainingFraction: Double?
    var resetTime: String?
    var resetInSeconds: Double?
}
struct AntigravityStatuslinePayload: Codable, Equatable {
    let conversationID: String
    let projectDirectory: String
    var version: String?
    let agentState: String
    let taskCount: Int
    var toolConfirmationPending: Bool?
    var quota: [String: AntigravityQuotaStatus] = [:]

    static func decodeOfficial(_ data: Data) -> AntigravityStatuslinePayload? {
        guard data.count <= 262_144, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["product"] as? String == "antigravity",
              let conversation = (root["conversation_id"] as? String) ?? (root["session_id"] as? String),
              let workspace = root["workspace"] as? [String: Any], let directory = workspace["project_dir"] as? String,
              let state = root["agent_state"] as? String,
              let number = root["task_count"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (0...1_000_000).contains(number.doubleValue) else { return nil }
        var permission: Bool?
        if let value = root["tool_confirmation_pending"] {
            guard let bool = value as? NSNumber, CFGetTypeID(bool) == CFBooleanGetTypeID() else { return nil }
            permission = bool.boolValue
        }
        var quotas: [String: AntigravityQuotaStatus] = [:]
        for (key, value) in (root["quota"] as? [String: Any]) ?? [:] {
            guard key.count <= 100, let bucket = value as? [String: Any] else { continue }
            func numeric(_ key: String) -> Double? {
                guard let value = bucket[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
                return value.doubleValue
            }
            quotas[key] = AntigravityQuotaStatus(remainingFraction: numeric("remaining_fraction"),
                resetTime: bucket["reset_time"] as? String, resetInSeconds: numeric("reset_in_seconds"))
        }
        let payload = AntigravityStatuslinePayload(conversationID: conversation, projectDirectory: directory,
            version: root["version"] as? String, agentState: state, taskCount: number.intValue,
            toolConfirmationPending: permission, quota: quotas)
        return payload.isValid ? payload : nil
    }
    var isValid: Bool {
        !conversationID.isEmpty && conversationID.count <= 160 && projectDirectory.hasPrefix("/") &&
        projectDirectory.count <= 4_096 && ["idle", "thinking", "working", "tool_use", "initializing"].contains(agentState) &&
        (0...1_000_000).contains(taskCount) && (version?.count ?? 0) <= 100 && quota.count <= 100
    }
}

struct AntigravityStatuslineAdapter {
    private struct Conversation {
        let runtimeID: String
        var permission: PendingRequestSnapshot?
        var state: WorkState?
    }
    private var conversations: [String: Conversation] = [:]
    // The official statusline exposes a dialog flag, not its native request ID
    // or tool arguments. This local interval identity never authorizes a reply.
    mutating func events(payload: AntigravityStatuslinePayload, at: Date) -> [CodexEvent] {
        guard payload.isValid else { return [] }
        if conversations[payload.conversationID] == nil, conversations.count >= 200 { return [] }
        var current = conversations[payload.conversationID] ?? Conversation(runtimeID: "agy-statusline:" + UUID().uuidString)
        let runtime = RuntimeMetadata(id: current.runtimeID, host: .terminal, version: payload.version)
        let caps = RuntimeCapabilities(provider: .antigravity, runtimeID: current.runtimeID, version: payload.version ?? "unknown",
            evidence: [CapabilityEvidence(capability: .observePermissions, support: .documented,
                source: "https://antigravity.google/docs/cli/statusline"),
                CapabilityEvidence(capability: .respondToPermissions, support: .unsupported,
                source: "Statusline exposes no native response channel"),
                CapabilityEvidence(capability: .answerQuestions, support: .unsupported,
                source: "Statusline exposes no structured question response channel")])
        let title = ProjectLabel.resolve(explicit: nil, cwd: payload.projectDirectory, title: nil)
        func event(_ kind: EventKind, request: PendingRequestSnapshot? = nil,
                   update: RequestLifecycleUpdate? = nil, state: WorkState? = nil, detail: String? = nil) -> CodexEvent {
            CodexEvent(sessionID: payload.conversationID, turnID: request?.identity.turnID ?? update?.identity.turnID ?? "statusline:" + current.runtimeID,
                requestID: request?.id ?? update?.identity.requestID, kind: kind, source: .cli, title: title,
                at: at, id: UUID().uuidString, detail: detail, provider: .antigravity, fidelity: .official,
                projectPath: payload.projectDirectory, runtime: runtime, capabilities: caps,
                requestSnapshot: request, requestUpdate: update,
                requestTurnScope: request != nil || update != nil ? .request : nil, runtimeState: state)
        }
        var result: [CodexEvent] = []
        let state: WorkState = payload.agentState == "idle" && payload.taskCount == 0 ? .idle : .running
        if current.state != state {
            result.append(event(state == .running ? .activity : .unknownEvent, state: state,
                detail: state == .idle ? "Antigravity CLI boşta; iş sonucu doğrulanmadı" : "Antigravity CLI çalışıyor"))
            current.state = state
        }
        if payload.toolConfirmationPending == true, current.permission == nil {
            let id = "statusline-permission:" + UUID().uuidString
            let request = PendingRequestSnapshot(identity: RequestIdentity(provider: .antigravity,
                runtimeID: current.runtimeID, sessionID: payload.conversationID, turnID: "request:" + id,
                requestID: id, generation: UUID().uuidString), kind: .permission,
                permission: PermissionRequestBody(requestedAction: "Antigravity bir işlem için izin bekliyor",
                    scope: payload.projectDirectory,
                    explanation: "Statusline yalnızca onay penceresinin açık olduğunu bildirir; işlem ayrıntıları ve yerel istek kimliği verilmez. Antigravity CLI içinde devam edin."),
                turnScope: .request, observedAt: at)
            current.permission = request
            result.append(event(.permissionObserved, request: request))
        } else if payload.toolConfirmationPending == false, let request = current.permission {
            result.append(event(.requestResolved, update: RequestLifecycleUpdate(identity: request.identity, lifecycle: .resolved)))
            current.permission = nil
            // Clearing a confirmation flag proves the dialog is gone, not the
            // decision, execution outcome, or successful task completion.
            result.append(event(state == .running ? .activity : .unknownEvent, state: state))
        }
        conversations[payload.conversationID] = current
        for key in payload.quota.keys.sorted() {
            guard let bucket = payload.quota[key], !key.isEmpty, key.count <= 100,
                  let fraction = bucket.remainingFraction, fraction.isFinite, (0...1).contains(fraction) else { continue }
            let reset: Date?
            if let raw = bucket.resetTime {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                reset = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
            } else if let seconds = bucket.resetInSeconds, seconds.isFinite, seconds > 0, seconds <= 31_536_000 {
                reset = at.addingTimeInterval(seconds)
            } else { reset = nil }
            guard let reset, reset > at else { continue }
            result.append(CodexEvent(sessionID: "usage:antigravity:" + key, turnID: "usage", requestID: nil,
                kind: .usage, source: .cli, title: key, at: at, id: UUID().uuidString, detail: "remaining",
                provider: .antigravity, fidelity: .official, progress: fraction, ttl: min(86_400, reset.timeIntervalSince(at)),
                projectPath: payload.projectDirectory, resetAt: reset, runtime: runtime, capabilities: caps))
        }
        return result
    }
}
