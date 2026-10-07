import XCTest
@testable import refik

final class AttentionTests: XCTestCase {
    func event(_ id: String, _ kind: EventKind, _ at: Int, provider: Provider = .codex) -> CodexEvent {
        var event = CodexEvent(sessionID: id, turnID: "turn", requestID: kind == .permissionObserved ? "request" : nil, kind: kind, source: .desktop,
            title: "Project", at: Date(timeIntervalSince1970: Double(at)), id: "\(id):\(at)")
        event.provider = provider
        if provider == .codex { event.runtime = RuntimeMetadata(id: "fixture-desktop", host: .codexDesktop) }
        return event
    }
    func testOnlyCurrentAndUnseenRowsAreVisibleAndSorted() {
        var state = StateReducer()
        for (id, kind) in [("working", EventKind.started), ("success", .completed), ("failure", .failed), ("waiting", .permissionObserved), ("old", .completed), ("unknown", .sessionEnded)] {
            state.apply(event(id, kind, 1))
        }
        state.markSeen(["old"])
        XCTAssertEqual(state.visibleAttentionRows.map(\.id), ["waiting", "failure", "success", "working"])
        XCTAssertEqual(state.attentionFooter, "1 çalışıyor · 1 bekliyor · 2 yeni sonuç")
        XCTAssertFalse(state.attentionFooter.contains("oturum"))
    }
    func testIndependentCompletionsGreenThenWhiteThenIdle() {
        var state = StateReducer()
        state.apply(event("a", .completed, 1)); state.apply(event("b", .completed, 2)); state.apply(event("work", .started, 3))
        XCTAssertEqual(state.aggregate, .completed)
        state.markSeen(["a"])
        XCTAssertEqual(Set(state.visibleAttentionRows.map(\.id)), ["b", "work"])
        XCTAssertEqual(state.aggregate, .completed)
        state.markSeen(["b"])
        XCTAssertEqual(state.aggregate, .running)
        state.apply(event("work", .completed, 4)); state.markSeen(["work"])
        XCTAssertEqual(state.aggregate, .neutral)
        XCTAssertEqual(state.attentionFooter, "Aktif işlem yok")
        XCTAssertEqual(state.sessions.count, 3, "diagnostic records are preserved")
    }
    func testWatchSignalFailureInterruptAndRunningAcknowledgement() {
        for provider in [Provider.watch, .signal] {
            for kind in [EventKind.completed, .failed, .interrupted] {
                var state = StateReducer()
                state.apply(event("result", kind, 1, provider: provider))
                XCTAssertEqual(state.visibleAttentionRows.count, 1)
                state.markSeen(["result"])
                XCTAssertTrue(state.visibleAttentionRows.isEmpty)
                XCTAssertNotNil(state.sessions["result"])
            }
        }
        var state = StateReducer()
        state.apply(event("work", .started, 1)); state.apply(event("wait", .permissionObserved, 2))
        state.markSeen(["work", "wait"])
        XCTAssertEqual(state.visibleAttentionRows.count, 2)
        XCTAssertEqual(state.aggregate, .waiting)
    }
    @MainActor func testPublicRouteDispatchDoesNotAcknowledgeAndKeepsWorking() {
        let app = AppModel(inspectNotificationPermission: false)
        let id = UUID().uuidString
        app.accept(event(id, .completed, 1), historical: false)
        app.accept(event("b", .failed, 2), historical: false)
        let a = app.sessions.first { $0.id == id }!
        app.open(a) { _ in false }
        XCTAssertEqual(app.sessions.count, 2)
        app.open(a) { route in
            if SessionRouting.verifiedCodexRouting { XCTAssertEqual(route.url?.absoluteString, "codex://threads/\(id)") }
            return true
        }
        XCTAssertEqual(Set(app.sessions.map(\.id)), ["b", id])
        app.accept(event("work", .started, 3), historical: false)
        app.open(app.sessions.first { $0.id == "work" }!) { _ in true }
        XCTAssertTrue(app.sessions.contains { $0.id == "work" })
    }
    @MainActor func testPanelAppearanceAndCloseDoNotAcknowledge() {
        let app = AppModel(inspectNotificationPermission: false)
        app.accept(event("completion", .completed, 1), historical: false)
        let windows = WindowCoordinator(model: app)
        windows.showPanel(); windows.closePanel()
        XCTAssertEqual(app.aggregate, .completed)
        XCTAssertEqual(app.sessions.map(\.id), ["completion"])
    }
    @MainActor func testIsolatedStoreSurvivesRestartAndReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        let app = AppModel(inspectNotificationPermission: false, stateURL: url)
        let completion = event("watch", .completed, 1, provider: .watch)
        app.accept(completion, historical: false)
        XCTAssertEqual(AppModel(inspectNotificationPermission: false, stateURL: url).sessions.count, 1)
        app.markSeen(["watch"])
        let restored = AppModel(inspectNotificationPermission: false, stateURL: url)
        restored.accept(completion, historical: true)
        XCTAssertTrue(restored.sessions.isEmpty)
        XCTAssertEqual(restored.aggregate, .neutral)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotEqual(url.deletingLastPathComponent(), BridgePath.directory)
    }
    func testUsageDurationAndExplicitSemantics() {
        for (minutes, text) in [(60, "1 saat"), (300, "5 saat"), (1440, "1 gün"), (10080, "7 gün")] {
            XCTAssertEqual(UsageFormatting.duration(minutes: minutes), text)
        }
        var entry = UsageEntry(provider: .codex, window: "7 gün", percent: 83, fidelity: .derived, expires: .distantFuture)
        XCTAssertEqual(entry.valueLabel, "Türetilmiş veri")
        XCTAssertFalse(entry.valueLabel.contains("83"))
        entry.semantic = .used
        XCTAssertEqual(entry.valueLabel, "~%17 kaldı")
        entry.semantic = .remaining
        XCTAssertEqual(entry.valueLabel, "~%83 kaldı")
        let official = UsageEntry(provider: .codex, window: "7 gün", percent: 83, fidelity: .official, expires: .distantFuture, semantic: .used)
        XCTAssertEqual(official.valueLabel, "%17 kaldı")
        let hourly = UsageEntry(provider: .codex, window: "5 saat", percent: 83, fidelity: .derived, expires: .distantFuture, semantic: .used)
        XCTAssertEqual(hourly.valueLabel, "~%83 kullanıldı")
    }
    @MainActor func testFallbackApplicationOpenPreservesEveryResult() {
        let app = AppModel(inspectNotificationPermission: false)
        for provider in [Provider.codex, .claude, .antigravity] {
            app.accept(event(provider.rawValue, .completed, 1, provider: provider), historical: false)
        }
        for session in app.sessions { app.open(session) { route in XCTAssertFalse(route.exact); return true } }
        XCTAssertEqual(app.sessions.count, 3)
        XCTAssertEqual(app.aggregate, .completed)
    }
    func testMascotDisplayNamesPreserveLegacyAssetIdentity() {
        for raw in ["cute", "tatlı", "weety"] {
            XCTAssertEqual(MascotStyle.identifier(raw), "cute")
            XCTAssertEqual(MascotStyle.displayName(raw), "weety")
            XCTAssertEqual(MascotStyle.assetName(raw), "tatlı")
        }
        for raw in ["stern", "sert", "ardly"] {
            XCTAssertEqual(MascotStyle.identifier(raw), "stern")
            XCTAssertEqual(MascotStyle.displayName(raw), "ardly")
            XCTAssertEqual(MascotStyle.assetName(raw), "sert")
        }
        for raw in ["webAI", "web ai", "web-ai", "webai"] {
            XCTAssertEqual(MascotStyle.identifier(raw), "webAI")
            XCTAssertEqual(MascotStyle.displayName(raw), "webai")
            XCTAssertEqual(MascotStyle.assetName(raw), "web-ai")
        }
    }
    func testProjectRootFallback() {
        XCTAssertEqual(ProjectLabel.resolve(cwd: "/", title: "Task title"), "Task title")
        XCTAssertEqual(ProjectLabel.resolve(cwd: "/"), "Codex oturumu")
        XCTAssertEqual(ProjectLabel.resolve(cwd: "/workspace/sample-project"), "sample-project")
        XCTAssertEqual(ProjectLabel.resolve(explicit: "Workspace", cwd: "/workspace/sample-project"), "Workspace")
    }
    func testExactCodexRoutingBeforeHonestFallback() {
        var state = StateReducer()
        let id = UUID().uuidString
        state.apply(event(id, .completed, 1))
        let session = state.sessions[id]!
        let exact = SessionRouting.route(for: session, codexRoutingVerified: true)
        XCTAssertEqual(exact.url?.absoluteString, "codex://threads/\(id)")
        XCTAssertEqual(exact.label, "Oturuma git")
        let fallback = SessionRouting.route(for: session, codexRoutingVerified: false)
        XCTAssertNil(fallback.url)
        XCTAssertEqual(fallback.label, "Uygulamayı aç")
        for provider in [Provider.claude, .antigravity] {
            var other = session; other.provider = provider
            XCTAssertFalse(SessionRouting.route(for: other).exact)
        }
    }
    func testSeenHistoryDoesNotPreventNewWorkAtStoreLimit() {
        var state = StateReducer()
        for n in 0..<200 {
            let id = "seen-\(n)"
            state.apply(event(id, .completed, n)); state.markSeen([id])
        }
        XCTAssertTrue(state.apply(event("new", .started, 201)))
        XCTAssertEqual(state.sessions.count, 200)
        XCTAssertEqual(state.visibleAttentionRows.map(\.id), ["new"])
    }
    func testExpireAndDropRemoveAttention() {
        var state = StateReducer()
        var working = event("ttl", .started, 1, provider: .signal); working.ttl = 5
        state.apply(working); state.expire(at: Date(timeIntervalSince1970: 7))
        XCTAssertTrue(state.visibleAttentionRows.isEmpty)
        state.apply(event("drop", .completed, 8, provider: .signal)); state.apply(event("drop", .dropped, 9, provider: .signal))
        XCTAssertTrue(state.visibleAttentionRows.isEmpty)
    }
}
