import Foundation
import CryptoKit
import Darwin
import RefikInteractionWire

enum EditorFocusInstaller {
    static let extensionID = "refik.editor-focus"
    static let version = "0.1.0"
    enum Failure: String, Codable { case none, preparation, launch, timeout, signal, nonzeroExit, outputLimit, cleanupBlocked }
    struct Result {
        let success: Bool
        let output: String
        var failure: Failure = .none
        var elapsedMS: Int = 0
        var terminationCode: Int? = nil
        var processPID: Int32? = nil
        var cleanupUncertain = false
        var outputEOF: Bool? = nil
        var remainingChildren: Bool? = nil
        var captureIncomplete: Bool? = nil
        var outputReadFailed: Bool? = nil
        var leaderReaped: Bool? = nil
    }
    typealias Runner = (URL, [String]) -> Result
    static func managedHosts(receiptURL: URL) -> Set<String> {
        let receipts = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))) ?? [:]
        return Set(EditorFocusHost.installations.filter { receipts[$0.application.path] != nil }.map(\.bundleID))
    }
    static func run(_ executable: URL, _ arguments: [String]) -> Result {
        EditorFocusProcessRunner.run(executable, arguments)
    }

    // Public CLI receipts describe only our extension. Foreign extensions and
    // every editor setting remain untouched, including custom profiles.
    private static let mutationLock = NSLock()
    private static var healthFailures: [String: (failure: Failure, cleanupUncertain: Bool)] = [:]
    static func healthWarning(_ host: EditorFocusHost.Installation) -> String? {
        mutationLock.lock(); defer { mutationLock.unlock() }
        return healthFailures[host.bundleID].map {
            ($0.failure == .none ? "Editör komutu tamamlandı. Kurulu paket ayrıca doğrulandı." : "Son editör komutu: " + failureText($0.failure) + ". Kurulu paket ayrıca doğrulandı.") +
            ($0.cleanupUncertain && $0.failure != .cleanupBlocked ? " Alt süreçlerin tamamlandığı doğrulanamadı; özel çalışma klasörü korundu." : "")
        }
    }
    static func extensionsRoot(_ host: EditorFocusHost.Installation) -> URL? {
        let names = ["com.microsoft.VSCode": ".vscode", "com.todesktop.230313mzl4w4u92": ".cursor", "com.google.antigravity-ide": ".antigravity-ide"]
        let directory = names[host.bundleID] ?? (host.name == "Devin" ? ".devin" : host.name == "Windsurf" ? ".windsurf" : nil)
        return directory.map { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent($0 + "/extensions") }
    }
    // A receipt may be recovered only for our exact installed package. The
    // editor-added manifest metadata is not part of the authored payload.
    static func adoptionProof(root: URL, archive: URL) -> String? {
        func secure(_ url: URL, directory: Bool) -> Bool {
            var info = stat()
            return lstat(url.path, &info) == 0 && info.st_uid == getuid() && info.st_mode & 0o022 == 0 && info.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG)
        }
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let base = root.standardizedFileURL
        guard base.path.hasPrefix(home.path + "/"), base.resolvingSymlinksInPath().path == base.path else { return nil }
        var component = base
        while component.path != home.path {
            guard secure(component, directory: true) else { return nil }
            component.deleteLastPathComponent()
        }
        let metadata = base.appendingPathComponent("extensions.json")
        guard secure(metadata, directory: false), let data = try? Data(contentsOf: metadata), data.count <= 1_048_576,
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let matching = entries.filter { ($0["identifier"] as? [String: Any])?["id"] as? String == extensionID }
        guard matching.count == 1, let entry = matching.first, entry["version"] as? String == version,
              let location = entry["location"] as? [String: Any], location["scheme"] as? String == "file",
              let path = location["fsPath"] as? String else { return nil }
        let folder = URL(fileURLWithPath: path).standardizedFileURL
        guard folder.deletingLastPathComponent().path == base.path, folder.resolvingSymlinksInPath().path == folder.path,
              secure(folder, directory: true) else { return nil }
        var fingerprint = data
        for name in ["package.json", "extension.js", "readme.md"] {
            let file = folder.appendingPathComponent(name)
            guard secure(file, directory: false), let installed = try? Data(contentsOf: file), installed.count <= 65_536 else { return nil }
            let packed = run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", archive.path, "extension/" + name])
            guard packed.success else { return nil }
            let expected = Data(packed.output.utf8)
            if name == "package.json" {
                guard var actual = try? JSONSerialization.jsonObject(with: installed) as? [String: Any],
                      let authored = try? JSONSerialization.jsonObject(with: expected) as? [String: Any], authored["__metadata"] == nil else { return nil }
                actual.removeValue(forKey: "__metadata")
                guard NSDictionary(dictionary: actual).isEqual(to: authored) else { return nil }
            } else if installed != expected { return nil }
            fingerprint.append(installed)
        }
        return SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
    }
    struct PayloadProof {
        let checksum: String
        let fingerprint: String
        let root: URL
    }
    static func payloadProof(_ host: EditorFocusHost.Installation, archive: URL,
                             verified: (EditorFocusHost.Installation) -> Bool = EditorFocusHost.verified,
                             extensionRoot: (EditorFocusHost.Installation) -> URL? = extensionsRoot) -> PayloadProof? {
        guard verified(host), let bytes = try? Data(contentsOf: archive), !bytes.isEmpty,
              let root = extensionRoot(host), let fingerprint = adoptionProof(root: root, archive: archive),
              verified(host) else { return nil }
        return PayloadProof(checksum: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), fingerprint: fingerprint, root: root)
    }
    static func ready(_ host: EditorFocusHost.Installation, archive: URL, receipts: [String: String],
                      verified: (EditorFocusHost.Installation) -> Bool = EditorFocusHost.verified,
                      extensionRoot: (EditorFocusHost.Installation) -> URL? = extensionsRoot) -> Bool {
        guard let proof = payloadProof(host, archive: archive, verified: verified, extensionRoot: extensionRoot) else { return false }
        return receipts[host.application.path] == proof.checksum
    }
    enum Stage: String, Codable { case preflight, installation, payload, receipt, complete }
    enum DiagnosticReason: String, Codable {
        case none, signature, foreignPayload, started, commandFinished, commandFailed, mismatch, uninstallUnverified, changed, write
    }
    struct Diagnostic: Codable {
        let host: String
        let stage: Stage
        let reason: DiagnosticReason
        let commandFailure: Failure?
        let elapsedMS: Int?
        let terminationCode: Int?
        let processPID: Int32?
        let cleanupUncertain: Bool?
        let outputEOF: Bool?
        let remainingChildren: Bool?
        let captureIncomplete: Bool?
        let outputReadFailed: Bool?
        let leaderReaped: Bool?
    }
    private static let diagnosticStart = ProcessInfo.processInfo.systemUptime
    private static var diagnostics: [Diagnostic] = []
    private static let diagnosticDirectory: URL? = {
        guard ProcessInfo.processInfo.environment["REFIK_SETUP_DIAGNOSTICS"] == "1" else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("refik-setup-diagnostic-\(getpid())-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return directory }
        catch { return nil }
    }()
    // Explicit process-only opt-in. No output bodies, paths, accounts or tokens.
    private static func diagnose(_ host: EditorFocusHost.Installation, _ stage: Stage, _ reason: DiagnosticReason, result: Result? = nil) {
        guard ProcessInfo.processInfo.environment["REFIK_SETUP_DIAGNOSTICS"] == "1",
              ProcessInfo.processInfo.systemUptime - diagnosticStart <= 120, diagnostics.count < 60 else { return }
        diagnostics.append(Diagnostic(host: host.bundleID, stage: stage, reason: reason, commandFailure: result?.failure, elapsedMS: result?.elapsedMS, terminationCode: result?.terminationCode, processPID: result?.processPID, cleanupUncertain: result?.cleanupUncertain, outputEOF: result?.outputEOF, remainingChildren: result?.remainingChildren, captureIncomplete: result?.captureIncomplete, outputReadFailed: result?.outputReadFailed, leaderReaped: result?.leaderReaped))
        guard let directory = diagnosticDirectory else { return }
        let file = directory.appendingPathComponent("stages.json")
        if let bytes = try? JSONEncoder().encode(diagnostics) {
            try? bytes.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private static func failureText(_ failure: Failure) -> String {
        switch failure {
        case .timeout: return "komut zaman aşımına uğradı"
        case .signal: return "editör komutu beklenmedik biçimde sonlandı"
        case .outputLimit: return "komut çıktısı güvenli sınırı aştı"
        case .preparation: return "özel çalışma klasörü hazırlanamadı"
        case .launch: return "editör komutu başlatılamadı"
        case .nonzeroExit: return "editör komutu hata döndürdü"
        case .cleanupBlocked: return "komut alt süreci tamamlanamadı; çalışma klasörü korundu"
        case .none: return "kurulum sonucu doğrulanamadı"
        }
    }
    static func configure(enabled: Bool, archive: URL, receiptURL: URL,
                          installations: [EditorFocusHost.Installation] = EditorFocusHost.installations,
                          verified: (EditorFocusHost.Installation) -> Bool = EditorFocusHost.verified,
                          runner: Runner = run, extensionRoot: (EditorFocusHost.Installation) -> URL? = extensionsRoot,
                          executableAvailable: (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }) -> String {
        mutationLock.lock(); defer { mutationLock.unlock() }
        let initialReceipt = try? Data(contentsOf: receiptURL)
        guard initialReceipt == nil || initialReceipt.flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) }) != nil else {
            return "Bağlantı kaydı okunamadı; mevcut veriler korundu"
        }
        var receipts = initialReceipt.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        guard let bytes = try? Data(contentsOf: archive), !bytes.isEmpty else { return "Editör eklentisi paketi bulunamadı" }
        let checksum = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        var messages: [String] = []
        for host in installations where executableAvailable(host.command) {
            guard verified(host) else { diagnose(host, .preflight, .signature); messages.append("\(host.name): uygulama doğrulanamadı"); continue }
            let key = host.application.path
            let receiptBefore = try? Data(contentsOf: receiptURL)
            let existing = payloadProof(host, archive: archive, verified: verified, extensionRoot: extensionRoot)
            if !enabled {
                guard let receipt = receipts[key] else { continue }
                var info = stat()
                guard receipt == checksum, receiptBefore.flatMap({ try? JSONDecoder().decode([String: String].self, from: $0) }) == receipts,
                      lstat(receiptURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                      info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
                    diagnose(host, .receipt, .changed); messages.append("\(host.name): mevcut eklenti ve bağlantı kaydı korunuyor; sahiplik doğrulanamadı"); continue
                }
            }
            if enabled, existing?.checksum == checksum, receipts[key] == checksum {
                diagnose(host, .complete, .none); messages.append("\(host.name): bağlantı zaten kurulu"); continue
            }
            var result = Result(success: true, output: "")
            if !enabled || existing == nil {
                // Only preflight uses the public CLI; installation completion is
                // verified from the same strict authored payload on every path.
                let listed = runner(host.command, ["--list-extensions", "--show-versions"])
                if listed.cleanupUncertain { healthFailures[host.bundleID] = (listed.failure, true) }
                guard listed.success else { diagnose(host, .preflight, .commandFailed, result: listed); messages.append("\(host.name): \(failureText(listed.failure)); eklenti durumu okunamadı"); continue }
                diagnose(host, .preflight, .commandFinished, result: listed)
                let own = listed.output.split(whereSeparator: \.isNewline).contains { $0.lowercased().hasPrefix(extensionID + "@") }
                if enabled && own { diagnose(host, .payload, .foreignPayload); messages.append("\(host.name): aynı kimlikli mevcut eklenti korunuyor; paket doğrulanamadı"); continue }
                if !enabled && own {
                    let listedOwn = listed.output.split(whereSeparator: \.isNewline).filter { $0.lowercased().hasPrefix(extensionID + "@") }
                    guard listedOwn.count == 1, listedOwn[0].lowercased() == extensionID + "@" + version,
                          let existing, existing.checksum == receipts[key],
                          let current = payloadProof(host, archive: archive, verified: verified, extensionRoot: extensionRoot),
                          current.checksum == existing.checksum, current.fingerprint == existing.fingerprint,
                          (try? Data(contentsOf: receiptURL)) == receiptBefore else {
                        diagnose(host, .payload, .foreignPayload); messages.append("\(host.name): mevcut eklenti ve bağlantı kaydı korunuyor; paket sahipliği doğrulanamadı"); continue
                    }
                }
                // A valid stale receipt can be cleared when the CLI confirms
                // absence, without issuing an uninstall command.
                if enabled || own {
                    diagnose(host, .installation, .started)
                    result = runner(host.command, enabled ? ["--install-extension", archive.path] : ["--uninstall-extension", extensionID])
                    diagnose(host, .installation, .commandFinished, result: result)
                    if result.success && !result.cleanupUncertain {
                        if healthFailures[host.bundleID]?.cleanupUncertain != true { healthFailures.removeValue(forKey: host.bundleID) }
                    }
                    else { healthFailures[host.bundleID] = (result.failure, result.cleanupUncertain) }
                }
            }
            let proof = enabled ? payloadProof(host, archive: archive, verified: verified, extensionRoot: extensionRoot) : nil
            if enabled && proof == nil {
                diagnose(host, .payload, .mismatch); messages.append("\(host.name): \(failureText(result.failure)); kurulu paket doğrulanamadı"); continue
            }
            if !enabled {
                let check = runner(host.command, ["--list-extensions", "--show-versions"])
                guard check.success, !check.output.split(whereSeparator: \.isNewline).contains(where: { $0.lowercased().hasPrefix(extensionID + "@") }) else {
                    diagnose(host, .payload, .uninstallUnverified); messages.append("\(host.name): kaldırma sonucu doğrulanamadı"); continue
                }
            }
            var info = stat(); let exists = lstat(receiptURL.path, &info) == 0
            guard verified(host), (try? Data(contentsOf: receiptURL)) == receiptBefore,
                  !exists || (info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid() && info.st_mode & 0o022 == 0 && receiptBefore.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } == receipts),
                  proof.map({ original in
                      guard let current = payloadProof(host, archive: archive, verified: verified, extensionRoot: extensionRoot) else { return false }
                      return current.fingerprint == original.fingerprint && current.checksum == checksum
                  }) ?? true else {
                diagnose(host, .receipt, .changed); messages.append("\(host.name): bağlantı kaydı veya paket değişti; mevcut veriler korundu"); continue
            }
            if enabled { receipts[key] = checksum } else { receipts.removeValue(forKey: key) }
            do {
                try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
                diagnose(host, .complete, .none)
                messages.append("\(host.name): \(enabled ? "paket doğrulandı · bağlantı kurulu" : "kaldırıldı")" + (result.success ? "" : " · " + failureText(result.failure)))
            } catch { diagnose(host, .receipt, .write); messages.append("\(host.name): kurulum kaydı kaydedilemedi") }
        }
        return messages.isEmpty ? "Desteklenen kurulu editör bulunamadı" : messages.joined(separator: "\n")
    }
}
