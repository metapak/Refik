import Foundation

// Credentials are deliberately neither Codable nor persisted. Supply them from
// the user's configured local server credentials, never provider API keys.
struct OpenCodeConnectionConfiguration {
    let serverURL: URL
    let projectDirectory: String
    var host: RuntimeHost = .terminal
    var username: String = "opencode"
    var password: String? = nil
    var timeout: TimeInterval = 10

    func validate() throws {
        guard ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(serverURL.host?.lowercased() ?? ""),
              serverURL.user == nil, serverURL.password == nil,
              serverURL.query == nil, serverURL.fragment == nil,
              serverURL.path.isEmpty || serverURL.path == "/",
              !projectDirectory.isEmpty, timeout > 0, timeout <= 30 else {
            throw OpenCodeConnectionError.invalidConfiguration
        }
    }
}

enum OpenCodeConnectionError: Error, Equatable {
    case invalidConfiguration, disconnected, unsupportedAPI, unauthorized
    case http(Int), malformedResponse, staleRequest, duplicateSubmission, unconfirmedResponse
}

struct OpenCodeConnectionSnapshot {
    let runtimeID: String
    let version: String?
    let connected: Bool
    let channelID: String?
    let pending: [PendingRequestSnapshot]
    let canSelectSession: Bool
}

// The public SDK v1.18.34 documents these response shapes. Every runtime must
// advertise the corresponding actual paths in its /doc before they are used.
struct OpenCodeWireQuestion: Decodable {
    struct Item: Decodable {
        struct Option: Decodable { let label: String; let description: String? }
        let question: String
        let header: String?
        let options: [Option]
        let multiple: Bool?
        let custom: Bool?
    }
    struct Tool: Decodable { let messageID: String; let callID: String }
    let id: String
    let sessionID: String
    let questions: [Item]
    let tool: Tool?
}
struct OpenCodeWirePermission: Decodable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let tool: OpenCodeWireQuestion.Tool?
}
struct OpenCodeWireSession: Decodable {
    let id: String
    let directory: String
    let title: String
}
