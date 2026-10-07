import Foundation
import RefikInteractionWire

// Exact documented tool_use_id correlation; this observer has no response lease.
struct VSCodeHookReceiver {
    private struct Conversation {
        var turn = UUID().uuidString
        var terminal = false
        var latest = Date.distantPast
        var pending: [String: PendingRequestSnapshot] = [:]
        var used: Set<String> = []
        var seenInTurn: Set<String> = []
        var ambiguous: Set<String> = []
        var degraded = false
        var lastPromptEventID: String?
    }
    private var conversations: [String: Conversation] = [:]
    let maximumKeys: Int
    init(maximumKeys: Int = 512) { self.maximumKeys = maximumKeys }

    mutating func events(_ input: CodexEvent, observation: VSCodeHookObservation) -> [CodexEvent] {
        guard observation.isValid, input.provider == .copilot,
              let runtime = input.runtime, runtime.host == .vscode, !runtime.id.isEmpty,
              input.sessionID == "copilot:" + observation.sessionID else { return [] }
        let key = runtime.id + "\u{0}" + input.sessionID
        guard conversations[key] != nil || conversations.count < 200 else { return [] }
        let fresh = conversations[key] == nil
        var current = conversations[key] ?? Conversation()
        guard input.at >= current.latest else { return [] }
        current.latest = input.at
        var result: [CodexEvent] = []
        func event(_ kind: EventKind, request: PendingRequestSnapshot? = nil, update: RequestLifecycleUpdate? = nil) -> CodexEvent {
            CodexEvent(sessionID: input.sessionID, turnID: current.turn, requestID: request?.id ?? update?.identity.requestID,
                kind: kind, source: input.source, title: input.title, at: input.at, id: UUID().uuidString,
                detail: input.detail, provider: .copilot, fidelity: .official, projectPath: input.projectPath, verifiedEditorHost: input.verifiedEditorHost,
                runtime: runtime, capabilities: RuntimeCapabilities(provider: .copilot, runtimeID: runtime.id,
                    version: runtime.version ?? "unknown", evidence: [CapabilityEvidence(capability: .observeQuestions,
                        support: .documented, source: "https://code.visualstudio.com/docs/agents/reference/hooks-reference#pretooluse")]),
                requestSnapshot: request, requestUpdate: update)
        }
        if fresh || (observation.phase == .userPromptSubmit && current.lastPromptEventID != input.id) {
            current.turn = UUID().uuidString; current.terminal = false; current.pending.removeAll(); current.seenInTurn.removeAll()
            if observation.phase == .userPromptSubmit { current.lastPromptEventID = input.id }
            result.append(event(.started))
        }
        switch observation.phase {
        case .preToolUse:
            guard !current.terminal else { break }
            if observation.toolName == "vscode_askQuestions", let native = observation.nativeToolID,
               let questions = observation.questions, current.pending[native] == nil,
               !current.seenInTurn.contains(native), current.seenInTurn.count <= maximumKeys {
                current.seenInTurn.insert(native)
                if current.used.contains(native) { current.ambiguous.insert(native) }
                if current.used.count >= maximumKeys && !current.used.contains(native) { current.degraded = true }
                if !current.degraded { current.used.insert(native) }
                let body = QuestionRequestBody(questions: questions.enumerated().map { index, question in
                    StructuredQuestion(id: "q\(index)", prompt: question.text, header: question.header,
                        options: question.options.enumerated().map { optionIndex, option in
                            QuestionOption(id: "o\(optionIndex)", label: option.label, description: option.description)
                        }, allowsFreeform: false, allowsMultipleSelection: question.multiSelect)
                })
                let request = PendingRequestSnapshot(identity: RequestIdentity(provider: .copilot, runtimeID: runtime.id,
                    sessionID: input.sessionID, turnID: current.turn, requestID: "vscode-question:" + native,
                    generation: UUID().uuidString), kind: .question, question: body, observedAt: input.at)
                if request.isValid { current.pending[native] = request; result.append(event(.userQuestionObserved, request: request)) }
            } else if observation.toolName != "vscode_askQuestions" { result.append(event(.activity)) }
        case .postToolUse:
            if !current.terminal, !current.degraded, observation.toolName == "vscode_askQuestions",
               let native = observation.nativeToolID, !current.ambiguous.contains(native),
               let request = current.pending.removeValue(forKey: native) {
                result.append(event(.requestResolved, update: RequestLifecycleUpdate(identity: request.identity, lifecycle: .resolved)))
            }
        case .userPromptSubmit:
            break
        case .stop, .sessionEnd:
            current.terminal = true; current.pending.removeAll(); current.seenInTurn.removeAll()
            result.append(event([EventKind.completed, .failed, .interrupted, .sessionEnded].contains(input.kind) ? input.kind : .sessionEnded))
        case .sessionStart, .preCompact, .subagentStart, .subagentStop:
            if !current.terminal && result.isEmpty { result.append(event(.activity)) }
        }
        conversations[key] = current
        return result
    }
}
