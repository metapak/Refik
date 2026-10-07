import Foundation

// Compatibility names are deliberately confined to this migration boundary.
enum LegacyMigration {
    static let oldBundleID = "com.mascotmet.app"
    static let oldPreferenceKey = "mascotmet.preferences"
    static var legacyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mascotmet", isDirectory: true)
    }
    static var isolated: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["REFIK_DATA_DIR"] != nil || env["MASCOTMET_DATA_DIR"] != nil
    }
    static var dataOverride: String? {
        let env = ProcessInfo.processInfo.environment
        return env["REFIK_DATA_DIR"] ?? env["MASCOTMET_DATA_DIR"]
    }
    static var observationOverride: String? {
        let env = ProcessInfo.processInfo.environment
        return env["REFIK_OBSERVATION_ROOT"] ?? env["MASCOTMET_OBSERVATION_ROOT"]
    }
    static func quoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func ownsCommand(_ command: String, executable: URL) -> Bool {
        command.hasPrefix(quoted(executable.path) + " ") || command.hasPrefix(executable.path + " ")
    }
    static func ownsLegacyHook(_ command: String) -> Bool {
        ownsCommand(command, executable: legacyDirectory.appendingPathComponent("MascotmetHook"))
    }
    static func ownsLegacyStatusLine(_ command: String) -> Bool {
        ownsCommand(command, executable: legacyDirectory.appendingPathComponent("MascotmetCLI"))
    }
    // Copy only portable state. Live socket files and executable copies must not migrate.
    static func copyState(from old: URL, to new: URL) throws {
        let manager = FileManager.default
        for name in ["attention-state.json", "signal.token"] {
            let source = old.appendingPathComponent(name), destination = new.appendingPathComponent(name)
            guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) else { continue }
            try manager.createDirectory(at: new, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
    static func legacyPreferences(domain: [String: Any]?) -> Data? {
        domain?[oldPreferenceKey] as? Data
    }
    static func containsLegacyHook(_ root: [String: Any]) -> Bool {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { value in
            (value as? [[String: Any]])?.contains { entry in
                (entry["hooks"] as? [[String: Any]])?.contains { ownsLegacyHook($0["command"] as? String ?? "") } ?? false
            } ?? false
        }
    }
    static func perform() throws {
        guard !isolated else { return }
        try copyState(from: legacyDirectory, to: BridgePath.directory)
        let defaults = UserDefaults.standard
        if defaults.data(forKey: "refik.preferences") == nil,
           let data = legacyPreferences(domain: defaults.persistentDomain(forName: oldBundleID)),
           (try? JSONDecoder().decode(Preferences.self, from: data)) != nil {
            defaults.set(data, forKey: "refik.preferences")
        }
        for provider in [Provider.codex, .claude, .antigravity] {
            let path = HookInstaller.configuration(provider)
            guard let data = try? Data(contentsOf: path),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  containsLegacyHook(root) || legacyAntigravity(root) else { continue }
            try HookInstaller.setEnabled(true, provider: provider)
        }
        let manager = FileManager.default
        let bin = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let oldLink = bin.appendingPathComponent("mascotmet")
        let oldTarget = legacyDirectory.appendingPathComponent("mascotmet").path
        guard (try? manager.destinationOfSymbolicLink(atPath: oldLink.path)) == oldTarget else { return }
        let source = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikCLI")
        let stable = BridgePath.directory.appendingPathComponent("refik"), link = bin.appendingPathComponent("refik")
        guard manager.isExecutableFile(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
        if manager.fileExists(atPath: link.path) || (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            guard (try? manager.destinationOfSymbolicLink(atPath: link.path)) == stable.path else { throw CocoaError(.fileWriteFileExists) }
        }
        try manager.createDirectory(at: BridgePath.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(contentsOf: source).write(to: stable, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stable.path)
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) == nil {
            try manager.createSymbolicLink(at: link, withDestinationURL: stable)
        }
        // Preserve the old alias as a rollback symlink before removing its public name.
        let backup = legacyDirectory.appendingPathComponent("legacy-cli-link-backup")
        if (try? manager.destinationOfSymbolicLink(atPath: backup.path)) == nil && !manager.fileExists(atPath: backup.path) {
            try manager.createSymbolicLink(atPath: backup.path, withDestinationPath: oldTarget)
        }
        try manager.removeItem(at: oldLink)
    }
    static func legacyAntigravity(_ root: [String: Any]) -> Bool {
        guard let entry = root["mascotmet-observer"] as? [String: Any] else { return false }
        return entry.values.contains { value in
            guard let items = value as? [[String: Any]] else { return false }
            return items.contains { item in
                ownsLegacyHook(item["command"] as? String ?? "") ||
                (item["hooks"] as? [[String: Any]])?.contains { ownsLegacyHook($0["command"] as? String ?? "") } == true
            }
        }
    }
    static func migrateStatusLineKey(_ root: inout [String: Any]) {
        guard let status = root["statusLine"] as? [String: Any],
              ownsLegacyStatusLine(status["command"] as? String ?? ""),
              root["refikOriginalStatusLine"] == nil,
              let saved = root["mascotmetOriginalStatusLine"] else { return }
        root["refikOriginalStatusLine"] = saved
        root.removeValue(forKey: "mascotmetOriginalStatusLine")
    }
    static func removeLegacyAntigravity(_ root: inout [String: Any]) {
        guard legacyAntigravity(root) else { return }
        removeObserverCommands(&root, key: "mascotmet-observer", owns: ownsLegacyHook)
    }
    static func removeObserverCommands(_ root: inout [String: Any], key: String, owns: (String) -> Bool) {
        guard var observer = root[key] as? [String: Any] else { return }
        for event in HookInstaller.antigravityEvents {
            guard let items = observer[event] as? [[String: Any]] else { continue }
            let filtered = items.compactMap { item -> [String: Any]? in
                if owns(item["command"] as? String ?? "") { return nil }
                guard let handlers = item["hooks"] as? [[String: Any]] else { return item }
                let kept = handlers.filter { !owns($0["command"] as? String ?? "") }
                if kept.isEmpty && Set(item.keys).isSubset(of: ["matcher", "hooks"]) { return nil }
                var edited = item; edited["hooks"] = kept
                return edited
            }
            if filtered.isEmpty { observer.removeValue(forKey: event) }
            else { observer[event] = filtered }
        }
        if Set(observer.keys).isSubset(of: ["enabled"]) { root.removeValue(forKey: key) }
        else { root[key] = observer }
    }
}
