import Foundation
import RefikInteractionWire

// Local observation correlation only: neither turn IDs nor generations claim
// a native provider epoch. Completed keys remain tombstoned until app exit.
struct AntigravityHookReceiver {
    private struct NativeKey: Hashable { let step: Int; let tool: String }
    private struct Conversation {
        var turn = UUID().uuidString
        var terminal = false
        var latest = Date.distantPast
        var pending: [NativeKey: PendingRequestSnapshot] = [:]
        var used: Set<NativeKey> = []
        var seenInTurn: Set<NativeKey> = []
        var ambiguous: Set<NativeKey> = []
        var degraded = false
    }
    private var conversations: [String: Conversation] = [:]
    let maximumKeys: Int
    let maximumConversations: Int
    init(maximumKeys: Int = 512, maximumConversations: Int = 200) {
        self.maximumKeys = maximumKeys; self.maximumConversations = maximumConversations
    }

    mutating func events(_ input: CodexEvent, observation: AntigravityHookObservation) -> [CodexEvent] {
        guard observation.isValid, input.provider == .antigravity, let runtime = input.runtime, !runtime.id.isEmpty,
              input.sessionID == "antigravity:" + observation.conversationID else { return [] }
        let key = runtime.id + "\u{0}" + input.sessionID
        guard conversations[key] != nil || conversations.count < maximumConversations else { return [] }
        let fresh = conversations[key] == nil
        var current = conversations[key] ?? Conversation()
        guard input.at >= current.latest else { return [] }
        current.latest = input.at
        var result: [CodexEvent] = []
        func event(_ kind: EventKind, request: PendingRequestSnapshot? = nil, update: RequestLifecycleUpdate? = nil) -> CodexEvent {
            CodexEvent(sessionID: input.sessionID, turnID: current.turn, requestID: request?.id ?? update?.identity.requestID,
                kind: kind, source: input.source, title: input.title, at: input.at, id: UUID().uuidString,
                detail: input.detail, provider: .antigravity, fidelity: .official, projectPath: input.projectPath, verifiedEditorHost: input.verifiedEditorHost, verifiedTerminalHost: input.verifiedTerminalHost,
                terminalNavigation: input.terminalNavigation, terminalNavigationIssuedAt: input.terminalNavigationIssuedAt,
                runtime: runtime, capabilities: RuntimeCapabilities(provider: .antigravity, runtimeID: runtime.id,
                    version: runtime.version ?? "unknown", evidence: [CapabilityEvidence(capability: .observeQuestions,
                        support: .documented, source: "Antigravity ask_question hook observation")]),
                requestSnapshot: request, requestUpdate: update)
        }
        // A reset is meaningful only after an observed terminal boundary.
        if fresh || (current.terminal && observation.phase == .preInvocation && observation.invocationNum == 0) {
            current.turn = UUID().uuidString; current.terminal = false; current.pending.removeAll(); current.seenInTurn.removeAll()
            result.append(event(.started))
        }
        switch observation.phase {
        case .preToolUse:
            if observation.toolName == "ask_question", let step = observation.stepIndex, step >= 0,
               let questions = observation.questions, !questions.isEmpty, !current.terminal {
                let native = NativeKey(step: step, tool: "ask_question")
                if !current.seenInTurn.contains(native) && current.seenInTurn.count <= maximumKeys {
                    current.seenInTurn.insert(native)
                    if current.used.contains(native) { current.ambiguous.insert(native) }
                    if current.used.count >= maximumKeys && !current.used.contains(native) { current.degraded = true }
                    if !current.degraded { current.used.insert(native) }
                    let body = QuestionRequestBody(questions: questions.enumerated().map { index, question in
                        StructuredQuestion(id: "q\(index)", prompt: question.text,
                            options: question.options.enumerated().map { QuestionOption(id: "o\($0.offset)", label: $0.element) },
                            allowsFreeform: false, allowsMultipleSelection: question.multiSelect)
                    })
                    let request = PendingRequestSnapshot(identity: RequestIdentity(provider: .antigravity, runtimeID: runtime.id,
                        sessionID: input.sessionID, turnID: current.turn, requestID: "ag-question:" + UUID().uuidString,
                        generation: UUID().uuidString), kind: .question, question: body, observedAt: input.at)
                    if request.isValid { current.pending[native] = request; result.append(event(.userQuestionObserved, request: request)) }
                }
            } else if !current.terminal { result.append(event(.activity)) }
        case .postToolUse:
            if observation.toolName == "ask_question", let step = observation.stepIndex {
                let native = NativeKey(step: step, tool: "ask_question")
                if !current.terminal, !current.degraded, !current.ambiguous.contains(native),
                   let request = current.pending.removeValue(forKey: native) {
                    result.append(event(.requestResolved, update: RequestLifecycleUpdate(identity: request.identity, lifecycle: .resolved)))
                }
            }
            // Unmatched posts are suppressed, including any legacy resolution.
        case .stop:
            if observation.fullyIdle == true {
                current.terminal = true; current.pending.removeAll(); current.seenInTurn.removeAll()
                let terminal: EventKind = observation.hasError ? .failed :
                    ([EventKind.completed, .failed, .interrupted, .sessionEnded].contains(input.kind) ? input.kind : .sessionEnded)
                result.append(event(terminal))
            }
        case .preInvocation:
            if !current.terminal && result.isEmpty { result.append(event(.activity)) }
        case .postInvocation:
            break
        }
        conversations[key] = current
        return result
    }
}
