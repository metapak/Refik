import Foundation
import CoreFoundation

public enum AntigravityHookPhase: String, Codable {
    case preInvocation = "PreInvocation", postInvocation = "PostInvocation"
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", stop = "Stop"
}
public struct AntigravityHookQuestion: Codable, Equatable {
    public var text: String
    public var options: [String]
    public var multiSelect: Bool
    public var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 4000 &&
        (2...8).contains(options.count) && Set(options).count == options.count &&
        options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 4000 }
    }
}
// No provider turn is inferred. The app receiver binds these observations to
// its local turn and exact step generation, including reuse tombstones.
public struct AntigravityHookObservation: Codable, Equatable {
    public var phase: AntigravityHookPhase
    public var conversationID: String
    public var stepIndex: Int?
    public var invocationNum: Int?
    public var initialNumSteps: Int?
    public var executionNum: Int?
    public var toolName: String?
    public var questions: [AntigravityHookQuestion]?
    public var fullyIdle: Bool?
    public var terminationReason: String?
    public var hasError: Bool
    public var isValid: Bool {
        !conversationID.isEmpty && conversationID.count <= 160 &&
        [stepIndex, invocationNum, initialNumSteps, executionNum].allSatisfy { $0 == nil || (0...1_000_000_000).contains($0!) } &&
        (toolName == nil || Self.tools.contains(toolName!)) &&
        (terminationReason == nil || Self.reasons.contains(terminationReason!)) &&
        (questions == nil || toolName == "ask_question" && (1...4).contains(questions!.count) && questions!.allSatisfy(\.isValid))
    }
    static let tools: Set<String> = ["ask_question", "run_command", "view_file", "list_dir", "grep_search", "find_by_name"]
    static let reasons: Set<String> = ["model_stop", "NO_TOOL_CALL", "max_steps_exceeded", "error", "cancelled", "interrupted", "user_cancelled"]
    public static func parse(_ object: [String: Any], phase rawPhase: String) -> Self? {
        guard let phase = AntigravityHookPhase(rawValue: rawPhase), let conversation = object["conversationId"] as? String else { return nil }
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded(.towardZero) == n.doubleValue,
                  (0...1_000_000_000).contains(n.doubleValue) else { return nil }
            return n.intValue
        }
        func boolean(_ value: Any?) -> Bool? {
            guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return n.boolValue
        }
        let tool = object["toolCall"] as? [String: Any]
        let name = (tool?["name"] as? String).flatMap { tools.contains($0) ? $0 : nil }
        // Current native ask_question calls can serialize this array as JSON text.
        // Decode only the exact tool field, then apply the same strict schema.
        func questionArray(_ value: Any?) -> [[String: Any]]? {
            if let array = value as? [[String: Any]] { return array }
            guard let text = value as? String, text.utf8.count <= 200_000,
                  let data = text.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data),
                  let array = decoded as? [[String: Any]] else { return nil }
            return array
        }
        var questions: [AntigravityHookQuestion]?
        if name == "ask_question", let args = tool?["args"] as? [String: Any],
           let raw = questionArray(args["questions"]), (1...4).contains(raw.count) {
            let parsed = raw.compactMap { q -> AntigravityHookQuestion? in
                guard let text = q["question"] as? String, let options = q["options"] as? [String],
                      let multiple = boolean(q["is_multi_select"]) else { return nil }
                let question = AntigravityHookQuestion(text: text, options: options, multiSelect: multiple)
                return question.isValid ? question : nil
            }
            if parsed.count == raw.count { questions = parsed }
        }
        let reason = (object["terminationReason"] as? String).flatMap { reasons.contains($0) ? $0 : nil }
        let result = Self(phase: phase, conversationID: conversation, stepIndex: integer(object["stepIdx"]),
                          invocationNum: integer(object["invocationNum"]), initialNumSteps: integer(object["initialNumSteps"]),
                          executionNum: integer(object["executionNum"]), toolName: name, questions: questions,
                          fullyIdle: boolean(object["fullyIdle"]), terminationReason: reason,
                          hasError: (object["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        return result.isValid ? result : nil
    }
}
