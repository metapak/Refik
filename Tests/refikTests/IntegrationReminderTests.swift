import XCTest
import UserNotifications
@testable import refik

private struct FixtureTransport: InteractionResponseTransport {
    let lifecycle: RequestLifecycle
    var fails = false
    func submit(_ response: InteractionResponse, channelID: String) async throws -> ResponseReceipt {
        if fails { throw CocoaError(.fileReadUnknown) }
        return ResponseReceipt(identity: response.identity, lifecycle: lifecycle)
    }
}
final class IntegrationReminderTests: XCTestCase {
    func request(at now: Date, turn: String = "turn", scope: RequestTurnScope? = nil) -> PendingRequestSnapshot {
        PendingRequestSnapshot(identity: RequestIdentity(provider: .codex, runtimeID: "runtime", sessionID: "session", turnID: turn, requestID: turn, generation: turn), kind: .question,
            question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Private prompt")]), turnScope: scope, observedAt: now)
    }
    let runtime = RuntimeMetadata(id: "runtime", host: .terminal, version: "1", chatName: nil)
    var capabilities: RuntimeCapabilities {
        RuntimeCapabilities(provider: .codex, runtimeID: "runtime", version: "1", evidence: [CapabilityEvidence(capability: .answerQuestions, support: .live, source: "isolated fixture")], responseChannelID: "private-channel")
    }
    @MainActor func populate(_ app: AppModel, request: PendingRequestSnapshot) {
        let start = request.observedAt.addingTimeInterval(-1)
        app.accept(CodexEvent(sessionID: "session", turnID: "turn", requestID: nil, kind: .started, source: .cli, title: nil, at: start, id: "start", runtime: runtime, capabilities: capabilities), historical: true)
        app.accept(CodexEvent(sessionID: "session", turnID: request.identity.turnID, requestID: request.id, kind: .userQuestionObserved, source: .cli, title: nil, at: request.observedAt, id: "ask", runtime: runtime, capabilities: capabilities, requestSnapshot: request, requestTurnScope: request.turnScope), historical: true)
    }
    @MainActor func testChannelRegistryRequiredAndSubmittedIsNotAccepted() async {
        let app = AppModel(inspectNotificationPermission: false)
        let pending = request(at: Date().addingTimeInterval(-1))
        populate(app, request: pending)
        XCTAssertFalse(app.canSubmitResponse(pending))
        app.registerInteractionTransport(FixtureTransport(lifecycle: .submitted), capabilities: capabilities)
        XCTAssertTrue(app.canSubmitResponse(pending))
        let result = await app.submitResponse(InteractionResponse(identity: pending.identity, answers: [QuestionAnswer(questionID: "q", text: "answer")]))
        XCTAssertEqual(result.lifecycle, .submitted)
        XCTAssertEqual(app.sessions.first?.orderedRequests.first?.lifecycle, .submitted)
        XCTAssertEqual(app.aggregate, .waiting)
        XCTAssertFalse(app.canSubmitResponse(pending))
    }
    @MainActor func testUncertainDeliveryCannotRetryAndPersistenceContainsNoBodyOrChannel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let app = AppModel(inspectNotificationPermission: false, stateURL: file)
        let pending = request(at: Date().addingTimeInterval(-1))
        populate(app, request: pending)
        app.registerInteractionTransport(FixtureTransport(lifecycle: .submitted, fails: true), capabilities: capabilities)
        let result = await app.submitResponse(InteractionResponse(identity: pending.identity, answers: [QuestionAnswer(questionID: "q", text: "private-answer")]))
        XCTAssertEqual(result.lifecycle, .deliveryUnknown); XCTAssertFalse(app.canSubmitResponse(pending))
        let contents = try String(contentsOf: file)
        XCTAssertFalse(contents.contains("Private prompt")); XCTAssertFalse(contents.contains("private-answer")); XCTAssertFalse(contents.contains("private-channel"))
        let restored = AppModel(inspectNotificationPermission: false, stateURL: file)
        XCTAssertFalse(restored.canSubmitResponse(pending))
    }
    func testScopedRequestsPreserveRealTurnAndNewTurnInvalidatesAll() {
        var reducer = StateReducer(); let now = Date()
        XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "session", turnID: "turn", requestID: nil, kind: .started, source: .cli, title: nil, at: now, id: "start", runtime: runtime)))
        for (index, turn) in ["request:first", "hook:second"].enumerated() {
            let scope: RequestTurnScope = index == 0 ? .request : .hookInvocation
            let pending = request(at: now.addingTimeInterval(Double(index + 1)), turn: turn, scope: scope)
            XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "session", turnID: turn, requestID: turn, kind: .userQuestionObserved, source: .cli, title: nil, at: pending.observedAt, id: turn, requestSnapshot: pending, requestTurnScope: scope)))
        }
        XCTAssertEqual(reducer.sessions["session"]?.turnID, "turn")
        XCTAssertEqual(reducer.sessions["session"]?.pending.count, 2)
        XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "session", turnID: "new", requestID: nil, kind: .started, source: .cli, title: nil, at: now.addingTimeInterval(3), id: "new")))
        XCTAssertTrue(reducer.sessions["session"]!.orderedRequests.isEmpty)
        let stale = request(at: now, turn: "request:first", scope: .request)
        XCTAssertFalse(reducer.apply(CodexEvent(sessionID: "session", turnID: stale.identity.turnID, requestID: stale.id, kind: .requestResolved, source: .cli, title: nil, at: now.addingTimeInterval(4), id: "late", requestUpdate: RequestLifecycleUpdate(identity: stale.identity, lifecycle: .accepted), requestTurnScope: .request)))
    }
    func testReminderClockOnceCancellationWakeAndLegacyPreferences() throws {
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertNil(preferences.preferredDisplayID); XCTAssertTrue(preferences.displayPositions.isEmpty); XCTAssertFalse(preferences.remindersEnabled)
        let now = Date(timeIntervalSince1970: 10)
        let pending = request(at: now)
        var scheduler = ReminderScheduler()
        scheduler.observe(pending, at: now, preferences: preferences)
        preferences.remindersEnabled = true; preferences.reminderDelaySeconds = 30
        XCTAssertTrue(scheduler.due(at: now.addingTimeInterval(30), preferences: preferences, isCurrent: { _ in true }).isEmpty)
        scheduler.observe(pending, at: now, preferences: preferences)
        XCTAssertEqual(scheduler.due(at: now.addingTimeInterval(30), preferences: preferences, isCurrent: { _ in true }).count, 1)
        scheduler.observe(pending, at: now, preferences: preferences)
        XCTAssertTrue(scheduler.due(at: now.addingTimeInterval(31), preferences: preferences, isCurrent: { _ in true }).isEmpty)
        var sleeping = ReminderScheduler(); sleeping.observe(pending, at: now, preferences: preferences)
        XCTAssertTrue(sleeping.due(at: now.addingTimeInterval(100), preferences: preferences, isCurrent: { _ in true }).isEmpty)
        var canceled = ReminderScheduler(); canceled.observe(pending, at: now, preferences: preferences); canceled.cancel(pending.identity)
        XCTAssertTrue(canceled.due(at: now.addingTimeInterval(30), preferences: preferences, isCurrent: { _ in true }).isEmpty)
    }
    func testReminderSoundIndependentFromBannerAuthorization() {
        var sounds: [String] = [], banners: [UNNotificationRequest] = []
        let coordinator = NotificationCoordinator(playSound: { sounds.append($0) }, postBanner: { banners.append($0) })
        var preferences = Preferences(); preferences.reminderSound = true; preferences.reminderBanner = false; preferences.soundName = "Tink"
        coordinator.reminder(request: request(at: Date()), preferences: preferences)
        XCTAssertEqual(sounds, ["Tink"]); XCTAssertTrue(banners.isEmpty)
    }
    @MainActor func testObserveOnlyQuestionCanRemindWithoutEnablingResponse() {
        let app = AppModel(inspectNotificationPermission: false)
        let now = Date()
        let pending = request(at: now)
        populate(app, request: pending)
        XCTAssertFalse(app.canSubmitResponse(pending))
        var preferences = Preferences(); preferences.remindersEnabled = true; preferences.reminderDelaySeconds = 30
        var scheduler = ReminderScheduler()
        scheduler.observe(pending, at: now, preferences: preferences)
        let due = scheduler.due(at: now.addingTimeInterval(30), preferences: preferences) { current in
            // Trusted observer liveness is separate from response capabilities.
            app.sessions.contains { $0.pending.contains(current.id) && $0.orderedRequests.contains { $0.identity == current.identity } }
        }
        XCTAssertEqual(due.count, 1)
        XCTAssertFalse(app.canSubmitResponse(pending))
        XCTAssertTrue(scheduler.due(at: now.addingTimeInterval(31), preferences: preferences, isCurrent: { _ in true }).isEmpty)
    }

    @MainActor func testSeparateObserverRuntimeCannotReplaceExactLiveLease() {
        let coordinator = IntegrationCoordinator()
        coordinator.register(capabilities, transport: FixtureTransport(lifecycle: .submitted), runtime: runtime)
        let pending = request(at: Date())
        var session = Session(id: "session", turnID: "turn", source: .cli, title: "Job", state: .waitingUser, started: pending.observedAt, updated: pending.observedAt)
        session.pending = [pending.id]; session.requestSnapshots = [pending]
        session.runtime = RuntimeMetadata(id: "native-observer", host: .codexDesktop, version: nil, chatName: nil)
        XCTAssertNotNil(coordinator.transport(for: session, request: pending))
        coordinator.remove(runtimeID: "runtime")
        XCTAssertNil(coordinator.transport(for: session, request: pending))
    }

    func testAuthoritativeOpenCodeBodyRevisionPreservesOrderRejectsOldReceiptAndEqualBodyReplay() {
        var reducer = StateReducer(); let now = Date()
        let runtime = RuntimeMetadata(id: "open-runtime", host: .terminal, version: "1", chatName: nil)
        func snapshot(generation: String, prompt: String, at: Date) -> PendingRequestSnapshot {
            PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: "open-runtime", sessionID: "open-session", turnID: "request:native", requestID: "native", generation: generation), kind: .question,
                question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: prompt)]), turnScope: .request, observedAt: at)
        }
        func observation(_ request: PendingRequestSnapshot, id: String, at: Date) -> CodexEvent {
            CodexEvent(sessionID: "open-session", turnID: request.identity.turnID, requestID: request.id, kind: .userQuestionObserved, source: .unknown, title: nil, at: at, id: id, provider: .opencode, runtime: runtime, requestSnapshot: request, requestTurnScope: .request, trustedInteractionSnapshot: true)
        }
        let original = snapshot(generation: "one", prompt: "Original", at: now)
        XCTAssertTrue(reducer.apply(observation(original, id: "one", at: now)))
        let equalReplay = snapshot(generation: "two", prompt: "Original", at: now.addingTimeInterval(1))
        XCTAssertFalse(reducer.apply(observation(equalReplay, id: "equal", at: now.addingTimeInterval(1))))
        XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "open-session", turnID: original.identity.turnID, requestID: original.id, kind: .requestResolved, source: .unknown, title: nil, at: now.addingTimeInterval(1.5), id: "body-replaced", provider: .opencode, requestUpdate: RequestLifecycleUpdate(identity: original.identity, lifecycle: .resolved), requestTurnScope: .request)))
        let revision = snapshot(generation: "three", prompt: "Revised", at: now.addingTimeInterval(2))
        XCTAssertTrue(reducer.apply(observation(revision, id: "revision", at: now.addingTimeInterval(2))))
        XCTAssertEqual(reducer.sessions["open-session"]!.orderedRequests.map(\.id), ["native"])
        XCTAssertEqual(reducer.sessions["open-session"]!.orderedRequests.first?.identity.generation, "three")
        let oldReceipt = CodexEvent(sessionID: "open-session", turnID: original.identity.turnID, requestID: original.id, kind: .requestResolved, source: .unknown, title: nil, at: now.addingTimeInterval(3), id: "receipt", provider: .opencode, requestUpdate: RequestLifecycleUpdate(identity: original.identity, lifecycle: .accepted), requestTurnScope: .request)
        XCTAssertFalse(reducer.apply(oldReceipt)); XCTAssertEqual(reducer.sessions["open-session"]!.state, .waitingUser)
    }

    func testRedactedRestartRehydratesOnlySameContextAndPreservesUncertainLock() throws {
        let now = Date()
        for uncertain in [false, true] {
            var reducer = StateReducer()
            let oldRuntime = RuntimeMetadata(id: "old-runtime", host: .terminal, version: "1", chatName: nil, sourceContextID: "endpoint-project")
            let old = PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: "old-runtime", sessionID: "native", turnID: "request:q", requestID: "q", generation: "old"), kind: .question,
                question: QuestionRequestBody(questions: [StructuredQuestion(id: "q", prompt: "Private prompt")]), turnScope: .request, observedAt: now)
            XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "native", turnID: old.identity.turnID, requestID: old.id, kind: .userQuestionObserved, source: .unknown, title: nil, at: now, id: "old", provider: .opencode, runtime: oldRuntime, requestSnapshot: old, requestTurnScope: .request)))
            if uncertain {
                XCTAssertTrue(reducer.apply(CodexEvent(sessionID: "native", turnID: old.identity.turnID, requestID: old.id, kind: .requestResolved, source: .unknown, title: nil, at: now.addingTimeInterval(1), id: "uncertain", provider: .opencode, requestUpdate: RequestLifecycleUpdate(identity: old.identity, lifecycle: .deliveryUnknown), requestTurnScope: .request)))
            }
            reducer = try JSONDecoder().decode(StateReducer.self, from: JSONEncoder().encode(reducer))
            XCTAssertNil(reducer.sessions["native"]!.orderedRequests.first?.question)
            let fresh = PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: "new-runtime", sessionID: "native", turnID: "request:q", requestID: "q", generation: "fresh"), kind: .question,
                question: old.question, turnScope: .request, observedAt: now.addingTimeInterval(2))
            var event = CodexEvent(sessionID: "native", turnID: fresh.identity.turnID, requestID: fresh.id, kind: .userQuestionObserved, source: .unknown, title: nil, at: now.addingTimeInterval(2), id: "fresh", provider: .opencode,
                runtime: RuntimeMetadata(id: "new-runtime", host: .terminal, version: "1", chatName: nil, sourceContextID: "different-target"), requestSnapshot: fresh, requestTurnScope: .request, trustedInteractionSnapshot: true)
            XCTAssertFalse(reducer.apply(event))
            event.runtime?.sourceContextID = "endpoint-project"
            XCTAssertTrue(reducer.apply(event))
            XCTAssertEqual(reducer.sessions["native"]!.orderedRequests.first?.question?.questions.first?.prompt, "Private prompt")
            XCTAssertEqual(reducer.sessions["native"]!.orderedRequests.first?.lifecycle, uncertain ? .deliveryUnknown : .pending)
        }
    }

}
