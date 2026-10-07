import XCTest
@testable import RefikInteractionWire

final class CopilotDesktopHostTests: XCTestCase {
    func testUnrelatedExecutableCannotClaimNativeCopilotHost() {
        XCTAssertNil(CopilotDesktopHost.verifiedApplication(executable: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertNil(CopilotDesktopHost.verifiedApplication(executable: URL(fileURLWithPath: "/tmp/GitHub Copilot.app/Contents/MacOS/github")))
        XCTAssertNil(CopilotDesktopHost.currentEmitter())
    }
    func testInstalledNativeApplicationRequiresItsSignedBundle() throws {
        guard FileManager.default.fileExists(atPath: CopilotDesktopHost.executable.path) else {
            throw XCTSkip("Native Copilot app is not installed")
        }
        let metadata = try XCTUnwrap(CopilotDesktopHost.verifiedApplication(executable: CopilotDesktopHost.executable))
        XCTAssertEqual(metadata.executable.path, "/Applications/GitHub Copilot.app/Contents/MacOS/github")
        XCTAssertEqual(metadata.version, Bundle(url: CopilotDesktopHost.application)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        XCTAssertFalse(metadata.version.isEmpty)
    }
}
