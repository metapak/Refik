import SwiftUI
import AppKit
import ServiceManagement

struct StatusPanelView: View {
    @ObservedObject var model: AppModel
    let openSession: (Session) -> Void
    let changeTerminal: (Session) -> Void
    let acknowledge: (String) -> Void
    let openSettings: () -> Void
    let targetSessionID: String?
    let listHeight: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("refik").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: openSettings) { Image(systemName: "gearshape") }.buttonStyle(.plain).accessibilityLabel("Ayarlar")
            }.padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 11)
            Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1)
            if model.sessions.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "moon.stars").font(.system(size: 23)).foregroundStyle(.secondary)
                    Text("Aktif iş yok").font(.system(size: 13, weight: .medium))
                    Text("İzlenen iş başladığında burada görünür.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 29)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.sessions) { session in
                                SessionRow(session: session, terminalPreference: model.terminalChoice(for: session), openSession: openSession, changeTerminal: changeTerminal, acknowledge: acknowledge, isTargeted: session.id == targetSessionID, canSubmit: model.canSubmitResponse, resumeNative: model.resumeNativeResponse, canSelectOpenCode: model.canSelectOpenCodeSession(session), selectOpenCode: { await model.selectOpenCodeSession(session) }, submit: { response in
                                    guard let current = model.sessions.first(where: { $0.id == response.identity.sessionID && $0.provider == response.identity.provider })?.orderedRequests.first(where: { $0.identity == response.identity }), model.canSubmitResponse(current) else { return "İstek değişti. Uygulamadan kontrol edin." }
                                    return await model.submitResponse(response).errorMessage
                                })
                                    .id(session.id)
                                if session.id != model.sessions.last?.id {
                                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.leading, 15)
                                }
                            }
                        }
                    }
                    .onAppear { if let targetSessionID { proxy.scrollTo(targetSessionID, anchor: .center) } }
                }.frame(height: listHeight)
            }
            Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                Text("KULLANIM").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                if let message = model.usageUnavailableMessage() {
                    Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(model.currentUsageWindows()) { entry in
                    HStack {
                        Text(entry.providerLabel(at: model.usageUpdatedAt))
                        Spacer()
                        Text(entry.valueLabel)
                    }.font(.system(size: 10))
                }
            }.padding(.horizontal, 15).padding(.vertical, 9)
            Rectangle().fill(Color.white.opacity(0.11)).frame(height: 1)
            HStack {
                Text(model.footer).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text("Yerel gözlem").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.horizontal, 15).padding(.vertical, 10)
        }
        .frame(width: 324)
        .background(Color(red: 0.105, green: 0.099, blue: 0.13))
        .foregroundStyle(Color.white.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.purple.opacity(0.2), lineWidth: 1))
    }
}

struct SessionRow: View {
    let session: Session
    let terminalPreference: TerminalApplicationPreference
    let openSession: (Session) -> Void
    let changeTerminal: (Session) -> Void
    let acknowledge: (String) -> Void
    let isTargeted: Bool
    let canSubmit: (PendingRequestSnapshot) -> Bool
    let resumeNative: (RequestIdentity) -> String?
    let canSelectOpenCode: Bool
    let selectOpenCode: () async -> String?
    @State private var selectingOpenCode = false
    @State private var selectionMessage: String?
    let submit: (InteractionResponse) async -> String?
    private var color: Color {
        switch session.state {
        case .waitingPermission, .waitingUser: return Color(nsColor: MascotPalette.color(.waiting))
        case .completed: return Color(nsColor: MascotPalette.color(.completed))
        case .failed, .interrupted: return .red
        case .running: return .white
        default: return .gray
        }
    }
    private var verifiedHostLabel: String? {
        switch session.verifiedEditorHost {
        case "com.microsoft.VSCode": return "VS Code"
        case "com.todesktop.230313mzl4w4u92": return "Cursor"
        case "com.exafunction.windsurf": return "Devin / Windsurf"
        case "com.google.antigravity-ide": return "Antigravity IDE"
        default: return nil
        }
    }
    private var icon: String { SessionPresentation.statusIcon(session.state) }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color).frame(width: 19).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(ProjectLabel.resolve(cwd: session.projectPath, title: session.title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(session.updated, style: .relative).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Label("\(SessionPresentation.providerLabel(session.provider)) · \((verifiedHostLabel ?? SessionPresentation.hostLabel(session)))", systemImage: SessionPresentation.providerIcon(session.provider))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(SessionPresentation.statusLabel(session))
                    .font(.system(size: 11)).foregroundStyle(color.opacity(0.86))
                if let chatName = session.runtime?.chatName, !chatName.isEmpty {
                    Text(chatName).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                } else if session.projectPath != nil && session.title != ProjectLabel.resolve(cwd: session.projectPath, title: session.title) {
                    Text(session.title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !["İş başladı", "İş tamamlandı", "Tur durumu izleniyor"].contains(session.detail) {
                    Text(session.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let progress = session.progress {
                    ProgressView(value: progress).tint(color)
                    Text("\(Int(progress * 100))% · elle bildirildi").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(session.orderedRequests.filter { ![.resolved, .canceled, .expired].contains($0.lifecycle) }) { request in
                    RequestEditor(request: request, available: canSubmit(request), resumeNative: resumeNative, submit: submit)
                        .id(request.identity)
                }
                if session.provider == .opencode && canSelectOpenCode {
                    Button(selectingOpenCode ? "Seçiliyor" : "OpenCode’da oturumu seç") {
                        selectingOpenCode = true
                        Task { @MainActor in
                            selectionMessage = await selectOpenCode() ?? "Oturum seçildi"
                            selectingOpenCode = false
                        }
                    }.buttonStyle(.link).font(.system(size: 10)).disabled(selectingOpenCode)
                    if let selectionMessage { Text(selectionMessage).font(.system(size: 10)).foregroundStyle(.secondary) }
                } else if session.provider != .watch && session.provider != .signal {
                    let route = SessionRouting.route(for: session, terminalPreference: terminalPreference)
                    Button(route.label) { openSession(session) }.buttonStyle(.link).font(.system(size: 10)).disabled(route.url == nil && route.bundleID.isEmpty && !route.chooseTerminal)
                    if !route.exact { Text("Belirli oturuma doğrudan geçiş kullanılamıyor").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if route.manualTerminal != nil {
                        Button("Terminal seçimini değiştir") { changeTerminal(session) }.buttonStyle(.link).font(.system(size: 10))
                    }
                }
                if [.completed, .failed, .interrupted].contains(session.state) {
                    Button("Görüldü") { acknowledge(session.id) }
                        .buttonStyle(.link).font(.system(size: 10))
                }
            }
        }.padding(.horizontal, 15).padding(.vertical, 11)
            .background(isTargeted ? Color.purple.opacity(0.15) : Color.clear)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let resetPosition: () -> Void
    let openFirstLaunch: () -> Void
    @State private var openCodeURL = ""
    @State private var openCodeProject = ""
    @State private var openCodePassword = ""
    @State private var openCodeHost: RuntimeHost = .terminal
    @State private var openCodeConnecting = false
    @State private var openCodeMessage: String?

    var body: some View {
        Form {
            Section("İlk kurulum") {
                Button("Bağlantı kurulumunu aç", action: openFirstLaunch)
                Text("Bulunan araçları bağlayın veya eksik bağlantıları tekrar deneyin.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Görünüm") {
                Picker("Maskot", selection: Binding(get: { MascotStyle.identifier(model.preferences.mascot) }, set: { model.preferences.mascot = $0 })) {
                    Text("weety").tag("cute"); Text("ardly").tag("stern"); Text("webai").tag("webAI")
                }
                HStack { Spacer(); MascotPreview(style: model.preferences.mascot); Spacer() }
                Picker("Ekran", selection: $model.preferences.preferredDisplayID) {
                    Text("Otomatik").tag(String?.none)
                    ForEach(WindowCoordinator.availableDisplays, id: \.id) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                Picker("Konum", selection: $model.preferences.edge) {
                    Text("Sol").tag("left"); Text("Sağ").tag("right")
                }.pickerStyle(.segmented)
                HStack { Text("Opaklık"); Slider(value: $model.preferences.opacity, in: 0.2...1.0); Text("\(Int(model.preferences.opacity * 100))%") }
                Toggle("Gözler imleci takip etsin", isOn: $model.preferences.followEyes)
                Button("Konumu sıfırla", action: resetPosition)
            }
            Section("Bildirimler") {
                Toggle("macOS bildirimlerini aç", isOn: Binding(get: { model.preferences.notifications }, set: { model.setNotifications($0) }))
                Text(model.notificationPermission).font(.caption).foregroundStyle(.secondary)
                Toggle("Tamamlanınca bildir", isOn: $model.preferences.notifyCompleted)
                Toggle("Soru/izin beklenince bildir", isOn: $model.preferences.notifyWaiting)
                Toggle("Hata olduğunda bildir", isOn: $model.preferences.notifyFailed)
                Toggle("Ses çal", isOn: $model.preferences.sound)
                Text("Ses, macOS bildirim izninden bağımsız çalar.").font(.caption).foregroundStyle(.secondary)
                Picker("Ses", selection: $model.preferences.soundName) {
                    Text("Glass").tag("Glass"); Text("Pop").tag("Pop"); Text("Tink").tag("Tink")
                }
                Button("Sesi dene") { model.testSound() }
                Toggle("Bildirimde görev adı", isOn: $model.preferences.showDetails)
            }
            Section("Hatırlatmalar") {
                Toggle("Bekleyen istekleri hatırlat", isOn: $model.preferences.remindersEnabled)
                Picker("Bekleme süresi", selection: $model.preferences.reminderDelaySeconds) {
                    Text("1 dakika").tag(60.0)
                    Text("3 dakika").tag(180.0)
                    Text("5 dakika").tag(300.0)
                    Text("10 dakika").tag(600.0)
                }
                Toggle("Sorular", isOn: $model.preferences.remindQuestions)
                Toggle("İzinler", isOn: $model.preferences.remindPermissions)
                Toggle("Hatırlatma sesi", isOn: $model.preferences.reminderSound)
                Toggle("macOS hatırlatma bildirimi", isOn: $model.preferences.reminderBanner)
                Text("Her bekleyen istek için bir kez hatırlatılır.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Otomatik proje bağlantısı") {
                Text("Desteklenen yerel editörlere Refik eklentisini tek adımda kurar. Projeye dönünce tamamlanan görevleri görüldü sayar; dosya veya mesaj içeriği okumaz.").font(.caption)
                HStack {
                    Button("Editörleri otomatik bağla") { model.configureEditorFocus(true) }.disabled(model.editorFocusInstalling)
                    Button("Refik eklentisini kaldır") { model.configureEditorFocus(false) }.disabled(model.editorFocusInstalling)
                }
                Text(model.editorFocusMessage).font(.caption).foregroundStyle(.secondary)
                Text("Yerel tek klasör desteklenir. Farklı profil, devre dışı eklenti veya editör politikası bağlantıyı engelleyebilir. Codex Desktop, GitHub Desktop ve bağımsız Claude bu editör bağlantısını kullanmaz.").font(.caption).foregroundStyle(.secondary)
                Text(model.projectFocusPermissionGranted ? "Eski pencere bağlantısı: Refik izni açık" : "Eski pencere bağlantısı: Refik ekran kaydı izni yok. Editör eklentisi bu izni gerektirmez.").font(.caption).foregroundStyle(.secondary)
                Button("Eski pencere bağlantısı için Refik iznini aç") { model.requestProjectFocusPermission() }
            }
            Section("Entegrasyonlar") {
                Text("Her terminal oturumunda uygulamayı o oturumun kartından seçebilirsiniz. Seçilen uygulamayı açar; belirli bir oturumu seçmez.").font(.caption).foregroundStyle(.secondary)
                Button("Terminal seçimlerini sıfırla") { model.clearTerminalChoices() }
                    .disabled(model.preferences.terminalApplications.count == 0)
                ForEach(model.integrationStatuses) { status in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(SessionPresentation.providerLabel(status.provider), systemImage: SessionPresentation.providerIcon(status.provider)).fontWeight(.medium)
                        Text("\(status.installed ? "Kurulu" : "Kurulum doğrulanmadı") · \(SessionPresentation.runtimeHostLabel(status.host)) · \(status.version ?? "Sürüm bilinmiyor")")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach([RuntimeCapability.observeQuestions, .observePermissions, .answerQuestions, .respondToPermissions, .openSession], id: \.rawValue) { capability in
                            Text(IntegrationPresentation.capabilityLabel(capability) + ": " + IntegrationPresentation.supportLabel(capability, evidence: status.capabilities)).font(.caption)
                        }
                        Text(status.message).font(.caption).foregroundStyle(.secondary)
                        if status.provider == .opencode {
                            TextField("Yerel sunucu adresi", text: $openCodeURL).textFieldStyle(.roundedBorder)
                            TextField("Proje klasörü", text: $openCodeProject).textFieldStyle(.roundedBorder)
                            Picker("Çalıştığı uygulama", selection: $openCodeHost) {
                                Text("Terminal").tag(RuntimeHost.terminal)
                                Text("VS Code").tag(RuntimeHost.vscode)
                                Text("Cursor").tag(RuntimeHost.cursor)
                                Text(SessionPresentation.runtimeHostLabel(.windsurf)).tag(RuntimeHost.windsurf)
                            }
                            SecureField("Parola (varsa)", text: $openCodePassword).textFieldStyle(.roundedBorder)
                            HStack {
                                Button(openCodeConnecting ? "Bağlanıyor" : "Bağlan") { connectOpenCode() }
                                    .disabled(openCodeConnecting || openCodeURL.isEmpty || openCodeProject.isEmpty)
                                Button("Bağlantıyı kes") {
                                    Task { @MainActor in openCodeMessage = await model.configureOpenCode(nil) }
                                }.disabled(openCodeConnecting)
                            }
                            Text("Adres ve klasörü çalışan yerel OpenCode oturumundan alın. Parola yalnızca bu bağlantı için kullanılır.").font(.caption).foregroundStyle(.secondary)
                            if let openCodeMessage { Text(openCodeMessage).font(.caption).foregroundStyle(.secondary) }
                        }
                        if [.codex, .claude, .antigravity].contains(status.provider) {
                            HStack {
                                Button("Kur / onar") { model.setIntegration(true, provider: status.provider) }
                                Button("Kaldır") { model.setIntegration(false, provider: status.provider) }
                            }
                        }
                    }.padding(.vertical, 4)
                }
                Text(model.integrationMessage).font(.caption).foregroundStyle(.secondary)
                Text("Kurulum mevcut ayarları korur ve yedekler. Uygulamanın güven onayını kendi arayüzünde verin.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Komut Satırı") {
                Button("refik komutunu kur") { model.setCommandLine(true) }
                Button("Komut bağlantısını kaldır") { model.setCommandLine(false) }
                Text(model.commandLineMessage).font(.caption).foregroundStyle(.secondary)
                Text("refik watch npm test · refik signal render --progress 0.4")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Kullanım") {
                if let message = model.usageUnavailableMessage() { Text(message).font(.caption).foregroundStyle(.secondary) }
                else { ForEach(model.currentUsageWindows()) { entry in Text("\(entry.providerLabel(at: model.usageUpdatedAt)): \(entry.valueLabel)") } }
            }
            Section("Genel") {
                Toggle("Oturum açılışında başlat", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { model.setLaunchAtLogin($0) }))
                if !model.launchMessage.isEmpty { Text(model.launchMessage).font(.caption) }
                Button("Arındırılmış tanı raporu dışa aktar") { model.exportDiagnostics() }
                if !model.diagnosticsMessage.isEmpty { Text(model.diagnosticsMessage).font(.caption).foregroundStyle(.secondary) }
                Text("Sürüm: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "bilinmiyor")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 450, height: 650)
    }
    private func connectOpenCode() {
        guard let url = URL(string: openCodeURL) else { openCodeMessage = "Sunucu adresini kontrol edin."; return }
        let configuration = OpenCodeConnectionConfiguration(serverURL: url, projectDirectory: openCodeProject, host: openCodeHost, password: openCodePassword.isEmpty ? nil : openCodePassword)
        openCodePassword = ""
        openCodeConnecting = true
        Task { @MainActor in
            openCodeMessage = await model.configureOpenCode(configuration, retainExistingCredentialsIfSameTarget: true)
            openCodeConnecting = false
        }
    }
}

struct MascotPreview: View {
    let style: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(["running", "waiting", "completed"], id: \.self) { state in
                if let url = Bundle.main.resourceURL?.appendingPathComponent("Mascots/\(MascotStyle.assetName(style))-\(state)-body.png"),
                   let image = NSImage(contentsOf: url),
                   let eyeURL = Bundle.main.resourceURL?.appendingPathComponent("Mascots/\(MascotStyle.assetName(style))-\(state)-eyes.png"),
                   let eyes = NSImage(contentsOf: eyeURL) {
                    ZStack {
                        Image(nsImage: image).resizable()
                        Image(nsImage: eyes).resizable()
                    }.frame(width: 56, height: 56)
                }
            }
        }
    }
}
