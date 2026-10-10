import Foundation
import CryptoKit

// This failure proves the response POST was never dispatched. Callers can
// restore the same pending request without guessing about delivery.
struct OpenCodePreDispatchError: Error {
    let underlying: Error
}

actor OpenCodeAdapter: InteractionResponseTransport {
    private let configuration: OpenCodeConnectionConfiguration
    private let session: URLSession
    private var worker: Task<Void, Never>?
    private var callback: (@Sendable (CodexEvent) -> Void)?
    private var runtimeID = UUID().uuidString
    private var channelID: String?
    private var version: String?
    private var connected = false
    private var canSelect = false
    private var pending: [String: PendingRequestSnapshot] = [:]
    private var submitting: Set<RequestIdentity> = []
    private var dispatched: Set<RequestIdentity> = []
    private var sessionInfo: [String: OpenCodeWireSession] = [:]
    private var lastStatus: [String: String] = [:]
    private var sourceContextID: String {
        var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased(); components.path = "/"
        if components.port == nil { components.port = components.scheme == "https" ? 443 : 80 }
        let context = (components.string ?? "") + "\n" + URL(fileURLWithPath: configuration.projectDirectory).standardizedFileURL.path
        return SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func canonicalSessionID(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data((sourceContextID + "\n" + raw).utf8)).map { String(format: "%02x", $0) }.joined()
        return "opencode:" + digest
    }
    private var epoch = UUID()
    private var refreshRevision = 0
    private var deliveryUnknown: Set<RequestIdentity> = []
    private var inflight: [UUID: Task<(Data, URLResponse), Error>] = [:]

    init(configuration: OpenCodeConnectionConfiguration, session: URLSession? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = configuration.timeout
            config.timeoutIntervalForResource = configuration.timeout
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            self.session = URLSession(configuration: config, delegate: OpenCodeNoRedirectDelegate(), delegateQueue: nil)
        }
    }

    func snapshot() -> OpenCodeConnectionSnapshot {
        OpenCodeConnectionSnapshot(runtimeID: runtimeID, version: version, connected: connected,
                                   channelID: channelID, pending: Array(pending.values), canSelectSession: canSelect)
    }

    func start(onEvent: @escaping @Sendable (CodexEvent) -> Void) {
        stop()
        callback = onEvent
        let token = epoch
        worker = Task { await self.run(token: token) }
    }

    func stop() {
        worker?.cancel(); worker = nil
        epoch = UUID()
        for identity in dispatched {
            deliveryUnknown.insert(identity)
            if let key = pending.first(where: { $0.value.identity == identity })?.key {
                pending[key]?.lifecycle = .deliveryUnknown
            }
        }
        for task in inflight.values { task.cancel() }
        inflight.removeAll()
        connected = false; channelID = nil; canSelect = false
        announceDisconnection()
    }

    private func run(token: UUID) async {
        var failures = 0
        while !Task.isCancelled && token == epoch {
            do {
                try await connect()
                guard token == epoch, !Task.isCancelled else { return }
                failures = 0
                // Reconcile after establishing the stream, closing the snapshot /
                // subscription gap. SSE contents only trigger authoritative reads.
                var request = try makeRequest("/event")
                request.timeoutInterval = 45
                let (bytes, response) = try await session.bytes(for: request)
                try validate(response)
                guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
                    throw OpenCodeConnectionError.malformedResponse
                }
                try await refresh()
                for try await line in bytes.lines {
                    guard token == epoch, !Task.isCancelled else { return }
                    guard line.count <= 200_000 else { throw OpenCodeConnectionError.malformedResponse }
                    if line.hasPrefix("data:") { try await refresh() }
                }
                throw OpenCodeConnectionError.disconnected
            } catch {
                guard token == epoch, !Task.isCancelled else { return }
                connected = false; channelID = nil; canSelect = false
                announceDisconnection()
                failures = min(failures + 1, 5)
                try? await Task.sleep(nanoseconds: UInt64(min(pow(2, Double(failures)), 30) * 1_000_000_000))
            }
        }
    }

    // Also available to the app's explicit Connect action and isolated tests.
    func connect() async throws {
        connected = false; channelID = nil; canSelect = false
        announceDisconnection()
        let token = epoch
        let health = try await json("/global/health")
        guard let object = health as? [String: Any], object["healthy"] as? Bool == true,
              let runtimeVersion = object["version"] as? String, !runtimeVersion.isEmpty else {
            throw OpenCodeConnectionError.malformedResponse
        }
        let document = try await json("/doc")
        guard let doc = document as? [String: Any], let paths = doc["paths"] as? [String: [String: Any]] else {
            throw OpenCodeConnectionError.unsupportedAPI
        }
        let required = [("/question", "get"), ("/permission", "get"), ("/session", "get"),
                        ("/session/status", "get"), ("/event", "get"),
                        ("/question/{requestID}/reply", "post"), ("/permission/{requestID}/reply", "post")]
        guard required.allSatisfy({ paths[$0.0]?[$0.1] != nil }) else {
            throw OpenCodeConnectionError.unsupportedAPI
        }
        guard token == epoch, !Task.isCancelled else { throw CancellationError() }
        // A stream reconnect does not prove a new backend runtime or request.
        // Keep exact request identities and uncertain-delivery locks.
        version = runtimeVersion; channelID = UUID().uuidString
        lastStatus.removeAll()
        connected = true; canSelect = paths["/tui/select-session"]?["post"] != nil
        do { try await refresh() } catch { connected = false; channelID = nil; announceDisconnection(); throw error }
    }

    func refresh() async throws {
        _ = try await refreshSnapshot()
    }

    // A newer authoritative read supersedes this result without disconnecting
    // the healthy stream. Submission requires a read that actually committed.
    private func refreshSnapshot() async throws -> Bool {
        guard connected else { throw OpenCodeConnectionError.disconnected }
        let token = epoch
        refreshRevision += 1
        let revision = refreshRevision
        let questions: [OpenCodeWireQuestion] = try await decode("/question")
        let permissions: [OpenCodeWirePermission] = try await decode("/permission")
        let sessions: [OpenCodeWireSession] = try await decode("/session")
        let statuses = try await json("/session/status") as? [String: [String: Any]] ?? [:]
        guard token == epoch, connected, !Task.isCancelled else { throw CancellationError() }
        guard revision == refreshRevision else { return false }
        sessionInfo = Dictionary(sessions.filter { $0.directory == configuration.projectDirectory }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [String: PendingRequestSnapshot] = [:]
        for item in questions where sessionInfo[item.sessionID] != nil {
            let key = "question:" + item.id
            let identity = identityFor(id: item.id, sessionID: canonicalSessionID(item.sessionID), messageID: item.tool?.messageID, key: key)
            let body = QuestionRequestBody(questions: item.questions.enumerated().map { index, question in
                StructuredQuestion(id: String(index), prompt: question.question, header: question.header,
                    options: question.options.enumerated().map { QuestionOption(id: String($0.offset), label: $0.element.label, description: $0.element.description) },
                    allowsFreeform: question.custom ?? true, allowsMultipleSelection: question.multiple ?? false)
            })
            next[key] = PendingRequestSnapshot(identity: identity, kind: .question, question: body, turnScope: .request, observedAt: pending[key]?.observedAt ?? Date())
        }
        for item in permissions where sessionInfo[item.sessionID] != nil {
            let key = "permission:" + item.id
            let identity = identityFor(id: item.id, sessionID: canonicalSessionID(item.sessionID), messageID: item.tool?.messageID, key: key)
            let related = permissions.filter { $0.sessionID == item.sessionID }.map(\.id).sorted()
            let scope = "Bu istek için bir kez: " + item.patterns.joined(separator: ", ")
            let explanation = "Reddetmek aynı oturumun bekleyen izinlerini de reddedebilir. Etkilenen istekler: " + related.joined(separator: ", ")
            next[key] = PendingRequestSnapshot(identity: identity, kind: .permission,
                permission: PermissionRequestBody(requestedAction: item.permission, scope: scope, explanation: explanation), turnScope: .request, observedAt: pending[key]?.observedAt ?? Date())
        }
        for key in Array(next.keys) {
            guard var item = next[key] else { continue }
            if let old = pending[key], old.question != item.question || old.permission != item.permission {
                emitResolution(old, lifecycle: .resolved)
                item = PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: runtimeID,
                    sessionID: item.identity.sessionID, turnID: item.identity.turnID, requestID: item.id, generation: UUID().uuidString),
                    kind: item.kind, question: item.question, permission: item.permission, turnScope: .request, observedAt: Date())
            }
            if deliveryUnknown.contains(item.identity) { item.lifecycle = .deliveryUnknown }
            else if pending[key]?.lifecycle == .submitting, submitting.contains(item.identity) { item.lifecycle = .submitting }
            next[key] = item
        }
        for (id, info) in sessionInfo {
            let status = statuses[id]?["type"] as? String ?? "idle"
            guard lastStatus[id] != status else { continue }
            lastStatus[id] = status
            let turn = "runtime:" + runtimeID
            emit(sessionID: canonicalSessionID(id), turnID: turn, kind: status == "busy" ? .activity : .unknownEvent, title: info.title,
                 detail: status == "idle" ? "OpenCode oturumu boşta; iş sonucu doğrulanmadı" : "OpenCode çalışma durumu: " + status,
                 runtimeState: status == "idle" ? .idle : status == "busy" ? .running : nil)
        }
        for (key, old) in pending where next[key] == nil { emitResolution(old, lifecycle: .resolved); deliveryUnknown.remove(old.identity) }
        for (key, request) in next where pending[key] != request && request.isValid { emitRequest(request) }
        pending = next.filter { $0.value.isValid }
        return true

    }

    private func identityFor(id: String, sessionID: String, messageID: String?, key: String) -> RequestIdentity {
        let turn = messageID ?? "request:" + id
        if let old = pending[key], old.identity.sessionID == sessionID, old.identity.turnID == turn { return old.identity }
        return RequestIdentity(provider: .opencode, runtimeID: runtimeID, sessionID: sessionID,
                               turnID: turn, requestID: id, generation: UUID().uuidString)
    }

    func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt {
        guard connected, self.channelID == channelID else { throw OpenCodePreDispatchError(underlying: OpenCodeConnectionError.disconnected) }
        guard !submitting.contains(response.identity) else { throw OpenCodeConnectionError.duplicateSubmission }
        submitting.insert(response.identity)
        defer { submitting.remove(response.identity); dispatched.remove(response.identity) }
        let entry: Dictionary<String, PendingRequestSnapshot>.Element
        do {
            var refreshed = false
            for _ in 0..<3 {
                if try await refreshSnapshot() { refreshed = true; break }
            }
            guard refreshed else { throw OpenCodeConnectionError.staleRequest }
            guard let current = pending.first(where: { $0.value.identity == response.identity }), response.isValid(for: current.value) else {
                throw OpenCodeConnectionError.staleRequest
            }
            guard connected, self.channelID == channelID else { throw OpenCodeConnectionError.disconnected }
            entry = current
        } catch {
            throw OpenCodePreDispatchError(underlying: error)
        }
        let request = entry.value
        let payload: [String: Any]
        let path: String
        if request.kind == .permission {
            payload = ["reply": response.permissionDecision == .allow ? "once" : "reject"]
            path = "/permission/" + escaped(request.id) + "/reply"
        } else {
            let answers = request.question!.questions.map { question -> [String] in
                let answer = response.answers!.first { $0.questionID == question.id }!
                var labels = answer.optionIDs.compactMap { id in question.options.first { $0.id == id }?.label }
                if let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { labels.append(text) }
                return labels
            }
            payload = ["answers": answers]
            path = "/question/" + escaped(request.id) + "/reply"
        }
        let token = epoch
        pending[entry.key]?.lifecycle = .submitting
        emitResolution(request, lifecycle: .submitting)
        let data: Data
        dispatched.insert(request.identity)
        do { data = try await send(path, method: "POST", body: payload) }
        catch OpenCodeConnectionError.http(404) {
            try? await refresh()
            throw OpenCodeConnectionError.staleRequest
        } catch {
            if token == epoch, connected {
                deliveryUnknown.insert(request.identity)
                if pending[entry.key]?.identity == request.identity { pending[entry.key]?.lifecycle = .deliveryUnknown }
                emitResolution(request, lifecycle: .deliveryUnknown)
            }
            throw error
        }
        guard token == epoch, connected, self.channelID == channelID else { throw OpenCodeConnectionError.disconnected }
        // Public API's exact request path returns true only after processing.
        // A successful HTTP transport without that acknowledgment is unresolved.
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? Bool == true else {
            deliveryUnknown.insert(request.identity)
            if pending[entry.key]?.identity == request.identity { pending[entry.key]?.lifecycle = .deliveryUnknown }
            emitResolution(request, lifecycle: .deliveryUnknown)
            throw OpenCodeConnectionError.unconfirmedResponse
        }
        if let current = pending[entry.key] {
            guard current.identity == request.identity,
                  current.question == request.question, current.permission == request.permission else {
                throw OpenCodeConnectionError.staleRequest
            }
        }
        refreshRevision += 1
        pending.removeValue(forKey: entry.key)
        emitResolution(request, lifecycle: .accepted)
        // Reject can remove other pending permissions; refresh reports those as
        // expired, never falsely accepted on behalf of the submitted request.
        try? await refresh()
        return ResponseReceipt(identity: request.identity, lifecycle: .accepted)
    }

    func selectSession(sessionID: String) async throws {
        guard connected, canSelect, let raw = sessionInfo.keys.first(where: { canonicalSessionID($0) == sessionID }) else { throw OpenCodeConnectionError.unsupportedAPI }
        let data = try await send("/tui/select-session", method: "POST", body: ["sessionID": raw])
        guard (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? Bool == true else { throw OpenCodeConnectionError.unconfirmedResponse }
    }

    private func announceDisconnection() {
        refreshRevision += 1
        for identity in dispatched {
            deliveryUnknown.insert(identity)
            if let key = pending.first(where: { $0.value.identity == identity })?.key, let request = pending[key] {
                pending[key]?.lifecycle = .deliveryUnknown
                emitResolution(request, lifecycle: .deliveryUnknown)
            }
        }
        for id in Set(sessionInfo.keys.map { canonicalSessionID($0) }).union(pending.values.map { $0.identity.sessionID }) {
            emit(sessionID: id, turnID: "runtime:" + runtimeID, kind: .unknownEvent,
                 detail: "OpenCode bağlantısı kesildi; bekleyen isteklerin sonucu doğrulanmadı")
        }
    }
    private func emitRequest(_ request: PendingRequestSnapshot) {
        emit(sessionID: request.identity.sessionID, turnID: request.identity.turnID,
             kind: request.kind == .question ? .userQuestionObserved : .permissionObserved,
             title: sessionInfo.values.first { canonicalSessionID($0.id) == request.identity.sessionID }?.title, request: request)
    }
    private func emitResolution(_ request: PendingRequestSnapshot, lifecycle: RequestLifecycle) {
        emit(sessionID: request.identity.sessionID, turnID: request.identity.turnID, kind: .requestResolved,
             update: RequestLifecycleUpdate(identity: request.identity, lifecycle: lifecycle))
    }
    private func emit(sessionID: String, turnID: String, kind: EventKind, title: String? = nil, detail: String? = nil, runtimeState: WorkState? = nil,
                      request: PendingRequestSnapshot? = nil, update: RequestLifecycleUpdate? = nil) {
        let runtime = RuntimeMetadata(id: runtimeID, host: configuration.host, version: version,
            canonicalSessionID: sessionID, sourceContextID: sourceContextID)
        let capabilities = RuntimeCapabilities(provider: .opencode, runtimeID: runtimeID, version: version ?? "",
            evidence: RuntimeCapability.allOpenCode.map { CapabilityEvidence(capability: $0, support: .live, source: "OpenCode local /doc and live snapshot") } +
                [CapabilityEvidence(capability: .openSession, support: connected && canSelect ? .live : .unsupported,
                    source: "OpenCode local /doc /tui/select-session")], responseChannelID: channelID)
        callback?(CodexEvent(sessionID: sessionID, turnID: turnID, requestID: request?.id ?? update?.identity.requestID,
            kind: kind, source: .unknown, title: title.map { String($0.prefix(100)) }, at: Date(), id: UUID().uuidString, detail: detail, provider: .opencode,
            projectPath: configuration.projectDirectory, runtime: runtime, capabilities: capabilities, requestSnapshot: request, requestUpdate: update, requestTurnScope: request != nil || update != nil ? .request : nil, runtimeState: runtimeState))
    }
    private func escaped(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func makeRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = path
        components.queryItems = [URLQueryItem(name: "directory", value: configuration.projectDirectory)]
        guard let url = components.url else { throw OpenCodeConnectionError.invalidConfiguration }
        var request = URLRequest(url: url, timeoutInterval: configuration.timeout)
        request.httpMethod = method
        if let password = configuration.password {
            let credential = Data((configuration.username + ":" + password).utf8).base64EncodedString()
            request.setValue("Basic " + credential, forHTTPHeaderField: "Authorization")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.url?.host == configuration.serverURL.host,
              http.url?.port == configuration.serverURL.port else { throw OpenCodeConnectionError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw OpenCodeConnectionError.unauthorized }
        guard (200..<300).contains(http.statusCode) else { throw OpenCodeConnectionError.http(http.statusCode) }
    }
    private func send(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let request = try makeRequest(path, method: method, body: body)
        let id = UUID()
        let transport = session
        let task = Task { try await transport.data(for: request) }
        inflight[id] = task
        defer { inflight.removeValue(forKey: id) }
        let (data, response) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        try validate(response)
        guard data.count <= 4_000_000 else { throw OpenCodeConnectionError.malformedResponse }
        return data
    }
    private func json(_ path: String) async throws -> Any {
        try JSONSerialization.jsonObject(with: await send(path), options: [.fragmentsAllowed])
    }
    private func decode<T: Decodable>(_ path: String) async throws -> T { try JSONDecoder().decode(T.self, from: await send(path)) }
}

private extension RuntimeCapability {
    static var allOpenCode: [RuntimeCapability] { [.observeQuestions, .observePermissions, .answerQuestions, .respondToPermissions] }
}
private final class OpenCodeNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
