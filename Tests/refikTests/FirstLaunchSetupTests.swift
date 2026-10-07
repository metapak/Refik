import XCTest
import SwiftUI
import AppKit
import RefikInteractionWire
@testable import refik

final class FirstLaunchSetupTests: XCTestCase {
    func testPublicCLIRunnerUsesPrivateEmptyDirectoryAndPreservesRestrictedEnvironment() throws {
        let result = EditorFocusInstaller.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "pwd; /usr/bin/stat -f %Lp .; printf '%s\\n' \"$HOME\" \"$PATH\"; /bin/ls -A"])
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.failure, .none)
        let lines = result.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        let directory = try XCTUnwrap(lines.first)
        XCTAssertTrue(URL(fileURLWithPath: directory).lastPathComponent.hasPrefix("refik-extension-"))
        XCTAssertEqual(lines[1], "700")
        XCTAssertEqual(lines[2], NSHomeDirectory())
        XCTAssertEqual(lines[3], "/usr/bin:/bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory))
    }
    func testPublicCLIRunnerClassifiesFailureWithoutExposingStderrInFailureCode() {
        let failed = EditorFocusInstaller.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "printf private-detail >&2; exit 7"])
        XCTAssertFalse(failed.success)
        XCTAssertEqual(failed.failure, .nonzeroExit)
        let absent = EditorFocusInstaller.run(URL(fileURLWithPath: "/nonexistent/refik-test-cli"), [])
        XCTAssertEqual(absent.failure, .launch)
    }
    private func defaults() -> (UserDefaults, String) {
        let name = "refik.setup.test." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    @MainActor func testFreshDiscoveryDoesNotInstallOrCompleteAndSkipSurvivesRestart() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        var installs = 0
        let state = FirstLaunchSetup(defaults: store, discover: { [FirstLaunchTool(id: "codex", name: "Codex", provider: .codex, editor: false)] }, install: { rows in installs += 1; return rows })
        XCTAssertTrue(state.shouldPresentAutomatically(existingEvidence: false))
        await state.refresh()
        XCTAssertEqual(installs, 0)
        XCTAssertNil(store.string(forKey: FirstLaunchSetup.dispositionKey))
        state.finish(skipped: true)
        let restarted = FirstLaunchSetup(defaults: store, discover: { [] }, install: { $0 })
        XCTAssertFalse(restarted.shouldPresentAutomatically(existingEvidence: false))
        XCTAssertEqual(store.string(forKey: FirstLaunchSetup.dispositionKey), "skipped")
    }
    @MainActor func testExistingInstallAdoptionMarkerStopsForcedOpeningButDoesNotPreventSettingsRefresh() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let state = FirstLaunchSetup(defaults: store, discover: { [FirstLaunchTool(id: "claude", name: "Claude Code", provider: .claude, editor: false, status: .installed)] }, install: { $0 })
        XCTAssertFalse(state.shouldPresentAutomatically(existingEvidence: true))
        XCTAssertEqual(store.string(forKey: FirstLaunchSetup.dispositionKey), "existingInstallation")
        await state.refresh()
        XCTAssertEqual(state.tools.count, 1)
        XCTAssertFalse(state.shouldPresentAutomatically(existingEvidence: false))
    }
    @MainActor func testFailureFinishAndRetryRetainMissingConnectionWithoutReopeningAutomatically() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let row = FirstLaunchTool(id: "claude", name: "Claude Code", provider: .claude, editor: false)
        var calls = 0
        let state = FirstLaunchSetup(defaults: store, discover: { [row] }, install: { rows in
            calls += 1; return rows.map { row in var next = row; next.status = calls == 1 ? .failed : .installed; return next }
        })
        await state.refresh(); await state.connect()
        XCTAssertEqual(state.tools[0].status, .failed)
        XCTAssertTrue(state.attempted)
        state.finish(skipped: false)
        XCTAssertEqual(store.string(forKey: FirstLaunchSetup.dispositionKey), "finished")
        let reopen = FirstLaunchSetup(defaults: store, discover: { [row] }, install: { $0 })
        XCTAssertFalse(reopen.shouldPresentAutomatically(existingEvidence: false))
        await reopen.refresh(); XCTAssertEqual(reopen.tools[0].status, .failed)
        await state.connect(); XCTAssertEqual(state.tools[0].status, .installed)
        XCTAssertEqual(store.stringArray(forKey: FirstLaunchSetup.failuresKey), [])
    }
    @MainActor func testUnselectedAbsentAndBusyActionsDoNotInvokeInstall() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        var calls = 0
        let state = FirstLaunchSetup(defaults: store, discover: { [] }, install: { calls += 1; return $0 })
        await state.refresh(); await state.connect(); XCTAssertEqual(calls, 0)
        state.tools = [FirstLaunchTool(id: "codex", name: "Codex", provider: .codex, editor: false, selected: false)]
        await state.connect(); XCTAssertEqual(calls, 0)
    }
    func testProviderDedupPartialFailureAndAlreadyInstalledNoOp() {
        let rows = [FirstLaunchTool(id: "claude", name: "Claude", provider: .claude, editor: false), FirstLaunchTool(id: "claude-second-host", name: "Claude VS Code", provider: .claude, editor: false), FirstLaunchTool(id: "editor:Code", name: "Code", provider: nil, editor: true)]
        var providerCalls = 0, editorCalls = 0
        let result = FirstLaunchSetup.runInstall(rows, providerInstaller: { _ in providerCalls += 1; throw CocoaError(.fileWriteNoPermission) }, editorInstaller: { editorCalls += 1; return "" }, installed: { $0.editor })
        XCTAssertEqual(providerCalls, 1); XCTAssertEqual(editorCalls, 1)
        XCTAssertEqual(result.map(\.status), [.failed, .failed, .installed])
        let already = rows.map { row in var row = row; row.status = .installed; return row }
        _ = FirstLaunchSetup.runInstall(already, providerInstaller: { _ in providerCalls += 1 }, editorInstaller: { editorCalls += 1; return "" }, installed: { _ in true })
        XCTAssertEqual(providerCalls, 1); XCTAssertEqual(editorCalls, 1)
    }
    func testPartialAndDisabledOwnedHooksAreNotReadyAndDisabledIsNeverReenabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refik-setup-hooks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("settings.json"), helper = root.appendingPathComponent("refikHook"), bundled = root.appendingPathComponent("bundledHelper")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bundled.path)
        let entry: [String: Any] = ["hooks": [["type": "command", "command": helper.path + " claude Stop"]]]
        var hooks: [String: Any] = ["Stop": [entry]]
        func write(_ disabled: Bool = false) throws {
            try JSONSerialization.data(withJSONObject: ["hooks": hooks, "disableAllHooks": disabled, "foreignSetting": "preserved"]).write(to: config)
        }
        try write()
        XCTAssertEqual(FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled), .found)
        let partialBytes = try Data(contentsOf: config)
        var repairs = 0
        let partialRow = FirstLaunchTool(id: "claude", name: "Claude Code", provider: .claude, editor: false, status: .found)
        let repaired = FirstLaunchSetup.runInstall([partialRow], providerInstaller: { provider in
            repairs += 1
            try HookInstaller.ensureHelper(destination: helper, bundled: bundled)
            try HookInstaller.setEnabled(true, provider: provider, at: config, helper: helper, expectedOriginal: partialBytes)
        }, editorInstaller: { XCTFail("No editor"); return "" }, installed: { _ in FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled) == .installed })
        XCTAssertEqual(repairs, 1); XCTAssertEqual(repaired[0].status, .installed)
        let repairedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any])
        XCTAssertEqual(repairedObject["foreignSetting"] as? String, "preserved")
        for event in HookInstaller.claudeEvents { hooks[event] = [["hooks": [["type": "command", "command": helper.path + " claude " + event]]]] }
        try write()
        XCTAssertEqual(FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled), .installed)
        try FileManager.default.removeItem(at: helper)
        XCTAssertEqual(FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled), .found)
        let completeBytes = try Data(contentsOf: config)
        let restored = FirstLaunchSetup.runInstall([partialRow], providerInstaller: { provider in
            repairs += 1
            try HookInstaller.ensureHelper(destination: helper, bundled: bundled)
            try HookInstaller.setEnabled(true, provider: provider, at: config, helper: helper, expectedOriginal: completeBytes)
        }, editorInstaller: { XCTFail("No editor"); return "" }, installed: { _ in FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled) == .installed })
        XCTAssertEqual(repairs, 2); XCTAssertEqual(restored[0].status, .installed)
        try write(true)
        let original = try Data(contentsOf: config)
        XCTAssertEqual(FirstLaunchSetup.providerStatus(.claude, at: config, helper: helper, bundledHelper: bundled), .disabled)
        let disabled = FirstLaunchTool(id: "claude", name: "Claude Code", provider: .claude, editor: false, selected: false, status: .disabled)
        let result = FirstLaunchSetup.runInstall([disabled], providerInstaller: { _ in XCTFail("Disabled provider must not be enabled") }, editorInstaller: { XCTFail("No editor installation"); return "" }, installed: { _ in false })
        XCTAssertEqual(result[0].status, .disabled)
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    func testRetainedEditorReceiptRequiresSignedPublicInstalledExtensionProofAndCanRepairMissingExtension() {
        let host = EditorFocusHost.installations[0], receipts = [EditorFocusHost.installations[0].application.path: "prior-checksum"]
        var queries = 0
        let missing = FirstLaunchSetup.editorStatus(host, receipts: receipts, verified: { _ in true }, runner: { _, args in
            queries += 1; XCTAssertEqual(args, ["--list-extensions", "--show-versions"])
            return .init(success: true, output: "foreign.extension@1.0.0")
        }, helperValid: { true })
        XCTAssertEqual(missing, .found); XCTAssertEqual(queries, 0)
        XCTAssertEqual(FirstLaunchSetup.editorStatus(host, receipts: receipts, verified: { _ in false }, runner: { _, _ in XCTFail("Unsigned CLI must not run"); return .init(success: false, output: "") }, helperValid: { true }), .found)
        let installed = FirstLaunchSetup.editorStatus(host, receipts: receipts, verified: { _ in true }, runner: { _, _ in .init(success: true, output: "refik.editor-focus@" + EditorFocusInstaller.version) }, helperValid: { true })
        XCTAssertEqual(installed, .found) // A prior arbitrary checksum or CLI listing is not package proof.
        var repairs = 0
        let row = FirstLaunchTool(id: "editor:" + host.name, name: host.name, provider: nil, editor: true, status: missing)
        let result = FirstLaunchSetup.runInstall([row], providerInstaller: { _ in XCTFail("No provider") }, editorInstaller: { repairs += 1; return "installed" }, installed: { _ in true })
        XCTAssertEqual(repairs, 1); XCTAssertEqual(result[0].status, .installed)
    }
    func testEditorOnlyFreshSetupRestoresHelperWithoutProviderConfigurationAndRejectsStaleHelper() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("refik-setup-helper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bundledHelper"), target = root.appendingPathComponent("support/refikHook")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: source.path)
        XCTAssertFalse(FirstLaunchSetup.helperReady(helper: target, bundled: source))
        let editor = FirstLaunchTool(id: "editor:Code", name: "Code", provider: nil, editor: true)
        let result = FirstLaunchSetup.runInstall([editor], providerInstaller: { _ in XCTFail("Editor-only setup cannot register provider hooks") }, editorInstaller: {
            do { try HookInstaller.ensureHelper(destination: target, bundled: source); return "installed" }
            catch { XCTFail("Helper install failed"); return "failed" }
        }, installed: { _ in FirstLaunchSetup.helperReady(helper: target, bundled: source) })
        XCTAssertEqual(result[0].status, .installed)
        let files = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        XCTAssertEqual(files, ["refikHook"])
        let modified = try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertFalse(try HookInstaller.ensureHelper(destination: target, bundled: source))
        XCTAssertEqual(try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        try Data("stale".utf8).write(to: target)
        XCTAssertFalse(FirstLaunchSetup.helperReady(helper: target, bundled: source))
        XCTAssertTrue(try HookInstaller.ensureHelper(destination: target, bundled: source))
        XCTAssertTrue(FirstLaunchSetup.helperReady(helper: target, bundled: source))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        XCTAssertFalse(FirstLaunchSetup.helperReady(helper: target, bundled: source))
        try HookInstaller.ensureHelper(destination: target, bundled: source)
        XCTAssertTrue(FirstLaunchSetup.helperReady(helper: target, bundled: source))
    }
    @MainActor func testVerifiedConnectionHidesTechnicalCleanupNoteWithoutHidingFailedSetup() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let technical = "Editör komutu tamamlandı. Özel çalışma klasörü korundu."
        let rows = [FirstLaunchTool(id: "editor:Cursor", name: "Cursor", provider: nil, editor: true),
                    FirstLaunchTool(id: "editor:Antigravity IDE", name: "Antigravity IDE", provider: nil, editor: true)]
        let setup = FirstLaunchSetup(defaults: store, discover: { rows }, install: { rows in
            rows.enumerated().map { index, row in
                var result = row; result.healthNote = technical
                result.status = index == 0 ? .installed : .failed
                result.detail = index == 0 ? nil : "Kurulu paket doğrulanamadı; yeniden deneyebilirsiniz."
                return result
            }
        })
        await setup.refresh(); await setup.connect()
        XCTAssertEqual(setup.tools[0].status, .installed)
        XCTAssertEqual(setup.tools[0].healthNote, technical, "Internal diagnostic state remains intact")
        XCTAssertNil(setup.tools[0].visibleHealthNote)
        XCTAssertNil(setup.tools[0].detail)
        XCTAssertEqual(setup.tools[1].status, .failed)
        XCTAssertEqual(setup.tools[1].visibleHealthNote, technical)
        XCTAssertTrue(setup.tools[1].detail?.contains("doğrulanamadı") == true)
        XCTAssertEqual(store.stringArray(forKey: FirstLaunchSetup.failuresKey), ["editor:Antigravity IDE"])
        XCTAssertTrue(setup.message.contains("kurulamadı"))
    }
    @MainActor func testEditorFailureDetailSurvivesRefreshAndSuccessfulRetryClearsIt() async {
        let (store, name) = defaults(); defer { store.removePersistentDomain(forName: name) }
        let row = FirstLaunchTool(id: "editor:Antigravity IDE", name: "Antigravity IDE · proje bağlantısı", provider: nil, editor: true)
        let failed = FirstLaunchSetup.runInstall([row], providerInstaller: { _ in XCTFail() }, editorInstaller: { "Antigravity IDE: mevcut eklenti korunuyor; paket doğrulanamadı" }, installed: { _ in false })
        XCTAssertTrue(failed[0].detail?.contains("paket doğrulanamadı") == true)
        let setup = FirstLaunchSetup(defaults: store, discover: { [row] }, install: { _ in failed })
        await setup.refresh(); await setup.connect()
        let retry = FirstLaunchSetup(defaults: store, discover: { [row] }, install: { rows in rows.map { r in var r = r; r.status = .installed; r.detail = nil; return r } })
        await retry.refresh(); XCTAssertEqual(retry.tools[0].detail, failed[0].detail)
        await retry.connect(); XCTAssertNil(retry.tools[0].detail)
        XCTAssertEqual(store.dictionary(forKey: FirstLaunchSetup.failureDetailsKey)?.count, 0)
    }
    func testExactOwnedEditorPayloadCanAdoptMissingReceiptAndRejectsChangedOrAmbiguousInstallations() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".refik-adoption-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let authored = root.appendingPathComponent("extension"), extensions = root.appendingPathComponent("extensions"), installed = extensions.appendingPathComponent("refik.editor-focus-0.1.0")
        for directory in [authored, extensions, installed] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let manifest: [String: Any] = ["name": "editor-focus", "publisher": "refik", "version": "0.1.0", "main": "extension.js"]
        for directory in [authored, installed] {
            try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("package.json"))
            try Data("owned script".utf8).write(to: directory.appendingPathComponent("extension.js"))
            try Data("owned readme".utf8).write(to: directory.appendingPathComponent("readme.md"))
        }
        let archive = root.appendingPathComponent("own.vsix"), receipts = root.appendingPathComponent("receipt.json")
        let zipped = EditorFocusInstaller.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", authored.path, archive.path]); XCTAssertTrue(zipped.success)
        var metadata: [String: Any] = ["identifier": ["id": "refik.editor-focus"], "version": "0.1.0", "location": ["scheme": "file", "fsPath": installed.path]]
        let index = extensions.appendingPathComponent("extensions.json")
        func writeIndex(_ entries: [[String: Any]]) throws { try JSONSerialization.data(withJSONObject: entries).write(to: index) }
        try writeIndex([metadata])
        var localManifest = manifest; localManifest["__metadata"] = ["installedTimestamp": 1]
        try JSONSerialization.data(withJSONObject: localManifest).write(to: installed.appendingPathComponent("package.json"))
        XCTAssertNotNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        let host = EditorFocusHost.installations[0]
        try JSONEncoder().encode(["/Applications/Other.app": "foreign-receipt"]).write(to: receipts)
        let result = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipts, installations: [host], verified: { _ in true }, runner: { _, args in XCTAssertEqual(args, ["--list-extensions", "--show-versions"]); return .init(success: true, output: "refik.editor-focus@0.1.0") }, extensionRoot: { _ in extensions }, executableAvailable: { _ in true })
        XCTAssertTrue(result.contains("paket doğrulandı")); XCTAssertNotNil(try? Data(contentsOf: receipts))
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipts))["/Applications/Other.app"], "foreign-receipt")
        let validReceipts = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipts))
        XCTAssertEqual(FirstLaunchSetup.editorStatus(host, receipts: validReceipts, verified: { _ in true }, runner: { _, _ in XCTFail("Discovery must not spawn vendor CLI"); return .init(success: false, output: "") }, helperValid: { true }, archive: archive, extensionRoot: { _ in extensions }), .installed)
        XCTAssertEqual(FirstLaunchSetup.editorStatus(host, receipts: [host.application.path: "old-checksum"], verified: { _ in true }, helperValid: { true }, archive: archive, extensionRoot: { _ in extensions }), .found)
        localManifest["unexpected"] = true; try JSONSerialization.data(withJSONObject: localManifest).write(to: installed.appendingPathComponent("package.json")); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        localManifest.removeValue(forKey: "unexpected"); try JSONSerialization.data(withJSONObject: localManifest).write(to: installed.appendingPathComponent("package.json"))
        try Data("foreign script".utf8).write(to: installed.appendingPathComponent("extension.js")); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        try Data("owned script".utf8).write(to: installed.appendingPathComponent("extension.js"))
        metadata["version"] = "9.0.0"; try writeIndex([metadata]); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        metadata["version"] = "0.1.0"; try writeIndex([metadata, metadata]); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        metadata["identifier"] = ["id": "foreign.extension"]; try writeIndex([metadata]); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        metadata["identifier"] = ["id": "refik.editor-focus"]; metadata["location"] = ["scheme": "file", "fsPath": authored.path]; try writeIndex([metadata]); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
        metadata["location"] = ["scheme": "file", "fsPath": installed.path]; try writeIndex([metadata])
        let script = installed.appendingPathComponent("extension.js"); try FileManager.default.removeItem(at: script); try FileManager.default.createSymbolicLink(at: script, withDestinationURL: authored.appendingPathComponent("extension.js")); XCTAssertNil(EditorFocusInstaller.adoptionProof(root: extensions, archive: archive))
    }
    func testFailedInstallExitRequiresExactPostconditionAndPreservesConcurrentReceipt() throws {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".refik-postcondition-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let authored = root.appendingPathComponent("extension"), extensions = root.appendingPathComponent("extensions"), installed = extensions.appendingPathComponent("refik.editor-focus-0.1.0")
        for d in [authored, extensions, installed] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let manifest = ["name": "editor-focus", "publisher": "refik", "version": "0.1.0", "main": "extension.js"]
        for d in [authored, installed] {
            try JSONSerialization.data(withJSONObject: manifest).write(to: d.appendingPathComponent("package.json"))
            try Data("owned".utf8).write(to: d.appendingPathComponent("extension.js"))
            try Data("readme".utf8).write(to: d.appendingPathComponent("readme.md"))
        }
        let archive = root.appendingPathComponent("own.vsix"), receipt = root.appendingPathComponent("receipt.json")
        XCTAssertTrue(EditorFocusInstaller.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", authored.path, archive.path]).success)
        try JSONSerialization.data(withJSONObject: [["identifier": ["id": "refik.editor-focus"], "version": "0.1.0", "location": ["scheme": "file", "fsPath": installed.path]]]).write(to: extensions.appendingPathComponent("extensions.json"))
        let host = EditorFocusHost.installations[0], foreign = ["foreign": "preserved"]
        for scenario in ["valid", "signal", "timeoutCleanup", "successCleanup", "absent", "changed", "successForeign", "concurrent"] {
            try JSONEncoder().encode(foreign).write(to: receipt)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
            if FileManager.default.fileExists(atPath: installed.path) { try FileManager.default.removeItem(at: installed) }
            var queries = 0
            _ = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipt, installations: [host], verified: { _ in true }, runner: { _, args in
                if args.first == "--install-extension" {
                    if scenario != "absent" {
                        try! FileManager.default.copyItem(at: authored, to: installed)
                        if scenario == "changed" || scenario == "successForeign" { try! Data("foreign".utf8).write(to: installed.appendingPathComponent("extension.js")) }
                    }
                    if scenario == "concurrent" { try! JSONEncoder().encode(["foreign": "newer"]).write(to: receipt) }
                    return .init(success: scenario == "successForeign" || scenario == "successCleanup", output: "private vendor error", failure: scenario == "successCleanup" ? .none : (scenario == "signal" ? .signal : (scenario == "timeoutCleanup" ? .timeout : .nonzeroExit)), cleanupUncertain: scenario == "timeoutCleanup" || scenario == "successCleanup")
                }
                queries += 1
                XCTAssertEqual(queries, 1, "No immediately-postinstall vendor spawn")
                return .init(success: true, output: queries > 1 && scenario != "absent" ? "refik.editor-focus@0.1.0" : "")
            }, extensionRoot: { _ in extensions }, executableAvailable: { _ in true })
            let records = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receipt))
            XCTAssertEqual(records["foreign"], scenario == "concurrent" ? "newer" : "preserved")
            XCTAssertEqual(records[host.application.path] != nil, scenario == "valid" || scenario == "signal" || scenario == "timeoutCleanup" || scenario == "successCleanup", scenario)
            if scenario == "successCleanup" {
                let warning = try XCTUnwrap(EditorFocusInstaller.healthWarning(host))
                XCTAssertTrue(warning.contains("komutu tamamlandı"))
                XCTAssertTrue(warning.contains("özel çalışma klasörü korundu"))
                XCTAssertFalse(warning.contains("kurulum sonucu doğrulanamadı"))
            }
            if scenario == "timeoutCleanup" { XCTAssertTrue(EditorFocusInstaller.healthWarning(host)?.contains("özel çalışma klasörü korundu") == true) }
            if scenario == "valid" {
                XCTAssertNotNil(EditorFocusInstaller.healthWarning(host))
                let before = try Data(contentsOf: receipt)
                _ = EditorFocusInstaller.configure(enabled: true, archive: archive, receiptURL: receipt, installations: [host], verified: { _ in true }, runner: { _, args in
                    XCTFail("Exact ready payload must not spawn CLI")
                    return .init(success: true, output: "refik.editor-focus@0.1.0")
                }, extensionRoot: { _ in extensions }, executableAvailable: { _ in true })
                XCTAssertEqual(try Data(contentsOf: receipt), before)
            }
        }
    }
    func testPreviouslyReadyRowIsRecheckedAtCommitAndDisabledRowIsPreserved() {
        let ready = FirstLaunchTool(id: "editor:Code", name: "Code", provider: nil, editor: true, status: .installed)
        let result = FirstLaunchSetup.runInstall([ready], providerInstaller: { _ in XCTFail() }, editorInstaller: { XCTFail(); return "" }, installed: { _ in false })
        XCTAssertEqual(result[0].status, .failed)
        var disabled = ready; disabled.status = .disabled
        XCTAssertEqual(FirstLaunchSetup.runInstall([disabled], providerInstaller: { _ in XCTFail() }, editorInstaller: { XCTFail(); return "" }, installed: { _ in XCTFail(); return false })[0].status, .disabled)
    }
    func testOptInInstalledAntigravityPayloadProofWithoutReceiptMutation() throws {
        guard ProcessInfo.processInfo.environment["REFIK_TEST_AG_ADOPTION_PROOF"] == "1" else { throw XCTSkip("Opt-in installed own extension read-only proof") }
        let host = try XCTUnwrap(EditorFocusHost.installations.first { $0.bundleID == "com.google.antigravity-ide" })
        XCTAssertTrue(EditorFocusHost.verified(host))
        let listing = EditorFocusInstaller.run(host.command, ["--list-extensions", "--show-versions"])
        XCTAssertTrue(listing.success)
        XCTAssertTrue(listing.output.split(whereSeparator: \.isNewline).contains { $0 == "refik.editor-focus@0.1.0" })
        let root = try XCTUnwrap(EditorFocusInstaller.extensionsRoot(host))
        XCTAssertNotNil(EditorFocusInstaller.adoptionProof(root: root, archive: URL(fileURLWithPath: "/Applications/refik.app/Contents/Resources/RefikEditorFocus.vsix")))
    }
    @MainActor func testOffscreenFixturePreviews() throws {
        guard ProcessInfo.processInfo.environment["REFIK_TEST_FIRST_LAUNCH_PREVIEW"] == "1" else { throw XCTSkip("Opt-in isolated fixture rendering") }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/tmp/refik-first-launch-preview-20261005")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for phase in ["first", "success", "partial"] {
            let view = NSHostingView(rootView: FirstLaunchView(setup: .fixture(phase), finish: { _ in XCTFail("Preview action must not run") }, notifications: { XCTFail("Preview must not request permission") }).environment(\.controlActiveState, .key))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640), styleMask: [], backing: .buffered, defer: false)
            window.contentView = view; view.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
            view.appearance = NSAppearance(named: .aqua); view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(phase + ".png"))
        }
    }
}
