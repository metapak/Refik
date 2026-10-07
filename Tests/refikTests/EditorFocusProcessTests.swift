import XCTest
import Foundation
import Darwin
@testable import refik

final class EditorFocusProcessTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let limits = EditorFocusProcessRunner.Limits(duration: 0.15, grace: 0.08, reap: 0.8, outputBytes: 1024)
    func testNonCloexecParentSentinelDoesNotReachVendorProcess() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Public Python fixture unavailable") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("refik-fd-sentinel-" + UUID().uuidString)
        try Data("refik-noncloexec-sentinel".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(original, 0)
        guard original >= 0 else { return }
        defer { close(original) }
        let descriptor = fcntl(original, F_DUPFD, 64)
        XCTAssertGreaterThanOrEqual(descriptor, 64)
        guard descriptor >= 64 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(fcntl(descriptor, F_SETFD, 0), 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0)
        let code = "import os; fd=" + String(descriptor) + ";\ntry: print('leaked' if os.read(fd,64)==b'refik-noncloexec-sentinel' else 'other')\nexcept OSError: print('closed')"
        let result = EditorFocusProcessRunner.run(python, ["-c", code])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "closed")
    }
    func testSignalAndExitFailuresRemainTyped() {
        XCTAssertEqual(EditorFocusProcessRunner.run(shell, ["-c", "kill -TERM $$"]).failure, .signal)
        XCTAssertEqual(EditorFocusProcessRunner.run(shell, ["-c", "exit 7"]).failure, .nonzeroExit)
        XCTAssertEqual(EditorFocusProcessRunner.run(URL(fileURLWithPath: "/missing-refik-fixture"), []).failure, .launch)
    }
    func testNoisyProcessIsBoundedWhileRunning() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = EditorFocusProcessRunner.run(shell, ["-c", "while :; do printf '01234567890123456789'; done"], limits: limits)
        XCTAssertEqual(result.failure, .outputLimit)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 1024)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }
    func testIgnoredTermIsEscalatedInOwnedGroup() {
        let started = ProcessInfo.processInfo.systemUptime
        let result = EditorFocusProcessRunner.run(shell, ["-c", "trap '' TERM; while :; do :; done"], limits: limits)
        XCTAssertEqual(result.failure, .timeout)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
    }
    func testParentExitWithLiveChildRetainsDirectoryInsteadOfKillingChild() throws {
        let result = EditorFocusProcessRunner.run(shell, ["-c", "pwd; sleep 0.4 & exit 0"])
        XCTAssertEqual(result.failure, .cleanupBlocked)
        XCTAssertTrue(result.cleanupUncertain)
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        Thread.sleep(forTimeInterval: 0.6)
        try FileManager.default.removeItem(atPath: path)
    }
    func testTimedOutJobDoesNotSignalUnrelatedProcess() throws {
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["2"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate() } }
        let result = EditorFocusProcessRunner.run(shell, ["-c", "trap 'sleep 0.2 &' TERM; while :; do :; done"], limits: limits)
        XCTAssertEqual(result.failure, .timeout)
        XCTAssertTrue(unrelated.isRunning)
    }
    func testKnownDetachedChildRetainsCwdAndIsNotHunted() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Public Python fixture unavailable") }
        let code = "import os,time; print(os.getcwd(),flush=True); child=os.fork(); os.setsid() if child==0 else None; time.sleep(0.5 if child==0 else 0.12)"
        let result = EditorFocusProcessRunner.run(python, ["-c", code])
        XCTAssertEqual(result.failure, .cleanupBlocked)
        XCTAssertTrue(result.cleanupUncertain)
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        Thread.sleep(forTimeInterval: 0.6)
        try FileManager.default.removeItem(atPath: path)
    }
    func testTimeoutKeepsPrimaryFailureAndReportsDetachedCleanupUncertainty() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Public Python fixture unavailable") }
        let code = "import os,time; print(os.getcwd(),flush=True); child=os.fork(); os.setsid() if child==0 else None; time.sleep(0.6 if child==0 else 10)"
        let result = EditorFocusProcessRunner.run(python, ["-c", code], limits: limits)
        XCTAssertEqual(result.failure, .timeout)
        XCTAssertTrue(result.cleanupUncertain)
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        Thread.sleep(forTimeInterval: 0.7)
        try FileManager.default.removeItem(atPath: path)
    }
    func testUnavailableFastChildSnapshotDoesNotRejectCompleteReapedCommand() throws {
        var bounds = EditorFocusProcessRunner.Limits()
        bounds.snapshotIdentityUnavailable = { _ in true }
        let result = EditorFocusProcessRunner.run(shell, ["-c", "pwd; sleep 0.08 & wait; printf complete"], limits: bounds)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.failure, .none)
        XCTAssertEqual(result.terminationCode, 0)
        XCTAssertEqual(result.outputEOF, true)
        XCTAssertEqual(result.captureIncomplete, true)
        XCTAssertEqual(result.remainingChildren, false)
        XCTAssertEqual(result.outputReadFailed, false)
        XCTAssertEqual(result.leaderReaped, true)
        XCTAssertTrue(result.cleanupUncertain)
        XCTAssertTrue(result.output.hasSuffix("complete"))
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        try FileManager.default.removeItem(atPath: path)
    }
    func testDetachedChildWithClosedOutputAllowsCommandButRetainsCwd() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("Public Python fixture unavailable") }
        let code = "import os,time; print(os.getcwd(),flush=True); child=os.fork();\nif child==0:\n os.setsid(); os.close(1); os.close(2); time.sleep(0.5)\nelse: time.sleep(0.12)"
        let result = EditorFocusProcessRunner.run(python, ["-c", code])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.failure, .none)
        XCTAssertEqual(result.outputEOF, true)
        XCTAssertEqual(result.remainingChildren, true)
        XCTAssertEqual(result.leaderReaped, true)
        XCTAssertTrue(result.cleanupUncertain)
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        Thread.sleep(forTimeInterval: 0.6)
        try FileManager.default.removeItem(atPath: path)
    }
    func testSuccessfulCwdAndDescriptorsAreCleanedWithoutInputInheritance() throws {
        let result = EditorFocusProcessRunner.run(shell, ["-c", "pwd; if read value; then exit 9; fi; printf ok"])
        XCTAssertTrue(result.success)
        let path = try XCTUnwrap(result.output.split(separator: "\n").first).description
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(result.output.hasSuffix("ok"))
    }
}
