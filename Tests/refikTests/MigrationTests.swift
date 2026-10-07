import XCTest
@testable import refik

final class MigrationTests: XCTestCase {
    func testStateAndTokenMigrationIsIdempotentAndExcludesLiveSocket() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refik-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("old"), new = root.appendingPathComponent("new")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        var state = StateReducer()
        for (id, seen) in [("unseen", false), ("seen", true)] {
            let event = CodexEvent(sessionID: id, turnID: "turn", requestID: nil, kind: .completed, source: .desktop, title: "project", at: Date(), id: id)
            state.apply(event)
            if seen { state.markSeen([id]) }
        }
        try JSONEncoder().encode(state).write(to: old.appendingPathComponent("attention-state.json"))
        try Data("original-token".utf8).write(to: old.appendingPathComponent("signal.token"))
        try Data("not-portable".utf8).write(to: old.appendingPathComponent("events.sock"))
        try LegacyMigration.copyState(from: old, to: new)
        let migrated = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: new.appendingPathComponent("attention-state.json")))
        XCTAssertEqual(migrated.sessions["seen"]?.seen, true)
        XCTAssertEqual(migrated.sessions["unseen"]?.seen, false)
        XCTAssertEqual(migrated.visibleAttentionRows.map(\.id), ["unseen"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.appendingPathComponent("events.sock").path))
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("signal.token")), Data("original-token".utf8))
        try Data("newer-state".utf8).write(to: new.appendingPathComponent("attention-state.json"))
        try LegacyMigration.copyState(from: old, to: new)
        XCTAssertEqual(try Data(contentsOf: new.appendingPathComponent("attention-state.json")), Data("newer-state".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: new.appendingPathComponent("signal.token").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testPreferenceMigrationPreservesAllValuesAndRawMascotID() throws {
        for raw in ["cute", "stern", "webAI", "tatlı", "sert", "web ai"] {
            var preferences = Preferences(); preferences.mascot = raw
            preferences.followEyes = false; preferences.opacity = 0.43; preferences.vertical = 0.17
            let data = try JSONEncoder().encode(preferences)
            let migrated = try XCTUnwrap(LegacyMigration.legacyPreferences(domain: [LegacyMigration.oldPreferenceKey: data]))
            let result = try JSONDecoder().decode(Preferences.self, from: migrated)
            XCTAssertEqual(result.mascot, raw); XCTAssertFalse(result.followEyes)
            XCTAssertEqual(result.opacity, 0.43); XCTAssertEqual(result.vertical, 0.17)
        }
    }
    func testHookMigrationOnlyReplacesOwnedExecutableAndKeepsOtherHandlers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refik-hook-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("hooks.json")
        let legacy = LegacyMigration.legacyDirectory.appendingPathComponent("MascotmetHook")
        let owned = LegacyMigration.quoted(legacy.path) + " codex Stop"
        let unrelated = "echo MascotmetHook user-owned"
        let fixture: [String: Any] = ["unrelated": "keep", "hooks": ["Stop": [["matcher": "*", "hooks": [["command": owned], ["command": unrelated]]]]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let helper = root.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .codex, at: file, helper: helper)
        let first = try Data(contentsOf: file)
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(migrated["unrelated"] as? String, "keep")
        let hooks = migrated["hooks"] as! [String: [[String: Any]]]
        let commands = hooks.values.flatMap { $0 }.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
        XCTAssertTrue(commands.contains(unrelated)); XCTAssertFalse(commands.contains(owned))
        XCTAssertEqual(commands.filter { LegacyMigration.ownsCommand($0, executable: helper) }.count, HookInstaller.codexEvents.count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("backup") }.count, 1)
        try HookInstaller.setEnabled(true, provider: .codex, at: file, helper: helper)
        XCTAssertEqual(try Data(contentsOf: file), first)
        XCTAssertFalse(LegacyMigration.ownsLegacyHook("echo " + owned))
    }
    func testMixedAntigravityMigrationPreservesSiblingAndUnknownMetadata() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("refik-antigravity-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent("hooks.json")
        let legacy = LegacyMigration.quoted(LegacyMigration.legacyDirectory.appendingPathComponent("MascotmetHook").path)
        let sibling: [String: Any] = ["command": "echo unrelated-preserve", "custom": "sibling"]
        let metadata: [String: Any] = ["nested": ["keep": 7]]
        let fixture: [String: Any] = ["outside": "preserve", "mascotmet-observer": [
            "enabled": true, "customMetadata": metadata,
            "Stop": [["command": legacy + " antigravity Stop"], sibling],
            "PreToolUse": [["matcher": "*", "entryMetadata": "keep", "hooks": [["command": legacy + " antigravity PreToolUse"], sibling]]],
            "UnknownEvent": [["command": "echo unknown-preserve"]]
        ]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        let helper = path.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .antigravity, at: file, helper: helper)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(result["outside"] as? String, "preserve")
        let observer = try XCTUnwrap(result["mascotmet-observer"] as? [String: Any])
        XCTAssertEqual(observer["customMetadata"] as? NSDictionary, metadata as NSDictionary)
        XCTAssertEqual(observer["UnknownEvent"] as? NSArray, (fixture["mascotmet-observer"] as! [String: Any])["UnknownEvent"] as? NSArray)
        XCTAssertEqual(observer["Stop"] as? NSArray, [sibling] as NSArray)
        let pre = observer["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre[0]["entryMetadata"] as? String, "keep")
        XCTAssertEqual(pre[0]["hooks"] as? NSArray, [sibling] as NSArray)
        XCTAssertNotNil(result["refik-observer"])
        var onlyOwned: [String: Any] = ["mascotmet-observer": ["enabled": true, "Stop": [["command": legacy + " antigravity Stop"]]]]
        LegacyMigration.removeLegacyAntigravity(&onlyOwned)
        XCTAssertNil(onlyOwned["mascotmet-observer"])
    }
    func testClaudeUninstallPreservesUnrelatedStatusLineSubstringAndRestoresOwnedOnly() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("refik-claude-uninstall-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent("settings.json")
        let original: [String: Any] = ["type": "command", "command": "echo original"]
        let user: [String: Any] = ["type": "command", "command": "echo refikCLI user-owned"]
        let fixture: [String: Any] = ["statusLine": user, "refikOriginalStatusLine": original, "unrelated": "preserve"]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        try HookInstaller.setEnabled(false, provider: .claude, at: file)
        let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(unchanged["statusLine"] as? NSDictionary, user as NSDictionary)
        XCTAssertEqual(unchanged["refikOriginalStatusLine"] as? NSDictionary, original as NSDictionary)
        XCTAssertEqual(unchanged["unrelated"] as? String, "preserve")
        var owned = fixture
        owned["statusLine"] = ["type": "command", "command": LegacyMigration.quoted(HookInstaller.cliDestination.path) + " statusline abc"]
        try JSONSerialization.data(withJSONObject: owned).write(to: file)
        try HookInstaller.setEnabled(false, provider: .claude, at: file)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(restored["statusLine"] as? NSDictionary, original as NSDictionary)
        XCTAssertNil(restored["refikOriginalStatusLine"])
    }
    func testCurrentAntigravityRepairAndUninstallPreserveMixedObserver() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("refik-observer-preservation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let file = path.appendingPathComponent("hooks.json"), helper = path.appendingPathComponent("refikHook")
        let owned = LegacyMigration.quoted(helper.path)
        let sibling: [String: Any] = ["command": "echo refikHook custom-preserve"]
        let fixture: [String: Any] = ["refik-observer": ["enabled": true, "metadata": ["keep": true],
            "Stop": [["command": owned + " antigravity Stop"], sibling],
            "PreToolUse": [["matcher": "other", "metadata": "preserve", "hooks": [sibling, ["command": owned + " antigravity PreToolUse"]]]],
            "FutureEvent": [["command": "echo future-preserve"]]]]
        try JSONSerialization.data(withJSONObject: fixture).write(to: file)
        try HookInstaller.setEnabled(true, provider: .antigravity, at: file, helper: helper)
        let repaired = try Data(contentsOf: file)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: repaired) as? [String: Any])
        let observer = result["refik-observer"] as! [String: Any]
        XCTAssertTrue(HookInstaller.hasOwnedObserver(result, helper: helper))
        XCTAssertEqual(observer["metadata"] as? NSDictionary, ["keep": true] as NSDictionary)
        XCTAssertEqual((observer["Stop"] as! [[String: Any]])[0] as NSDictionary, sibling as NSDictionary)
        XCTAssertEqual((observer["PreToolUse"] as! [[String: Any]])[0]["metadata"] as? String, "preserve")
        XCTAssertNotNil(observer["FutureEvent"])
        try HookInstaller.setEnabled(true, provider: .antigravity, at: file, helper: helper)
        XCTAssertEqual(try Data(contentsOf: file), repaired)
        try HookInstaller.setEnabled(false, provider: .antigravity, at: file, helper: helper)
        let uninstalled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let remaining = uninstalled["refik-observer"] as! [String: Any]
        XCTAssertFalse(HookInstaller.hasOwnedObserver(uninstalled, helper: helper))
        XCTAssertEqual(remaining["metadata"] as? NSDictionary, observer["metadata"] as? NSDictionary)
        XCTAssertEqual(remaining["Stop"] as? NSArray, [sibling] as NSArray)
        XCTAssertEqual(remaining["FutureEvent"] as? NSArray, observer["FutureEvent"] as? NSArray)
        let pre = remaining["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre[0]["hooks"] as? NSArray, [sibling] as NSArray)
        XCTAssertEqual(pre[0]["metadata"] as? String, "preserve")
    }
    func testReduceMotionDisablesAnimationWithoutDisablingCursorDirection() {
        XCTAssertFalse(MascotHitView.animatesGaze(reduceMotion: true))
        XCTAssertTrue(MascotHitView.animatesGaze(reduceMotion: false))
        let center = NSPoint(x: 200, y: 200)
        for mouse in [NSPoint(x: 0, y: 0), NSPoint(x: 400, y: 0), NSPoint(x: 0, y: 400), NSPoint(x: 400, y: 400)] {
            let target = MascotHitView.gazeTarget(mouse: mouse, center: center)
            XCTAssertEqual(hypot(target.x, target.y), 1.7, accuracy: 0.001)
            XCTAssertEqual(target.x > 0, mouse.x > center.x)
            XCTAssertEqual(target.y > 0, mouse.y > center.y)
        }
    }
    func testWeeklyRemainingAndOtherWindowsPreserveExplicitSemantics() {
        for (used, expected) in [(0.0, "~%100 kaldı"), (72.0, "~%28 kaldı"), (100.0, "~%0 kaldı")] {
            let entry = UsageEntry(provider: .codex, window: "7 gün", percent: used, fidelity: .derived, expires: .distantFuture, semantic: .used)
            XCTAssertEqual(entry.valueLabel, expected)
        }
        let unknown = UsageEntry(provider: .codex, window: "7 gün", percent: 72, fidelity: .derived, expires: .distantFuture)
        XCTAssertEqual(unknown.valueLabel, "Türetilmiş veri")
        let alreadyRemaining = UsageEntry(provider: .codex, window: "7 gün", percent: 28, fidelity: .derived, expires: .distantFuture, semantic: .remaining)
        XCTAssertEqual(alreadyRemaining.valueLabel, "~%28 kaldı")
    }
}
