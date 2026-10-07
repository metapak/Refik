import XCTest
import Darwin
import RefikInteractionWire
@testable import refik

final class TerminalNavigationDiagnosticTests: XCTestCase {
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("refik-nav-diagnostic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return path
    }
    private func rows(_ root: URL) throws -> [Data] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.flatMap { url in
                let records: [Data] = try Data(contentsOf: url).split(separator: UInt8(10))
                return records
            }
    }
    func testDefaultOffPrivateSchemaBoundCapAndExpiry() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1000)
        TerminalNavigationDiagnostic.record(.init(.helperInvoked, tabPresent: true, timestamp: now), directory: root, now: now)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        let epoch = try XCTUnwrap(TerminalNavigationDiagnostic.arm(directory: root, now: now))
        for _ in 0..<70 { TerminalNavigationDiagnostic.record(.init(.helperInvoked, tabPresent: false, timestamp: now), directory: root, now: now) }
        let entries = try rows(root); XCTAssertEqual(entries.count, 60)
        for entry in entries {
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: entry) as? [String: Any])
            XCTAssertEqual(Set(value.keys), ["stage", "tabPresent", "timestamp"])
            XCTAssertEqual(value["stage"] as? String, "helperInvoked")
        }
        let other = try self.root(); defer { try? FileManager.default.removeItem(at: other) }
        _ = TerminalNavigationDiagnostic.arm(directory: other, now: now)
        XCTAssertEqual(TerminalNavigationDiagnostic.lifetime, 600)
        TerminalNavigationDiagnostic.record(.init(.bindReady), directory: other, now: now.addingTimeInterval(599))
        XCTAssertEqual(try rows(other).count, 1)
        TerminalNavigationDiagnostic.record(.init(.bindReady), directory: other, now: now.addingTimeInterval(600))
        TerminalNavigationDiagnostic.record(.init(.bindReady), directory: other, now: now.addingTimeInterval(-1))
        XCTAssertEqual(try rows(other).count, 1)
        TerminalNavigationDiagnostic.disarm(directory: root, epoch: UUID())
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("navigation-diagnostics.enabled").path))
        TerminalNavigationDiagnostic.disarm(directory: root, epoch: epoch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("navigation-diagnostics.enabled").path))
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let info = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((info[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testSymlinkWrongModeHardlinkAndNonfiniteRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let foreign = root.appendingPathComponent("foreign"); try Data("preserve".utf8).write(to: foreign)
        let marker = root.appendingPathComponent("navigation-diagnostics.enabled")
        try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: foreign)
        XCTAssertNil(TerminalNavigationDiagnostic.arm(directory: root))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("preserve".utf8))
        try FileManager.default.removeItem(at: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: foreign.path)
        XCTAssertEqual(link(foreign.path, marker.path), 0)
        XCTAssertNil(TerminalNavigationDiagnostic.arm(directory: root))
        try FileManager.default.removeItem(at: marker)
        try Data().write(to: marker); try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        XCTAssertNil(TerminalNavigationDiagnostic.arm(directory: root))
        try FileManager.default.removeItem(at: marker)
        XCTAssertNil(TerminalNavigationDiagnostic.arm(directory: root, now: Date(timeIntervalSince1970: .infinity)))
        let epoch = try XCTUnwrap(TerminalNavigationDiagnostic.arm(directory: root))
        TerminalNavigationDiagnostic.record(.init(.applied, timestamp: Date(timeIntervalSince1970: .infinity)), directory: root)
        XCTAssertTrue(try rows(root).isEmpty)
        TerminalNavigationDiagnostic.disarm(directory: root, epoch: epoch)
        let alias = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }
        XCTAssertNil(TerminalNavigationDiagnostic.arm(directory: alias))
    }
    func testConcurrentRowsRemainBoundedAndEpochRearmCannotBeDisarmedByOldTask() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let old = try XCTUnwrap(TerminalNavigationDiagnostic.arm(directory: root))
        let new = try XCTUnwrap(TerminalNavigationDiagnostic.arm(directory: root))
        TerminalNavigationDiagnostic.disarm(directory: root, epoch: old)
        DispatchQueue.concurrentPerform(iterations: 150) { _ in
            TerminalNavigationDiagnostic.record(.init(.captureReady), directory: root)
        }
        let entries = try rows(root); XCTAssertGreaterThan(entries.count, 0); XCTAssertLessThanOrEqual(entries.count, 60)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        for entry in entries { XCTAssertNoThrow(try decoder.decode(TerminalNavigationDiagnostic.Sample.self, from: entry), "JSON schema stays intact") }
        TerminalNavigationDiagnostic.disarm(directory: root, epoch: new)
    }
    func testActualHelperReadsOwnedMarkerWithoutInheritedDiagnosticFlagAndOnlyLogsPresence() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let epoch = try XCTUnwrap(TerminalNavigationDiagnostic.arm(directory: root))
        defer { TerminalNavigationDiagnostic.disarm(directory: root, epoch: epoch) }
        let binary = URL(fileURLWithPath: ".build/debug/refikHook", relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw XCTSkip("helper not built") }
        let process = Process(); process.executableURL = binary
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "REFIK_TERMINAL_NAV_DIAGNOSTICS")
        environment["REFIK_DATA_DIR"] = root.path
        environment["ITERM_SESSION_ID"] = "private-tab-content-must-not-be-logged"
        process.environment = environment
        let input = Pipe(); process.standardInput = input
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0); process.terminationHandler = { _ in finished.signal() }
        try process.run(); try input.fileHandleForWriting.write(contentsOf: Data("{}".utf8)); try input.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + 2) == .success else { process.terminate(); XCTFail("bounded malformed-input helper exit"); return }
        XCTAssertEqual(process.terminationStatus, 0)
        let entries = try rows(root); XCTAssertEqual(entries.count, 1)
        let data = try XCTUnwrap(entries.first), object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["stage"] as? String, "helperInvoked"); XCTAssertEqual(object["tabPresent"] as? Bool, true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-tab-content"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.sock").path), "no fabricated event delivered")
    }

}
