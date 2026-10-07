import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class HookOriginDiagnosticTests: XCTestCase {
    func testCodexIdentityMigrationPreservesOriginalControlsForeignDataAndSecondLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("hooks.json"), helper = root.appendingPathComponent("refikHook")
        try HookInstaller.setEnabled(true, provider: .codex, at: config, helper: helper)
        var original = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
        var hooks = original["hooks"] as! [String: Any]
        for event in HookInstaller.codexIdentityEvents { hooks.removeValue(forKey: event) }
        hooks["SubagentStart"] = [["hooks": [["type": "command", "command": "foreign-observer", "timeout": 5]]]]
        original["hooks"] = hooks; original["statusLine"] = ["command": "foreign-status"]
        try JSONSerialization.data(withJSONObject: original).write(to: config)
        XCTAssertTrue(try HookInstaller.repairExistingCodexIdentityObservers(at: config, helper: helper))
        let bytes = try Data(contentsOf: config)
        let repaired = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let current = repaired["hooks"] as! [String: Any]
        for event in HookInstaller.codexLifecycleEvents { XCTAssertTrue((current[event] as! NSArray).isEqual(hooks[event] as! NSArray)) }
        XCTAssertTrue((repaired["statusLine"] as! NSDictionary).isEqual(original["statusLine"] as! NSDictionary))
        XCTAssertTrue(((current["SubagentStart"] as! [[String: Any]])[0] as NSDictionary).isEqual((hooks["SubagentStart"] as! [[String: Any]])[0] as NSDictionary))
        for event in HookInstaller.codexIdentityEvents {
            let handler = ((current[event] as! [[String: Any]]).last!["hooks"] as! [[String: Any]])[0]
            XCTAssertEqual(handler["timeout"] as? Int, 1)
            XCTAssertFalse((handler["command"] as! String).contains("--interactive"))
        }
        let modification = try config.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(try HookInstaller.repairExistingCodexIdentityObservers(at: config, helper: helper))
        XCTAssertEqual(try Data(contentsOf: config), bytes)
        XCTAssertEqual(try config.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modification)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), files)
        for bad in [["disableAllHooks": true, "hooks": hooks], ["hooks": ["Stop": hooks["Stop"]!]], ["hooks": ["Stop": ["malformed"]]]] as [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: bad); try data.write(to: config)
            if bad["disableAllHooks"] != nil || (bad["hooks"] as? [String: Any])?.count == 1 && (bad["hooks"] as? [String: Any])?["Stop"] is [[String: Any]] {
                XCTAssertFalse(try HookInstaller.repairExistingCodexIdentityObservers(at: config, helper: helper))
            } else { XCTAssertThrowsError(try HookInstaller.repairExistingCodexIdentityObservers(at: config, helper: helper)) }
            XCTAssertEqual(try Data(contentsOf: config), data)
        }
    }
    @MainActor func testStartupSchedulesCodexIdentityRepairOnlyOnce() {
        let app = AppModel(inspectNotificationPermission: false)
        let called = expectation(description: "one startup repair"); called.assertForOverFulfill = true
        app.codexIdentityStartupRepair = { called.fulfill(); return false }
        app.beginCodexIdentityStartupRepair(); app.beginCodexIdentityStartupRepair()
        wait(for: [called], timeout: 2)
    }
    func testExplicitBoundedPrivateMetadataOnlyCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("origin-diagnostics.enabled"), output = root.appendingPathComponent("origin-diagnostics.jsonl")
        let sample = HookOriginDiagnostic.Sample(stage: .missingLocator, sessionID: UUID().uuidString, turnID: "private-content",
            event: .init(name: "private-tool-name"), locatorPresent: false, agentIDPresent: true)
        HookOriginDiagnostic.record(sample, directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try Data().write(to: marker); _ = chmod(marker.path, 0o600)
        for _ in 0..<65 { HookOriginDiagnostic.record(sample, directory: root) }
        let bytes = try Data(contentsOf: output)
        XCTAssertEqual(bytes.filter { $0 == 10 }.count, 60)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private"))
        let row = try JSONSerialization.jsonObject(with: bytes.prefix { $0 != 10 }) as! [String: Any]
        XCTAssertEqual(row["stage"] as? String, "missingLocator")
        XCTAssertEqual(row["event"] as? String, "other")
        XCTAssertNil(row["turnID"])
        var info = stat(); XCTAssertEqual(lstat(output.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o600)
        try FileManager.default.removeItem(at: output)
        HookOriginDiagnostic.record(sample, directory: root, now: Date().addingTimeInterval(121))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        HookOriginDiagnostic.record(sample, directory: root, now: Date().addingTimeInterval(-1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        _ = chmod(marker.path, 0o644); HookOriginDiagnostic.record(sample, directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try FileManager.default.removeItem(at: marker)
        let alias = root.appendingPathComponent("alias"); try Data().write(to: alias); _ = chmod(alias.path, 0o600)
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: alias)
        HookOriginDiagnostic.record(sample, directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
