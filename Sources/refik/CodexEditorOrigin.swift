import Foundation
import Darwin

// Metadata provenance is deliberately separate from signed hook-peer proof.
enum EditorOriginEvidence: String, Codable { case codexVSCodeRollout }
enum EditorFocusBlockReason: String, Codable { case codexAsyncQuestionUnresolved, codexBlockingQuestionUnresolved }

struct CodexEditorOriginProof {
    let sessionID: String
    let projectPath: String
    init?(metadata: Data, file: URL, root: URL) {
        let path = file.standardizedFileURL.path
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        var info = stat()
        guard path == file.resolvingSymlinksInPath().path,
              path.hasPrefix(canonicalRoot + "/"), lstat(path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any],
              payload["source"] as? String == "vscode", payload["originator"] as? String == "codex_vscode",
              let id = payload["id"] as? String, UUID(uuidString: id) != nil,
              file.lastPathComponent.hasSuffix("-" + id + ".jsonl"),
              payload["subagent"] == nil, payload["parent_thread_id"] == nil,
              payload["agent_path"] == nil || payload["agent_path"] as? String == "",
              let project = ProjectIdentity.canonical(payload["cwd"] as? String) else { return nil }
        sessionID = id; projectPath = project
    }
}

extension Session {
    var hasUnresolvedInteraction: Bool {
        !pending.isEmpty || (requestSnapshots ?? []).contains { [.pending, .submitting, .submitted, .deliveryUnknown, .accepted].contains($0.lifecycle) }
    }
    var focusEditorHost: String? {
        guard editorFocusBlockReason == nil, !hasUnresolvedInteraction else { return nil }
        if let verifiedEditorHost { return verifiedEditorHost }
        guard editorOriginEvidence == .codexVSCodeRollout, provider == .codex,
              runtime?.host == .vscode, UUID(uuidString: id) != nil,
              projectPath != nil else { return nil }
        return "com.microsoft.VSCode"
    }
}

