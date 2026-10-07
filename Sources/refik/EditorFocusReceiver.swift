import Foundation
import RefikInteractionWire

final class EditorFocusReceiver: @unchecked Sendable {
    struct Proof {
        let host: EditorHostBinding
        let project: String
        let observedAt: Date
        let issuedMonotonic: Double
    }
    private struct Entry {
        let epoch: String, host: EditorHostBinding, observation: EditorFocusObservation
        let received: Double, date: Date
    }
    private let lock = NSLock()
    private var retiredEpochs: Set<String> = []
    private var entries: [String: Entry] = [:]
    func receive(epoch: String, host: EditorHostBinding, observation: EditorFocusObservation?, at monotonic: Double, date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard UUID(uuidString: epoch) != nil, monotonic.isFinite else { return }
        guard let observation else { entries.removeValue(forKey: epoch); return }
        guard !retiredEpochs.contains(epoch), retiredEpochs.count < 256, observation.isValid, entries.count < 32 || entries[epoch] != nil else { return }
        if let old = entries[epoch] {
            guard old.host == host, old.observation.windowID == observation.windowID,
                  old.observation.generation == observation.generation, observation.sequence > old.observation.sequence else { return }
        }
        // One activation can reconnect after a broken channel. The new epoch
        // supersedes only that exact window/generation with a newer sequence.
        let matches = entries.filter { $0.value.host == host && $0.value.observation.windowID == observation.windowID }
        for (key, old) in matches where key != epoch {
            guard old.observation.generation == observation.generation,
                  observation.sequence > old.observation.sequence else { return }
        }
        for key in matches.keys where key != epoch { entries.removeValue(forKey: key); retiredEpochs.insert(key) }
        entries[epoch] = Entry(epoch: epoch, host: host, observation: observation, received: monotonic, date: date)
    }
    struct Diagnostic: Codable {
        var reason = "no-fresh-focused-window"
        var liveHosts: [String: Int] = [:]
        var foregroundWindows = 0
        var cursorLeaseAge: Double?
    }
    @discardableResult func withProof(at monotonic: Double, foreground: (EditorHostBinding) -> Bool,
                                     currentHost: (EditorHostBinding) -> Bool = EditorFocusHost.isCurrent,
                                     diagnose: ((Diagnostic) -> Void)? = nil,
                                     commit: (Proof) -> Bool) -> Bool {
        lock.lock()
        var diagnostic = Diagnostic()
        defer { lock.unlock(); diagnose?(diagnostic) }
        let live = entries.values.filter { monotonic >= $0.received && monotonic - $0.received < 5 && $0.observation.focused }
        for entry in live { diagnostic.liveHosts[entry.host.bundleID, default: 0] += 1 }
        diagnostic.cursorLeaseAge = entries.values.filter { $0.host.bundleID == "com.todesktop.230313mzl4w4u92" }.map { monotonic - $0.received }.filter(\.isFinite).min()
        // Window focus in another editor process is not ambiguity within the
        // independently verified foreground application and launch identity.
        let selected = live.filter { foreground($0.host) && currentHost($0.host) }
        diagnostic.foregroundWindows = selected.count
        diagnostic.reason = selected.isEmpty ? "no-verified-foreground-window" : "ambiguous-foreground-windows"
        guard selected.count == 1, let entry = selected.first else { return false }
        diagnostic.reason = "invalid-project"
        guard let root = ProjectIdentity.canonical(entry.observation.projectPath) else { return false }
        diagnostic.reason = "foreground-or-launch-changed"
        guard currentHost(entry.host), foreground(entry.host) else { return false }
        let result = commit(Proof(host: entry.host, project: root, observedAt: entry.date, issuedMonotonic: entry.received))
        diagnostic.reason = result ? "committed" : "commit-refused"
        return result
    }
    @discardableResult func acknowledge(at monotonic: Double, foreground: (EditorHostBinding) -> Bool,
                                       currentHost: (EditorHostBinding) -> Bool = EditorFocusHost.isCurrent,
                                       diagnose: ((Diagnostic) -> Void)? = nil,
                                       commit: (Proof) -> Bool, afterCommit: () -> Void) -> Bool {
        let committed = withProof(at: monotonic, foreground: foreground, currentHost: currentHost, diagnose: diagnose, commit: commit)
        if committed { afterCommit() }
        return committed
    }
    static func permitsLegacyReader(foregroundBundleID: String?, managedHosts: Set<String>) -> Bool {
        guard let foregroundBundleID else { return false }
        return !managedHosts.contains(foregroundBundleID)
    }
    func reset() { lock.lock(); entries.removeAll(); retiredEpochs.removeAll(); lock.unlock() }
    var hasConnection: Bool { lock.lock(); defer { lock.unlock() }; return !entries.isEmpty }
}

// Receiver-local completion eligibility; wall-clock timestamps never establish
// whether a challenge was issued after this exact terminal generation.
struct EditorFocusTerminalGeneration: Hashable {
    let id: String, turn: String, state: String
    let updated: Date
    init(_ session: Session) { id = session.id; turn = session.turnID; state = session.state.rawValue; updated = session.updated }
}
struct EditorFocusEligibility {
    private var boundaries: [EditorFocusTerminalGeneration: Double] = [:]
    mutating func observe(_ reducer: StateReducer, at monotonic: Double) {
        guard monotonic.isFinite else { return }
        let active = Array(reducer.sessions.values) + (reducer.nativeDismissalHistory ?? []).filter { $0.providerAttention != nil }.map(\.session)
        let generations = Set(active.filter { !$0.seen && $0.focusEditorHost != nil && !$0.hasUnresolvedInteraction && [.completed, .failed, .interrupted].contains($0.state) }.map(EditorFocusTerminalGeneration.init))
        boundaries = boundaries.filter { generations.contains($0.key) }
        for generation in generations where boundaries[generation] == nil { boundaries[generation] = monotonic }
    }
    func eligible(afterChallenge issued: Double) -> Set<EditorFocusTerminalGeneration> {
        guard issued.isFinite else { return [] }
        return Set(boundaries.filter { issued > $0.value }.map(\.key))
    }
}
