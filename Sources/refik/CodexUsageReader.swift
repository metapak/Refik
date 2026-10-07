import Foundation

// Read bounded recent tails, on demand. Conversation bodies never leave this function.
enum CodexUsageReader {
    static let freshness: TimeInterval = 86_400
    static let candidateLimit = 16
    static func events(in root: URL, now: Date = Date()) -> [CodexEvent] {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var candidates: [(URL, Date)] = []
        for case let url as URL in iterator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard date > now.addingTimeInterval(-freshness) else { continue }
            candidates.append((url, date))
            candidates.sort { $0.1 > $1.1 }
            if candidates.count > candidateLimit { candidates.removeLast() }
        }
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let whole = ISO8601DateFormatter()
        var latest: (at: Date, limits: [String: Any])?
        for (url, _) in candidates {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let length = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: length > 262_144 ? length - 262_144 : 0)
            let data = try? handle.read(upToCount: 262_144)
            try? handle.close()
            guard let data, let text = String(data: data, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let timestamp = object["timestamp"] as? String,
                      let observed = fractional.date(from: timestamp) ?? whole.date(from: timestamp),
                      observed > now.addingTimeInterval(-freshness), observed <= now,
                      let payload = object["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let limits = payload["rate_limits"] as? [String: Any] else { continue }
                if latest == nil || observed > latest!.at { latest = (observed, limits) }
                break
            }
        }
        guard let latest else { return [] }
        return ["primary", "secondary"].compactMap { name in
            guard let window = latest.limits[name] as? [String: Any],
                  let percent = window["used_percent"] as? Double, (0...100).contains(percent),
                  let minutes = window["window_minutes"] as? Int, minutes > 0,
                  let reset = window["resets_at"] as? TimeInterval else { return nil }
            // Weekly reset can be days away. Snapshot freshness is independent of reset.
            let expires = min(reset, latest.at.addingTimeInterval(freshness).timeIntervalSince1970)
            guard expires > now.timeIntervalSince1970 else { return nil }
            var event = CodexEvent(sessionID: "usage:codex:\(name)", turnID: "usage", requestID: nil,
                kind: .usage, source: .unknown, title: UsageFormatting.duration(minutes: minutes), at: latest.at, id: "usage:codex:\(name):\(reset)")
            event.detail = "used"; event.provider = .codex; event.fidelity = .derived; event.progress = percent / 100
            event.ttl = expires - latest.at.timeIntervalSince1970
            event.resetAt = Date(timeIntervalSince1970: reset)
            return event
        }
    }
}
