import XCTest
@testable import refik

final class AntigravityStatuslineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func sample(_ conversation: String = "actual-conversation", pending: Bool? = nil,
                        state: String = "idle", tasks: Int = 0) -> AntigravityStatuslinePayload {
        AntigravityStatuslinePayload(conversationID: conversation, projectDirectory: "/project", version: "1.0.13",
            agentState: state, taskCount: tasks, toolConfirmationPending: pending)
    }
    func testDocumentedFieldsNormalizeWithoutPrivateQuestionAPI() throws {
        let raw = Data(#"{"product":"antigravity","conversation_id":"actual-conversation","workspace":{"project_dir":"/project"},"version":"1.0.13","agent_state":"working","task_count":1,"tool_confirmation_pending":true,"email":"excluded@example.test","quota":{}}"#.utf8)
        let payload = try XCTUnwrap(AntigravityStatuslinePayload.decodeOfficial(raw))
        var adapter = AntigravityStatuslineAdapter()
        let events = adapter.events(payload: payload, at: now)
        let permission = try XCTUnwrap(events.first { $0.kind == .permissionObserved })
        XCTAssertEqual(permission.provider, .antigravity)
        XCTAssertEqual(permission.source, .cli)
        XCTAssertEqual(permission.runtime?.host, .terminal)
        XCTAssertEqual(permission.runtime?.version, "1.0.13")
        XCTAssertEqual(permission.requestSnapshot?.turnScope, .request)
        XCTAssertTrue(permission.requestID!.hasPrefix("statusline-permission:"))
        XCTAssertNil(permission.capabilities?.responseChannelID)
        XCTAssertFalse(permission.capabilities!.hasLive(.respondToPermissions, runtime: permission.runtime))
        XCTAssertFalse(events.contains { $0.kind == .userQuestionObserved })
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("excluded@example.test"))
    }
    func testPermissionFlagIntervalResolvesExactIdentityWithoutDecisionClaim() {
        var adapter = AntigravityStatuslineAdapter()
        let first = adapter.events(payload: sample(pending: true), at: now)
        let request = first.first { $0.kind == .permissionObserved }!.requestSnapshot!
        XCTAssertFalse(adapter.events(payload: sample(pending: true), at: now.addingTimeInterval(1)).contains { $0.kind == .permissionObserved })
        let resolved = adapter.events(payload: sample(pending: false), at: now.addingTimeInterval(2)).first { $0.kind == .requestResolved }!
        XCTAssertEqual(resolved.requestUpdate?.identity, request.identity)
        XCTAssertEqual(resolved.requestUpdate?.lifecycle, .resolved)
        XCTAssertFalse(adapter.events(payload: sample(pending: false), at: now.addingTimeInterval(3)).contains { $0.kind == .requestResolved })
        let next = adapter.events(payload: sample(pending: true), at: now.addingTimeInterval(4)).first { $0.kind == .permissionObserved }!.requestSnapshot!
        XCTAssertNotEqual(next.identity.generation, request.identity.generation)
        XCTAssertNotEqual(next.identity.requestID, request.identity.requestID)
    }
    func testMissingFlagAndOtherConversationCannotResolveObservedWait() {
        var adapter = AntigravityStatuslineAdapter()
        let first = adapter.events(payload: sample(pending: true), at: now)
        let request = first.first { $0.kind == .permissionObserved }!.requestSnapshot!
        XCTAssertFalse(adapter.events(payload: sample(), at: now.addingTimeInterval(1)).contains { $0.kind == .requestResolved })
        XCTAssertFalse(adapter.events(payload: sample("other", pending: false), at: now.addingTimeInterval(2)).contains { $0.kind == .requestResolved })
        let resolution = adapter.events(payload: sample(pending: false), at: now.addingTimeInterval(3)).first { $0.kind == .requestResolved }!
        XCTAssertEqual(resolution.requestUpdate?.identity, request.identity)
    }
    func testTaskCountAndIdleDoNotInventTaskCompletion() {
        var adapter = AntigravityStatuslineAdapter()
        let busy = adapter.events(payload: sample(state: "idle", tasks: 1), at: now)
        XCTAssertEqual(busy.first?.runtimeState, .running)
        let idle = adapter.events(payload: sample(state: "idle", tasks: 0), at: now.addingTimeInterval(1))
        XCTAssertEqual(idle.first?.runtimeState, .idle)
        XCTAssertFalse((busy + idle).contains { $0.kind == .completed })
    }
    func testQuotaRemainingFractionAndBothResetForms() {
        var adapter = AntigravityStatuslineAdapter(); var payload = sample()
        payload.quota = ["weekly": AntigravityQuotaStatus(remainingFraction: 0.9378,
            resetTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(120)), resetInSeconds: nil),
            "seconds": AntigravityQuotaStatus(remainingFraction: 0, resetTime: nil, resetInSeconds: 60)]
        let events = adapter.events(payload: payload, at: now).filter { $0.kind == .usage }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first { $0.title == "weekly" }?.progress, 0.9378)
        XCTAssertEqual(events.first { $0.title == "seconds" }?.progress, 0)
        XCTAssertTrue(events.allSatisfy { $0.detail == "remaining" && $0.resetAt! > now && $0.ttl! > 0 })
    }
    func testMissingInvalidOrExpiredQuotaNeverBecomesZeroPercent() {
        var adapter = AntigravityStatuslineAdapter(); var payload = sample()
        XCTAssertFalse(adapter.events(payload: payload, at: now).contains { $0.kind == .usage })
        payload.quota = ["missing": .init(remainingFraction: nil, resetTime: nil, resetInSeconds: 60),
            "out-of-range": .init(remainingFraction: 1.1, resetTime: nil, resetInSeconds: 60),
            "expired": .init(remainingFraction: 0.5, resetTime: "2000-01-01T00:00:00Z", resetInSeconds: 60),
            "missing-reset": .init(remainingFraction: 0.5, resetTime: nil, resetInSeconds: nil)]
        XCTAssertFalse(adapter.events(payload: payload, at: now).contains { $0.kind == .usage })
    }
    func testMalformedScalarsUnknownStateAndPrivatePayloadRejected() {
        for raw in [#"{"product":"antigravity","conversation_id":"c","workspace":{"project_dir":"/project"},"agent_state":"idle","task_count":true}"#,
                    #"{"product":"antigravity","conversation_id":"c","workspace":{"project_dir":"/project"},"agent_state":"idle","task_count":0,"tool_confirmation_pending":1}"#,
                    #"{"product":"antigravity","conversation_id":"c","workspace":{"project_dir":"/project"},"agent_state":"completed","task_count":0}"#,
                    #"{"type":"ask_question","stepIdx":4}"#] {
            XCTAssertNil(AntigravityStatuslinePayload.decodeOfficial(Data(raw.utf8)))
        }
    }
    func testUnknownVersionRemainsUnknownAndReducerRetainsPermissionUntilFalse() {
        var adapter = AntigravityStatuslineAdapter(); var payload = sample(pending: true)
        payload.version = nil
        var reducer = StateReducer()
        for event in adapter.events(payload: payload, at: now) { XCTAssertTrue(reducer.apply(event, allowActivityResume: true)) }
        XCTAssertEqual(reducer.sessions[payload.conversationID]?.state, .waitingPermission)
        XCTAssertNil(reducer.sessions[payload.conversationID]?.runtime?.version)
        payload.toolConfirmationPending = nil
        for event in adapter.events(payload: payload, at: now.addingTimeInterval(1)) { reducer.apply(event, allowActivityResume: true) }
        XCTAssertEqual(reducer.sessions[payload.conversationID]?.state, .waitingPermission)
        payload.toolConfirmationPending = false
        for event in adapter.events(payload: payload, at: now.addingTimeInterval(2)) { reducer.apply(event, allowActivityResume: true) }
        XCTAssertEqual(reducer.sessions[payload.conversationID]?.state, .idle)
        XCTAssertTrue(reducer.sessions[payload.conversationID]!.pending.isEmpty)
    }
}
