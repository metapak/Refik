import Foundation
import RefikInteractionWire

enum WorkState: String, Codable {
    case running, waitingPermission, waitingUser, completed, failed, interrupted, idle, unknown
    var label: String {
        switch self {
        case .running: return "Çalışıyor"
        case .waitingPermission: return "İzin bekliyor"
        case .waitingUser: return "Yanıt bekliyor"
        case .completed: return "Tamamlandı"
        case .failed: return "Başarısız"
        case .interrupted: return "Kesildi"
        case .idle: return "Boşta"
        case .unknown: return "Durum bilinmiyor"
        }
    }
}

enum MascotState: String { case waiting, completed, running, neutral }
enum Provider: String, Codable { case codex, claude, antigravity, opencode, cursor, copilot, windsurf, watch, signal
    var label: String { switch self { case .codex: "Codex"; case .claude: "Claude"; case .antigravity: "Antigravity"; case .opencode: "OpenCode"; case .cursor: "Cursor"; case .copilot: "Copilot"; case .windsurf: "Windsurf"; case .watch: "Watch"; case .signal: "Signal" } }
}
enum Fidelity: String, Codable { case official, derived, manual }
enum CodexSource: String, Codable { case desktop, cli, unknown
    var label: String { self == .desktop ? "Codex Desktop" : self == .cli ? "Codex CLI" : "Codex" }
}
enum EventKind: String, Codable {
    case started, reconciledRunning, activity, permissionObserved, userQuestionObserved, requestResolved, completed, failed, interrupted, sessionEnded, dropped, usage, unknownEvent
}

struct CodexUnverifiedCompletion: Codable, Equatable {
    let turnID: String, eventID: String
    let eventAt: Date, recordedAt: Date, expiresAt: Date
    let originalState: WorkState
    let refusal: CodexOriginObservation
}

struct CodexOriginObservation: Codable, Equatable {
    let stage: HookOriginDiagnostic.Stage
    let locatorPresent: Bool
}

struct CodexEvent: Codable {
    var sessionID: String
    var turnID: String
    let requestID: String?
    let kind: EventKind
    var source: CodexSource
    let title: String?
    let at: Date
    let id: String
    var detail: String? = nil
    var provider: Provider = .codex
    var fidelity: Fidelity = .official
    var progress: Double? = nil
    var ttl: Double? = nil
    var authToken: String? = nil
    var requestMatchKey: String? = nil
    var missingTurnIdentity: Bool? = nil
    var projectPath: String? = nil
    var verifiedEditorHost: String? = nil
    // Receiver-local provenance, intentionally excluded from wire CodingKeys.
    var verifiedTerminalHost: String? = nil
    var terminalNavigation: TerminalNavigationTarget? = nil
    var terminalNavigationIssuedAt: Double? = nil
    // Untrusted transport value; only the authenticated receiver may attest it.
    var navigationTabToken: String? = nil
    // Receiver-validated rollout origin; never decoded from wire input.
    var verifiedCodexOriginHost: RuntimeHost? = nil
    var codexOriginObservation: CodexOriginObservation? = nil
    var codexNativeTurnProof: CodexNativeTurnProof? = nil
    // Untrusted file locator. Never an origin/host proof by itself.
    var transcriptPath: String? = nil
    var resetAt: Date? = nil
    var runtime: RuntimeMetadata? = nil
    var capabilities: RuntimeCapabilities? = nil
    var requestSnapshot: PendingRequestSnapshot? = nil
    var requestUpdate: RequestLifecycleUpdate? = nil
    var requestTurnScope: RequestTurnScope? = nil
    var runtimeState: WorkState? = nil
    var trustedInteractionSnapshot: Bool? = nil
    var antigravityStatusline: AntigravityStatuslinePayload? = nil
}

extension CodexEvent {
    private enum CodingKeys: String, CodingKey { case sessionID, turnID, requestID, kind, source, title, at, id, detail, provider, fidelity, progress, ttl, authToken, requestMatchKey, missingTurnIdentity, projectPath, verifiedEditorHost, transcriptPath, resetAt, runtime, capabilities, requestSnapshot, requestUpdate, requestTurnScope, runtimeState, trustedInteractionSnapshot, antigravityStatusline, navigationTabToken }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        turnID = try c.decode(String.self, forKey: .turnID)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        kind = try c.decode(EventKind.self, forKey: .kind)
        source = try c.decodeIfPresent(CodexSource.self, forKey: .source) ?? .unknown
        title = try c.decodeIfPresent(String.self, forKey: .title)
        at = try c.decode(Date.self, forKey: .at)
        id = try c.decode(String.self, forKey: .id)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .codex
        fidelity = try c.decodeIfPresent(Fidelity.self, forKey: .fidelity) ?? .official
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        ttl = try c.decodeIfPresent(Double.self, forKey: .ttl)
        authToken = try c.decodeIfPresent(String.self, forKey: .authToken)
        requestMatchKey = try c.decodeIfPresent(String.self, forKey: .requestMatchKey)
        missingTurnIdentity = try c.decodeIfPresent(Bool.self, forKey: .missingTurnIdentity)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        verifiedEditorHost = try c.decodeIfPresent(String.self, forKey: .verifiedEditorHost)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath)
        resetAt = try c.decodeIfPresent(Date.self, forKey: .resetAt)
        runtime = try c.decodeIfPresent(RuntimeMetadata.self, forKey: .runtime)
        capabilities = try c.decodeIfPresent(RuntimeCapabilities.self, forKey: .capabilities)
        requestSnapshot = try c.decodeIfPresent(PendingRequestSnapshot.self, forKey: .requestSnapshot)
        requestUpdate = try c.decodeIfPresent(RequestLifecycleUpdate.self, forKey: .requestUpdate)
        requestTurnScope = try c.decodeIfPresent(RequestTurnScope.self, forKey: .requestTurnScope)
        runtimeState = try c.decodeIfPresent(WorkState.self, forKey: .runtimeState)
        trustedInteractionSnapshot = try c.decodeIfPresent(Bool.self, forKey: .trustedInteractionSnapshot)
        antigravityStatusline = try c.decodeIfPresent(AntigravityStatuslinePayload.self, forKey: .antigravityStatusline)
        navigationTabToken = TerminalNavigationOrigin.validTabToken(try c.decodeIfPresent(String.self, forKey: .navigationTabToken))
    }
}

struct Session: Identifiable, Codable {
    let id: String
    var turnID: String
    var source: CodexSource
    var title: String
    var detail: String = "Tur durumu izleniyor"
    var state: WorkState
    var started: Date
    var updated: Date
    var seen = false
    var pending: Set<String> = []
    var pendingKinds: [String: WorkState] = [:]
    var pendingMatchKeys: [String: String] = [:]
    var lastEventIDs: Set<String> = []
    var provider: Provider = .codex
    var fidelity: Fidelity = .official
    var progress: Double? = nil
    var expires: Date? = nil
    var recovered: Bool? = nil
    var officiallyEnded: Bool? = nil
    var projectPath: String? = nil
    var verifiedEditorHost: String? = nil
    var editorOriginEvidence: EditorOriginEvidence? = nil
    var verifiedTerminalHost: String? = nil
    var terminalNavigation: TerminalNavigationTarget? = nil
    var editorFocusBlockReason: EditorFocusBlockReason? = nil
    var editorFocusBlockTurnID: String? = nil
    // Provider disposition is reversible and never means the user saw a result.
    // Manual/project acknowledgments continue to use the sticky seen bit.
    var providerAttention: ProviderAttentionDisposition? = nil
    var codexOriginObservation: CodexOriginObservation? = nil
    var unverifiedCodexCompletion: CodexUnverifiedCompletion? = nil
    var runtime: RuntimeMetadata? = nil
    var capabilities: RuntimeCapabilities? = nil
    var requestSnapshots: [PendingRequestSnapshot]? = nil
    // Nil runtime is retained only for legacy Desktop snapshots. Newly parsed
    // rollouts always carry an explicit host, including unknown/conflicting origin.
    var supportsDesktopNativeAttention: Bool {
        guard provider == .codex, source == .desktop,
              verifiedEditorHost == nil, editorOriginEvidence == nil else { return false }
        return runtime == nil || runtime?.host == .codexDesktop
    }
    var isPublicAttentionEligible: Bool {
        // A received hook is not proof of a live root session when its native
        // locator was absent. Retain the diagnostic record, but do not count it
        // as work until origin evidence arrives. Pending requests stay visible.
        if provider == .codex, state == .running, source == .unknown,
           runtime?.host == .unknown, codexOriginObservation?.stage == .missingLocator,
           pending.isEmpty, verifiedEditorHost == nil, verifiedTerminalHost == nil,
           terminalNavigation == nil, editorOriginEvidence == nil { return false }
        return !(provider == .codex && source == .unknown && pending.isEmpty &&
          unverifiedCodexCompletion?.turnID == turnID)
    }
    var requestsResultAttention: Bool {
        isPublicAttentionEligible && !seen && !(supportsDesktopNativeAttention && state == .completed && providerAttention?.turn == turnID && providerAttention?.completed == updated)
    }
}

struct ProviderAttentionDisposition: Codable, Equatable {
    let turn: String
    let completed: Date
    let authority: String
    let suppressedAt: Date
}

struct StateReducer: Codable {
    private(set) var sessions: [String: Session] = [:]
    // Independent of the 200-session working registry. Native dismissal never
    // destroys the outcome; the newest 100 remain in the persisted history.
    private(set) var nativeDismissalHistory: [NativeDismissal]? = nil

    struct NativeDismissal: Codable {
        let session: Session
        let at: Date
        let reason: String
        var providerAttention: ProviderAttentionDisposition? = nil
    }

    @discardableResult mutating func expireUnverifiedCodexCompletions(at now: Date) -> Bool {
        var changed = false
        for id in Array(sessions.keys) {
            guard let observation = sessions[id]?.unverifiedCodexCompletion, observation.expiresAt <= now else { continue }
            sessions[id]?.unverifiedCodexCompletion = nil; changed = true
        }
        return changed
    }
    @discardableResult mutating func migrateUnverifiedCodexCompletions(at now: Date) -> Bool {
        var changed = expireUnverifiedCodexCompletions(at: now)
        for id in Array(sessions.keys) {
            guard var session = sessions[id], session.provider == .codex, session.source == .unknown,
                  session.state == .completed, !session.seen, session.pending.isEmpty,
                  session.unverifiedCodexCompletion == nil, let refusal = session.codexOriginObservation,
                  ![.desktopBound, .editorBound, .terminalBound, .applied, .childSuppressed].contains(refusal.stage) else { continue }
            session.unverifiedCodexCompletion = CodexUnverifiedCompletion(turnID: session.turnID,
                eventID: "migration:" + session.id + ":" + session.turnID, eventAt: session.updated,
                recordedAt: now, expiresAt: now.addingTimeInterval(86_400), originalState: session.state, refusal: refusal)
            session.state = .unknown; session.detail = "Tamamlanma kaynağı doğrulanamadı"
            sessions[id] = session; changed = true
        }
        return changed
    }
    private mutating func observeUnverifiedCodexCompletion(_ event: CodexEvent, at now: Date) -> Bool? {
        guard event.provider == .codex, event.kind == .completed,
              let refusal = event.codexOriginObservation, event.verifiedCodexOriginHost == nil,
              event.codexNativeTurnProof?.matches(event) != true else { return nil }
        if let existing = sessions[event.sessionID] {
            guard existing.provider == .codex, existing.turnID == event.turnID, event.at >= existing.started, event.at >= existing.updated, !existing.seen,
                  ![.failed, .interrupted].contains(existing.state),
                  existing.state != .completed || existing.source == .unknown else { return false }
        }
        var session = sessions[event.sessionID] ?? Session(id: event.sessionID, turnID: event.turnID,
            source: .unknown, title: event.title ?? "Codex", state: .unknown, started: event.at, updated: event.at)
        if session.lastEventIDs.contains(event.id) || session.unverifiedCodexCompletion.map({ event.at <= $0.eventAt }) == true { return false }
        if sessions[event.sessionID] == nil {
            session.projectPath = ProjectIdentity.canonical(event.projectPath)
            session.runtime = event.runtime
        }
        session.unverifiedCodexCompletion = CodexUnverifiedCompletion(turnID: event.turnID, eventID: event.id,
            eventAt: event.at, recordedAt: now, expiresAt: now.addingTimeInterval(86_400),
            originalState: session.unverifiedCodexCompletion?.originalState ?? session.state, refusal: refusal)
        session.codexOriginObservation = refusal
        session.lastEventIDs.insert(event.id)
        if session.lastEventIDs.count > 200 { session.lastEventIDs = Set(session.lastEventIDs.sorted().suffix(100)) }
        if session.source == .unknown && session.pending.isEmpty {
            session.state = .unknown; session.detail = "Tamamlanma kaynağı doğrulanamadı"
        }
        if sessions[event.sessionID] == nil { guard makeWorkingSlot(at: now) else { return false } }
        sessions[event.sessionID] = session
        return true
    }
    // The archive's bounded provisional records remain observable after their
    // working slots are reused. Current/newer working turns always win.
    var providerAttentionCandidates: [Session] {
        var candidates = sessions
        for entry in (nativeDismissalHistory ?? []).reversed() {
            guard let disposition = entry.providerAttention, !entry.session.seen,
                  candidates[entry.session.id] == nil else { continue }
            var session = entry.session; session.providerAttention = disposition
            candidates[session.id] = session
        }
        return Array(candidates.values)
    }
    private mutating func clearArchivedDisposition(_ id: String) {
        guard var history = nativeDismissalHistory else { return }
        for index in history.indices where history[index].session.id == id { history[index].providerAttention = nil }
        nativeDismissalHistory = history
    }
    private mutating func retainProvisional(_ session: Session, disposition: ProviderAttentionDisposition, at now: Date) {
        var history = nativeDismissalHistory ?? []
        if let index = history.firstIndex(where: { $0.reason == "provider-not-requesting-attention" &&
            $0.session.provider == session.provider && $0.session.id == session.id &&
            $0.session.turnID == session.turnID && $0.session.updated == session.updated }) {
            history[index].providerAttention = disposition
        } else {
            history.append(NativeDismissal(session: session, at: now, reason: "provider-not-requesting-attention",
                                           providerAttention: disposition))
        }
        nativeDismissalHistory = Array(history.suffix(100))
    }
    private mutating func makeWorkingSlot(at now: Date) -> Bool {
        guard sessions.count >= 200 else { return true }
        let removable = sessions.values.filter { $0.seen || $0.state == .idle || $0.state == .unknown ||
            ($0.state == .completed && !$0.requestsResultAttention) }
            .sorted { $0.updated == $1.updated ? $0.id < $1.id : $0.updated < $1.updated }
        guard let oldest = removable.first else { return false }
        if let disposition = oldest.providerAttention, !oldest.seen {
            retainProvisional(oldest, disposition: disposition, at: now)
        }
        sessions.removeValue(forKey: oldest.id)
        return true
    }

    @discardableResult mutating func reconcileProviderAttention(_ observations: [ProviderAttentionObservation], at now: Date) -> Bool {
        var changed = false
        for observation in observations {
            let completion = observation.completion
            guard observation.observedAt <= now, now.timeIntervalSince(observation.observedAt) < 3,
                  completion.completed < observation.observedAt,
                  let session = providerAttentionCandidates.first(where: { $0.id == completion.thread }), session.provider == .codex,
                  session.supportsDesktopNativeAttention, session.state == .completed, !session.seen,
                  session.pending.isEmpty, session.turnID == completion.turn,
                  session.updated == completion.completed,
                  completion.registryStarted == nil || completion.registryStarted == session.started else { continue }
            // An unavailable or changed account/host never inherits or reverses
            // another authority's disposition. A new turn resets this binding.
            if let disposition = session.providerAttention, disposition.authority != observation.authority { continue }
            if observation.requestsAttention {
                guard session.providerAttention != nil else { continue }
                if sessions[session.id] == nil {
                    guard makeWorkingSlot(at: now) else { continue }
                    sessions[session.id] = session
                }
                sessions[session.id]?.providerAttention = nil
                clearArchivedDisposition(session.id); changed = true
            } else {
                guard session.providerAttention == nil else { continue }
                let disposition = ProviderAttentionDisposition(turn: completion.turn,
                    completed: completion.completed, authority: observation.authority, suppressedAt: now)
                retainProvisional(session, disposition: disposition, at: now)
                sessions[session.id]?.providerAttention = disposition
                changed = true
            }
        }
        return changed
    }

    @discardableResult mutating func dismissNative(_ completions: [NativeCompletion], at now: Date) -> Bool {
        var changed = false
        for completion in completions {
            guard let session = sessions[completion.thread], session.provider == .codex,
                  session.supportsDesktopNativeAttention, session.state == .completed, !session.seen,
                  session.turnID == completion.turn, session.updated == completion.completed else { continue }
            var history = nativeDismissalHistory ?? []
            history.append(NativeDismissal(session: session, at: now, reason: "codex-native-attention-dismissal"))
            nativeDismissalHistory = Array(history.suffix(100))
            sessions[session.id]?.seen = true
            clearArchivedDisposition(session.id)
            changed = true
        }
        return changed
    }

    @discardableResult mutating func associateProject(_ event: CodexEvent) -> Bool {
        guard let path = ProjectIdentity.canonical(event.projectPath),
              let session = sessions[event.sessionID], session.provider == event.provider,
              session.turnID == event.turnID, session.projectPath == nil else { return false }
        sessions[event.sessionID]?.projectPath = path; return true
    }
    @discardableResult mutating func associateEditorOrigin(_ proof: CodexEditorOriginProof, event: CodexEvent) -> Bool {
        if event.kind == .requestResolved {
            guard sessions[event.sessionID]?.updated == event.at else { return false }
            return reconcileReplayedEditorOrigin(proof, event: event)
        }
        guard var session = sessions[event.sessionID], event.sessionID == proof.sessionID,
              session.turnID == event.turnID, session.provider == .codex, event.provider == .codex,
              session.updated == event.at, session.runtime?.host == .vscode, event.runtime?.host == .vscode,
              session.projectPath == proof.projectPath, event.projectPath == proof.projectPath,
              session.editorOriginEvidence == nil,
              session.editorFocusBlockReason == nil || (session.editorFocusBlockReason == .codexBlockingQuestionUnresolved &&
                event.kind == .requestResolved && event.requestUpdate?.lifecycle == .resolved) else { return false }
        session.editorOriginEvidence = .codexVSCodeRollout
        session.editorFocusBlockReason = nil; session.editorFocusBlockTurnID = nil
        sessions[session.id] = session
        return true
    }

    // Historical answer timestamps can precede a persisted completion. This
    // callback is internal to a validated ordered rollout, never a wire claim.
    @discardableResult mutating func reconcileReplayedEditorOrigin(_ proof: CodexEditorOriginProof, event: CodexEvent) -> Bool {
        guard var session = sessions[event.sessionID], proof.sessionID == session.id,
              session.provider == .codex, event.provider == .codex,
              session.turnID == event.turnID, session.runtime?.host == .vscode,
              event.runtime?.host == .vscode, session.projectPath == proof.projectPath,
              event.projectPath == proof.projectPath, event.at <= session.updated else { return false }
        if event.kind == .requestResolved {
            guard let update = event.requestUpdate, update.lifecycle == .resolved,
                  update.identity.sessionID == session.id, update.identity.turnID == session.turnID,
                  update.identity.requestID == event.requestID,
                  update.identity.runtimeID == session.runtime?.id,
                  session.requestSnapshots?.contains(where: { $0.identity == update.identity && $0.lifecycle == .resolved }) == true,
                  !session.hasUnresolvedInteraction,
                  session.editorFocusBlockReason != .codexAsyncQuestionUnresolved ||
                    update.identity.generation.hasPrefix("vscode-async:" + session.turnID + ":") else { return false }
            session.editorFocusBlockReason = nil; session.editorFocusBlockTurnID = nil
        } else {
            guard event.kind == .completed, event.at == session.updated,
                  session.state == .completed, session.editorFocusBlockReason == nil,
                  !session.hasUnresolvedInteraction else { return false }
        }
        session.editorOriginEvidence = .codexVSCodeRollout
        sessions[session.id] = session; return true
    }

    @discardableResult mutating func recoverHistoricalEditorCompletion(_ proof: CodexEditorOriginProof, event: CodexEvent) -> Bool {
        guard let session = sessions[proof.sessionID], event.sessionID == proof.sessionID,
              event.kind == .completed, session.provider == .codex, event.provider == .codex,
              session.turnID == event.turnID, session.runtime?.host == .vscode, event.runtime?.host == .vscode,
              session.runtime?.id == event.runtime?.id,
              session.projectPath == proof.projectPath, event.projectPath == proof.projectPath,
              [.running, .unknown].contains(session.state), !session.seen,
              !session.hasUnresolvedInteraction, session.editorFocusBlockReason == nil,
              event.at >= session.updated else { return false }
        return apply(event)
    }

    // Only the watcher's current validated CLI ledger may rebuild a missing
    // pending snapshot. This does not alter timestamps, outcomes or Seen.
    @discardableResult mutating func recoverCLIPending(_ proof: CodexCLIQuestionProof, requests: [PendingRequestSnapshot]) -> Bool {
        guard proof.fileStillValid, !requests.isEmpty, requests.count <= 16, var session = sessions[proof.sessionID],
              session.provider == .codex, session.source == .cli, session.runtime?.host == .terminal,
              session.runtime?.id == proof.runtimeID, session.turnID == proof.turnID,
              session.projectPath == proof.projectPath, !session.seen,
              [.running, .unknown, .waitingUser, .waitingPermission].contains(session.state) else { return false }
        for request in requests {
            guard request.isValid, request.lifecycle == .pending, request.kind == .question,
                  request.identity.sessionID == proof.sessionID, request.identity.turnID == proof.turnID,
                  request.identity.runtimeID == proof.runtimeID,
                  request.identity.generation.hasPrefix("cli-native:" + proof.turnID + ":"),
                  request.observedAt >= session.started,
                  !(session.requestSnapshots ?? []).contains(where: { $0.id == request.id && ($0.identity != request.identity || $0.lifecycle != .pending) }) else { return false }
        }
        let previous = session
        for request in requests {
            if !(session.requestSnapshots ?? []).contains(where: { $0.identity == request.identity }) {
                session.requestSnapshots = (session.requestSnapshots ?? []) + [request]
            }
            session.pending.insert(request.id); session.pendingKinds[request.id] = .waitingUser
        }
        session.state = session.pendingKinds.values.contains(.waitingPermission) ? .waitingPermission : .waitingUser
        guard session.pending != previous.pending || session.state != previous.state || session.requestSnapshots != previous.requestSnapshots else { return false }
        sessions[session.id] = session; return true
    }

    @discardableResult mutating func recoverNativeAsyncPending(_ proof: CodexEditorOriginProof, requests: [PendingRequestSnapshot]) -> Bool {
        guard !requests.isEmpty, requests.count <= 64, var session = sessions[proof.sessionID],
              session.provider == .codex, session.runtime?.host == .vscode,
              session.projectPath == proof.projectPath, !session.seen else { return false }
        for request in requests {
            guard request.isValid, request.lifecycle == .pending, request.kind == .question,
                  request.identity.sessionID == session.id, request.identity.turnID == session.turnID,
                  request.identity.runtimeID == session.runtime?.id,
                  request.identity.generation.hasPrefix("vscode-async:" + session.turnID + ":"),
                  request.observedAt <= session.updated,
                  !(session.requestSnapshots ?? []).contains(where: { $0.id == request.id && ($0.identity != request.identity || $0.lifecycle != .pending) }) else { return false }
        }
        var changed = false
        for request in requests {
            if !(session.requestSnapshots ?? []).contains(where: { $0.identity == request.identity }) {
                session.requestSnapshots = (session.requestSnapshots ?? []) + [request]; changed = true
            }
            if session.pending.insert(request.id).inserted { changed = true }
            session.pendingKinds[request.id] = .waitingUser
        }
        if session.state != .waitingUser { session.state = .waitingUser; changed = true }
        guard changed else { return false }
        session.editorFocusBlockReason = .codexAsyncQuestionUnresolved; session.editorFocusBlockTurnID = session.turnID
        session.providerAttention = nil
        sessions[session.id] = session; return true
    }

    @discardableResult mutating func supersedeEditorOriginBlock(_ proof: CodexEditorOriginProof, event: CodexEvent) -> Bool {
        guard var session = sessions[event.sessionID], event.kind == .started,
              proof.sessionID == session.id, session.provider == .codex, event.provider == .codex,
              session.turnID == event.turnID, session.updated == event.at,
              session.projectPath == proof.projectPath, session.runtime?.host == .vscode,
              let previous = session.editorFocusBlockTurnID, previous != event.turnID else { return false }
        session.editorFocusBlockReason = nil; session.editorFocusBlockTurnID = nil
        sessions[session.id] = session; return true
    }
    @discardableResult mutating func revokeEditorOrigin(_ sessionID: String, reason: EditorFocusBlockReason = .codexAsyncQuestionUnresolved, turnID: String? = nil) -> Bool {
        guard let session = sessions[sessionID], session.provider == .codex,
              session.runtime?.host == .vscode, (turnID == nil || session.turnID == turnID), session.editorFocusBlockReason != .codexAsyncQuestionUnresolved,
              session.editorFocusBlockReason != reason else { return false }
        // Proven source identity survives a question; eligibility is blocked separately.
        sessions[sessionID]?.editorFocusBlockReason = reason
        sessions[sessionID]?.editorFocusBlockTurnID = session.turnID; return true
    }
    @discardableResult mutating func associateEditorHost(_ event: CodexEvent) -> Bool {
        guard let host = event.verifiedEditorHost, let session = sessions[event.sessionID],
              session.provider == event.provider, session.turnID == event.turnID,
              session.verifiedEditorHost == nil else { return false }
        sessions[event.sessionID]?.verifiedEditorHost = host; return true
    }
    @discardableResult mutating func dismissProject(_ path: String, at now: Date, observedAt: Date? = nil, editorHost: String? = nil, eligibleEditorGenerations: Set<EditorFocusTerminalGeneration>? = nil) -> Bool {
        let proofTime = observedAt ?? now
        guard proofTime <= now, now.timeIntervalSince(proofTime) < 3,
              let canonical = ProjectIdentity.canonical(path), canonical == path else { return false }
        var changed = false
        for session in sessions.values where session.projectPath == canonical && !session.seen && !session.hasUnresolvedInteraction &&
            (editorHost == nil || session.focusEditorHost == editorHost) &&
            (eligibleEditorGenerations == nil || eligibleEditorGenerations!.contains(EditorFocusTerminalGeneration(session))) &&
            [.completed, .failed, .interrupted].contains(session.state) && session.updated < proofTime {
            var history = nativeDismissalHistory ?? []
            history.append(NativeDismissal(session: session, at: now, reason: editorHost == nil ? "verified-project-focus" : "verified-editor-focus"))
            nativeDismissalHistory = Array(history.suffix(100))
            sessions[session.id]?.seen = true; changed = true
            clearArchivedDisposition(session.id)
        }
        for entry in nativeDismissalHistory ?? [] where entry.providerAttention != nil && entry.session.projectPath == canonical && !entry.session.hasUnresolvedInteraction &&
            (editorHost == nil || entry.session.focusEditorHost == editorHost) &&
            (eligibleEditorGenerations == nil || eligibleEditorGenerations!.contains(EditorFocusTerminalGeneration(entry.session))) &&
            entry.session.updated < proofTime {
            clearArchivedDisposition(entry.session.id); changed = true
        }
        return changed
    }
    @discardableResult mutating func apply(_ input: CodexEvent, allowUnverifiedWait: Bool = false,
                                           allowActivityResume: Bool = false) -> Bool {
        var event = input
        if let canonical = event.runtime?.canonicalSessionID {
            guard !canonical.isEmpty, canonical.count <= 160 else { return false }
            event.sessionID = canonical
        }
        if [.opencode, .antigravity].contains(event.provider), event.fidelity == .official,
           event.runtimeState != nil, [.activity, .unknownEvent].contains(event.kind), let active = sessions[event.sessionID] {
            event.turnID = active.turnID
        }
        let requestTurn = event.turnID
        let scope = event.requestTurnScope ?? event.requestSnapshot?.turnScope
        let scopedRequest = scope == .request || scope == .hookInvocation
        if scopedRequest {
            guard [.permissionObserved, .userQuestionObserved, .requestResolved].contains(event.kind),
                  scope == .request ? requestTurn.hasPrefix("request:") || event.provider == .opencode : requestTurn.hasPrefix("hook:") else { return false }
            event.turnID = sessions[event.sessionID]?.turnID ?? event.sessionID
            event.missingTurnIdentity = false
        }
        // Legacy Claude events may keep their session fallback scope, but cannot
        // be associated with an explicitly identified newer prompt.
        if event.provider == .claude, event.missingTurnIdentity == true,
           let active = sessions[event.sessionID], active.turnID != event.turnID { return false }
        if event.provider == .codex, event.fidelity == .official, event.missingTurnIdentity == true,
           [.permissionObserved, .userQuestionObserved, .requestResolved, .completed, .failed, .interrupted, .sessionEnded].contains(event.kind) {
            // A fresh helper receipt cannot identify which submitted turn ended.
            guard ![.completed, .failed, .interrupted, .sessionEnded].contains(event.kind) else { return false }
            // The registry has one current turn per real thread. Never infer from
            // cwd/title, an unknown session, a terminal turn, or another provider.
            guard let active = sessions[event.sessionID], active.provider == event.provider,
                  [.running, .waitingPermission, .waitingUser].contains(active.state),
                  active.turnID != active.id, event.at >= active.started else { return false }
            event.turnID = active.turnID
        }
        guard !event.sessionID.isEmpty, !event.turnID.isEmpty, event.sessionID.count <= 160,
              event.turnID.count <= 160, event.id.count <= 200, event.requestID.map({ $0.count <= 160 }) ?? true,
              event.title.map({ $0.count <= 100 }) ?? true, event.detail.map({ $0.count <= 500 }) ?? true,
              event.requestMatchKey.map({ $0.count <= 100 }) ?? true,
              (event.progress == nil || (0...1).contains(event.progress!)),
              (event.ttl == nil || (1...86_400).contains(event.ttl!)) else { return false }
        if let existing = sessions[event.sessionID], existing.provider != event.provider { return false }
        if let request = event.requestSnapshot {
            guard request.isValid, request.identity.provider == event.provider,
                  request.identity.sessionID == event.sessionID, request.identity.turnID == (scopedRequest ? requestTurn : event.turnID),
                  request.identity.requestID == event.requestID,
                  request.lifecycle == .pending,
                  (request.kind == .question && event.kind == .userQuestionObserved ||
                   request.kind == .permission && event.kind == .permissionObserved),
                  request.identity.runtimeID == (event.runtime?.id ?? sessions[event.sessionID]?.runtime?.id) else { return false }
        }
        if let update = event.requestUpdate {
            guard event.kind == .requestResolved, update.identity.provider == event.provider,
                  update.identity.sessionID == event.sessionID, update.identity.turnID == (scopedRequest ? requestTurn : event.turnID),
                  update.identity.requestID == event.requestID,
                  let current = sessions[event.sessionID]?.requestSnapshots?.first(where: { $0.identity == update.identity }),
                  sessions[event.sessionID]?.pending.contains(update.identity.requestID) == true,
                  current.lifecycle == .pending || current.lifecycle == .submitting || current.lifecycle == .submitted || current.lifecycle == .deliveryUnknown else { return false }
            if update.lifecycle == .pending || update.lifecycle == .submitting {
                guard update.lifecycle == .pending || current.lifecycle == .pending else { return false }
            }
        } else if event.kind == .requestResolved, let current = sessions[event.sessionID] {
            // Legacy match keys may resolve only legacy requests, never bypass
            // the generation binding on a structured snapshot.
            let affected = current.requestSnapshots?.contains { request in
                request.id == event.requestID || (event.requestMatchKey != nil &&
                    current.pendingMatchKeys[request.id] == event.requestMatchKey)
            } == true
            if affected { return false }
        }
        if event.kind == .reconciledRunning &&
            (event.provider != .codex || event.fidelity != .derived || event.source != .desktop) { return false }
        _ = expireUnverifiedCodexCompletions(at: Date())
        if let observed = observeUnverifiedCodexCompletion(event, at: Date()) { return observed }
        if event.kind == .dropped {
            let archived = (nativeDismissalHistory ?? []).contains { $0.session.id == event.sessionID && $0.providerAttention != nil }
            clearArchivedDisposition(event.sessionID)
            return sessions.removeValue(forKey: event.sessionID) != nil || archived
        }
        if sessions[event.sessionID] == nil {
            // Do not resurrect an evicted outcome via stale/non-start replay.
            if let archived = (nativeDismissalHistory ?? []).last(where: { $0.session.id == event.sessionID }) {
                guard [.started, .reconciledRunning, .activity].contains(event.kind),
                      event.turnID != archived.session.turnID, event.at >= archived.session.updated,
                      event.kind != .activity || allowActivityResume else { return false }
            }
        }
        var s = sessions[event.sessionID] ?? Session(id: event.sessionID, turnID: event.turnID, source: event.source,
            title: event.title ?? "Codex oturumu", state: .unknown, started: event.at, updated: event.at)
        if event.kind == .started && event.provider == .signal &&
            [.completed, .failed, .interrupted, .idle, .unknown].contains(s.state) {
            s.lastEventIDs.removeAll()
        }
        if event.fidelity == .derived, s.turnID == event.turnID,
           [.waitingPermission, .waitingUser].contains(s.state),
           [.started, .reconciledRunning].contains(event.kind) { return false }
        if s.lastEventIDs.contains(event.id) && event.kind != .reconciledRunning { return false }
        if event.provider == .signal &&
            ((event.kind == .completed && s.state == .completed) ||
             (event.kind == .failed && s.state == .failed) ||
             (event.kind == .interrupted && s.state == .interrupted)) { return false }
        if event.kind == .completed, let observation = s.unverifiedCodexCompletion {
            guard observation.turnID == event.turnID, s.turnID == event.turnID, !s.seen, s.pending.isEmpty,
                  let root = ProjectIdentity.canonical(s.projectPath), ProjectIdentity.canonical(event.projectPath) == root,
                  event.codexNativeTurnProof?.matches(event) == true || event.verifiedCodexOriginHost != nil else { return false }
        }
        if event.kind == .completed, let observation = s.unverifiedCodexCompletion,
           observation.turnID == event.turnID, observation.expiresAt > Date(), s.turnID == event.turnID,
           !s.seen, s.pending.isEmpty, let proof = event.codexNativeTurnProof, proof.matches(event),
           ProjectIdentity.canonical(s.projectPath) == proof.projectPath,
           let nativeCompleted = proof.nativeCompleted {
            s.started = proof.started; s.updated = nativeCompleted; s.source = proof.source; s.runtime = proof.runtime
            s.state = .completed; s.unverifiedCodexCompletion = nil; s.fidelity = event.fidelity
            s.lastEventIDs.insert(event.id); s.detail = event.detail ?? "İş tamamlandı"
            sessions[event.sessionID] = s; return true
        }
        if s.turnID != event.turnID {
            if event.provider == .claude && event.kind != .started { return false }
            guard (event.kind == .started || event.kind == .reconciledRunning || (event.kind == .activity && allowActivityResume)), event.at >= s.updated else { return false }
            s.projectPath = nil; s.verifiedEditorHost = nil; s.verifiedTerminalHost = nil; s.terminalNavigation = nil; s.editorOriginEvidence = nil; s.providerAttention = nil; s.codexOriginObservation = nil; s.unverifiedCodexCompletion = nil
            s.turnID = event.turnID; s.officiallyEnded = false; s.fidelity = event.fidelity; s.recovered = event.kind == .reconciledRunning; s.state = .running; s.started = event.at; s.seen = false
            s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll(); s.requestSnapshots = nil; s.lastEventIDs.removeAll()
        } else if event.kind != .reconciledRunning && (event.at < s.started || event.at < s.updated) { return false }
        if ([.permissionObserved, .userQuestionObserved, .requestResolved].contains(event.kind)),
           (s.officiallyEnded == true || s.state == .completed || s.state == .failed || s.state == .interrupted) { return false }
        if event.kind == .reconciledRunning && s.officiallyEnded == true { return false }
        // Derived recovery/activity must never resurrect a reliably terminal turn.
        if event.fidelity == .derived && [.completed, .failed, .interrupted].contains(s.state) &&
            [.started, .reconciledRunning, .activity].contains(event.kind) { return false }
        // A verified local completion also carries the precise start of the
        // same turn. Repair only the known whole-second start boundary; never
        // infer that another turn, pending question, or result was seen.
        var normalizedNativeStart = false
        if event.kind == .completed, s.turnID == event.turnID, s.pending.isEmpty,
           let proof = event.codexNativeTurnProof, proof.matches(event),
           proof.source == .desktop, proof.runtime.host == .codexDesktop,
           ProjectIdentity.canonical(s.projectPath) == proof.projectPath,
           s.started.timeIntervalSince1970 == floor(s.started.timeIntervalSince1970),
           floor(proof.started.timeIntervalSince1970) == s.started.timeIntervalSince1970,
           s.started != proof.started {
            s.started = proof.started; normalizedNativeStart = true
        }
        let terminalReplay = (event.kind == .completed && s.state == .completed) ||
            (event.kind == .failed && s.state == .failed) || (event.kind == .interrupted && s.state == .interrupted)
        if event.provider == .codex, terminalReplay {
            // Terminal generation is immutable. A separately validated header
            // may enrich a previously unknown origin without replaying outcome.
            var changed = normalizedNativeStart
            if s.fidelity == .derived, event.fidelity == .official {
                s.fidelity = .official; changed = true
            }
            if s.source == .unknown, s.runtime == nil || s.runtime?.host == .unknown,
               let host = event.verifiedCodexOriginHost, host != .unknown,
               event.runtime?.host == host,
               event.source == (host == .terminal ? .cli : .desktop) {
                s.source = event.source; s.runtime = event.runtime; changed = true
            }
            if let observation = event.codexOriginObservation, s.codexOriginObservation != observation {
                s.codexOriginObservation = observation; changed = true
            }
            if let target = event.terminalNavigation, s.terminalNavigation != target {
                s.terminalNavigation = target; changed = true
            }
            guard changed else { return false }
            sessions[event.sessionID] = s
            return true
        }
        s.lastEventIDs.insert(event.id)
        if s.lastEventIDs.count > 200 { s.lastEventIDs = Set(s.lastEventIDs.sorted().suffix(100)) }
        if event.kind != .reconciledRunning { s.updated = max(s.updated, event.at) }
        if event.source != .unknown { s.source = event.source }
        if let observation = event.codexOriginObservation { s.codexOriginObservation = observation }
        let previousRuntimeContext = s.runtime?.sourceContextID
        s.provider = event.provider
        if let runtime = event.runtime {
            if s.runtime?.id != runtime.id || s.runtime?.version != runtime.version { s.capabilities = nil }
            s.runtime = runtime
        }
        if let capabilities = event.capabilities, capabilities.provider == event.provider { s.capabilities = capabilities }
        if let path = ProjectIdentity.canonical(event.projectPath) { s.projectPath = path }
        if let host = event.verifiedEditorHost { s.verifiedEditorHost = host }
        if let target = event.terminalNavigation { s.terminalNavigation = target }
        if event.verifiedEditorHost != nil || event.runtime.map({ [.vscode, .codexDesktop, .cursor, .windsurf, .antigravity].contains($0.host) }) == true {
            s.terminalNavigation = nil
        }
        if event.provider == .antigravity {
            s.verifiedTerminalHost = event.runtime?.host == .terminal ? event.verifiedTerminalHost : nil
        }
        if event.fidelity == .official || event.kind == .started { s.recovered = false }
        if !(terminalReplay && s.fidelity == .official && event.fidelity == .derived) &&
           !([.activity, .reconciledRunning].contains(event.kind) && ((s.fidelity == .official && s.state != .unknown) || s.state == .waitingPermission || s.state == .waitingUser)) {
            s.fidelity = event.fidelity
        }
        if let progress = event.progress { s.progress = progress }
        if let ttl = event.ttl { s.expires = event.at.addingTimeInterval(ttl) }
        if let title = event.title, !title.isEmpty { s.title = title }
        switch event.kind {
        case .started:
            s.providerAttention = nil
            s.officiallyEnded = false
            s.state = (event.provider == .signal || s.pending.isEmpty) ? .running : (s.pendingKinds.values.contains(.waitingPermission) ? .waitingPermission : .waitingUser); s.seen = false
            if event.provider == .signal { s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll() }
            if event.ttl == nil { s.expires = nil }
            s.detail = event.detail ?? "İş başladı"
        case .reconciledRunning:
            if s.state == .unknown { s.recovered = true; s.state = .running; s.seen = false; s.detail = event.detail ?? "Canlı tur doğrulandı" }
        case .activity:
            if s.state == .unknown && allowActivityResume { s.state = .running }
            if s.state == .running, let detail = event.detail { s.detail = detail }
        case .permissionObserved, .userQuestionObserved:
            if (allowUnverifiedWait || event.fidelity == .official || event.fidelity == .manual), let id = event.requestID {
                if !(id.hasPrefix("fallback:") && event.provider == .claude && !s.pending.isEmpty) {
                    if let request = event.requestSnapshot {
                        var requests = s.requestSnapshots ?? []
                        if let index = requests.firstIndex(where: { $0.id == id }) {
                            let previous = requests[index]
                            if previous.identity == request.identity {
                                guard s.pending.contains(id), [.pending, .submitting, .submitted, .deliveryUnknown].contains(previous.lifecycle) else { return false }
                                requests[index] = request
                                requests[index].lifecycle = previous.lifecycle
                            } else {
                                guard event.provider == .opencode, event.fidelity == .official,
                                      event.trustedInteractionSnapshot == true,
                                      request.turnScope == .request, previous.turnScope == .request,
                                      previous.identity.sessionID == request.identity.sessionID,
                                      previous.kind == request.kind,
                                      request.observedAt >= previous.observedAt, event.at >= request.observedAt else { return false }
                                let rehydration = [.pending, .submitting, .submitted, .deliveryUnknown].contains(previous.lifecycle) &&
                                    previous.question == nil && previous.permission == nil &&
                                    previousRuntimeContext != nil && previousRuntimeContext == event.runtime?.sourceContextID
                                let bodyRevision = (previous.question != nil || previous.permission != nil) &&
                                    previous.identity.runtimeID == request.identity.runtimeID &&
                                    previous.identity.turnID == request.identity.turnID &&
                                    (previous.question != request.question || previous.permission != request.permission)
                                guard rehydration || bodyRevision else { return false }
                                guard [.pending, .submitting, .submitted, .deliveryUnknown, .resolved].contains(previous.lifecycle) else { return false }
                                requests[index] = request
                                if rehydration && [.submitting, .submitted, .deliveryUnknown].contains(previous.lifecycle) {
                                    requests[index].lifecycle = .deliveryUnknown
                                }
                            }
                        } else { requests.append(request) }
                        s.requestSnapshots = requests
                    }
                    s.pending.insert(id)
                    s.pendingKinds[id] = event.kind == .permissionObserved ? .waitingPermission : .waitingUser
                    if let key = event.requestMatchKey { s.pendingMatchKeys[id] = key }
                    s.state = s.pendingKinds.values.contains(.waitingPermission) ? .waitingPermission : .waitingUser
                    s.detail = event.detail ?? (s.state == .waitingPermission ? "İzin bekliyor" : "Kullanıcı yanıtı bekliyor")
                }
            }
        case .requestResolved:
            if let update = event.requestUpdate, let index = s.requestSnapshots?.firstIndex(where: { $0.identity == update.identity }) {
                s.requestSnapshots?[index].lifecycle = update.lifecycle
                if [.pending, .submitting, .submitted, .deliveryUnknown].contains(update.lifecycle) { break }
            }
            let direct = event.requestID.flatMap { s.pending.contains($0) ? $0 : nil }
            let candidates = event.requestMatchKey.map { key in s.pending.filter { s.pendingMatchKeys[$0] == key } } ?? []
            let resolved = direct ?? (candidates.count == 1 ? candidates.first : nil)
            if let id = resolved {
                s.pending.remove(id); s.pendingKinds.removeValue(forKey: id); s.pendingMatchKeys.removeValue(forKey: id)
            }
            if !s.pending.isEmpty { s.state = s.pendingKinds.values.contains(.waitingPermission) ? .waitingPermission : .waitingUser }
            else if resolved != nil && (s.state == .waitingPermission || s.state == .waitingUser) { s.state = .running; s.expires = nil }
        case .completed: s.unverifiedCodexCompletion = nil; s.state = .completed; s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll(); s.expireRequests(); s.expires = nil; if !terminalReplay { s.seen = false }; s.detail = event.detail ?? "İş tamamlandı"
        case .failed: s.state = .failed; s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll(); s.expireRequests(); s.expires = nil; if !terminalReplay { s.seen = false }; s.detail = event.detail ?? "İş başarısız oldu"
        case .interrupted: if !terminalReplay { s.seen = false }; s.state = .interrupted; s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll(); s.expireRequests(); s.expires = nil; s.detail = event.detail ?? "Tur kesildi"
        case .sessionEnded:
            if event.fidelity == .official { s.officiallyEnded = true }
            s.pending.removeAll(); s.pendingKinds.removeAll(); s.pendingMatchKeys.removeAll(); s.expireRequests(); s.expires = nil
            if s.state == .running || s.state == .waitingPermission || s.state == .waitingUser { s.state = .unknown }
        case .unknownEvent: s.detail = event.detail ?? "Bilinmeyen sağlayıcı olayı"
        case .dropped, .usage: break
        }
        if [.opencode, .antigravity].contains(event.provider), event.fidelity == .official,
           [.activity, .unknownEvent].contains(event.kind), s.pending.isEmpty,
           !([.completed, .failed, .interrupted].contains(s.state) && s.requestsResultAttention),
           let state = event.runtimeState, [.idle, .running].contains(state) { s.state = state }
        if let disposition = s.providerAttention,
           s.state != .completed || disposition.turn != s.turnID || disposition.completed != s.updated {
            s.providerAttention = nil
        }
        if sessions[event.sessionID] == nil { guard makeWorkingSlot(at: event.at) else { return false } }
        sessions[event.sessionID] = s
        if [.started, .reconciledRunning].contains(event.kind) || (event.kind == .activity && allowActivityResume && s.state == .running) {
            clearArchivedDisposition(event.sessionID)
        }
        if sessions.count > 200,
           let oldest = sessions.values.filter({ $0.state != .running && $0.state != .waitingPermission && $0.state != .waitingUser })
                .min(by: { $0.updated < $1.updated }) {
            sessions.removeValue(forKey: oldest.id)
        }
        return true
    }

    mutating func markSeen(_ ids: Set<String>) {
        for id in ids where sessions[id]?.state == .completed || sessions[id]?.state == .failed || sessions[id]?.state == .interrupted {
            sessions[id]?.seen = true; sessions[id]?.providerAttention = nil
        }
        for id in ids { clearArchivedDisposition(id) }
    }
    @discardableResult mutating func expire(at date: Date) -> Bool {
        var changed = false
        for id in sessions.keys {
            guard var session = sessions[id], var requests = session.requestSnapshots else { continue }
            var expired = false
            for index in requests.indices where ([.pending, .submitting, .submitted, .deliveryUnknown].contains(requests[index].lifecycle)) &&
                requests[index].expiresAt.map({ $0 <= date }) == true {
                requests[index].lifecycle = .expired
                let requestID = requests[index].id
                session.pending.remove(requestID); session.pendingKinds.removeValue(forKey: requestID)
                session.pendingMatchKeys.removeValue(forKey: requestID); expired = true
            }
            if expired {
                session.requestSnapshots = requests
                if session.pending.isEmpty { session.state = .unknown; session.detail = "Bekleme çözülmesi doğrulanamadı" }
                else { session.state = session.pendingKinds.values.contains(.waitingPermission) ? .waitingPermission : .waitingUser }
                sessions[id] = session; changed = true
            }
        }
        for id in sessions.keys where sessions[id]?.expires.map({ $0 <= date }) == true {
            changed = true
            if var session = sessions[id],
               (session.provider == .codex || session.provider == .claude),
               (session.state == .waitingPermission || session.state == .waitingUser) {
                session.state = .unknown
                session.pending.removeAll(); session.pendingKinds.removeAll(); session.pendingMatchKeys.removeAll(); session.expireRequests(); session.expires = nil
                session.detail = "Bekleme çözülmesi doğrulanamadı"
                sessions[id] = session
            } else { sessions.removeValue(forKey: id) }
        }
        return changed
    }
    // Recover only the latest provisional outcome incorrectly governed by the
    // Desktop mirror. Existing working turns and later dismissals always win.
    private mutating func restoreInvalidDesktopMirrorOutcomes() {
        var visited = Set<String>()
        for entry in (nativeDismissalHistory ?? []).reversed() {
            guard visited.insert(entry.session.id).inserted,
                  sessions[entry.session.id] == nil,
                  entry.reason == "provider-not-requesting-attention",
                  entry.providerAttention != nil, !entry.session.seen,
                  entry.session.state == .completed,
                  !entry.session.supportsDesktopNativeAttention,
                  makeWorkingSlot(at: entry.at) else { continue }
            var restored = entry.session
            restored.providerAttention = nil
            sessions[restored.id] = restored
            clearArchivedDisposition(restored.id)
        }
    }
    mutating func markHistoricalRunningUnknown(except liveSessionIDs: Set<String> = []) {
        restoreInvalidDesktopMirrorOutcomes()
        for id in sessions.keys where sessions[id]?.state == .running && !liveSessionIDs.contains(id) { sessions[id]?.state = .unknown }
    }
    mutating func reconcilePresence(_ events: [CodexEvent]) {
        let identities = Set(events.map { "\($0.sessionID):\($0.turnID)" })
        for id in sessions.keys {
            guard var session = sessions[id], session.recovered == true, session.state == .running,
                  !identities.contains("\(session.id):\(session.turnID)") else { continue }
            session.state = .unknown; session.recovered = false
            sessions[id] = session
        }
    }
    var aggregate: MascotState {
        let all = Array(sessions.values).filter(\.isPublicAttentionEligible)
        if all.contains(where: { $0.state == .waitingPermission || $0.state == .waitingUser }) { return .waiting }
        if all.contains(where: { $0.state == .completed && $0.requestsResultAttention }) { return .completed }
        if all.contains(where: { $0.state == .running }) { return .running }
        return .neutral
    }
    var visibleAttentionRows: [Session] {
        ordered.filter { $0.isPublicAttentionEligible && ($0.state == .running || $0.state == .waitingPermission || $0.state == .waitingUser ||
            ($0.requestsResultAttention && [.completed, .failed, .interrupted].contains($0.state))) }
    }
    var attentionFooter: String {
        let rows = visibleAttentionRows
        let running = rows.filter { $0.state == .running }.count
        let waiting = rows.filter { $0.state == .waitingPermission || $0.state == .waitingUser }.count
        let results = rows.filter { [.completed, .failed, .interrupted].contains($0.state) }.count
        let parts = [(running, "çalışıyor"), (waiting, "bekliyor"), (results, "yeni sonuç")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "Aktif işlem yok" : parts.joined(separator: " · ")
    }
    var ordered: [Session] {
        sessions.values.sorted {
            func rank(_ s: Session) -> Int {
                if s.state == .waitingPermission || s.state == .waitingUser { return 0 }
                if [.failed, .interrupted].contains(s.state) && s.requestsResultAttention { return 1 }
                if s.state == .completed && s.requestsResultAttention { return 2 }
                if s.state == .running { return 3 }
                return 4
            }
            if rank($0) != rank($1) { return rank($0) < rank($1) }
            if $0.updated != $1.updated { return $0.updated > $1.updated }
            return $0.id < $1.id
        }
    }
}

extension StateReducer {
    // Only identity/status metadata survives restart. Content and response
    // channels are ephemeral even inside the provisional native archive.
    func persistenceSnapshot() -> StateReducer {
        var result = self
        result.redactInteractionContent()
        return result
    }
    mutating func redactInteractionContent() {
        for id in sessions.keys { sessions[id]?.redactInteractionContent() }
        if var history = nativeDismissalHistory {
            for index in history.indices {
                let entry = history[index]
                var session = entry.session; session.redactInteractionContent()
                history[index] = NativeDismissal(session: session, at: entry.at, reason: entry.reason, providerAttention: entry.providerAttention)
            }
            nativeDismissalHistory = history
        }
    }
}

extension Session {
    private enum CodingKeys: String, CodingKey { case id, turnID, source, title, detail, state, started, updated, seen, pending, pendingKinds, pendingMatchKeys, lastEventIDs, provider, fidelity, progress, expires, recovered, officiallyEnded, projectPath, verifiedEditorHost, verifiedTerminalHost, terminalNavigation, editorOriginEvidence, editorFocusBlockReason, editorFocusBlockTurnID, providerAttention, codexOriginObservation, unverifiedCodexCompletion, runtime, capabilities, requestSnapshots }
    func encode(to encoder: Encoder) throws {
        var safe = self; safe.redactInteractionContent()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(safe.id, forKey: .id)
        try c.encode(safe.turnID, forKey: .turnID)
        try c.encode(safe.source, forKey: .source)
        try c.encode(safe.title, forKey: .title)
        try c.encode(safe.detail, forKey: .detail)
        try c.encode(safe.state, forKey: .state)
        try c.encode(safe.started, forKey: .started)
        try c.encode(safe.updated, forKey: .updated)
        try c.encode(safe.seen, forKey: .seen)
        try c.encode(safe.pending, forKey: .pending)
        try c.encode(safe.pendingKinds, forKey: .pendingKinds)
        try c.encode(safe.pendingMatchKeys, forKey: .pendingMatchKeys)
        try c.encode(safe.lastEventIDs, forKey: .lastEventIDs)
        try c.encode(safe.provider, forKey: .provider)
        try c.encode(safe.fidelity, forKey: .fidelity)
        try c.encodeIfPresent(safe.progress, forKey: .progress)
        try c.encodeIfPresent(safe.expires, forKey: .expires)
        try c.encodeIfPresent(safe.recovered, forKey: .recovered)
        try c.encodeIfPresent(safe.officiallyEnded, forKey: .officiallyEnded)
        try c.encodeIfPresent(safe.projectPath, forKey: .projectPath)
        try c.encodeIfPresent(safe.verifiedEditorHost, forKey: .verifiedEditorHost)
        try c.encodeIfPresent(safe.verifiedTerminalHost, forKey: .verifiedTerminalHost)
        try c.encodeIfPresent(safe.terminalNavigation, forKey: .terminalNavigation)
        try c.encodeIfPresent(safe.editorOriginEvidence, forKey: .editorOriginEvidence)
        try c.encodeIfPresent(safe.editorFocusBlockReason, forKey: .editorFocusBlockReason)
        try c.encodeIfPresent(safe.editorFocusBlockTurnID, forKey: .editorFocusBlockTurnID)
        try c.encodeIfPresent(safe.providerAttention, forKey: .providerAttention)
        try c.encodeIfPresent(safe.codexOriginObservation, forKey: .codexOriginObservation)
        try c.encodeIfPresent(safe.unverifiedCodexCompletion, forKey: .unverifiedCodexCompletion)
        try c.encodeIfPresent(safe.runtime, forKey: .runtime)
        try c.encodeIfPresent(safe.capabilities, forKey: .capabilities)
        try c.encodeIfPresent(safe.requestSnapshots, forKey: .requestSnapshots)
    }
}

extension StateReducer {
    @discardableResult mutating func invalidateResponseChannel(_ identity: RequestIdentity) -> Bool {
        guard var session = sessions[identity.sessionID],
              let index = session.requestSnapshots?.firstIndex(where: { $0.identity == identity }) else { return false }
        session.capabilities?.responseChannelID = nil
        session.requestSnapshots?[index].expiresAt = nil
        if session.requestSnapshots?[index].lifecycle == .submitting || session.requestSnapshots?[index].lifecycle == .submitted {
            session.requestSnapshots?[index].lifecycle = .deliveryUnknown
        }
        // A helper lease ending is not evidence that the native prompt ended.
        sessions[identity.sessionID] = session
        return true
    }
}
