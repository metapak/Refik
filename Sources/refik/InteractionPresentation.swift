import Foundation

/// Answer contents stay in the view's local state until explicit submission.
struct QuestionDraft {
    let identity: RequestIdentity
    private(set) var answers: [QuestionAnswer]
    init(request: PendingRequestSnapshot) {
        identity = request.identity
        answers = (request.question?.questions ?? []).map { QuestionAnswer(questionID: $0.id) }
    }
    mutating func select(_ optionID: String, for question: StructuredQuestion) {
        guard let index = answers.firstIndex(where: { $0.questionID == question.id }),
              question.options.contains(where: { $0.id == optionID }) else { return }
        if question.allowsMultipleSelection {
            if answers[index].optionIDs.contains(optionID) { answers[index].optionIDs.removeAll { $0 == optionID } }
            else { answers[index].optionIDs.append(optionID) }
        } else { answers[index].optionIDs = [optionID] }
    }
    mutating func setText(_ text: String, for question: StructuredQuestion) {
        guard question.allowsFreeform, let index = answers.firstIndex(where: { $0.questionID == question.id }) else { return }
        answers[index].text = text
    }
    func answer(for question: StructuredQuestion) -> QuestionAnswer? { answers.first { $0.questionID == question.id } }
    func response(for request: PendingRequestSnapshot) -> InteractionResponse? {
        let response = InteractionResponse(identity: identity, answers: answers)
        return response.isValid(for: request) ? response : nil
    }
}

enum SessionPresentation {
    static func providerLabel(_ provider: Provider) -> String {
        switch provider {
        case .copilot: return "GitHub Copilot"
        case .windsurf: return "Devin / Windsurf"
        default: return provider.label
        }
    }
    static func runtimeHostLabel(_ host: RuntimeHost) -> String {
        if host == .githubCopilotDesktop { return "GitHub Copilot" }
        if host == .windsurf,
           let url = SessionRouting.preferredApplicationURL(bundleID: "com.exafunction.windsurf"),
           let bundle = Bundle(url: url),
           let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")) as? String,
           !name.isEmpty { return name }
        return host == .unknown ? "Uygulama bilinmiyor" : host.label
    }
    static func providerIcon(_ provider: Provider) -> String {
        switch provider {
        case .codex: return "sparkle"
        case .claude: return "sun.max"
        case .antigravity: return "a.circle"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .copilot: return "person.crop.circle.badge.checkmark"
        case .windsurf: return "wind"
        case .watch: return "terminal"
        case .signal: return "antenna.radiowaves.left.and.right"
        }
    }
    static func hostLabel(_ session: Session, terminalOperations: TerminalNavigationOrigin.Operations = AntigravityTerminalOrigin.live) -> String {
        if let editor = session.verifiedEditorHost {
            switch editor {
            case "com.microsoft.VSCode": return "VS Code"
            case "com.todesktop.230313mzl4w4u92": return "Cursor"
            case "com.google.antigravity-ide": return "Antigravity"
            case "com.exafunction.windsurf": return runtimeHostLabel(.windsurf)
            default: return "Uygulama"
            }
        }
        if let target = session.terminalNavigation,
           ![.vscode, .codexDesktop, .cursor, .windsurf, .antigravity].contains(session.runtime?.host ?? .unknown),
           TerminalNavigationOrigin.application(target, operations: terminalOperations) != nil {
            return target.bundleID == "com.googlecode.iterm2" ? "iTerm2" : "Terminal"
        }
        if let host = session.runtime?.host, host != .unknown { return runtimeHostLabel(host) }
        if session.source == .desktop { return "Desktop" }
        if session.source == .cli || [.watch, .signal].contains(session.provider) { return "Terminal" }
        return "Uygulama"
    }
    static func statusLabel(_ session: Session) -> String {
        if session.orderedRequests.contains(where: { $0.lifecycle == .submitting && session.pending.contains($0.id) }) { return "Gönderiliyor" }
        if session.state == .completed, ![.watch, .signal].contains(session.provider) { return "Yanıt hazır" }
        if session.state == .interrupted { return "Durduruldu" }
        return session.state.label
    }
    static func statusIcon(_ state: WorkState) -> String {
        switch state {
        case .waitingPermission: return "lock.circle"
        case .waitingUser: return "questionmark.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .interrupted: return "stop.circle"
        case .running: return "circle.dotted"
        default: return "minus.circle"
        }
    }
}


enum IntegrationPresentation {
    static func capabilityLabel(_ capability: RuntimeCapability) -> String {
        switch capability {
        case .observeQuestions: return "Soruları gösterme"
        case .observePermissions: return "İzinleri gösterme"
        case .answerQuestions: return "Yanıt gönderme"
        case .respondToPermissions: return "İzin verme / reddetme"
        case .openSession: return "Oturum seçme"
        }
    }
    static func supportLabel(_ capability: RuntimeCapability, evidence: [CapabilityEvidence]) -> String {
        let values = evidence.filter { $0.capability == capability }
        if values.contains(where: { $0.support == .live }) { return "Canlı doğrulandı" }
        if values.contains(where: { $0.support == .documented }) { return "Belgelenmiş · Canlı doğrulanmadı" }
        if values.contains(where: { $0.support == .unsupported }) { return "Desteklenmiyor" }
        return "Doğrulanmadı"
    }
}
