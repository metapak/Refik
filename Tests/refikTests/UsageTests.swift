import XCTest
@testable import refik

final class UsageTests: XCTestCase {
    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private func write(_ root: URL, name: String, observed: Date?, modified: Date, reset: Date, used: Double = 93) throws {
        let stamp = observed.map { ISO8601DateFormatter().string(from: $0) }
        var object: [String: Any] = ["payload": ["type": "token_count", "rate_limits": ["primary": [
            "used_percent": used, "window_minutes": 10080, "resets_at": reset.timeIntervalSince1970]]]]
        if let stamp { object["timestamp"] = stamp }
        let file = root.appendingPathComponent("rollout-\(name).jsonl")
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }
    @MainActor func testWeeklyResetBeyondOneDayReachesPanelAsRemaining() throws {
        try withRoot { root in
            let now = Date(), observed = now.addingTimeInterval(-30)
            try write(root, name: "weekly", observed: observed, modified: now, reset: now.addingTimeInterval(209_721))
            let events = CodexUsageReader.events(in: root, now: now)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.ttl, 86_400)
            XCTAssertEqual(events.first!.resetAt!.timeIntervalSince1970, now.addingTimeInterval(209_721).timeIntervalSince1970, accuracy: 0.001)
            XCTAssertLessThan(events.first!.at, now)
            let app = AppModel(inspectNotificationPermission: false)
            app.accept(events[0], historical: false)
            XCTAssertEqual(app.currentUsageWindows().first?.valueLabel, "~%7 kaldı")
            XCTAssertEqual(app.currentUsageWindows().first?.providerLabel(at: now), "Codex · 2 gün 10 saat kaldı")
            XCTAssertNil(app.usageUnavailableMessage())
            let expiry = events[0].at.addingTimeInterval(events[0].ttl!)
            // Both views suppress expired values even before the pruning timer fires.
            XCTAssertTrue(app.currentUsageWindows(at: expiry).isEmpty)
            XCTAssertEqual(app.usageUnavailableMessage(at: expiry), "Kullanım bilgisi bekleniyor")
            app.expire(at: expiry)
            XCTAssertTrue(app.usageWindows.isEmpty)
            XCTAssertEqual(app.usageUnavailableMessage(), "Kullanım bilgisi bekleniyor")
        }
    }
    func testNewestTranscriptWithoutUsageDoesNotHideRecentSnapshot() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try write(root, name: "limits", observed: now.addingTimeInterval(-60), modified: now.addingTimeInterval(-1), reset: now.addingTimeInterval(200_000))
            let empty = root.appendingPathComponent("rollout-newest.jsonl")
            try Data("{\"payload\":{\"type\":\"token_count\",\"rate_limits\":null}}\n".utf8).write(to: empty)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: empty.path)
            XCTAssertEqual(CodexUsageReader.events(in: root, now: now).first?.progress, 0.93)
        }
    }
    func testObservationTimeWinsOverFileModificationTime() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: 1_800_000_000), reset = now.addingTimeInterval(200_000)
            try write(root, name: "older-observation", observed: now.addingTimeInterval(-600), modified: now, reset: reset, used: 40)
            try write(root, name: "newer-observation", observed: now.addingTimeInterval(-60), modified: now.addingTimeInterval(-1), reset: reset, used: 93)
            XCTAssertEqual(CodexUsageReader.events(in: root, now: now).first?.progress, 0.93)
        }
    }
    func testFreshFileCannotRenewStaleMissingOrFutureSnapshot() throws {
        for age: TimeInterval? in [86_401, nil, -60] {
            try withRoot { root in
                let now = Date(timeIntervalSince1970: 1_800_000_000)
                try write(root, name: "invalid", observed: age.map { now.addingTimeInterval(-$0) }, modified: now, reset: now.addingTimeInterval(200_000))
                XCTAssertTrue(CodexUsageReader.events(in: root, now: now).isEmpty)
            }
        }
    }
    func testLatestExpiredResetDoesNotResurrectOlderSnapshot() throws {
        try withRoot { root in
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try write(root, name: "older", observed: now.addingTimeInterval(-60), modified: now, reset: now.addingTimeInterval(200_000))
            try write(root, name: "newer", observed: now.addingTimeInterval(-1), modified: now, reset: now.addingTimeInterval(-1))
            XCTAssertTrue(CodexUsageReader.events(in: root, now: now).isEmpty)
        }
    }
    @MainActor func testEmptyAndUnknownUsageShowNoInventedPercentage() {
        let app = AppModel(inspectNotificationPermission: false)
        XCTAssertEqual(app.usageUnavailableMessage(), "Kullanım bilgisi bekleniyor")
        var event = CodexEvent(sessionID: "usage", turnID: "usage", requestID: nil, kind: .usage, source: .unknown, title: "7 gün", at: Date(), id: "unknown")
        event.progress = 0.93; event.ttl = 100
        app.accept(event, historical: false)
        XCTAssertFalse(app.currentUsageWindows().first!.valueLabel.contains("%"))
    }
    @MainActor func testOptInLocalUsageProbe() throws {
        guard ProcessInfo.processInfo.environment["REFIK_VERIFY_LOCAL_USAGE"] == "1" else {
            throw XCTSkip("Local usage verification is explicitly opt-in")
        }
        let root = (ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")).appendingPathComponent("sessions")
        let now = Date(), events = CodexUsageReader.events(in: root, now: now)
        let weekly = try XCTUnwrap(events.first { $0.title == "7 gün" })
        let app = AppModel(inspectNotificationPermission: false)
        app.accept(weekly, historical: false)
        let entry = try XCTUnwrap(app.currentUsageWindows().first)
        XCTAssertNil(app.usageUnavailableMessage())
        print("LOCAL_USAGE_PROBE label=\(entry.providerLabel(at: now)) weekly=\(entry.valueLabel) observation_age_seconds=\(Int(now.timeIntervalSince(weekly.at))) snapshot_ttl_seconds=\(Int(weekly.ttl!))")
    }
    func testResetCountdownTurkishUnitsAndUnknownReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func label(_ seconds: Double) -> String? { UsageFormatting.resetCountdown(until: now.addingTimeInterval(seconds), at: now) }
        XCTAssertEqual(label(2 * 86_400 + 17 * 3_600), "2 gün 17 saat kaldı")
        XCTAssertEqual(label(3 * 86_400), "3 gün kaldı")
        XCTAssertEqual(label(3_600), "1 saat kaldı")
        XCTAssertEqual(label(1_800), "30 dk kaldı")
        XCTAssertEqual(label(1), "1 dk kaldı")
        XCTAssertNil(label(0))
        XCTAssertNil(label(-1))
        XCTAssertNil(UsageFormatting.resetCountdown(until: nil, at: now))
        let entry = UsageEntry(provider: .claude, window: "7 gün", percent: 93, fidelity: .official, expires: .distantFuture, semantic: .used)
        XCTAssertEqual(entry.providerLabel(at: now), "Claude")
        XCTAssertEqual(entry.valueLabel, "%7 kaldı")
    }
    @MainActor func testUsageTimerRefreshesCountdownWithoutChangingFreshnessOrPercentage() {
        let app = AppModel(inspectNotificationPermission: false), now = Date()
        var event = CodexEvent(sessionID: "usage", turnID: "usage", requestID: nil, kind: .usage, source: .unknown, title: "7 gün", at: now, id: "weekly", detail: "used", provider: .claude, progress: 0.93, ttl: 86_400)
        event.resetAt = now.addingTimeInterval(3 * 86_400)
        app.accept(event, historical: false)
        let entry = app.currentUsageWindows()[0]
        XCTAssertEqual(entry.expires, now.addingTimeInterval(86_400))
        XCTAssertEqual(entry.providerLabel(at: now), "Claude · 3 gün kaldı")
        app.expire(at: now.addingTimeInterval(3_600))
        XCTAssertEqual(entry.providerLabel(at: app.usageUpdatedAt), "Claude · 2 gün 23 saat kaldı")
        XCTAssertEqual(app.currentUsageWindows()[0].valueLabel, "%7 kaldı")
        XCTAssertEqual(app.currentUsageWindows()[0].expires, entry.expires)
    }
    func testOptionalResetDateRoundTripsAndOldEventsStillDecode() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var event = CodexEvent(sessionID: "usage", turnID: "usage", requestID: nil, kind: .usage, source: .unknown, title: "7 gün", at: now, id: "weekly", provider: .claude)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertNil(try decoder.decode(CodexEvent.self, from: encoder.encode(event)).resetAt)
        event.resetAt = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(try decoder.decode(CodexEvent.self, from: encoder.encode(event)).resetAt, event.resetAt)
    }
}
