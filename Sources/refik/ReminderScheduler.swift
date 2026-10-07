import Foundation

// A clock-driven scheduler lets the app's timer and tests use the same policy.
// No pending entry is restored from disk, so restart cannot replay reminders.
struct ReminderScheduler {
    private struct Entry { let request: PendingRequestSnapshot; let due: Date }
    private var entries: [RequestIdentity: Entry] = [:]
    private var delivered: Set<RequestIdentity> = []
    mutating func observe(_ request: PendingRequestSnapshot, at now: Date, preferences: Preferences) {
        guard preferences.remindersEnabled, request.lifecycle == .pending,
              now.timeIntervalSince(request.observedAt) >= 0, now.timeIntervalSince(request.observedAt) < 5,
              request.kind == .question ? preferences.remindQuestions : preferences.remindPermissions,
              !delivered.contains(request.identity), entries[request.identity] == nil else { return }
        let delay = preferences.reminderDelaySeconds.isFinite ? max(30, min(86_400, preferences.reminderDelaySeconds)) : 180
        entries[request.identity] = Entry(request: request, due: now.addingTimeInterval(delay))
    }
    mutating func cancel(_ identity: RequestIdentity) { entries.removeValue(forKey: identity) }
    mutating func cancelAll() { entries.removeAll() }
    mutating func due(at now: Date, preferences: Preferences, isCurrent: (PendingRequestSnapshot) -> Bool) -> [PendingRequestSnapshot] {
        guard preferences.remindersEnabled else { cancelAll(); return [] }
        var result: [PendingRequestSnapshot] = []
        for (identity, entry) in entries {
            let enabled = entry.request.kind == .question ? preferences.remindQuestions : preferences.remindPermissions
            guard enabled && isCurrent(entry.request) else { entries.removeValue(forKey: identity); continue }
            guard entry.due <= now else { continue }
            entries.removeValue(forKey: identity); delivered.insert(identity)
            // Delayed timer callbacks after sleep never produce a burst.
            if now.timeIntervalSince(entry.due) <= 30 { result.append(entry.request) }
        }
        if delivered.count > 1_000 { delivered = Set(delivered.sorted { $0.generation < $1.generation }.suffix(500)) }
        return result.sorted { $0.observedAt < $1.observedAt }
    }
}
