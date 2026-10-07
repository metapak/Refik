import SwiftUI
import AppKit
import CoreFoundation
import RefikInteractionWire

enum FirstLaunchDisposition: String { case finished, skipped, existingInstallation }
enum FirstLaunchToolStatus: String { case found, installed, failed, disabled
    var label: String { switch self { case .found: "Bulundu"; case .installed: "Bağlantı kurulu"; case .failed: "Kurulamadı"; case .disabled: "Devre dışı" } }
}
struct FirstLaunchTool: Identifiable {
    let id: String, name: String
    let provider: Provider?
    let editor: Bool
    var selected = true
    var status: FirstLaunchToolStatus = .found
    var healthNote: String?
    // A verified connection needs no user action for internal cwd cleanup.
    // Keep the health record for diagnostics and unsuccessful setup rows.
    var visibleHealthNote: String? { status == .installed ? nil : healthNote }
    var detail: String?
}
@MainActor final class FirstLaunchSetup: ObservableObject {
    static let dispositionKey = "refik.firstLaunch.v1.disposition"
    static let failuresKey = "refik.firstLaunch.v1.failures"
    static let failureDetailsKey = "refik.firstLaunch.v1.failureDetails"
    @Published var tools: [FirstLaunchTool] = []
    @Published private(set) var discovering = false
    @Published private(set) var installing = false
    @Published private(set) var attempted = false
    @Published private(set) var message = ""
    private let defaults: UserDefaults
    private let discover: () async -> [FirstLaunchTool]
    private let install: ([FirstLaunchTool]) async -> [FirstLaunchTool]
    init(defaults: UserDefaults = .standard,
         discover: @escaping () async -> [FirstLaunchTool] = { await Task.detached { discoverLocalTools() }.value },
         install: @escaping ([FirstLaunchTool]) async -> [FirstLaunchTool] = { rows in await Task.detached { installLocalTools(rows) }.value }) {
        self.defaults = defaults; self.discover = discover; self.install = install
    }
    // Adoption changes only Refik's own presentation marker, never provider settings.
    func shouldPresentAutomatically(existingEvidence: Bool) -> Bool {
        guard defaults.string(forKey: Self.dispositionKey) == nil else { return false }
        if existingEvidence { defaults.set(FirstLaunchDisposition.existingInstallation.rawValue, forKey: Self.dispositionKey); return false }
        return true
    }
    func finish(skipped: Bool) {
        defaults.set((skipped ? FirstLaunchDisposition.skipped : .finished).rawValue, forKey: Self.dispositionKey)
    }
    func refresh() async {
        guard !discovering, !installing else { return }
        discovering = true
        let previousFailures = Set(defaults.stringArray(forKey: Self.failuresKey) ?? [])
        let previousDetails = defaults.dictionary(forKey: Self.failureDetailsKey) as? [String: String] ?? [:]
        tools = await discover().map { item in
            var row = item
            if row.status == .found, previousFailures.contains(row.id) { row.status = .failed; row.detail = previousDetails[row.id] }
            return row
        }
        if tools.contains(where: { $0.status == .failed }) {
            attempted = true; message = "Eksik bağlantıları tekrar deneyebilir veya Ayarlar’dan daha sonra devam edebilirsiniz."
        } else if !tools.isEmpty && tools.allSatisfy({ $0.status == .installed || $0.status == .disabled }) {
            attempted = true; message = tools.allSatisfy { $0.status == .disabled } ? "Devre dışı bırakılan bağlantılar korunuyor." : "Bağlantılar kurulu. Açık editörlerde yeniden başlatma gerekebilir."
        }
        discovering = false
    }
    func connect() async {
        guard !installing, !discovering else { return }
        let selected = tools.filter(\.selected)
        guard !selected.isEmpty else { message = "Bağlamak istediğiniz aracı seçin."; return }
        installing = true; message = "Bağlantılar kuruluyor…"
        let results = await install(selected)
        let byID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        tools = tools.map { byID[$0.id] ?? $0 }
        defaults.set(tools.filter { $0.status == .failed }.map(\.id), forKey: Self.failuresKey)
        defaults.set(Dictionary(tools.compactMap { row in row.status == .failed ? row.detail.map { (row.id, $0) } : nil }, uniquingKeysWith: { _, last in last }), forKey: Self.failureDetailsKey)
        attempted = true; installing = false
        message = tools.contains { $0.status == .failed } ? "Bazı bağlantılar kurulamadı. Tekrar deneyebilir veya daha sonra Ayarlar’dan devam edebilirsiniz." : "Bağlantılar kuruldu. Açık editörlerde yeniden başlatma gerekebilir."
    }
    nonisolated static func discoverLocalTools() -> [FirstLaunchTool] {
        let fm = FileManager.default
        let search = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        func command(_ name: String) -> Bool { search.contains { fm.isExecutableFile(atPath: URL(fileURLWithPath: $0).appendingPathComponent(name).path) } }
        func app(_ path: String, _ bundle: String) -> Bool { Bundle(path: path)?.bundleIdentifier == bundle }
        var rows: [FirstLaunchTool] = []
        let providers: [(Provider, String, Bool)] = [
            (.codex, "Codex", command("codex") || app("/Applications/ChatGPT.app", "com.openai.codex")),
            (.claude, "Claude Code", command("claude")),
            (.antigravity, "Antigravity", command("agy") || app("/Applications/Antigravity IDE.app", "com.google.antigravity-ide"))
        ]
        for (provider, name, present) in providers where present {
            let status = providerStatus(provider)
            rows.append(FirstLaunchTool(id: provider.rawValue, name: name, provider: provider, editor: false, selected: status != .disabled, status: status))
        }
        let receiptURL = BridgePath.directory.appendingPathComponent("editor-focus-installations.json")
        let receipts = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))) ?? [:]
        for host in EditorFocusHost.installations where fm.isExecutableFile(atPath: host.command.path) && EditorFocusHost.verified(host) {
            rows.append(FirstLaunchTool(id: "editor:" + host.name, name: host.name + " · proje bağlantısı", provider: nil, editor: true, status: editorStatus(host, receipts: receipts)))
        }
        return rows
    }
    nonisolated static func providerStatus(_ provider: Provider, at url: URL? = nil, helper: URL? = nil, bytes: Data? = nil, bundledHelper: URL? = nil) -> FirstLaunchToolStatus {
        guard let data = bytes ?? (try? Data(contentsOf: url ?? HookInstaller.configuration(provider))),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .found }
        if let disabled = object["disableAllHooks"] as? NSNumber, CFGetTypeID(disabled) == CFBooleanGetTypeID(), disabled.boolValue { return .disabled }
        if provider == .antigravity, let observer = object["refik-observer"] as? [String: Any],
           let enabled = observer["enabled"] as? NSNumber, CFGetTypeID(enabled) == CFBooleanGetTypeID(), !enabled.boolValue { return .disabled }
        let commandPath = helper ?? HookInstaller.helperDestination
        func ownsHandler(_ handler: [String: Any], event: String) -> Bool {
            guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return false }
            return [LegacyMigration.quoted(commandPath.path), commandPath.path].contains { path in
                let prefix = path + " " + provider.rawValue + " " + event
                return command == prefix || command.hasPrefix(prefix + " ")
            }
        }
        guard helperReady(helper: commandPath, bundled: bundledHelper) else { return .found }
        let expected = provider == .codex ? HookInstaller.codexEvents : (provider == .claude ? HookInstaller.claudeEvents : HookInstaller.antigravityEvents)
        let hooks = object[provider == .antigravity ? "refik-observer" : "hooks"] as? [String: Any] ?? [:]
        for event in expected {
            guard let entries = hooks[event] as? [[String: Any]], entries.contains(where: { entry in
                if provider == .antigravity, ownsHandler(entry, event: event) { return true }
                return (entry["hooks"] as? [[String: Any]])?.contains { ownsHandler($0, event: event) } == true
            }) else { return .found }
        }
        return .installed
    }
    nonisolated static func helperReady(helper: URL? = nil, bundled: URL? = nil) -> Bool {
        AntigravityTerminalOrigin.live.helperMatches(helper ?? HookInstaller.helperDestination,
            bundled ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/refikHook"))
    }
    nonisolated static func editorStatus(_ host: EditorFocusHost.Installation, receipts: [String: String],
                                         verified: (EditorFocusHost.Installation) -> Bool = EditorFocusHost.verified,
                                         runner: EditorFocusInstaller.Runner = EditorFocusInstaller.run, helperValid: () -> Bool = { helperReady() },
                                         archive: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RefikEditorFocus.vsix"),
                                         extensionRoot: (EditorFocusHost.Installation) -> URL? = EditorFocusInstaller.extensionsRoot) -> FirstLaunchToolStatus {
        guard helperValid(), EditorFocusInstaller.ready(host, archive: archive, receipts: receipts, verified: verified, extensionRoot: extensionRoot) else { return .found }
        return .installed
    }
    nonisolated static func installLocalTools(_ rows: [FirstLaunchTool]) -> [FirstLaunchTool] {
        // Re-discover immediately before mutation: a tool removed or explicitly
        // disabled since the window opened is never installed or re-enabled.
        let current = Dictionary(discoverLocalTools().map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let eligible = rows.compactMap { current[$0.id] }
        let receiptURL = BridgePath.directory.appendingPathComponent("editor-focus-installations.json")
        let results = runInstall(eligible, providerInstaller: { provider in
            let config = HookInstaller.configuration(provider)
            let original = FileManager.default.fileExists(atPath: config.path) ? try Data(contentsOf: config) : Data("{}".utf8)
            guard providerStatus(provider, bytes: original) != .disabled else { return }
            try HookInstaller.setExplicitlyEnabled(true, provider: provider, expectedOriginal: original)
        }, editorInstaller: {
            do { try HookInstaller.ensureHelper() } catch { return "Refik bağlantı yardımcısı kurulamadı" }
            let selectedNames = Set(eligible.filter(\.editor).map { String($0.id.dropFirst("editor:".count)) })
            let hosts = EditorFocusHost.installations.filter { selectedNames.contains($0.name) }
            return EditorFocusInstaller.configure(enabled: true,
                archive: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/RefikEditorFocus.vsix"),
                receiptURL: receiptURL, installations: hosts)
        }, installed: { row in
            if let provider = row.provider { return providerStatus(provider) == .installed }
            guard let host = EditorFocusHost.installations.first(where: { row.id == "editor:" + $0.name }) else { return false }
            let receipts = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))) ?? [:]
            return editorStatus(host, receipts: receipts) == .installed
        })
        let resultByID = Dictionary(results.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return rows.map { row in
            if let provider = row.provider, providerStatus(provider) == .disabled {
                var disabled = row; disabled.status = .disabled; disabled.selected = false; return disabled
            }
            if let result = resultByID[row.id] { return result }
            var missing = row; missing.status = .failed; return missing
        }
    }
    nonisolated static func runInstall(_ rows: [FirstLaunchTool], providerInstaller: (Provider) throws -> Void,
                                      editorInstaller: () -> String, installed: (FirstLaunchTool) -> Bool) -> [FirstLaunchTool] {
        var failures = Set<Provider>()
        for provider in Set(rows.filter { $0.status != .installed && $0.status != .disabled }.compactMap(\.provider)) { do { try providerInstaller(provider) } catch { failures.insert(provider) } }
        let editorMessage = rows.contains(where: { $0.editor && $0.status != .installed && $0.status != .disabled }) ? editorInstaller() : ""
        return rows.map { row in
            var result = row
            if row.status == .disabled { return row }
            result.status = (row.provider.map { failures.contains($0) } ?? false) || !installed(row) ? .failed : .installed
            if result.status == .failed {
                let editorName = String(row.id.dropFirst("editor:".count))
                result.detail = row.editor ? editorMessage.split(separator: "\n").map(String.init).first(where: { $0.hasPrefix(editorName + ": ") }) ?? "Editör bağlantısı doğrulanamadı. Mevcut eklentiler korundu." : "Bağlantı kurulamadı. Mevcut ayarlar korundu; yeniden deneyebilirsiniz."
            } else {
                result.detail = nil
                if row.editor, let host = EditorFocusHost.installations.first(where: { row.id == "editor:" + $0.name }) {
                    result.healthNote = EditorFocusInstaller.healthWarning(host)
                }
            }
            return result
        }
    }
    static func fixture(_ phase: String) -> FirstLaunchSetup {
        let defaults = UserDefaults(suiteName: "refik.setup.preview." + UUID().uuidString)!
        let state = FirstLaunchSetup(defaults: defaults, discover: { [] }, install: { $0 })
        state.tools = [FirstLaunchTool(id: "codex", name: "Codex", provider: .codex, editor: false),
                       FirstLaunchTool(id: "claude", name: "Claude Code", provider: .claude, editor: false),
                       FirstLaunchTool(id: "antigravity", name: "Antigravity", provider: .antigravity, editor: false)]
        state.tools += ["Visual Studio Code", "Cursor", "Devin", "Antigravity IDE"].map { FirstLaunchTool(id: "editor:" + $0, name: $0 + " · proje bağlantısı", provider: nil, editor: true) }
        if phase != "first" {
            state.attempted = true
            state.tools = state.tools.enumerated().map { index, row in var value = row; value.status = phase == "partial" && index == 6 ? .failed : .installed; if value.status == .failed { value.detail = "Antigravity IDE: aynı kimlikli mevcut eklenti korunuyor; paket doğrulanamadığı için bağlantı kaydı oluşturulmadı." }; return value }
            state.message = phase == "partial" ? "Antigravity IDE proje bağlantısı kurulamadı. Mevcut ayarlar ve diğer bağlantılar korundu; eksik bağlantıyı daha sonra Ayarlar’dan yeniden deneyebilirsiniz." : "Bağlantılar kuruldu. Açık editörlerde yeniden başlatma gerekebilir."
        }
        return state
    }
}
struct FirstLaunchView: View {
    @ObservedObject var setup: FirstLaunchSetup
    let finish: (Bool) -> Void
    let notifications: () -> Void
    private var complete: Bool { setup.attempted && !setup.tools.isEmpty && setup.tools.allSatisfy { $0.status == .installed || $0.status == .disabled } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 34)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) { Text("Refik’e hoş geldin").font(.title2.bold()); Text("AI araçlarının durumunu tek maskotta takip et.").foregroundStyle(.secondary) }
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Text("Çalışırken hareket eder, soru veya izin beklenince sarı, yanıt hazır olduğunda yeşil olur. Desteklenen projeye dönünce sonuç bildirimi kapanır.").font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Text("Bu bilgisayarda bulunanlar").font(.headline)
                if setup.discovering { ProgressView("Araçlar aranıyor…") }
                else if setup.tools.isEmpty { Text("Desteklenen araç bulunamadı. Daha sonra Ayarlar’dan tekrar deneyebilirsiniz.").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 10) {
                    ForEach($setup.tools) { $tool in
                    VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(tool.name, isOn: $tool.selected).toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true).disabled(setup.installing || tool.status == .disabled)
                        Spacer()
                        Text(tool.status.label).font(.caption).foregroundStyle(tool.status == .failed ? Color.red : Color.secondary)
                    }
                    if let health = tool.visibleHealthNote { Text(health).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    if let detail = tool.detail, tool.status == .failed { Text(detail).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    }
                    }
                    }
            }.padding(16).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            Text("Bağlantı kurulması hesap erişimini doğrulamaz. Desteklenen editörlerde ekran kaydı izni gerekmez.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !setup.message.isEmpty { Text(setup.message).font(.callout).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Bildirimleri aç (isteğe bağlı)", action: notifications).buttonStyle(.link)
            HStack {
                Button("Şimdilik atla") { finish(true) }.disabled(setup.installing)
                Spacer()
                if setup.attempted && !complete { Button("Bitir") { finish(false) }.disabled(setup.installing) }
                Button(setup.installing ? "Kuruluyor…" : (complete ? "Bitir" : (setup.attempted ? "Yeniden dene" : "Bağlantıları kur"))) {
                    if complete { finish(false) } else { Task { await setup.connect() } }
                }.buttonStyle(.borderedProminent).disabled(setup.installing || setup.discovering || setup.tools.isEmpty || (!complete && !setup.tools.contains(where: \.selected)))
            }
            Text("Bu ekranı Ayarlar → İlk kurulum bölümünden yeniden açabilirsiniz.").font(.caption2).foregroundStyle(.secondary)
        }.padding(24).frame(width: 520, height: 640).background(Color(nsColor: .windowBackgroundColor))
    }
}
