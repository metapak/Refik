import Foundation
import CoreFoundation

public enum VSCodeHookPhase: String, Codable {
    case sessionStart = "SessionStart", userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", preCompact = "PreCompact"
    case subagentStart = "SubagentStart", subagentStop = "SubagentStop", stop = "Stop", sessionEnd = "SessionEnd"
}
public struct VSCodeHookOption: Codable, Equatable {
    public var label: String
    public var description: String
}
public struct VSCodeHookQuestion: Codable, Equatable {
    public var text: String
    public var header: String
    public var options: [VSCodeHookOption]
    public var multiSelect: Bool
    public var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000 && header.count <= 200 &&
        (2...8).contains(options.count) && Set(options.map(\.label)).count == options.count &&
        options.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.label.count <= 4000 && $0.description.count <= 4000 }
    }
}
public struct VSCodeHookObservation: Codable, Equatable {
    public var phase: VSCodeHookPhase
    public var sessionID: String
    public var nativeToolID: String?
    public var toolName: String?
    public var questions: [VSCodeHookQuestion]?
    public var isValid: Bool {
        !sessionID.isEmpty && sessionID.count <= 160 &&
        (nativeToolID == nil || !nativeToolID!.isEmpty && nativeToolID!.count <= 160) &&
        (toolName == nil || toolName == "vscode_askQuestions") &&
        (questions == nil || toolName == "vscode_askQuestions" && nativeToolID != nil && (1...4).contains(questions!.count) && questions!.allSatisfy(\.isValid))
    }
    public static func parse(_ object: [String: Any], phase rawPhase: String) -> Self? {
        guard let phase = VSCodeHookPhase(rawValue: rawPhase), let session = object["session_id"] as? String else { return nil }
        let toolName = object["tool_name"] as? String == "vscode_askQuestions" ? "vscode_askQuestions" : nil
        let nativeID = (object["tool_use_id"] as? String).flatMap { !$0.isEmpty && $0.count <= 160 ? $0 : nil }
        var questions: [VSCodeHookQuestion]?
        if toolName != nil, nativeID != nil, let input = object["tool_input"] as? [String: Any],
           let raw = input["questions"] as? [[String: Any]], (1...4).contains(raw.count) {
            let parsed = raw.compactMap { q -> VSCodeHookQuestion? in
                guard let text = q["question"] as? String, let header = q["header"] as? String,
                      let options = q["options"] as? [[String: Any]] else { return nil }
                var multiSelect = false
                if let value = q["multiSelect"] {
                    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
                    multiSelect = number.boolValue
                }
                let parsedOptions = options.compactMap { option -> VSCodeHookOption? in
                    guard let label = option["label"] as? String, let description = option["description"] as? String else { return nil }
                    return VSCodeHookOption(label: label, description: description)
                }
                guard parsedOptions.count == options.count else { return nil }
                let question = VSCodeHookQuestion(text: text, header: header, options: parsedOptions, multiSelect: multiSelect)
                return question.isValid ? question : nil
            }
            if parsed.count == raw.count { questions = parsed }
        }
        let result = Self(phase: phase, sessionID: session, nativeToolID: nativeID, toolName: toolName, questions: questions)
        return result.isValid ? result : nil
    }
}
