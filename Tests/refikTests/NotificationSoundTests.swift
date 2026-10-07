import XCTest
import UserNotifications
@testable import refik

final class NotificationSoundTests: XCTestCase {
    private func event(_ kind: EventKind, _ n: Int, request: String? = nil, turn: String = "one", provider: Provider = .codex) -> CodexEvent {
        CodexEvent(sessionID: provider == .codex ? "thread" : "\(provider.rawValue):thread", turnID: turn, requestID: request, kind: kind, source: .desktop,
                   title: "fixture", at: Date(timeIntervalSince1970: 1_790_816_400 + Double(n)), id: "event-\(n)", provider: provider)
    }
    func testAudioDoesNotRequireBannerPermissionAndBannerNeverDuplicatesAudio() {
        var audio: [String] = [], banners: [UNNotificationRequest] = []
        let coordinator = NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { banners.append($0) })
        var preferences = Preferences()
        preferences.soundName = "Tink"
        coordinator.transition(event: event(.userQuestionObserved, 1, request: "q"), preferences: preferences)
        XCTAssertEqual(audio, ["Tink"]); XCTAssertTrue(banners.isEmpty)
        preferences.notifications = true
        coordinator.transition(event: event(.completed, 2), preferences: preferences)
        XCTAssertEqual(audio, ["Tink", "Tink"]); XCTAssertEqual(banners.count, 1)
        XCTAssertNil(banners.first?.content.sound)
        coordinator.transition(event: event(.completed, 3), preferences: preferences)
        XCTAssertEqual(audio.count, 2); XCTAssertEqual(banners.count, 1)
    }
    func testExplicitMuteAndCategoryPreferencesAreRespected() {
        var audio: [String] = [], banners: [UNNotificationRequest] = []
        let coordinator = NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { banners.append($0) })
        var preferences = Preferences(); preferences.sound = false; preferences.notifications = true
        coordinator.transition(event: event(.completed, 1), preferences: preferences)
        XCTAssertTrue(audio.isEmpty); XCTAssertEqual(banners.count, 1)
        preferences.sound = true; preferences.notifyWaiting = false; preferences.notifyFailed = false; preferences.notifyCompleted = false
        for e in [event(.userQuestionObserved, 2, request: "q"), event(.permissionObserved, 3, request: "p"), event(.completed, 4, turn: "two"), event(.failed, 5), event(.interrupted, 6)] {
            coordinator.transition(event: e, preferences: preferences)
        }
        XCTAssertTrue(audio.isEmpty); XCTAssertEqual(banners.count, 1)
    }
    @MainActor func testNewQuestionsWhileAlreadyYellowAndNewGreenOnceWithReplayAndRestoreSilent() throws {
        var audio: [String] = []
        let coordinator = NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in XCTFail("banner disabled") })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(inspectNotificationPermission: false, stateURL: url, notificationCoordinator: coordinator)
        let saved = model.preferences
        defer { model.preferences = saved }
        model.preferences = Preferences()
        model.accept(event(.started, 0), historical: false)
        model.accept(event(.userQuestionObserved, 1, request: "q1"), historical: false)
        model.accept(event(.userQuestionObserved, 2, request: "q2"), historical: false)
        XCTAssertEqual(audio.count, 2)
        model.accept(event(.userQuestionObserved, 3, request: "q2"), historical: false)
        model.accept(event(.reconciledRunning, 4), historical: false)
        XCTAssertEqual(audio.count, 2)
        model.accept(event(.completed, 5), historical: false)
        model.accept(event(.completed, 6), historical: false)
        model.markSeen(["thread"])
        model.accept(event(.completed, 7), historical: false)
        XCTAssertEqual(audio.count, 3)
        let restored = AppModel(inspectNotificationPermission: false, stateURL: url, notificationCoordinator: coordinator)
        restored.accept(event(.completed, 8), historical: true)
        restored.accept(event(.completed, 9), historical: false)
        XCTAssertEqual(audio.count, 3)
        model.accept(event(.started, 10, turn: "two"), historical: false)
        model.accept(event(.completed, 11, turn: "two"), historical: false)
        XCTAssertEqual(audio.count, 4)
    }
    @MainActor func testHistoricalBootstrapAndOtherProviders() {
        var audio: [String] = []
        let model = AppModel(inspectNotificationPermission: false, notificationCoordinator: NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in }))
        let saved = model.preferences; defer { model.preferences = saved }
        model.preferences = Preferences()
        model.accept(event(.started, 0), historical: true)
        model.accept(event(.completed, 1), historical: true)
        model.accept(event(.completed, 2), historical: false)
        XCTAssertTrue(audio.isEmpty)
        model.accept(event(.started, 3, turn: "two", provider: .claude), historical: false)
        model.accept(event(.permissionObserved, 4, request: "permission", turn: "two", provider: .claude), historical: false)
        model.accept(event(.completed, 5, turn: "two", provider: .claude), historical: false)
        XCTAssertEqual(audio.count, 2)
        XCTAssertEqual(model.sessions.first(where: { $0.id == "claude:thread" })?.provider, .claude)
        XCTAssertNil(model.sessions.first(where: { $0.id == "thread" && $0.provider != .codex }))
    }
    @MainActor func testProviderMirrorSuppressionAndRestorationStaySilent() throws {
        var audio: [String] = []
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let model = AppModel(inspectNotificationPermission: false, stateURL: url, notificationCoordinator: NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in }))
        let saved = model.preferences; defer { model.preferences = saved }
        model.preferences = Preferences()
        model.accept(event(.started, 0), historical: false)
        model.accept(event(.completed, 1), historical: false)
        let reducer = try JSONDecoder().decode(StateReducer.self, from: Data(contentsOf: url))
        let completions = reducer.providerAttentionCandidates.map(NativeCompletion.init)
        let now = event(.completed, 2).at
        func observations(_ unread: Set<String>) -> [ProviderAttentionObservation] {
            let context = NativeAttentionContext(identity: "fixture", host: "local:fixture", authGeneration: now, expires: now.addingTimeInterval(100))
            return NativeAttentionMirror.observations(NativeAttentionSnapshot(context: context, unread: unread, observedAt: now), completions: completions, at: now)
        }
        model.reconcileProviderAttention(observations([]), at: now)
        XCTAssertEqual(model.aggregate, .neutral)
        model.reconcileProviderAttention(observations(["thread"]), at: now)
        XCTAssertEqual(model.aggregate, .completed)
        model.reconcileProviderAttention(observations(["thread"]), at: now)
        XCTAssertEqual(audio.count, 1)
    }
    @MainActor func testSignalRestartWithSameTurnHasNewTerminalGeneration() {
        var audio: [String] = []
        let model = AppModel(inspectNotificationPermission: false, notificationCoordinator: NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in }))
        let saved = model.preferences; defer { model.preferences = saved }
        model.preferences = Preferences()
        for e in [event(.started, 0, provider: .signal), event(.completed, 1, provider: .signal), event(.started, 2, provider: .signal), event(.completed, 3, provider: .signal)] {
            model.accept(e, historical: false)
        }
        XCTAssertEqual(audio.count, 2)
    }
    func testProviderAndGenerationIdentitiesStaySeparate() {
        var audio: [String] = []
        let coordinator = NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in })
        let preferences = Preferences()
        let first = event(.completed, 1)
        coordinator.transition(event: first, preferences: preferences, generation: Date(timeIntervalSince1970: 1))
        coordinator.transition(event: first, preferences: preferences, generation: Date(timeIntervalSince1970: 2))
        coordinator.transition(event: event(.completed, 2, provider: .claude), preferences: preferences, generation: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(audio.count, 3)
    }
    @MainActor func testCrossProviderSessionCollisionCannotProduceFalseWaitingSound() {
        var audio: [String] = []
        let model = AppModel(inspectNotificationPermission: false, notificationCoordinator: NotificationCoordinator(playSound: { audio.append($0) }, postBanner: { _ in }))
        let saved = model.preferences; defer { model.preferences = saved }
        model.preferences = Preferences()
        model.accept(event(.started, 0), historical: false)
        var collision = event(.permissionObserved, 1, request: "permission", provider: .claude)
        collision.sessionID = "thread"
        model.accept(collision, historical: false)
        XCTAssertTrue(audio.isEmpty); XCTAssertEqual(model.aggregate, .running)
        XCTAssertEqual(model.sessions.first(where: { $0.id == "thread" })?.provider, .codex)
        model.accept(event(.started, 2, provider: .claude), historical: false)
        model.accept(event(.permissionObserved, 3, request: "permission", provider: .claude), historical: false)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(model.sessions.first(where: { $0.id == "thread" })?.state, .running)
        XCTAssertEqual(model.sessions.first(where: { $0.id == "claude:thread" })?.state, .waitingPermission)
    }

}
