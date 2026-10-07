import XCTest
@testable import refik

private final class ReconnectProtocol: URLProtocol {
    static let lock = NSLock()
    static var posts = 0
    static var requireAuthentication = false
    static var authenticatedRequests = 0
    static var crossedCredentialBoundary = false
    static var unauthenticatedRequests = 0
    static let fixtureAuthorization = "Basic " + Data("fixture-user:fixture-password".utf8).base64EncodedString()
    static func configureAuthentication(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        requireAuthentication = enabled; authenticatedRequests = 0; crossedCredentialBoundary = false; unauthenticatedRequests = 0
    }
    static func checkAuthentication(_ request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard requireAuthentication else { return true }
        if request.url?.port == 49001 {
            let valid = request.value(forHTTPHeaderField: "Authorization") == fixtureAuthorization
            if valid { authenticatedRequests += 1 } else { unauthenticatedRequests += 1 }
            return valid
        }
        if request.value(forHTTPHeaderField: "Authorization") != nil { crossedCredentialBoundary = true }
        return true
    }
    static func unauthenticatedCount() -> Int { lock.lock(); defer { lock.unlock() }; return unauthenticatedRequests }
    static func authenticationEvidence() -> (Int, Bool) {
        lock.lock(); defer { lock.unlock() }; return (authenticatedRequests, crossedCredentialBoundary)
    }
    static func resetPosts() { lock.lock(); defer { lock.unlock() }; posts = 0 }
    static func postCount() -> Int { lock.lock(); defer { lock.unlock() }; return posts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        guard Self.checkAuthentication(request) else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: [:])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if path == "/event" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            // Hold this fixture stream open until the adapter cancels it.
            return
        }
        let value: Any
        switch path {
        case "/global/health": value = ["healthy": true, "version": "1.18.34"]
        case "/doc":
            var paths: [String: Any] = [:]
            for (route, method) in [("/question", "get"), ("/permission", "get"), ("/session", "get"), ("/session/status", "get"), ("/event", "get"), ("/question/{requestID}/reply", "post"), ("/permission/{requestID}/reply", "post")] { paths[route] = [method: [:]] }
            value = ["paths": paths]
        case "/question": value = [["id": "q", "sessionID": "native", "questions": [["question": "Choose", "options": [["label": "A"]], "custom": true]], "tool": ["messageID": "message", "callID": "call"]]]
        case "/permission": value = [["id": "permission", "sessionID": "native", "permission": "shell", "patterns": ["/project"], "tool": ["messageID": "message", "callID": "permission-call"]]]
        case "/session": value = [["id": "native", "directory": "/project", "title": "Fixture"]]
        case "/session/status": value = ["native": ["type": "busy"]]
        default:
            Self.lock.lock(); Self.posts += 1; Self.lock.unlock()
            value = false
        }
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class OpenCodeReconnectTests: XCTestCase {
    @MainActor func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected configured adapter state")
    }
    @MainActor func testSameConfigurationReconnectPreservesPendingAndUnknownLocksDifferentTargetSeparates() async throws {
        ReconnectProtocol.resetPosts(); ReconnectProtocol.configureAuthentication(true)
        defer { ReconnectProtocol.configureAuthentication(false) }
        var created = 0
        let app = AppModel(inspectNotificationPermission: false, openCodeAdapterFactory: { configuration in
            created += 1
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReconnectProtocol.self]
            return try OpenCodeAdapter(configuration: configuration, session: URLSession(configuration: config))
        })
        let first = OpenCodeConnectionConfiguration(serverURL: URL(string: "http://127.0.0.1:49001")!, projectDirectory: "/project", username: "fixture-user", password: "fixture-password")
        let clearedForm = OpenCodeConnectionConfiguration(serverURL: first.serverURL, projectDirectory: first.projectDirectory, username: first.username)
        _ = await app.configureOpenCode(first)
        try await waitUntil { app.sessions.first?.orderedRequests.first.map { app.canSubmitResponse($0) } == true }
        try await waitUntil { app.sessions.first?.orderedRequests.count == 2 }
        let original = try XCTUnwrap(app.sessions.first?.orderedRequests.first(where: { $0.kind == .question }))
        let permission = try XCTUnwrap(app.sessions.first?.orderedRequests.first(where: { $0.kind == .permission }))
        XCTAssertTrue(app.canSubmitResponse(permission))
        _ = await app.configureOpenCode(clearedForm, retainExistingCredentialsIfSameTarget: true)
        try await waitUntil { app.canSubmitResponse(original) && app.canSubmitResponse(permission) }
        XCTAssertEqual(created, 1)
        XCTAssertEqual(app.sessions.first?.orderedRequests.first(where: { $0.kind == .question })?.identity, original.identity)
        _ = await app.configureOpenCode(nil)
        XCTAssertFalse(app.canSubmitResponse(original)); XCTAssertFalse(app.canSubmitResponse(permission))
        XCTAssertEqual(app.aggregate, .waiting)
        _ = await app.configureOpenCode(clearedForm, retainExistingCredentialsIfSameTarget: true)
        try await waitUntil { app.canSubmitResponse(original) && app.canSubmitResponse(permission) }
        XCTAssertEqual(created, 1)
        let response = InteractionResponse(identity: original.identity, answers: [QuestionAnswer(questionID: "0", optionIDs: ["0"])])
        let result = await app.submitResponse(response)
        XCTAssertEqual(result.lifecycle, .deliveryUnknown)
        _ = await app.configureOpenCode(clearedForm, retainExistingCredentialsIfSameTarget: true)
        try await waitUntil { app.openCodeConnection.hasPrefix("Bağlı") }
        XCTAssertEqual(created, 1); XCTAssertFalse(app.canSubmitResponse(original))
        XCTAssertEqual(app.sessions.first?.orderedRequests.first(where: { $0.kind == .question })?.lifecycle, .deliveryUnknown)
        _ = await app.configureOpenCode(nil)
        XCTAssertEqual(app.aggregate, .waiting)
        _ = await app.configureOpenCode(clearedForm, retainExistingCredentialsIfSameTarget: true)
        try await waitUntil { app.openCodeConnection.hasPrefix("Bağlı") && app.canSubmitResponse(permission) }
        XCTAssertFalse(app.canSubmitResponse(original)); XCTAssertEqual(created, 1)
        _ = await app.submitResponse(response)
        let posts = ReconnectProtocol.postCount()
        XCTAssertEqual(posts, 1)
        let changedUser = OpenCodeConnectionConfiguration(serverURL: first.serverURL, projectDirectory: first.projectDirectory, username: "different-user")
        _ = await app.configureOpenCode(changedUser, retainExistingCredentialsIfSameTarget: true)
        XCTAssertEqual(created, 2)
        try await waitUntil { ReconnectProtocol.unauthenticatedCount() > 0 }
        XCTAssertFalse(app.canSubmitResponse(original)); XCTAssertFalse(app.canSubmitResponse(permission))
        let other = OpenCodeConnectionConfiguration(serverURL: URL(string: "http://127.0.0.1:49002")!, projectDirectory: "/project")
        _ = await app.configureOpenCode(other, retainExistingCredentialsIfSameTarget: true)
        try await waitUntil { app.sessions.contains { $0.id != original.identity.sessionID && $0.orderedRequests.contains { app.canSubmitResponse($0) } } }
        XCTAssertEqual(created, 3)
        let auth = ReconnectProtocol.authenticationEvidence()
        XCTAssertGreaterThan(auth.0, 10); XCTAssertFalse(auth.1)
        XCTAssertEqual(app.sessions.first(where: { $0.id == original.identity.sessionID })?.orderedRequests.first(where: { $0.kind == .question })?.lifecycle, .deliveryUnknown)
        _ = await app.configureOpenCode(nil)
    }
}
