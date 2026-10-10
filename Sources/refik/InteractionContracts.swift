import Foundation

// Host is presentation/routing metadata; provider and stable IDs own identity.
enum RuntimeHost: String, Codable, CaseIterable {
    case codexDesktop, githubCopilotDesktop, terminal, vscode, cursor, windsurf, antigravity, unknown
    var label: String {
        switch self {
        case .codexDesktop: return "Codex Desktop"
        case .githubCopilotDesktop: return "GitHub Copilot Desktop"
        case .terminal: return "Terminal"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .antigravity: return "Antigravity"
        case .unknown: return "Bilinmeyen host"
        }
    }
}

struct RuntimeMetadata: Codable, Equatable {
    let id: String
    var host: RuntimeHost
    var version: String?
    var chatName: String?
    // Only adapters with authoritative same-job evidence may populate this.
    var canonicalSessionID: String? = nil
    var sourceContextID: String? = nil
}

enum RuntimeCapability: String, Codable { case observeQuestions, observePermissions, answerQuestions, respondToPermissions, openSession }
enum CapabilitySupport: String, Codable { case documented, live, unsupported }
struct CapabilityEvidence: Codable, Equatable {
    let capability: RuntimeCapability
    let support: CapabilitySupport
    let source: String
}
struct RuntimeCapabilities: Codable, Equatable {
    let provider: Provider
    let runtimeID: String
    let version: String
    let evidence: [CapabilityEvidence]
    // Opaque channel ID only. Never persist credentials or an authentication URL.
    var responseChannelID: String? = nil
    func hasLive(_ capability: RuntimeCapability, runtime: RuntimeMetadata?) -> Bool {
        guard let runtime, runtime.id == runtimeID, runtime.version == version,
              responseChannelID?.isEmpty == false else { return false }
        return evidence.contains { $0.capability == capability && $0.support == .live }
    }
}

struct RequestIdentity: Codable, Equatable, Hashable {
    let provider: Provider
    let runtimeID: String
    let sessionID: String
    let turnID: String
    let requestID: String
    let generation: String
}
enum RequestTurnScope: String, Codable { case providerTurn, request, hookInvocation }
enum InteractionRequestKind: String, Codable { case question, permission }
enum RequestLifecycle: String, Codable { case pending, submitting, submitted, deliveryUnknown, accepted, resolved, canceled, expired }
struct QuestionOption: Codable, Equatable, Identifiable {
    let id: String
    let label: String
    var description: String? = nil
}
struct StructuredQuestion: Codable, Equatable, Identifiable {
    let id: String
    let prompt: String
    var header: String? = nil
    var options: [QuestionOption] = []
    var allowsFreeform: Bool = true
    var allowsMultipleSelection: Bool = false
}
struct QuestionRequestBody: Codable, Equatable { let questions: [StructuredQuestion] }
struct PermissionRequestBody: Codable, Equatable {
    let requestedAction: String
    let scope: String
    var explanation: String? = nil
}
enum RequestExpiryScope: String, Codable { case interaction, responseChannelLease }

struct PendingRequestSnapshot: Codable, Equatable, Identifiable {
    var id: String { identity.requestID }
    let identity: RequestIdentity
    let kind: InteractionRequestKind
    var question: QuestionRequestBody? = nil
    var permission: PermissionRequestBody? = nil
    var turnScope: RequestTurnScope? = nil
    var lifecycle: RequestLifecycle = .pending
    let observedAt: Date
    var expiresAt: Date? = nil
    var expiryScope: RequestExpiryScope? = nil
    var isValid: Bool {
        guard !identity.runtimeID.isEmpty, !identity.generation.isEmpty, !identity.requestID.isEmpty else { return false }
        switch kind {
        case .question:
            guard permission == nil, let questions = question?.questions, !questions.isEmpty,
                  questions.count <= 20, Set(questions.map(\.id)).count == questions.count else { return false }
            return questions.allSatisfy { !$0.id.isEmpty && !$0.prompt.isEmpty && $0.prompt.count <= 10_000 &&
                $0.options.count <= 50 && Set($0.options.map(\.id)).count == $0.options.count &&
                $0.options.allSatisfy { !$0.id.isEmpty && !$0.label.isEmpty && $0.label.count <= 2_000 } }
        case .permission:
            return question == nil && permission?.requestedAction.isEmpty == false && permission?.scope.isEmpty == false
        }
    }
}
struct RequestLifecycleUpdate: Codable, Equatable {
    let identity: RequestIdentity
    let lifecycle: RequestLifecycle
}
struct QuestionAnswer: Codable, Equatable {
    let questionID: String
    var optionIDs: [String] = []
    var text: String? = nil
}
enum PermissionDecision: String, Codable { case allow, deny }
struct InteractionResponse: Codable, Equatable {
    let identity: RequestIdentity
    var answers: [QuestionAnswer]? = nil
    var permissionDecision: PermissionDecision? = nil
    func isValid(for request: PendingRequestSnapshot) -> Bool {
        guard identity == request.identity, request.isValid, request.lifecycle == .pending else { return false }
        switch request.kind {
        case .permission: return answers == nil && permissionDecision != nil
        case .question:
            guard permissionDecision == nil, let answers, let questions = request.question?.questions,
                  answers.count == questions.count, Set(answers.map(\.questionID)).count == answers.count else { return false }
            return questions.allSatisfy { question in
                guard let answer = answers.first(where: { $0.questionID == question.id }),
                      Set(answer.optionIDs).count == answer.optionIDs.count,
                      answer.optionIDs.allSatisfy({ id in question.options.contains { $0.id == id } }),
                      question.allowsMultipleSelection || answer.optionIDs.count <= 1 else { return false }
                let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return (text.isEmpty || question.allowsFreeform) && (!text.isEmpty || !answer.optionIDs.isEmpty)
            }
        }
    }
}

// Transport implementations belong to adapters. Successful delivery alone is
// not acceptance: only an exact provider acknowledgment resolves the request.
struct ResponseReceipt: Codable, Equatable {
    let identity: RequestIdentity
    let lifecycle: RequestLifecycle
}
protocol InteractionResponseTransport {
    func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt
}

extension Session {
    var orderedRequests: [PendingRequestSnapshot] { requestSnapshots ?? [] }
    func canRespond(to request: PendingRequestSnapshot) -> Bool {
        guard request.identity.provider == provider, request.identity.sessionID == id,
              (request.identity.turnID == turnID || request.turnScope == .request || request.turnScope == .hookInvocation),
              request.identity.runtimeID == runtime?.id,
              pending.contains(request.id), request.isValid, request.lifecycle == .pending,
              requestSnapshots?.contains(where: { $0.identity == request.identity && $0.lifecycle == .pending }) == true,
              capabilities?.provider == provider else { return false }
        return capabilities?.hasLive(request.kind == .question ? .answerQuestions : .respondToPermissions, runtime: runtime) == true
    }
}

extension Session {
    mutating func expireRequests() {
        guard var requests = requestSnapshots else { return }
        for index in requests.indices where [.pending, .submitting, .submitted, .deliveryUnknown].contains(requests[index].lifecycle) {
            requests[index].lifecycle = .expired
        }
        requestSnapshots = requests
    }
}
