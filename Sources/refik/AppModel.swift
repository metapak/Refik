import RefikInteractionWire
import CoreGraphics
import AppKit
import Foundation
import UserNotifications
import ServiceManagement

struct Preferences: Codable {
    // Legacy global choice is retained for compatibility, never used for routing.
    var terminalApplication: TerminalApplicationPreference = .none
    var terminalApplications = SessionTerminalChoices()
    var mascot = "cute"
    var edge = "right"
    var opacity = 0.8
    var followEyes = true
    var hidden = false
    var vertical = 0.5
    var displayID: UInt32 = 0
    var preferredDisplayID: String? = nil
    var displayPositions: [String: DisplayPosition] = [:]
    var notifications = false
    var notifyCompleted = true
    var notifyWaiting = true
    var notifyFailed = true
    var sound = true
    var soundName = "Glass"
    var showDetails = false
    var remindersEnabled = false
    var reminderDelaySeconds: Double = 180
    var remindQuestions = true
    var remindPermissions = true
    var reminderSound = true
    var reminderBanner = false
}

extension Preferences {
    private enum CodingKeys: String, CodingKey { case terminalApplications, terminalApplication, mascot, edge, opacity, followEyes, hidden, vertical, displayID, preferredDisplayID, displayPositions, notifications, notifyCompleted, notifyWaiting, notifyFailed, sound, soundName, showDetails, remindersEnabled, reminderDelaySeconds, remindQuestions, remindPermissions, reminderSound, reminderBanner }
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalApplications = (try? c.decodeIfPresent(SessionTerminalChoices.self, forKey: .terminalApplications)) ?? SessionTerminalChoices()
        terminalApplication = (try? c.decodeIfPresent(TerminalApplicationPreference.self, forKey: .terminalApplication)) ?? .none
        mascot = try c.decodeIfPresent(String.self, forKey: .mascot) ?? mascot
        edge = try c.decodeIfPresent(String.self, forKey: .edge) ?? edge
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? opacity
        followEyes = try c.decodeIfPresent(Bool.self, forKey: .followEyes) ?? followEyes
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? hidden
        vertical = try c.decodeIfPresent(Double.self, forKey: .vertical) ?? vertical
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID) ?? displayID
        preferredDisplayID = try c.decodeIfPresent(String.self, forKey: .preferredDisplayID)
        displayPositions = try c.decodeIfPresent([String: DisplayPosition].self, forKey: .displayPositions) ?? displayPositions
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        notifyCompleted = try c.decodeIfPresent(Bool.self, forKey: .notifyCompleted) ?? notifyCompleted
        notifyWaiting = try c.decodeIfPresent(Bool.self, forKey: .notifyWaiting) ?? notifyWaiting
        notifyFailed = try c.decodeIfPresent(Bool.self, forKey: .notifyFailed) ?? notifyFailed
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? sound
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? soundName
        showDetails = try c.decodeIfPresent(Bool.self, forKey: .showDetails) ?? showDetails
        remindersEnabled = try c.decodeIfPresent(Bool.self, forKey: .remindersEnabled) ?? remindersEnabled
        reminderDelaySeconds = try c.decodeIfPresent(Double.self, forKey: .reminderDelaySeconds) ?? reminderDelaySeconds
        remindQuestions = try c.decodeIfPresent(Bool.self, forKey: .remindQuestions) ?? remindQuestions
        remindPermissions = try c.decodeIfPresent(Bool.self, forKey: .remindPermissions) ?? remindPermissions
        reminderSound = try c.decodeIfPresent(Bool.self, forKey: .reminderSound) ?? reminderSound
        reminderBanner = try c.decodeIfPresent(Bool.self, forKey: .reminderBanner) ?? reminderBanner
    }
}

struct UsageEntry: Identifiable {
    var id: String { "\(provider.rawValue):\(window)" }
    let provider: Provider
    let window: String
    let percent: Double
    let fidelity: Fidelity
    let expires: Date
    var semantic: UsageSemantic = .unknown
    var resetAt: Date? = nil
    func providerLabel(at now: Date) -> String {
        let countdown = UsageFormatting.resetCountdown(until: resetAt, at: now)
        return provider.label + (countdown.map { " · \($0)" } ?? "")
    }
    var valueLabel: String {
        guard semantic != .unknown else { return "Türetilmiş veri" }
        let weeklyUsed = window == UsageFormatting.duration(minutes: 10_080) && semantic == .used
        let value = weeklyUsed ? 100 - percent : percent
        return "\(fidelity == .derived ? "~" : "")%\(Int(value.rounded())) \(semantic == .used && !weeklyUsed ? "kullanıldı" : "kaldı")"
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var preferences: Preferences { didSet { if !preferences.remindersEnabled { reminders.cancelAll() }; persist(); onPreferences?() } }
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var aggregate: MascotState = .neutral
    @Published var integrationMessage = ""
    @Published var notificationPermission = "Bilinmiyor"
    @Published var launchMessage = ""
    @Published var cliConnection = "Kısıtlı destek"
    @Published var desktopConnection = "Kısıtlı destek"
    @Published var claudeConnection = "Kurulmadı"
    @Published var antigravityConnection = "Kurulmadı"
    @Published var commandLineMessage = ""
    @Published var diagnosticsMessage = ""
    @Published private(set) var usageWindows: [UsageEntry] = []
    @Published private(set) var usageUpdatedAt = Date()
    func currentUsageWindows(at date: Date = Date()) -> [UsageEntry] {
        usageWindows.filter { $0.expires > date }
    }
    func usageUnavailableMessage(at date: Date = Date()) -> String? {
        currentUsageWindows(at: date).isEmpty ? "Kullanım bilgisi bekleniyor" : nil
    }
    var onPreferences: (() -> Void)?
    var onState: (() -> Void)?
    private var reducer = StateReducer()
    private let integrations = IntegrationCoordinator()
    private var reminders = ReminderScheduler()
    private enum ObservationSource { case transcript, hook, openCode }
    private struct LiveObservation { let runtimeID: String; let source: ObservationSource }
    private var liveObservations: [RequestIdentity: LiveObservation] = [:]
    private var transcriptSourceRunning = false
    private var transcriptSourceHealthy = false
    private var hookSourceRunning = false
    private var openCodeSourceConnected = false
    private var requestChannels: [RequestIdentity: String] = [:]
    private var responseErrors: [RequestIdentity: String] = [:]
    private var openCodeAdapter: OpenCodeAdapter?
    private var openCodeConfiguration: OpenCodeConnectionConfiguration?
    private var openCodeCallbackGeneration = UUID()
    private let openCodeAdapterFactory: (OpenCodeConnectionConfiguration) throws -> OpenCodeAdapter
    private var openCodeSnapshot: OpenCodeConnectionSnapshot?
    private var agStatuslineAdapter = AntigravityStatuslineAdapter()
    private var agHookReceiver = AntigravityHookReceiver()
    private var vscodeHookReceiver = VSCodeHookReceiver()
    @Published private(set) var integrationStatuses: [ProviderIntegrationStatus] = []
    @Published var openCodeConnection = "Kapalı"

    private let stateURL: URL?
    var footer: String { reducer.attentionFooter }
    private func publish() {
        _ = reducer.migrateUnverifiedCodexCompletions(at: Date())
        editorFocusEligibility.observe(reducer, at: HookWire.uptime)
        sessions = reducer.visibleAttentionRows; aggregate = reducer.aggregate
        if let stateURL, let data = try? JSONEncoder().encode(reducer.persistenceSnapshot()) {
            try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: stateURL, options: .atomic)
        }
        onState?()
    }
    private var watcher: TranscriptWatcher?
    private var usageRoot: URL?
    private var bridge: HookBridge?
    private var reconciler: DesktopReconciler?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var expiryTimer: Timer?
    private var nativeAttentionTimer: Timer?
    private var nativeAttentionReader: NativeAttentionReader?
    private var projectFocusCorrelation = ProjectFocusCorrelation()
    private var projectFocusGeneration = UUID()
    private var projectFocusScanRunning = false
    private let editorFocusReceiver = EditorFocusReceiver()
    private var editorFocusManagedHosts = Set<String>()
    private var editorFocusEligibility = EditorFocusEligibility()
    private let editorFocusDiagnostic = EditorFocusDiagnostic()
    @Published var editorFocusMessage = "Otomatik proje bağlantısı kurulmadı"
    @Published var editorFocusInstalling = false
    private let projectFocusReader = ProjectFocusReader()
    private var nativeAttentionCorrelation = NativeAttentionCorrelation()
    private var liveSessionIDs = Set<String>()
    private let notifications: NotificationCoordinator

    init(inspectNotificationPermission: Bool = true, stateURL: URL? = nil, notificationCoordinator: NotificationCoordinator? = nil, openCodeAdapterFactory: ((OpenCodeConnectionConfiguration) throws -> OpenCodeAdapter)? = nil) {
        self.openCodeAdapterFactory = openCodeAdapterFactory ?? { try OpenCodeAdapter(configuration: $0) }
        notifications = notificationCoordinator ?? (inspectNotificationPermission ? NotificationCoordinator() : NotificationCoordinator(playSound: { _ in }, postBanner: { _ in }))
        self.stateURL = stateURL ?? (inspectNotificationPermission ? BridgePath.directory.appendingPathComponent("attention-state.json") : nil)
        if let url = self.stateURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(StateReducer.self, from: data) {
            reducer = saved
            reducer.markHistoricalRunningUnknown()
            reducer.expire(at: Date())
            _ = reducer.migrateUnverifiedCodexCompletions(at: Date())
            sessions = reducer.visibleAttentionRows; aggregate = reducer.aggregate
        }
        if let data = UserDefaults.standard.data(forKey: "refik.preferences"),
           let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        else { preferences = Preferences() }
        integrationMessage = HookInstaller.installed() ? "Hook kurulu · güven onayı gerekebilir" : "Yerel oturum kayıtları izleniyor · hook kurulmadı"
        claudeConnection = HookInstaller.installed(.claude) ? "Kurulu · canlı olay bekleniyor" : "Kurulmadı"
        antigravityConnection = HookInstaller.installed(.antigravity) ? "Kurulu · sınırlı destek" : "Kurulmadı"
        editorFocusEligibility.observe(reducer, at: HookWire.uptime)
        editorFocusManagedHosts = EditorFocusInstaller.managedHosts(receiptURL: BridgePath.directory.appendingPathComponent("editor-focus-installations.json"))
        if !editorFocusManagedHosts.isEmpty { editorFocusMessage = "Kurulum kaydı var · canlı editör bağlantısı bekleniyor" }
        refreshIntegrationStatuses()
        if inspectNotificationPermission { refreshPermission() }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "refik.preferences") }
    }
    private var claudeStartupRepairAttempted = false
    var claudeStartupRepair: () throws -> Bool = { try HookInstaller.repairExistingClaude() }
    func beginClaudeStartupRepair() {
        if !claudeStartupRepairAttempted {
            claudeStartupRepairAttempted = true
            let repair = claudeStartupRepair
            DispatchQueue.global(qos: .utility).async { [weak self] in
                do {
                    let changed = try repair()
                    if changed { DispatchQueue.main.async { [weak self] in
                        self?.integrationMessage = "Claude bağlantısı otomatik güncellendi"
                        self?.refreshIntegrationStatuses()
                    } }
                } catch { DispatchQueue.main.async { [weak self] in
                    self?.integrationMessage = "Claude bağlantısı güncellenemedi: \(error.localizedDescription) · Ayarlar’da Kur / onar ile kontrol edin"
                } }
            }
        }
    }
    private var codexIdentityRepairAttempted = false
    var codexIdentityStartupRepair: () throws -> Bool = { try HookInstaller.repairExistingCodexIdentityObservers() }
    func beginCodexIdentityStartupRepair() {
        guard !codexIdentityRepairAttempted else { return }
        codexIdentityRepairAttempted = true
        let repair = codexIdentityStartupRepair
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                if try repair() { DispatchQueue.main.async { [weak self] in
                    self?.integrationMessage = "Codex kaynak izleyicileri otomatik güncellendi"
                    self?.refreshIntegrationStatuses()
                } }
            } catch { DispatchQueue.main.async { [weak self] in
                self?.integrationMessage = "Codex kaynak izleyicileri güncellenemedi: \(error.localizedDescription)"
            } }
        }
    }
    func start() {
        beginClaudeStartupRepair()
        beginCodexIdentityStartupRepair()
        projectFocusGeneration = UUID(); projectFocusScanRunning = false
        let environment = ProcessInfo.processInfo.environment
        if environment["REFIK_TERMINAL_NAV_DIAGNOSTICS"] == "1" {
            let directory = BridgePath.directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let epoch = TerminalNavigationDiagnostic.arm(directory: directory) {
                TerminalNavigationDiagnostic.record(.init(.armed), directory: directory)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + TerminalNavigationDiagnostic.lifetime) {
                    TerminalNavigationDiagnostic.disarm(directory: directory, epoch: epoch)
                }
            }
        }
        // Explicit acceptance injection is enabled only with an isolated data dir.
        let observationRoot = LegacyMigration.isolated ? LegacyMigration.observationOverride : nil
        let codexRoot = (observationRoot ?? environment["CODEX_HOME"]).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let sessionsPath = codexRoot.appendingPathComponent("sessions")
        usageRoot = sessionsPath
        if !FileManager.default.isReadableFile(atPath: sessionsPath.path) {
            cliConnection = "Bağlantı kesildi"; desktopConnection = "Bağlantı kesildi"
        }
        watcher = TranscriptWatcher(root: sessionsPath) { [weak self] event, historical in
            DispatchQueue.main.async { self?.accept(event, historical: historical) }
        } onBootstrapDone: { [weak self] in
            DispatchQueue.main.async { self?.finishBootstrap() }
        } onHealth: { [weak self] healthy in
            DispatchQueue.main.async { self?.setConnectionHealthy(healthy) }
        } onEditorOrigin: { [weak self] event, proof in
            DispatchQueue.main.async {
                self?.associateEditorOrigin(proof, event: event)
            }
        } onEditorOriginBlocked: { [weak self] id, reason, turn in
            DispatchQueue.main.async {
                self?.observeEditorOriginBlock(id, reason: reason, turn: turn)
            }
        } onHistoricalEditorCompletion: { [weak self] proof, event in
            DispatchQueue.main.async { self?.recoverHistoricalEditorCompletion(proof, event: event) }
        } onNativeAsyncPendingRecovery: { [weak self] proof, requests in
            DispatchQueue.main.async { self?.recoverNativeAsyncPending(proof, requests: requests) }
        } onEditorOriginReplayed: { [weak self] event, proof in
            DispatchQueue.main.async {
                self?.reconcileReplayedEditorOrigin(proof, event: event)
            }
        } onEditorOriginTurnStarted: { [weak self] event, proof in
            DispatchQueue.main.async {
                self?.supersedeEditorOriginBlock(proof, event: event)
            }
        } onCLIQuestion: { [weak self] event, historical, proof in
            DispatchQueue.main.async { self?.accept(event, historical: historical, cliQuestionProof: proof) }
        } onCLIPendingRecovery: { [weak self] proof, requests in
            DispatchQueue.main.async {
                self?.recoverCLIPending(proof, requests: requests)
            }
        }
        transcriptSourceRunning = true; transcriptSourceHealthy = FileManager.default.isReadableFile(atPath: sessionsPath.path)
        watcher?.start()
        reconciler = DesktopReconciler(root: codexRoot) { [weak self] events in
            DispatchQueue.main.async { self?.reconcile(events) }
        }
        reconciler?.start()
        nativeAttentionReader = NativeAttentionReader(root: codexRoot)
        nativeAttentionCorrelation.reset()
        nativeAttentionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.expireUnverifiedCodexObservations(); self?.reconcileNativeAttention(at: Date()); self?.reconcileEditorFocus(); self?.reconcileProjectFocus(at: Date()) }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.reminders.cancelAll(); self?.reconciler?.reconcile() }
            })
        }
        let focusReceiver = editorFocusReceiver
        bridge = HookBridge(onInteraction: { [weak self] event, channel in
            DispatchQueue.main.async {
                guard let self, let bridge = self.bridge, let capabilities = event.capabilities,
                      let request = event.requestSnapshot else { return }
                self.integrations.register(capabilities, transport: bridge, runtime: event.runtime, requestIdentity: request.identity)
                self.requestChannels[request.identity] = channel
                var liveEvent = event
                liveEvent.requestSnapshot?.expiresAt = nil
                self.accept(liveEvent, historical: false)
                self.reconcileInteractionLiveness()
            }
        }, onInvalidation: { [weak self] identity in
            DispatchQueue.main.async { self?.invalidateInteraction(identity) }
        }, onAntigravityObservation: { [weak self] event, observation in
            DispatchQueue.main.async {
                guard let self else { return }
                for normalized in self.agHookReceiver.events(event, observation: observation) {
                    self.accept(normalized, historical: false)
                }
            }
        }, onVSCodeObservation: { [weak self] event, observation in
            DispatchQueue.main.async {
                guard let self else { return }
                for normalized in self.vscodeHookReceiver.events(event, observation: observation) {
                    self.accept(normalized, historical: false)
                }
            }
        }, onEditorFocus: { [weak self] epoch, host, observation, monotonic, date in
            focusReceiver.receive(epoch: epoch, host: host, observation: observation, at: monotonic, date: date)
            DispatchQueue.main.async {
                guard let self else { return }
                if observation != nil { self.editorFocusManagedHosts.insert(host.bundleID); self.editorFocusMessage = "Editör bağlantısı hazır · yerel tek proje odağı izleniyor" }
                else if !focusReceiver.hasConnection { self.editorFocusMessage = "Canlı editör bağlantısı bekleniyor" }
                self.reconcileEditorFocus()
            }
        }, onEvent: { [weak self] event in DispatchQueue.main.async { self?.accept(event, historical: false) } })
        hookSourceRunning = true
        bridge?.start()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.expire(at: Date())
            }
        }
    }
    func expire(at date: Date) {
        deliverReminders(at: date)
        usageUpdatedAt = date
        usageWindows.removeAll { $0.expires <= date }
        if reducer.expire(at: date) { reconcileInteractionLiveness(); publish() }
    }
    func stop() {
        projectFocusGeneration = UUID(); projectFocusScanRunning = false
        reminders.cancelAll(); liveObservations.removeAll()
        transcriptSourceRunning = false; transcriptSourceHealthy = false; hookSourceRunning = false; openCodeSourceConnected = false
        integrations.removeAll()
        if let adapter = openCodeAdapter { Task { await adapter.stop() } }; openCodeAdapter = nil
        watcher?.stop(); bridge?.stop(); reconciler?.stop(); expiryTimer?.invalidate()
        nativeAttentionTimer?.invalidate(); nativeAttentionReader = nil; nativeAttentionCorrelation.reset(); projectFocusCorrelation.reset(); editorFocusReceiver.reset()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
    }
    func reconcile(_ events: [CodexEvent]) {
        watcher?.reconcile()
        reducer.reconcilePresence(events)
        for event in events { accept(event, historical: false) }
        publish()
    }
    private var codexNativeTurnProofs: [String: CodexNativeTurnProof] = [:]
    func accept(_ input: CodexEvent, historical: Bool, trustedAdapterSnapshot: Bool = false, cliQuestionProof: CodexCLIQuestionProof? = nil) {
        var event = input
        if let target = event.terminalNavigation {
            let now = ProcessInfo.processInfo.systemUptime
            let rejection: TerminalNavigationDiagnostic.Stage?
            if historical { rejection = .mainHistorical }
            else if event.terminalNavigationIssuedAt.map({ now - $0 < 0 || now - $0 > 3 }) != false { rejection = .mainExpired }
            else if !TerminalNavigationOrigin.sourceCurrent(target) { rejection = .mainSourceInvalid }
            else { rejection = nil }
            TerminalNavigationDiagnostic.record(.init(rejection ?? .mainAccepted), directory: BridgePath.directory)
            if rejection != nil { event.terminalNavigation = nil }
        }
        if let proof = event.codexNativeTurnProof, proof.matches(event) {
            codexNativeTurnProofs[event.sessionID] = proof
            if codexNativeTurnProofs.count > 200 {
                let oldest = codexNativeTurnProofs.min { $0.value.started < $1.value.started }?.key
                if let oldest { codexNativeTurnProofs.removeValue(forKey: oldest) }
            }
        } else if event.provider == .codex, event.kind == .completed,
                  event.codexOriginObservation?.stage == .missingLocator,
                  let current = reducer.sessions[event.sessionID], current.turnID == event.turnID,
                  let proof = codexNativeTurnProofs[event.sessionID], proof.matches(event),
                  current.pending.isEmpty, ProjectIdentity.canonical(current.projectPath) == proof.projectPath,
                  current.started == proof.started || current.started.timeIntervalSince1970 == floor(proof.started.timeIntervalSince1970) {
            event.codexNativeTurnProof = proof; event.source = proof.source; event.runtime = proof.runtime
        }
        event.trustedInteractionSnapshot = trustedAdapterSnapshot
        if event.provider == .signal, let payload = event.antigravityStatusline {
            for normalized in agStatuslineAdapter.events(payload: payload, at: event.at) { accept(normalized, historical: historical) }
            return
        }
        if event.provider == .codex, event.kind == .started, event.codexNativeTurnProof == nil { codexNativeTurnProofs.removeValue(forKey: event.sessionID) }
        if let canonical = event.runtime?.canonicalSessionID { event.sessionID = canonical }
        if event.requestSnapshot?.turnScope == .hookInvocation { event.requestSnapshot?.expiresAt = nil }
        if event.provider == .opencode, let capabilities = event.capabilities, capabilities.responseChannelID == nil {
            openCodeSourceConnected = false
            integrations.remove(runtimeID: capabilities.runtimeID)
            for identity in liveObservations.keys where identity.runtimeID == capabilities.runtimeID { reminders.cancel(identity); liveObservations.removeValue(forKey: identity) }
            for identity in requestChannels.keys where identity.runtimeID == capabilities.runtimeID { reminders.cancel(identity); requestChannels.removeValue(forKey: identity) }
        }
        if event.provider != .antigravity, !(event.provider == .copilot && event.runtime?.host == .vscode), event.kind == .requestResolved, event.requestUpdate == nil, let id = event.requestID,
           let current = reducer.sessions[event.sessionID], current.turnID == event.turnID,
           let request = current.orderedRequests.first(where: { $0.id == id }),
           event.at >= request.observedAt {
            event.requestUpdate = RequestLifecycleUpdate(identity: request.identity, lifecycle: .resolved)
        }

        if event.kind == .usage {
            if let fraction = event.progress, let ttl = event.ttl, let title = event.title,
               (0...1).contains(fraction), (1...86_400).contains(ttl),
               event.at.addingTimeInterval(ttl) > Date(),
               event.resetAt.map({ $0.timeIntervalSince1970.isFinite && $0 > Date() }) ?? true {
                let expires = min(event.at.addingTimeInterval(ttl), event.resetAt ?? .distantFuture)
                let entry = UsageEntry(provider: event.provider, window: title, percent: fraction * 100,
                                       fidelity: event.fidelity, expires: expires, semantic: UsageSemantic(rawValue: event.detail ?? "") ?? .unknown, resetAt: event.resetAt)
                usageWindows.removeAll { $0.id == entry.id || $0.expires <= Date() }
                usageWindows.append(entry)
                usageUpdatedAt = Date()
            }
            return
        }
        if event.fidelity == .official { reconciler?.reconcile() }
        if reducer.associateProject(event) { publish() }
        if !historical, reducer.associateEditorHost(event) { publish() }
        // Bootstrap discovery may suppress newly found historical results, but
        // must preserve a result the user has already received and not seen.
        if historical, [.completed, .failed, .interrupted].contains(event.kind),
           let existing = reducer.sessions[event.sessionID], existing.turnID == event.turnID,
           [.completed, .failed, .interrupted].contains(existing.state) { return }
        let previous = reducer.sessions[event.sessionID]
        let promotesObservedCodexCompletion = previous?.unverifiedCodexCompletion?.turnID == event.turnID && event.codexNativeTurnProof?.matches(event) == true
        let structuredQuestion = event.fidelity == .derived && event.kind == .userQuestionObserved &&
            event.id.hasPrefix("rollout:") &&
            (event.requestID?.hasPrefix("[\"request_user_input_async\",") == true ||
             ((event.runtime?.host == .vscode || cliQuestionProof?.matches(event) == true) && event.requestID?.hasPrefix("[\"request_user_input\",") == true))
        if event.kind == .userQuestionObserved, event.runtime?.host == .terminal,
           (event.requestID?.hasPrefix("[\"request_user_input\",") == true || event.requestID?.hasPrefix("[\"request_user_input_async\",") == true),
           cliQuestionProof?.matches(event) != true { return }
        var candidate = reducer
        guard candidate.apply(event, allowUnverifiedWait: structuredQuestion, allowActivityResume: !historical) else { return }
        let evictedProvisional = reducer.sessions.values.contains {
            !$0.seen && $0.providerAttention != nil && candidate.sessions[$0.id] == nil
        }
        if evictedProvisional {
            // Capacity reuse must commit the retained full outcome before its
            // working slot disappears. A failed save leaves the prior state.
            guard commitDismissal(candidate) else { return }
        } else { reducer = candidate }
        if !historical && ([.started, .activity, .reconciledRunning].contains(event.kind)) { liveSessionIDs.insert(event.sessionID) }
        if historical && [.completed, .failed, .interrupted].contains(event.kind) && !promotesObservedCodexCompletion { reducer.markSeen([event.sessionID]) }
        if historical { reducer.markHistoricalRunningUnknown(except: liveSessionIDs) }
        publish()
        reconcileInteractionLiveness()
        refreshIntegrationStatuses()
        if !historical, let request = event.requestSnapshot, Date().timeIntervalSince(event.at) >= 0, Date().timeIntervalSince(event.at) < 5 {
            let source: ObservationSource = event.provider == .opencode ? .openCode :
                (event.provider == .codex && event.id.hasPrefix("rollout:") ? .transcript : .hook)
            liveObservations[request.identity] = LiveObservation(runtimeID: request.identity.runtimeID, source: source)
            reminders.observe(request, at: Date(), preferences: preferences)
        }
        if !historical, let current = reducer.sessions[event.sessionID],
           NotificationCoordinator.isNewAttention(event: event, previous: previous, current: current) {
            let generation = [.completed, .failed, .interrupted].contains(event.kind) ? current.updated : current.started
            notifications.transition(event: event, preferences: preferences, generation: generation)
        }
        if event.provider == .claude { claudeConnection = "Bağlı · olay alındı" }
        if event.provider == .antigravity { antigravityConnection = "Bağlı · bekleme olayı yok" }
    }

    func canSubmitResponse(_ request: PendingRequestSnapshot) -> Bool {
        guard request.expiresAt.map({ $0 > Date() }) ?? true,
              let session = reducer.sessions[request.identity.sessionID] else { return false }
        return integrations.transport(for: session, request: request) != nil
    }
    func responseError(for identity: RequestIdentity) -> String? { responseErrors[identity] }
    func resumeNativeResponse(_ identity: RequestIdentity) -> String? {
        guard identity.provider == .claude, let session = reducer.sessions[identity.sessionID],
              let request = session.orderedRequests.first(where: { $0.identity == identity }),
              canSubmitResponse(request), let channel = requestChannels[identity],
              let (_, registered) = integrations.transport(for: session, request: request), registered == channel,
              bridge?.resumeNative(channelID: channel, identity: identity) == true else {
            return "İstek artık etkin değil. Claude içinde devam edin."
        }
        requestChannels.removeValue(forKey: identity); integrations.remove(channelID: channel)
        reminders.cancel(identity)
        // Returning the hook without a decision releases the native prompt;
        // it is not an answer and the observed wait remains pending.
        if reducer.invalidateResponseChannel(identity) { publish(); refreshIntegrationStatuses() }
        return nil
    }
    // Test and adapter entry point: a capability claim alone never creates a route.
    func registerInteractionTransport(_ transport: InteractionResponseTransport, capabilities: RuntimeCapabilities) {
        integrations.register(capabilities, transport: transport)
    }
    func submitResponse(_ response: InteractionResponse) async -> InteractionSubmissionResult {
        let identity = response.identity
        guard let session = reducer.sessions[identity.sessionID],
              let request = session.orderedRequests.first(where: { $0.identity == identity }),
              canSubmitResponse(request), response.isValid(for: request),
              let (transport, channel) = integrations.transport(for: session, request: request) else {
            return InteractionSubmissionResult(lifecycle: nil, errorMessage: "İstek artık yanıtlanabilir değil. Sağlayıcıda devam edin.")
        }
        responseErrors.removeValue(forKey: identity); reminders.cancel(identity)
        updateInteraction(request, lifecycle: .submitting)
        do {
            let receipt = try await transport.submit(response, channelID: channel)
            guard receipt.identity == identity else { throw CocoaError(.validationMissingMandatoryProperty) }
            guard let current = reducer.sessions[identity.sessionID]?.orderedRequests.first(where: { $0.identity == identity }),
                  [.submitting, .submitted, .deliveryUnknown].contains(current.lifecycle) else {
                return InteractionSubmissionResult(lifecycle: reducer.sessions[identity.sessionID]?.orderedRequests.first(where: { $0.identity == identity })?.lifecycle,
                                                   errorMessage: nil)
            }
            guard [.submitted, .deliveryUnknown, .accepted, .resolved, .canceled, .expired].contains(receipt.lifecycle) else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            updateInteraction(current, lifecycle: receipt.lifecycle)
            return InteractionSubmissionResult(lifecycle: receipt.lifecycle, errorMessage: receipt.lifecycle == .deliveryUnknown ? "Teslim doğrulanamadı. Sağlayıcıda kontrol edin." : nil)
        } catch {
            if let current = reducer.sessions[identity.sessionID]?.orderedRequests.first(where: { $0.identity == identity }),
               current.lifecycle == .submitting {
                updateInteraction(current, lifecycle: .deliveryUnknown)
                responseErrors[identity] = "Teslim doğrulanamadı. Yeniden göndermeden sağlayıcıda kontrol edin."
                publish()
            }
            return InteractionSubmissionResult(lifecycle: .deliveryUnknown, errorMessage: responseErrors[identity] ?? "İstek değişti. Sağlayıcıda devam edin.")
        }
    }
    private func updateInteraction(_ request: PendingRequestSnapshot, lifecycle: RequestLifecycle) {
        let identity = request.identity
        let event = CodexEvent(sessionID: identity.sessionID, turnID: identity.turnID, requestID: identity.requestID,
            kind: .requestResolved, source: .unknown, title: nil, at: Date(), id: UUID().uuidString,
            provider: identity.provider, requestUpdate: RequestLifecycleUpdate(identity: identity, lifecycle: lifecycle), requestTurnScope: request.turnScope)
        accept(event, historical: false)
    }
    private func invalidateInteraction(_ identity: RequestIdentity) {
        if let channel = requestChannels.removeValue(forKey: identity) { integrations.remove(channelID: channel) }
        reminders.cancel(identity)
        if reducer.invalidateResponseChannel(identity) { publish(); refreshIntegrationStatuses() }
    }
    private func reconcileInteractionLiveness() {
        for identity in liveObservations.keys {
            guard let session = reducer.sessions[identity.sessionID], session.pending.contains(identity.requestID),
                  session.orderedRequests.contains(where: { $0.identity == identity && $0.lifecycle == .pending }) else {
                liveObservations.removeValue(forKey: identity); reminders.cancel(identity); continue
            }
        }
        for (identity, channel) in requestChannels {
            guard let session = reducer.sessions[identity.sessionID],
                  let request = session.orderedRequests.first(where: { $0.identity == identity }),
                  session.pending.contains(request.id), [.pending, .submitting, .submitted, .deliveryUnknown].contains(request.lifecycle) else {
                requestChannels.removeValue(forKey: identity); reminders.cancel(identity)
                if identity.provider != .opencode { bridge?.resumeNative(channelID: channel); integrations.remove(channelID: channel) }
                continue
            }
        }
    }
    private func sameOpenCodeConfiguration(_ lhs: OpenCodeConnectionConfiguration, _ rhs: OpenCodeConnectionConfiguration, retainMissingPassword: Bool = false) -> Bool {
        func endpoint(_ url: URL) -> String {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.scheme = c.scheme?.lowercased(); c.host = c.host?.lowercased(); c.path = "/"
            if c.port == nil { c.port = c.scheme == "https" ? 443 : 80 }
            return c.string ?? ""
        }
        return endpoint(lhs.serverURL) == endpoint(rhs.serverURL) &&
            URL(fileURLWithPath: lhs.projectDirectory).standardizedFileURL.path == URL(fileURLWithPath: rhs.projectDirectory).standardizedFileURL.path &&
            lhs.host == rhs.host && lhs.username == rhs.username &&
            ((retainMissingPassword && rhs.password == nil) || (lhs.password == rhs.password && lhs.timeout == rhs.timeout))
    }
    // An empty form field can explicitly reconnect the retained same-target
    // configuration. Credentials never cross endpoint/project/host/username.
    func configureOpenCode(_ configuration: OpenCodeConnectionConfiguration?, retainExistingCredentialsIfSameTarget: Bool = false) async -> String? {
        if let configuration {
            do { try configuration.validate() }
            catch { return "Bağlantı yapılandırması geçersiz" }
        }
        openCodeCallbackGeneration = UUID()
        let callbackGeneration = openCodeCallbackGeneration
        let reusable = configuration.flatMap { candidate in
            openCodeConfiguration.map { sameOpenCodeConfiguration($0, candidate, retainMissingPassword: retainExistingCredentialsIfSameTarget) } == true ? openCodeAdapter : nil
        }
        if let old = openCodeAdapter {
            let snapshot = await old.snapshot(); integrations.remove(runtimeID: snapshot.runtimeID)
            for identity in requestChannels.keys where identity.runtimeID == snapshot.runtimeID { requestChannels.removeValue(forKey: identity); reminders.cancel(identity) }
            await old.stop()
        }
        if configuration != nil { openCodeAdapter = reusable }
        openCodeSnapshot = nil; openCodeSourceConnected = false
        for identity in liveObservations.keys where identity.provider == .opencode { reminders.cancel(identity); liveObservations.removeValue(forKey: identity) }
        guard let configuration else {
            // Keep the stopped same-configuration actor in memory so explicit
            // Disconnect/Reconnect retains native generations and resend locks.
            openCodeConnection = "Kapalı"; refreshIntegrationStatuses(); return nil
        }
        do {
            let adapter = try reusable ?? openCodeAdapterFactory(configuration)
            if reusable == nil { openCodeConfiguration = configuration }
            openCodeAdapter = adapter; openCodeConnection = "Bağlanıyor · canlı doğrulama bekleniyor"
            await adapter.start { [weak self, weak adapter] event in
                Task { @MainActor in
                    guard let self, let adapter, self.openCodeAdapter === adapter, self.openCodeCallbackGeneration == callbackGeneration else { return }
                    let snapshot = await adapter.snapshot()
                    guard self.openCodeAdapter === adapter, self.openCodeCallbackGeneration == callbackGeneration else { return }
                    if event.capabilities?.responseChannelID != snapshot.channelID {
                        guard !snapshot.connected else { return }
                        var observed = event; observed.capabilities?.responseChannelID = nil
                        self.openCodeSnapshot = snapshot; self.openCodeSourceConnected = false
                        self.accept(observed, historical: false, trustedAdapterSnapshot: true)
                        self.openCodeConnection = "Bağlantı kesildi · bekleyen isteklerin sonucu doğrulanmadı"
                        self.refreshIntegrationStatuses()
                        return
                    }
                    self.openCodeSnapshot = snapshot
                    if let capabilities = event.capabilities {
                        self.integrations.register(capabilities, transport: adapter, runtime: event.runtime)
                        if let request = event.requestSnapshot, let channel = capabilities.responseChannelID { self.requestChannels[request.identity] = channel }
                    }
                    self.openCodeSourceConnected = event.capabilities?.responseChannelID != nil
                    self.accept(event, historical: false, trustedAdapterSnapshot: true)
                    self.openCodeConnection = event.capabilities?.responseChannelID == nil ? "Bağlantı kesildi · bekleyen isteklerin sonucu doğrulanmadı" : "Bağlı · sürüm ve yerel API doğrulandı"
                    self.refreshIntegrationStatuses()
                }
            }
            refreshIntegrationStatuses(); return nil
        } catch { openCodeConfiguration = nil; openCodeConnection = "Bağlantı yapılandırması geçersiz"; refreshIntegrationStatuses(); return openCodeConnection }
    }
    func canSelectOpenCodeSession(_ session: Session) -> Bool {
        guard session.provider == .opencode, openCodeAdapter != nil, openCodeSourceConnected,
              let snapshot = openCodeSnapshot, snapshot.connected, snapshot.canSelectSession,
              session.runtime?.id == snapshot.runtimeID, let version = snapshot.version,
              session.runtime?.version == version else { return false }
        return integrations.hasLiveChannel(provider: .opencode, runtimeID: snapshot.runtimeID, version: version, capability: .openSession)
    }
    func selectOpenCodeSession(_ session: Session) async -> String? {
        guard canSelectOpenCodeSession(session), let adapter = openCodeAdapter,
              let current = reducer.sessions[session.id], current.runtime == session.runtime else {
            return "Oturum seçme kanalı doğrulanmadı. OpenCode içinde devam edin."
        }
        do {
            try await adapter.selectSession(sessionID: session.id)
            return nil
        } catch { return "Oturum seçimi doğrulanamadı. OpenCode içinde devam edin." }
    }
    private func refreshIntegrationStatuses() {
        integrationStatuses = [Provider.codex, .claude, .antigravity, .opencode, .cursor, .copilot, .windsurf].map { provider in
            let current = reducer.sessions.values.first { $0.provider == provider && $0.capabilities != nil }
            let live = current?.orderedRequests.contains { canSubmitResponse($0) } == true
            let capabilities = current?.capabilities?.evidence.map { evidence in
                CapabilityEvidence(capability: evidence.capability, support: live ? evidence.support : (evidence.support == .live ? .documented : evidence.support), source: evidence.source)
            } ?? []
            let installed = [.codex, .claude, .antigravity].contains(provider) ? HookInstaller.installed(provider) : false
            return ProviderIntegrationStatus(provider: provider, installed: installed, version: current?.runtime?.version,
                host: current?.runtime?.host ?? .unknown, capabilities: capabilities,
                message: provider == .opencode ? openCodeConnection : (live ? "Canlı istek kanalı doğrulandı" : "Canlı yanıt kanalı doğrulanmadı · sağlayıcıda devam edin"))
        }
    }
    private func deliverReminders(at now: Date) {
        let due = reminders.due(at: now, preferences: preferences) { request in
            guard let session = reducer.sessions[request.identity.sessionID], session.pending.contains(request.id),
                  let current = session.orderedRequests.first(where: { $0.identity == request.identity }), current.lifecycle == .pending,
                  current.expiresAt.map({ $0 > now }) ?? true else { return false }
            guard let observation = liveObservations[request.identity], observation.runtimeID == current.identity.runtimeID else { return false }
            switch observation.source {
            case .transcript: return transcriptSourceRunning && transcriptSourceHealthy
            case .hook: return hookSourceRunning
            case .openCode: return openCodeSourceConnected
            }
        }
        for request in due { notifications.reminder(request: request, preferences: preferences) }
    }
    private func finishBootstrap() {
        reducer.markHistoricalRunningUnknown(except: liveSessionIDs)
        reconciler?.reconcile()
        publish()
    }
    private func setConnectionHealthy(_ healthy: Bool) {
        transcriptSourceHealthy = healthy
        if !healthy {
            for (identity, observation) in liveObservations where observation.source == .transcript { reminders.cancel(identity); liveObservations.removeValue(forKey: identity) }
        }
        if healthy { reconciler?.reconcile() }
        let status = healthy ? "Kısıtlı destek" : "Bağlantı kesildi"
        cliConnection = status; desktopConnection = status
        if !healthy { integrationMessage = "Yerel Codex kayıtları okunamıyor" }
        else if integrationMessage == "Yerel Codex kayıtları okunamıyor" {
            integrationMessage = HookInstaller.installed() ? "Hook kurulu · güven onayı gerekebilir" : "Yerel oturum kayıtları izleniyor · hook kurulmadı"
        }
    }
    func recoverHistoricalEditorCompletion(_ proof: CodexEditorOriginProof, event: CodexEvent) {
        guard reducer.recoverHistoricalEditorCompletion(proof, event: event) else { return }
        publish()
    }
    func supersedeEditorOriginBlock(_ proof: CodexEditorOriginProof, event: CodexEvent) {
        guard reducer.supersedeEditorOriginBlock(proof, event: event) else { return }
        publish()
    }
    func associateEditorOrigin(_ proof: CodexEditorOriginProof, event: CodexEvent) {
        guard reducer.associateEditorOrigin(proof, event: event) else { return }
        publish()
    }
    func recoverCLIPending(_ proof: CodexCLIQuestionProof, requests: [PendingRequestSnapshot]) {
        guard proof.fileStillValid, reducer.recoverCLIPending(proof, requests: requests) else { return }
        publish()
    }
    func recoverNativeAsyncPending(_ proof: CodexEditorOriginProof, requests: [PendingRequestSnapshot]) {
        guard reducer.recoverNativeAsyncPending(proof, requests: requests) else { return }
        publish()
    }
    func observeEditorOriginBlock(_ id: String, reason: EditorFocusBlockReason, turn: String) {
        guard reducer.revokeEditorOrigin(id, reason: reason, turnID: turn) else { return }
        publish()
    }
    func reconcileReplayedEditorOrigin(_ proof: CodexEditorOriginProof, event: CodexEvent) {
        guard reducer.reconcileReplayedEditorOrigin(proof, event: event) else { return }
        publish()
    }
    func markSeen(_ ids: Set<String>) {
        reducer.markSeen(ids); publish()
    }
    private func expireUnverifiedCodexObservations() {
        if reducer.expireUnverifiedCodexCompletions(at: Date()) { publish() }
    }
    private func reconcileNativeAttention(at now: Date) {
        guard let reader = nativeAttentionReader else { return }
        let snapshot = reader.snapshot(now: now)
        let verified = snapshot == nil ? [] : reader.verifiedCompletions(reducer.providerAttentionCandidates, rolloutProofs: watcher?.completionProofs() ?? [])
        let currentProofs = watcher?.completionProofs() ?? []
        let completions = verified.filter { completion in
            completion.proofGeneration == nil || currentProofs.contains { completion.matches($0) }
        }
        let appliedAt = Date()
        let observations = NativeAttentionMirror.observations(snapshot, completions: completions, at: appliedAt)
        // Main-actor provider mirror and reducer recheck are one synchronous step;
        // queued transcript events cannot replace the turn between these calls.
        reconcileProviderAttention(observations, at: appliedAt)
    }
    func configureEditorFocus(_ enabled: Bool) {
        guard !editorFocusInstalling else { return }
        editorFocusInstalling = true
        editorFocusMessage = "Editör bağlantıları hazırlanıyor"
        let archive = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RefikEditorFocus.vsix")
        let receipts = BridgePath.directory.appendingPathComponent("editor-focus-installations.json")
        Task {
            let message = await Task.detached { EditorFocusInstaller.configure(enabled: enabled, archive: archive, receiptURL: receipts) }.value
            editorFocusMessage = message; editorFocusInstalling = false
            editorFocusManagedHosts = EditorFocusInstaller.managedHosts(receiptURL: receipts)
            if !enabled { editorFocusReceiver.reset() }
        }
    }
    var projectFocusPermissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    func requestProjectFocusPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }
    private func reconcileEditorFocus() {
        let qaID = editorFocusDiagnostic.target?.sessionID ?? ""
        let qaHost = editorFocusDiagnostic.target?.host
        let qaProject = editorFocusDiagnostic.enabled ? editorFocusDiagnostic.target?.project : nil
        var qaEligible = false, candidateProjectMatches = false, commitResult = false
        let diagnose: ((EditorFocusReceiver.Diagnostic) -> Void)? = editorFocusDiagnostic.enabled ? { snapshot in
            let qa = self.reducer.sessions[qaID]
            self.editorFocusDiagnostic.record(.init(receiver: snapshot,
                cursorForeground: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.todesktop.230313mzl4w4u92",
                qaTerminal: qa.map { [.completed, .failed, .interrupted].contains($0.state) } ?? false,
                qaOriginMatches: qaHost != nil && qa?.focusEditorHost == qaHost,
                qaProjectMatches: qaProject != nil && qa?.projectPath == qaProject,
                qaEligible: qaEligible, candidateProjectMatches: candidateProjectMatches,
                qaSeen: qa?.seen ?? false,
                foregroundHostMatch: qaHost != nil && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == qaHost,
                leaseFresh: qaHost.map { (snapshot.liveHosts[$0] ?? 0) > 0 } ?? false,
                generationMatch: qaEligible, commitResult: commitResult), at: HookWire.uptime)
        } : nil
        editorFocusReceiver.acknowledge(at: HookWire.uptime, foreground: { host in
            guard let app = NSWorkspace.shared.frontmostApplication else { return false }
            return app.processIdentifier == host.pid && app.bundleIdentifier == host.bundleID
        }, diagnose: diagnose, commit: { proof in
            var candidate = reducer
            let eligible = editorFocusEligibility.eligible(afterChallenge: proof.issuedMonotonic)
            if let qa = reducer.sessions[qaID] { qaEligible = eligible.contains(EditorFocusTerminalGeneration(qa)) }
            candidateProjectMatches = qaProject != nil && proof.project == qaProject
            guard candidate.dismissProject(proof.project, at: Date(), observedAt: proof.observedAt,
                                           editorHost: proof.host.bundleID,
                                           eligibleEditorGenerations: eligible) else { return false }
            commitResult = commitDismissal(candidate, notify: false)
            return commitResult
        }, afterCommit: { publish() })
    }
    private func reconcileProjectFocus(at now: Date) {
        guard !projectFocusScanRunning, EditorFocusReceiver.permitsLegacyReader(
            foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            managedHosts: editorFocusManagedHosts) else { return }
        projectFocusScanRunning = true
        let generation = projectFocusGeneration
        let reader = projectFocusReader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let observation = reader.observation()
            DispatchQueue.main.async {
                guard let self, self.projectFocusGeneration == generation else { return }
                self.projectFocusScanRunning = false
                guard EditorFocusReceiver.permitsLegacyReader(foregroundBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, managedHosts: self.editorFocusManagedHosts),
                      Date().timeIntervalSince(now) < 3, let observation, reader.isCurrent(observation),
                      let path = self.projectFocusCorrelation.observe(observation, at: now) else { return }
                self.dismissProject(path, at: Date(), observedAt: observation.observedAt)
            }
        }
    }
    func dismissProject(_ path: String, at now: Date, observedAt: Date? = nil) {
        var candidate = reducer
        guard candidate.dismissProject(path, at: now, observedAt: observedAt) else { return }
        commitDismissal(candidate)
    }
    @discardableResult private func commitDismissal(_ candidate: StateReducer, notify: Bool = true) -> Bool {
        if let stateURL {
            do {
                let data = try JSONEncoder().encode(candidate.persistenceSnapshot())
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: stateURL, options: .atomic)
            } catch { return false }
        }
        reducer = candidate
        if notify { publish() }
        return true
    }
    func dismissNative(_ dismissed: [NativeCompletion], at now: Date) {
        var candidate = reducer
        guard candidate.dismissNative(dismissed, at: now) else { return }
        // Both acknowledgment routes persist outcome and seen state together.
        commitDismissal(candidate)
    }
    func reconcileProviderAttention(_ observations: [ProviderAttentionObservation], at now: Date) {
        var candidate = reducer
        guard candidate.reconcileProviderAttention(observations, at: now) else { return }
        // Full outcome archive and reversible disposition commit atomically.
        commitDismissal(candidate)
    }
    func terminalChoice(for session: Session) -> TerminalApplicationPreference {
        preferences.terminalApplications.choice(for: session)
    }
    func setTerminalChoice(_ choice: TerminalApplicationPreference, for session: Session, validatedReceipt: TerminalApplicationPreference.Receipt? = nil) {
        guard choice == .none || (validatedReceipt.map { choice.sourceMatches($0) } ?? (choice.validated() != nil)) else { return }
        var choices = preferences.terminalApplications
        guard choices.set(choice, for: session) else { return }
        preferences.terminalApplications = choices
    }
    func clearTerminalChoices() { preferences.terminalApplications = SessionTerminalChoices() }
    func open(_ session: Session, issue: (SessionRoute) -> Bool) {
        let route = SessionRouting.route(for: session, terminalPreference: terminalChoice(for: session))
        // Public URL dispatch acknowledges delivery, not native navigation or
        // question resolution. Only actual focus proof/manual Seen can do that.
        _ = issue(route)
    }
    func refreshUsage() {
        let root = usageRoot ?? (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).appendingPathComponent("sessions")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = CodexUsageReader.events(in: root)
            DispatchQueue.main.async { for event in events { self?.accept(event, historical: false) } }
        }
    }
    func setNotifications(_ enabled: Bool) {
        preferences.notifications = enabled
        if enabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshPermission() }
            }
        }
    }
    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.notificationPermission = switch settings.authorizationStatus {
                case .authorized, .provisional: "İzin verildi"
                case .denied: "İzin reddedildi · Sistem Ayarları'ndan değiştirin"
                default: "İzin istenmedi"
                }
            }
        }
    }
    func setIntegration(_ enabled: Bool) {
        setIntegration(enabled, provider: .codex)
    }
    func setIntegration(_ enabled: Bool, provider: Provider) {
        do {
            let directClaude = try HookInstaller.setExplicitlyEnabled(enabled, provider: provider)
            let message = enabled ? "\(provider.label) hook kuruldu" : "\(provider.label) hook kaldırıldı"
            integrationMessage = provider == .codex && enabled ? message + " · Codex /hooks içinde güven onayı verin" : message
            if provider == .claude { claudeConnection = enabled ? (directClaude ? "Kurulu · doğrudan yanıt için canlı soru bekleniyor" : "Kurulu · durum takibi; doğrudan yanıt sürümü doğrulanamadı") : "Kurulmadı" }
            if provider == .antigravity { antigravityConnection = enabled ? "Kurulu · sınırlı destek" : "Kurulmadı" }
        } catch { integrationMessage = "Entegrasyon değiştirilemedi: \(error.localizedDescription)" }
    }
    func setCommandLine(_ enabled: Bool) {
        let manager = FileManager.default
        let stable = BridgePath.directory.appendingPathComponent("refik")
        let link = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/refik")
        do {
            if enabled {
                let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikCLI")
                guard manager.isExecutableFile(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                try manager.createDirectory(at: BridgePath.directory, withIntermediateDirectories: true)
                try Data(contentsOf: source).write(to: stable, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stable.path)
                try manager.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
                if manager.fileExists(atPath: link.path) || (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
                    guard (try? manager.destinationOfSymbolicLink(atPath: link.path)) == stable.path else { throw CocoaError(.fileWriteFileExists) }
                    try manager.removeItem(at: link)
                }
                try manager.createSymbolicLink(at: link, withDestinationURL: stable)
                commandLineMessage = "Kuruldu: \(link.path)"
            } else {
                if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == stable.path { try manager.removeItem(at: link) }
                commandLineMessage = "Komut bağlantısı kaldırıldı"
            }
        } catch { commandLineMessage = "Komut kurulamadı: \(error.localizedDescription)" }
    }
    func exportDiagnostics() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let states = Dictionary(grouping: sessions, by: { $0.state.rawValue }).mapValues(\.count)
        let text = "refik \(version)\nCodex hooks: \(HookInstaller.installed(.codex))\nClaude hooks: \(HookInstaller.installed(.claude))\nAntigravity hooks: \(HookInstaller.installed(.antigravity))\nState counts: \(states)\nNotification permission: \(notificationPermission)\n"
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let file = desktop.appendingPathComponent("refik-diagnostics-\(UUID().uuidString.prefix(8)).txt")
        do { try Data(text.utf8).write(to: file, options: .atomic); diagnosticsMessage = "Kaydedildi: \(file.path)" }
        catch { diagnosticsMessage = "Tanı raporu kaydedilemedi: \(error.localizedDescription)" }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchMessage = enabled ? "Oturum açılışında başlatma etkin" : "Oturum açılışında başlatma kapalı"
        } catch { launchMessage = "Başlatma ayarı uygulanamadı: \(error.localizedDescription)" }
    }
    func testSound() {
        NotificationAudio.play(preferences.soundName)
    }
}

// App audio is independent of macOS banner authorization. Retain each sound
// until playback finishes rather than releasing the temporary NSSound object.
final class NotificationAudio {
    private static var active: [NSSound] = []
    static func play(_ name: String) {
        let safeName = ["Glass", "Pop", "Tink"].contains(name) ? name : "Glass"
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Sounds/\(safeName).wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        active.removeAll { !$0.isPlaying }
        if sound.play() { active.append(sound) }
    }
}

final class NotificationCoordinator {
    private var delivered = Set<String>()
    private let playSound: (String) -> Void
    private let postBanner: (UNNotificationRequest) -> Void
    init(playSound: @escaping (String) -> Void = NotificationAudio.play,
         postBanner: @escaping (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }) {
        self.playSound = playSound; self.postBanner = postBanner
    }
    static func isNewAttention(event: CodexEvent, previous: Session?, current: Session) -> Bool {
        switch event.kind {
        case .permissionObserved, .userQuestionObserved:
            guard let request = event.requestID else { return false }
            return current.pending.contains(request) &&
                (previous?.turnID != current.turnID || previous?.pending.contains(request) != true)
        case .completed, .failed, .interrupted:
            return current.requestsResultAttention &&
                (previous?.turnID != current.turnID || previous?.state != current.state)
        default: return false
        }
    }
    func reminder(request: PendingRequestSnapshot, preferences: Preferences) {
        if preferences.reminderSound { playSound(preferences.soundName) }
        guard preferences.reminderBanner else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.identity.provider.label) yanıt bekliyor"
        content.body = "Bekleyen isteği refik panelinden veya sağlayıcıdan kontrol edin"
        postBanner(UNNotificationRequest(identifier: "reminder:" + request.identity.generation, content: content, trigger: nil))
    }
    func claim(event: CodexEvent, preferences: Preferences, generation: Date? = nil) -> Bool {
        let relevant = (event.kind == .completed && preferences.notifyCompleted) ||
            ((event.kind == .permissionObserved || event.kind == .userQuestionObserved) && preferences.notifyWaiting) ||
            ((event.kind == .failed || event.kind == .interrupted) && preferences.notifyFailed)
        guard relevant else { return false }
        // Event transport IDs may differ between hook and transcript replay.
        // The request or terminal turn generation is the notification identity.
        let attention = event.requestID.map { "request:\($0)" } ?? "terminal:\(event.kind.rawValue)"
        let key = [event.provider.rawValue, event.sessionID, event.turnID,
                   generation.map { String($0.timeIntervalSince1970) } ?? "", attention]
        let identity = String(data: try! JSONEncoder().encode(key), encoding: .utf8)!
        guard delivered.insert(identity).inserted else { return false }
        return preferences.sound || preferences.notifications
    }
    func transition(event: CodexEvent, preferences: Preferences, generation: Date? = nil) {
        guard claim(event: event, preferences: preferences, generation: generation) else { return }
        if preferences.sound { playSound(preferences.soundName) }
        guard preferences.notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = event.kind == .completed ? "\(event.provider.label) işi tamamlandı" :
            (event.kind == .permissionObserved || event.kind == .userQuestionObserved ? "\(event.provider.label) seni bekliyor" : "\(event.provider.label) işi başarısız")
        content.body = preferences.showDetails ? (event.title ?? "İş") : "refik panelinde ayrıntılara bakın"
        content.userInfo = ["sessionID": event.sessionID]
        // Builtin playback owns audio; banners never play a second sound.
        postBanner(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }
}
