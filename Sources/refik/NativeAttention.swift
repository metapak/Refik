import Foundation
import CryptoKit
import SQLite3
import Darwin

// Version-specific local metadata reconciliation. This is native attention
// dismissal, not evidence that a window or result was physically viewed.
struct NativeAttentionContext: Equatable {
    let identity: String
    let host: String
    let authGeneration: Date
    let expires: Date
    var authority: String {
        // Only an opaque digest crosses into persisted provider disposition.
        let value = "\(identity)|\(host)|\(authGeneration.timeIntervalSince1970)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeAttentionSnapshot {
    let context: NativeAttentionContext
    let unread: Set<String>
    var observedAt: Date? = nil
}

struct ProviderAttentionObservation {
    let completion: NativeCompletion
    let requestsAttention: Bool
    let authority: String
    let observedAt: Date
}

enum NativeAttentionMirror {
    static func observations(_ snapshot: NativeAttentionSnapshot?, completions: [NativeCompletion], at now: Date) -> [ProviderAttentionObservation] {
        guard let snapshot, snapshot.context.expires > now, let sampled = snapshot.observedAt,
              sampled <= now, now.timeIntervalSince(sampled) < 3 else { return [] }
        return completions.filter { $0.completed < sampled }.map {
            ProviderAttentionObservation(completion: $0, requestsAttention: snapshot.unread.contains($0.thread),
                                         authority: snapshot.context.authority, observedAt: sampled)
        }
    }
}

struct NativeCompletion: Equatable {
    let thread: String
    let turn: String
    let completed: Date
    let proofGeneration: String?
    // The registry generation stays immutable when a whole-second helper receipt
    // is corroborated by the exact native start/terminal pair.
    let registryStarted: Date?
    let nativeStarted: Date?
    let nativeCompleted: Date?
    init(thread: String, turn: String, completed: Date, proofGeneration: String? = nil,
         registryStarted: Date? = nil, nativeStarted: Date? = nil, nativeCompleted: Date? = nil) {
        self.thread = thread; self.turn = turn; self.completed = completed; self.proofGeneration = proofGeneration
        self.registryStarted = registryStarted; self.nativeStarted = nativeStarted; self.nativeCompleted = nativeCompleted
    }
    func matches(_ proof: RolloutCompletionProof) -> Bool {
        if let nativeStarted, let nativeCompleted, registryStarted != nil {
            return thread == proof.completion.thread && turn == proof.completion.turn &&
                proofGeneration == proof.completion.proofGeneration && nativeStarted == proof.started &&
                nativeCompleted == proof.completion.completed
        }
        return self == proof.completion
    }
    init(_ session: Session) {
        self.init(thread: session.id, turn: session.turnID, completed: session.updated)
    }
}

struct NativeAttentionCorrelation {
    private var context: NativeAttentionContext?
    private var lastObservation: Date?
    private var armed: [String: NativeCompletion] = [:]
    mutating func reset() { context = nil; lastObservation = nil; armed.removeAll() }
    mutating func observe(_ snapshot: NativeAttentionSnapshot?, completions: [NativeCompletion], at now: Date) -> [NativeCompletion] {
        guard let snapshot, snapshot.context.expires > now else { reset(); return [] }
        if context != snapshot.context || lastObservation.map({ now.timeIntervalSince($0) > 8 || now < $0 }) == true {
            armed.removeAll()
        }
        context = snapshot.context; lastObservation = now
        let current = Dictionary(completions.map { ($0.thread, $0) }, uniquingKeysWith: { _, latest in latest })
        armed = armed.filter { current[$0.key] == $0.value }
        var dismissed: [NativeCompletion] = []
        for completion in completions where completion.completed < now {
            if snapshot.unread.contains(completion.thread) {
                armed[completion.thread] = completion
            } else if armed[completion.thread] == completion {
                dismissed.append(completion); armed.removeValue(forKey: completion.thread)
            }
        }
        return dismissed
    }
}

// A conservative TOML capability gate, not a replacement configuration loader.
// Decode assignment/table keys (including quoted/dotted keys and TOML escapes)
// before inspecting relevant options. Unsupported compound/multiline syntax
// fails closed so it cannot hide a host or credential-store override.
enum NativeAttentionConfiguration {
    private static let store = "cli_auth_credentials_store"
    private static let host = "websocket_url"
    private static func whitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" || c == "\r" }
    private static func quoted(_ chars: [Unicode.Scalar], at index: inout Int) -> String? {
        guard index < chars.count, chars[index] == "\"" || chars[index] == "'" else { return nil }
        let quote = chars[index]; index += 1
        // Multiline TOML strings require a separate adapter; never infer through them.
        if index + 1 < chars.count, chars[index] == quote, chars[index + 1] == quote { return nil }
        var output = String.UnicodeScalarView()
        while index < chars.count {
            let c = chars[index]; index += 1
            if c == quote { return String(output) }
            guard c.value >= 0x20 || c == "\t" else { return nil }
            if c != "\\" || quote == "'" { output.append(c); continue }
            guard index < chars.count else { return nil }
            let escape = chars[index]; index += 1
            switch escape {
            case "b": output.append("\u{08}")
            case "t": output.append("\t")
            case "n": output.append("\n")
            case "f": output.append("\u{0C}")
            case "r": output.append("\r")
            case "\"", "\\": output.append(escape)
            case "u", "U":
                let count = escape == "u" ? 4 : 8
                guard index + count <= chars.count else { return nil }
                let digits = chars[index..<(index + count)]
                guard digits.allSatisfy({ (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value) }),
                      let value = UInt32(String(String.UnicodeScalarView(digits)), radix: 16), let scalar = Unicode.Scalar(value) else { return nil }
                output.append(scalar); index += count
            default: return nil
            }
        }
        return nil
    }
    private static func keys(_ text: String) -> [String]? {
        let chars = Array(text.unicodeScalars); var index = 0, result: [String] = []
        while true {
            while index < chars.count && whitespace(chars[index]) { index += 1 }
            guard index < chars.count else { return nil }
            if chars[index] == "\"" || chars[index] == "'" {
                guard let key = quoted(chars, at: &index) else { return nil }; result.append(key)
            } else {
                let start = index
                while index < chars.count {
                    let value = chars[index].value
                    guard (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) || chars[index] == "_" || chars[index] == "-" else { break }
                    index += 1
                }
                guard start < index else { return nil }
                result.append(String(String.UnicodeScalarView(chars[start..<index])))
            }
            while index < chars.count && whitespace(chars[index]) { index += 1 }
            if index == chars.count { return result }
            guard chars[index] == "." else { return nil }; index += 1
        }
    }
    static func supportsDefaultHost(_ config: String) -> Bool {
        for rawLine in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let chars = Array(rawLine.unicodeScalars); var index = 0, end = chars.count, assignment: Int?
            while index < chars.count {
                let c = chars[index]
                if c == "#" { end = index; break }
                if c == "\"" || c == "'" {
                    guard quoted(chars, at: &index) != nil else { return false }; continue
                }
                if c == "{" || c == "}" { return false } // inline tables can contain relevant nested keys
                if c == "=" && assignment == nil { assignment = index }
                index += 1
            }
            let line = String(String.UnicodeScalarView(chars[..<end])).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let assignment else {
                // Parse table boundaries rather than treating section text as assignments.
                let array = line.hasPrefix("[[")
                let width = array ? 2 : 1
                guard line.hasPrefix("["), line.hasSuffix(array ? "]]" : "]"), line.count > width * 2,
                      let table = keys(String(line.dropFirst(width).dropLast(width))),
                      !table.contains(store), !table.contains(host) else { return false }
                continue
            }
            guard assignment < end,
                  let path = keys(String(String.UnicodeScalarView(chars[..<assignment]))) else { return false }
            if path.contains(host) { return false }
            if path.contains(store) {
                guard path.last == store else { return false }
                let value = Array(chars[(assignment + 1)..<end]); var position = 0
                while position < value.count && whitespace(value[position]) { position += 1 }
                guard quoted(value, at: &position) == "file" else { return false }
                while position < value.count && whitespace(value[position]) { position += 1 }
                guard position == value.count else { return false }
            }
        }
        return true
    }
}

final class NativeAttentionReader {
    private let root: URL
    private var authStamp: Date?
    private var cachedContext: NativeAttentionContext?
    init(root: URL) { self.root = root }
    private struct Auth: Decodable {
        let auth_mode: String?
        let tokens: Tokens?
        struct Tokens: Decodable { let access_token: String; let account_id: String? }
    }
    private struct Claims: Decodable {
        let exp: Double
        let principal: Principal
        enum CodingKeys: String, CodingKey { case exp; case principal = "https://api.openai.com/auth" }
        struct Principal: Decodable {
            let chatgpt_account_id: String?
            let account_id: String?
            let user_id: String?
            let chatgpt_user_id: String?
        }
    }
    private struct Global: Decodable {
        let readState: ReadState
        enum CodingKeys: String, CodingKey { case readState = "electron-thread-read-state-v1" }
    }
    private struct ReadState: Decodable {
        let version: Int
        let unreadByIdentity: [String: [String: [String]]]
    }
    private static func digest(_ value: [Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    // Tokens exist only in this decode scope. Neither credentials nor raw IDs
    // are retained, persisted, copied, logged, or used for network requests.
    static func context(authData: Data, generation: Date, now: Date) -> NativeAttentionContext? {
        guard let auth = try? JSONDecoder().decode(Auth.self, from: authData),
              auth.auth_mode == "chatgpt", let tokens = auth.tokens else { return nil }
        let parts = tokens.access_token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var body = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let data = Data(base64Encoded: body), let claims = try? JSONDecoder().decode(Claims.self, from: data),
              let account = claims.principal.chatgpt_account_id ?? claims.principal.account_id,
              let user = claims.principal.user_id ?? claims.principal.chatgpt_user_id,
              !account.isEmpty, !user.isEmpty, tokens.account_id == account,
              claims.exp.isFinite, claims.exp > now.timeIntervalSince1970,
              let identity = digest(["chatgpt", account, user]),
              let host = digest(["local", "local", NSNull()]) else { return nil }
        return NativeAttentionContext(identity: identity, host: "local:" + host, authGeneration: generation,
                                      expires: Date(timeIntervalSince1970: claims.exp))
    }
    func snapshot(now: Date) -> NativeAttentionSnapshot? {
        // This adapter supports the documented file-backed default local host.
        // Explicit other stores/host URLs require a separate proven adapter.
        let configURL = root.appendingPathComponent("config.toml")
        if let config = try? String(contentsOf: configURL, encoding: .utf8) {
            guard NativeAttentionConfiguration.supportsDefaultHost(config) else { invalidate(); return nil }
        } else if FileManager.default.fileExists(atPath: configURL.path) {
            invalidate(); return nil
        }
        let authURL = root.appendingPathComponent("auth.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: authURL.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let stamp = attrs[.modificationDate] as? Date,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 131_072 else {
            invalidate(); return nil
        }
        if authStamp != stamp {
            cachedContext = (try? Data(contentsOf: authURL)).flatMap { Self.context(authData: $0, generation: stamp, now: now) }
            authStamp = stamp
        }
        guard let context = cachedContext, context.expires > now else { invalidate(); return nil }
        let stateURL = root.appendingPathComponent(".codex-global-state.json")
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .fileResourceIdentifierKey, .isRegularFileKey]
        guard let values = try? stateURL.resourceValues(forKeys: keys), values.isRegularFile == true,
              let stamp = values.contentModificationDate, (values.fileSize ?? Int.max) <= 16_777_216,
              let data = try? Data(contentsOf: stateURL), data.count == values.fileSize,
              let state = try? JSONDecoder().decode(Global.self, from: data).readState,
              let after = try? stateURL.resourceValues(forKeys: keys), after.isRegularFile == true,
              after.contentModificationDate == stamp, after.fileSize == values.fileSize,
              let beforeID = values.fileResourceIdentifier as? NSObject,
              let afterID = after.fileResourceIdentifier as? NSObject, beforeID.isEqual(afterID) else {
            invalidate(); return nil
        }
        guard state.version == 1,
              let unread = state.unreadByIdentity[context.identity]?[context.host],
              unread.count <= 10_000, Set(unread).count == unread.count, unread.allSatisfy({ !$0.isEmpty }) else {
            invalidate(); return nil
        }
        return NativeAttentionSnapshot(context: context, unread: Set(unread), observedAt: now)
    }
    private func invalidate() { authStamp = nil; cachedContext = nil }

    // SQL proves the latest root Desktop turn, or vetoes a bounded watcher
    // completion proof when its index contains an equal/newer conflicting turn.
    // No conversation columns or provider credentials are selected.
    private static func matchesRegistry(_ proof: RolloutCompletionProof, session: Session) -> Bool {
        if proof.completion.completed == session.updated && proof.started == session.started { return true }
        // A whole-second hook/recovery start can survive until a precise
        // rollout completion replaces the runtime. Bind that existing mixed
        // generation only to the exact root rollout identity and completion.
        if session.fidelity == .derived, session.runtime?.host == .codexDesktop,
           session.runtime?.id == "codex-rollout:desktop:" + session.id,
           let registryRoot = ProjectIdentity.canonical(session.projectPath),
           let nativeRoot = ProjectIdentity.canonical(proof.cwd), registryRoot == nativeRoot,
           session.started.timeIntervalSince1970 == floor(session.started.timeIntervalSince1970),
           floor(proof.started.timeIntervalSince1970) == session.started.timeIntervalSince1970,
           proof.completion.completed == session.updated { return true }
        // Only the known official helper encoding can lose fractions. This is
        // not a time window: both whole-second boundaries must match, under the
        // independently validated exact Desktop rollout/root/turn proof.
        guard session.fidelity == .official, session.runtime?.host == .codexDesktop,
              let registryRoot = ProjectIdentity.canonical(session.projectPath),
              let nativeRoot = ProjectIdentity.canonical(proof.cwd), registryRoot == nativeRoot,
              session.runtime?.id.hasPrefix("hook:codex:") == true,
              session.started.timeIntervalSince1970 == floor(session.started.timeIntervalSince1970),
              session.updated.timeIntervalSince1970 == floor(session.updated.timeIntervalSince1970) else { return false }
        return floor(proof.started.timeIntervalSince1970) == session.started.timeIntervalSince1970 &&
            floor(proof.completion.completed.timeIntervalSince1970) == session.updated.timeIntervalSince1970
    }
    func verifiedCompletions(_ sessions: [Session], rolloutProofs: [RolloutCompletionProof] = []) -> [NativeCompletion] {
        let candidates = sessions.filter { $0.supportsDesktopNativeAttention && $0.state == .completed && !$0.seen }
        guard !candidates.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("thread_history_1.sqlite").path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)
        var attach: OpaquePointer?
        guard sqlite3_prepare_v2(db, "ATTACH DATABASE ? AS state", -1, &attach, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(attach) }
        let uri = "file:" + root.appendingPathComponent("state_5.sqlite").path + "?mode=ro"
        _ = uri.withCString { sqlite3_bind_text(attach, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(attach) == SQLITE_DONE else { return [] }
        let placeholders = candidates.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT t.thread_id,t.turn_id,t.status,t.started_at,t.completed_at,s.source,s.archived,s.agent_path,s.cwd
        FROM thread_turns t JOIN state.threads s ON s.id=t.thread_id
        WHERE t.thread_id IN (\(placeholders))
        AND NOT EXISTS (SELECT 1 FROM thread_turns newer WHERE newer.thread_id=t.thread_id
          AND (newer.started_at>t.started_at OR newer.rollout_ordinal>t.rollout_ordinal))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (index, session) in candidates.enumerated() {
            _ = session.id.withCString { sqlite3_bind_text(stmt, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        }
        func field(_ column: Int32) -> String { sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "" }
        var matches: [String: NativeCompletion] = [:]
        var encountered = Set<String>()
        var step = sqlite3_step(stmt)
        while step == SQLITE_ROW {
            let thread = field(0), turn = field(1)
            // Multiple equally latest indexed rows are ambiguous.
            guard encountered.insert(thread).inserted else { return [] }
            if let session = candidates.first(where: { $0.id == thread }),
               field(5) == "vscode", sqlite3_column_int(stmt, 6) == 0, field(7).isEmpty {
                if turn == session.turnID, field(2) == "completed", sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    matches[thread] = NativeCompletion(session)
                } else if rolloutProofs.filter({ $0.completion.thread == thread }).count == 1,
                          let proof = rolloutProofs.first(where: {
                    $0.completion.thread == thread && $0.completion.turn == session.turnID &&
                    Self.matchesRegistry($0, session: session) &&
                    $0.cwd == URL(fileURLWithPath: field(8)).standardizedFileURL.path
                }), turn != session.turnID,
                    Double(sqlite3_column_int64(stmt, 3)) < floor(proof.started.timeIntervalSince1970) {
                    matches[thread] = proof.completion.completed == session.updated && proof.started == session.started
                        ? proof.completion : NativeCompletion(thread: thread, turn: session.turnID, completed: session.updated,
                            proofGeneration: proof.completion.proofGeneration, registryStarted: session.started,
                            nativeStarted: proof.started, nativeCompleted: proof.completion.completed)
                }
            }
            step = sqlite3_step(stmt)
        }
        guard step == SQLITE_DONE else { return [] }
        return candidates.compactMap { matches[$0.id] }
    }
}
