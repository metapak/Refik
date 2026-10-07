import XCTest
import RefikInteractionWire
@testable import refik

final class InteractionPresentationTests: XCTestCase {
    private func request() -> PendingRequestSnapshot {
        PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: "runtime", sessionID: "session", turnID: "turn", requestID: "request", generation: "generation"), kind: .question,
            question: QuestionRequestBody(questions: [
                StructuredQuestion(id: "first", prompt: "Tek seçim", options: [QuestionOption(id: "a", label: "A"), QuestionOption(id: "b", label: "B")]),
                StructuredQuestion(id: "second", prompt: "Çok seçim", options: [QuestionOption(id: "c", label: "C"), QuestionOption(id: "d", label: "D")], allowsMultipleSelection: true)
            ]), observedAt: Date())
    }
    func testDraftPreservesOrderAndSingleMultipleSelections() {
        let request = request(); let questions = request.question!.questions
        var draft = QuestionDraft(request: request)
        draft.select("a", for: questions[0]); draft.select("b", for: questions[0])
        draft.select("c", for: questions[1]); draft.select("d", for: questions[1]); draft.select("c", for: questions[1])
        XCTAssertEqual(draft.answers.map(\.questionID), ["first", "second"])
        XCTAssertEqual(draft.answers[0].optionIDs, ["b"])
        XCTAssertEqual(draft.answers[1].optionIDs, ["d"])
        XCTAssertNotNil(draft.response(for: request))
    }
    func testDraftRejectsIncompleteAndChangedRequest() {
        var request = request(); var draft = QuestionDraft(request: request)
        XCTAssertNil(draft.response(for: request))
        for question in request.question!.questions { draft.setText("cevap", for: question) }
        XCTAssertNotNil(draft.response(for: request))
        request.lifecycle = .submitting
        XCTAssertNil(draft.response(for: request))
        let newer = PendingRequestSnapshot(identity: RequestIdentity(provider: .opencode, runtimeID: "runtime", sessionID: "session", turnID: "turn", requestID: "request", generation: "new"), kind: .question, question: request.question, observedAt: Date())
        XCTAssertNil(draft.response(for: newer))
    }
    func testUnknownOptionAndForbiddenTextDoNotEnterDraft() {
        let request = request(); var draft = QuestionDraft(request: request)
        var question = request.question!.questions[0]; question.allowsFreeform = false
        draft.select("unknown", for: question); draft.setText("secret", for: question)
        XCTAssertEqual(draft.answers[0].optionIDs, [])
        XCTAssertNil(draft.answers[0].text)
    }
    func testWaitingTypesUseDistinctIcons() {
        XCTAssertNotEqual(SessionPresentation.statusIcon(.waitingPermission), SessionPresentation.statusIcon(.waitingUser))
        XCTAssertEqual(WorkState.waitingPermission.label, "İzin bekliyor")
        XCTAssertEqual(WorkState.waitingUser.label, "Yanıt bekliyor")
    }
    func testCapabilityEvidenceSeparatesDocumentationAndLiveSupport() {
        XCTAssertEqual(IntegrationPresentation.supportLabel(.answerQuestions, evidence: []), "Doğrulanmadı")
        let documented = CapabilityEvidence(capability: .answerQuestions, support: .documented, source: "docs")
        XCTAssertEqual(IntegrationPresentation.supportLabel(.answerQuestions, evidence: [documented]), "Belgelenmiş · Canlı doğrulanmadı")
        let live = CapabilityEvidence(capability: .answerQuestions, support: .live, source: "receipt")
        XCTAssertEqual(IntegrationPresentation.supportLabel(.answerQuestions, evidence: [documented, live]), "Canlı doğrulandı")
    }

    func testProviderNamesKeepGitHubCopilotAndDevinIdentityClear() {
        XCTAssertEqual(SessionPresentation.providerLabel(.copilot), "GitHub Copilot")
        XCTAssertEqual(SessionPresentation.providerLabel(.windsurf), "Devin / Windsurf")
        XCTAssertEqual(Provider.windsurf.rawValue, "windsurf")
    }

    func testAntigravityApplicationRouteUsesVerifiedInstalledIDENotLegacyBundle() throws {
        let now = Date()
        var session = Session(id:"antigravity:fixture",turnID:"turn",source:.unknown,title:"QA",state:.completed,started:now,updated:now)
        session.provider = .antigravity
        session.runtime = RuntimeMetadata(id: "verified-ide", host: .antigravity)
        let route = SessionRouting.route(for:session)
        let installed = try XCTUnwrap(EditorFocusHost.installations.first { $0.name == "Antigravity IDE" })
        let verified = EditorFocusHost.verified(installed)
        XCTAssertEqual(installed.bundleID, "com.google.antigravity-ide")
        XCTAssertEqual(route.bundleID, verified ? installed.bundleID : "")
        XCTAssertFalse(route.exact)
        XCTAssertNil(route.url)
        XCTAssertEqual(route.label,"Uygulamayı aç")
        XCTAssertEqual(route.applicationURL, verified ? installed.application : nil)
        session.provider = .opencode
        session.runtime = RuntimeMetadata(id:"runtime",host:.antigravity)
        let hosted = SessionRouting.route(for:session)
        XCTAssertEqual(hosted.bundleID, EditorFocusHost.verified(installed) ? installed.bundleID : "")
        XCTAssertFalse(hosted.exact)
        session.runtime?.host = .unknown
        XCTAssertTrue(SessionRouting.route(for:session).bundleID.isEmpty)
        XCTAssertNil(SessionRouting.route(for:session).applicationURL)
    }
    func testNativeGitHubCopilotApplicationRouteRequiresExplicitHost() {
        let now = Date()
        var session = Session(id: "copilot:session", turnID: "turn", source: .unknown, title: "Chat", state: .completed, started: now, updated: now)
        session.provider = .copilot
        session.runtime = RuntimeMetadata(id: "runtime", host: .unknown)
        let unknown = SessionRouting.route(for: session)
        XCTAssertNil(unknown.applicationURL)
        XCTAssertTrue(unknown.bundleID.isEmpty)
        session.runtime?.host = .githubCopilotDesktop
        let native = SessionRouting.route(for: session)
        let installedURL = URL(fileURLWithPath: "/Applications/GitHub Copilot.app")
        let installed = Bundle(url: installedURL)?.bundleIdentifier == "com.github.githubapp"
        XCTAssertEqual(native.applicationURL, installed ? installedURL : nil)
        XCTAssertEqual(native.bundleID, installed ? "com.github.githubapp" : "")
        XCTAssertEqual(native.label, "Uygulamayı aç")
        XCTAssertFalse(native.exact)
        XCTAssertNil(native.url)
        XCTAssertEqual(SessionPresentation.hostLabel(session), "GitHub Copilot")
        XCTAssertNil(session.capabilities)
    }

    func testClaudeCannotGuessHostButVerifiedEditorStillRoutes() throws {
        let now = Date()
        var session = Session(id: "claude:fixture", turnID: "turn", source: .unknown, title: "QA", state: .completed, started: now, updated: now)
        session.provider = .claude
        for host in [RuntimeHost.unknown, .terminal, .vscode] {
            session.runtime = RuntimeMetadata(id: "hook:claude", host: host)
            let route = SessionRouting.route(for: session)
            XCTAssertFalse(route.exact); XCTAssertTrue(route.bundleID.isEmpty); XCTAssertNil(route.applicationURL)
            XCTAssertEqual(route.label, host == .terminal ? "Terminal uygulamasını seç" : "Uygulama doğrulanmadı")
        }
        session.verifiedEditorHost = "com.microsoft.VSCode"
        let editor = try XCTUnwrap(EditorFocusHost.installations.first { $0.bundleID == session.verifiedEditorHost })
        let route = SessionRouting.route(for: session)
        XCTAssertEqual(route.bundleID, EditorFocusHost.verified(editor) ? editor.bundleID : "")
        XCTAssertEqual(route.applicationURL, EditorFocusHost.verified(editor) ? editor.application : nil)
        XCTAssertFalse(route.exact); XCTAssertFalse(session.seen)
    }

}
