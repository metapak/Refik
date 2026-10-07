import Foundation
import AppKit
import RefikInteractionWire

// Display names are independent of persisted preference identifiers and asset filenames.
enum MascotStyle {
    static func identifier(_ raw: String) -> String {
        switch raw.lowercased() {
        case "stern", "sert", "ardly": return "stern"
        case "webai", "web ai", "web-ai": return "webAI"
        default: return "cute"
        }
    }
    static func assetName(_ raw: String) -> String {
        switch identifier(raw) {
        case "stern": return "sert"
        case "webAI": return "web-ai"
        default: return "tatlı"
        }
    }
    static func displayName(_ raw: String) -> String {
        switch identifier(raw) {
        case "stern": return "ardly"
        case "webAI": return "webai"
        default: return "weety"
        }
    }
}

enum UsageSemantic: String { case used, remaining, unknown }
enum UsageFormatting {
    static func resetCountdown(until reset: Date?, at now: Date) -> String? {
        guard let reset else { return nil }
        let seconds = reset.timeIntervalSince(now)
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return nil }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days > 0 { return "\(days) gün\(hours > 0 ? " \(hours) saat" : "") kaldı" }
        if hours > 0 { return "\(hours) saat kaldı" }
        return "\(max(1, Int(ceil(seconds / 60)))) dk kaldı"
    }
    static func duration(minutes: Int) -> String {
        if minutes % 1440 == 0 { return "\(minutes / 1440) gün" }
        if minutes % 60 == 0 { return "\(minutes / 60) saat" }
        if minutes > 60 { return "\(minutes / 60) saat \(minutes % 60) dk" }
        return "\(minutes) dk"
    }
}
enum ProjectLabel {
    static func resolve(explicit: String? = nil, cwd: String? = nil, title: String? = nil) -> String {
        if let explicit, !explicit.isEmpty, explicit != "/" { return explicit }
        if let cwd, cwd != "/", !cwd.isEmpty {
            var path = URL(fileURLWithPath: cwd)
            while path.path != "/" {
                if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) { return path.lastPathComponent }
                path.deleteLastPathComponent()
            }
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        if let title, !title.isEmpty, title != "/" { return title }
        return "Codex oturumu"
    }
}
struct SessionRoute: Equatable {
    let url: URL?
    let bundleID: String
    let label: String
    var applicationURL: URL? = nil
    var manualTerminal: TerminalApplicationPreference? = nil
    var manualTerminalReceipt: TerminalApplicationPreference.Receipt? = nil
    var chooseTerminal = false
    var exact: Bool { url != nil }
}
enum SessionRouting {
    private static let antigravityHost = EditorFocusHost.installations.first { $0.name == "Antigravity IDE" }
    private static var antigravityBundleID: String { antigravityHost?.bundleID ?? "" }
    // Verified against installed 26.928.40906: src-ghAWefM3.js Gt parses
    // codex://threads/<UUID>; local rollout session_meta.id is the thread UUID.
    static var verifiedCodexRouting: Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex"),
              let bundle = Bundle(url: url) else { return false }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == "26.928.40906"
    }
    static func preferredApplicationURL(bundleID: String) -> URL? {
        if bundleID == antigravityBundleID, let host = antigravityHost {
            return EditorFocusHost.verified(host) ? host.application : nil
        }
        if bundleID == "com.github.githubapp" {
            let url = URL(fileURLWithPath: "/Applications/GitHub Copilot.app")
            return Bundle(url: url)?.bundleIdentifier == bundleID ? url : nil
        }
        if bundleID == "com.exafunction.windsurf" {
            for path in ["/Applications/Devin.app", "/Applications/Windsurf.app"] {
                let url = URL(fileURLWithPath: path)
                if Bundle(url: url)?.bundleIdentifier == bundleID { return url }
            }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
    private static func runtimeFallback(for session: Session, providerBundleID: String = "") -> SessionRoute {
        let bundleID: String
        switch session.runtime?.host {
        case .terminal: bundleID = "" // A runtime label does not identify a terminal application.
        case .vscode: bundleID = "com.microsoft.VSCode"
        case .githubCopilotDesktop: bundleID = "com.github.githubapp"
        case .cursor: bundleID = "com.todesktop.230313mzl4w4u92"
        case .windsurf: bundleID = "com.exafunction.windsurf"
        case .antigravity: bundleID = antigravityBundleID
        default: bundleID = providerBundleID
        }
        let applicationURL = bundleID.isEmpty ? nil : preferredApplicationURL(bundleID: bundleID)
        return SessionRoute(url: nil, bundleID: applicationURL != nil ? bundleID : "", label: "Uygulamayı aç", applicationURL: applicationURL)
    }
    static func route(for session: Session, codexRoutingVerified: Bool = verifiedCodexRouting,
                      terminalOperations: TerminalNavigationOrigin.Operations = AntigravityTerminalOrigin.live,
                      terminalPreference: TerminalApplicationPreference = .none) -> SessionRoute {
        // AI provider does not identify the application hosting the session.
        // Receiver-verified editor origin takes precedence over older runtime metadata.
        if let editor = session.verifiedEditorHost {
            guard let host = EditorFocusHost.installations.first(where: { $0.bundleID == editor }),
                  EditorFocusHost.verified(host) else {
                return SessionRoute(url: nil, bundleID: "", label: "Uygulamayı aç")
            }
            return SessionRoute(url: nil, bundleID: host.bundleID, label: "Uygulamayı aç", applicationURL: host.application)
        }
        if let target = session.terminalNavigation,
           ![.vscode, .codexDesktop, .cursor, .windsurf, .antigravity].contains(session.runtime?.host ?? .unknown),
           let application = TerminalNavigationOrigin.application(target, operations: terminalOperations) {
            let tab = TerminalNavigationOrigin.tabURL(target, operations: terminalOperations)
            return SessionRoute(url: tab, bundleID: target.bundleID,
                label: tab == nil ? "Uygulamayı aç" : "Terminal sekmesine git", applicationURL: application)
        }
        // A user-selected application is independent of verified session navigation.
        if TerminalApplicationPreference.eligible(session) {
            if session.provider == .antigravity, let bundleID = session.verifiedTerminalHost,
               let application = AntigravityTerminalOrigin.application(for: bundleID, operations: terminalOperations) {
                return SessionRoute(url: nil, bundleID: bundleID, label: "Uygulamayı aç", applicationURL: application)
            }
            if let receipt = terminalPreference.validated(operations: terminalOperations) {
                return SessionRoute(url: nil, bundleID: receipt.bundleID, label: terminalPreference == .terminal ? "Terminal’i aç" : "iTerm2’yi aç",
                    applicationURL: receipt.application, manualTerminal: terminalPreference, manualTerminalReceipt: receipt)
            }
            return SessionRoute(url: nil, bundleID: "", label: "Terminal uygulamasını seç", chooseTerminal: true)
        }
        switch session.provider {
        case .codex:
            if session.runtime?.host == .vscode {
                guard let host = EditorFocusHost.installations.first(where: { $0.bundleID == "com.microsoft.VSCode" }),
                      EditorFocusHost.verified(host) else {
                    return SessionRoute(url: nil, bundleID: "", label: "Uygulamayı aç")
                }
                return SessionRoute(url: nil, bundleID: host.bundleID, label: "Uygulamayı aç", applicationURL: host.application)
            }
            if session.runtime?.host == .codexDesktop, codexRoutingVerified, UUID(uuidString: session.id) != nil {
                return SessionRoute(url: URL(string: "codex://threads/\(session.id)"), bundleID: "com.openai.codex", label: "Oturuma git")
            }
            return runtimeFallback(for: session, providerBundleID: session.runtime?.host == .codexDesktop ? "com.openai.codex" : "")
        case .claude:
            // Claude Code's executable is not proof of a Desktop or terminal
            // host. Only the receiver-verified editor route above can open it.
            return SessionRoute(url: nil, bundleID: "", label: "Uygulama doğrulanmadı")
        case .antigravity:
            if session.runtime?.host == .terminal {
                guard let bundleID = session.verifiedTerminalHost,
                      let application = AntigravityTerminalOrigin.application(for: bundleID) else {
                    return SessionRoute(url: nil, bundleID: "", label: "Uygulama doğrulanmadı")
                }
                return SessionRoute(url: nil, bundleID: bundleID, label: "Uygulamayı aç", applicationURL: application)
            }
            guard session.runtime?.host == .antigravity else {
                return SessionRoute(url: nil, bundleID: "", label: "Uygulama doğrulanmadı")
            }
            return runtimeFallback(for: session)
        case .opencode: return runtimeFallback(for: session)
        case .cursor: return runtimeFallback(for: session, providerBundleID: "com.todesktop.230313mzl4w4u92")
        case .copilot: return runtimeFallback(for: session)
        case .windsurf: return runtimeFallback(for: session, providerBundleID: "com.exafunction.windsurf")
        case .watch, .signal: return SessionRoute(url: nil, bundleID: "", label: "Görüldü")
        }
    }
}
