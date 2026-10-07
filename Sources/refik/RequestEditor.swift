import SwiftUI

struct RequestEditor: View {
    let request: PendingRequestSnapshot
    let available: Bool
    let submit: (InteractionResponse) async -> String?
    let resumeNative: ((RequestIdentity) -> String?)?
    @State private var draft: QuestionDraft
    @State private var page = 0
    @State private var reviewing = false
    @State private var sent = false
    @State private var nativeReleased = false
    @State private var errorMessage: String?
    init(request: PendingRequestSnapshot, available: Bool, resumeNative: ((RequestIdentity) -> String?)? = nil, submit: @escaping (InteractionResponse) async -> String?) {
        self.request = request; self.available = available; self.submit = submit; self.resumeNative = resumeNative
        _draft = State(initialValue: QuestionDraft(request: request))
    }
    private var questions: [StructuredQuestion] { request.question?.questions ?? [] }
    private var enabled: Bool { available && request.lifecycle == .pending && !sent }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.lifecycle == .submitting || sent {
                Label("Gönderiliyor", systemImage: "arrow.triangle.2.circlepath")
            } else if request.lifecycle == .submitted {
                Text("Gönderildi · Uygulamanın yanıtı bekleniyor").foregroundStyle(.secondary)
            } else if request.lifecycle == .deliveryUnknown {
                Text("Gönderim sonucu doğrulanamadı. Uygulamadan kontrol edin.").foregroundStyle(.secondary)
            } else if request.lifecycle == .resolved {
                Text("İstek kapandı").foregroundStyle(.secondary)
            } else if request.lifecycle == .accepted {
                Label("Yanıt alındı", systemImage: "checkmark.circle")
            } else if request.lifecycle == .canceled || request.lifecycle == .expired {
                Text("İstek artık etkin değil").foregroundStyle(.secondary)
            } else if request.kind == .permission, let permission = request.permission {
                Text(permission.requestedAction).fontWeight(.medium).textSelection(.enabled)
                Text("Kapsam: \(permission.scope)").textSelection(.enabled)
                if let explanation = permission.explanation { Text(explanation).foregroundStyle(.secondary) }
                if available {
                    Text("Onay yalnızca bu istek için geçerli.").foregroundStyle(.secondary)
                    Text(request.identity.provider == .opencode ? "Reddetmek bu oturumdaki diğer bekleyen izinleri de reddedebilir." : "Reddetme sonucunu uygulama belirler.").foregroundStyle(.secondary)
                    HStack {
                        Button("Bir kez izin ver") { send(InteractionResponse(identity: request.identity, permissionDecision: .allow)) }
                        Button("Reddet") { send(InteractionResponse(identity: request.identity, permissionDecision: .deny)) }
                    }.disabled(!enabled)
                }
            } else if request.kind == .question, !questions.isEmpty {
                if reviewing {
                    Text("Yanıtları gözden geçir").fontWeight(.medium)
                    ForEach(questions) { question in
                        Text(question.prompt).fontWeight(.medium)
                        let answer = draft.answer(for: question)
                        Text(question.options.filter { answer?.optionIDs.contains($0.id) == true }.map(\.label).joined(separator: ", "))
                        if let text = answer?.text, !text.isEmpty { Text(text).textSelection(.enabled) }
                    }
                    HStack {
                        Button("Geri") { reviewing = false }
                        if available {
                            Button("Yanıtları gönder") { if let response = draft.response(for: request) { send(response) } }
                                .disabled(!enabled || draft.response(for: request) == nil)
                        }
                    }
                } else {
                    let question = questions[min(page, questions.count - 1)]
                    Text("Soru \(page + 1) / \(questions.count)").foregroundStyle(.secondary)
                    Text(question.prompt).fontWeight(.medium)
                    ForEach(question.options) { option in
                        if available {
                        Button { draft.select(option.id, for: question) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: draft.answer(for: question)?.optionIDs.contains(option.id) == true ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(option.label)
                                    if let description = option.description { Text(description).foregroundStyle(.secondary) }
                                }
                            }
                        }.buttonStyle(.plain).disabled(!enabled)
                        } else {
                            Text(option.label)
                            if let description = option.description { Text(description).foregroundStyle(.secondary) }
                        }
                    }
                    if question.allowsFreeform && available {
                        TextField("Yanıtınız", text: Binding(get: { draft.answer(for: question)?.text ?? "" }, set: { draft.setText($0, for: question) }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).disabled(!enabled)
                    }
                    HStack {
                        if page > 0 { Button("Geri") { page -= 1 } }
                        if page + 1 < questions.count {
                            Button("İleri") { page += 1 }
                                .disabled(available && !enabled)
                        } else if available {
                            Button("Gözden geçir") { reviewing = true }
                                .disabled(!enabled)
                        }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            if request.identity.provider == .claude, available, request.lifecycle == .pending, let resumeNative {
                Text("Claude’un kendi istemi hook döndükten sonra açılır. Buradan yanıtlayabilir veya Claude’da devam edebilirsiniz.").foregroundStyle(.secondary)
                Button(request.kind == .question ? "Claude’da yanıtla" : "Claude’da devam et") {
                    guard enabled else { return }
                    errorMessage = resumeNative(request.identity)
                    if errorMessage == nil { nativeReleased = true }
                }.disabled(!enabled)
            }
            if !available && request.lifecycle == .pending {
                Text(nativeReleased ? "Claude’da yanıt bekleniyor. Refik yanıt veya izin kararı göndermedi." : "Canlı yanıt kanalı yok. Uygulamadan devam edin.").foregroundStyle(.secondary)
            }
        }.font(.system(size: 11)).padding(9)
            .background(Color.yellow.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 7))
            .onChange(of: request.lifecycle) { value in if value != .pending { sent = false } }
    }
    private func send(_ response: InteractionResponse) {
        guard enabled, response.isValid(for: request) else { return }
        sent = true
        errorMessage = nil
        Task { @MainActor in
            errorMessage = await submit(response)
            sent = false
        }
    }
}
