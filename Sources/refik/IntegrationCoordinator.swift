import Foundation

struct InteractionSubmissionResult {
    let lifecycle: RequestLifecycle?
    let errorMessage: String?
}
struct ProviderIntegrationStatus: Identifiable {
    var id: String { provider.rawValue }
    let provider: Provider
    var installed: Bool
    var version: String?
    var host: RuntimeHost
    var capabilities: [CapabilityEvidence]
    var message: String
}

@MainActor final class IntegrationCoordinator {
    private struct Channel {
        let provider: Provider
        let runtimeID: String
        let transport: InteractionResponseTransport
        let capabilities: RuntimeCapabilities
        let runtime: RuntimeMetadata?
        let requestIdentity: RequestIdentity?
    }
    private var channels: [String: Channel] = [:]
    func register(_ capabilities: RuntimeCapabilities, transport: InteractionResponseTransport, runtime: RuntimeMetadata? = nil, requestIdentity: RequestIdentity? = nil) {
        guard let channel = capabilities.responseChannelID, !channel.isEmpty else { return }
        if let requestIdentity {
            guard requestIdentity.provider == capabilities.provider, requestIdentity.runtimeID == capabilities.runtimeID else { return }
            channels = channels.filter { $0.value.requestIdentity != requestIdentity }
        } else {
            channels = channels.filter { $0.key == channel || $0.value.provider != capabilities.provider || $0.value.runtimeID != capabilities.runtimeID || $0.value.requestIdentity != nil }
        }
        channels[channel] = Channel(provider: capabilities.provider, runtimeID: capabilities.runtimeID, transport: transport, capabilities: capabilities, runtime: runtime, requestIdentity: requestIdentity)
    }
    func transport(for session: Session, request: PendingRequestSnapshot) -> (InteractionResponseTransport, String)? {
        guard request.identity.provider == session.provider, request.identity.sessionID == session.id,
              request.identity.turnID == session.turnID || request.turnScope == .request || request.turnScope == .hookInvocation,
              session.pending.contains(request.id), request.isValid, request.lifecycle == .pending,
              session.orderedRequests.contains(where: { $0.identity == request.identity && $0.lifecycle == .pending }) else { return nil }
        // Display metadata from another observer cannot replace a live lease.
        for (id, channel) in channels where channel.provider == request.identity.provider && channel.runtimeID == request.identity.runtimeID {
            if let identity = channel.requestIdentity {
                guard identity == request.identity else { continue }
                if let hook = channel.transport as? HookBridge, !hook.hasLiveChannel(id, identity: identity) { continue }
            } else if channel.provider == .claude || channel.transport is HookBridge { continue }
            let runtime = channel.runtime ?? (session.runtime?.id == channel.runtimeID ? session.runtime : nil)
            if channel.capabilities.hasLive(request.kind == .question ? .answerQuestions : .respondToPermissions, runtime: runtime) {
                return (channel.transport, id)
            }
        }
        return nil
    }
    func hasLiveChannel(provider: Provider, runtimeID: String, version: String, capability: RuntimeCapability) -> Bool {
        channels.values.contains { channel in
            channel.provider == provider && channel.runtimeID == runtimeID && channel.capabilities.version == version &&
            channel.capabilities.hasLive(capability, runtime: channel.runtime)
        }
    }
    func remove(runtimeID: String) { channels = channels.filter { $0.value.runtimeID != runtimeID } }
    func remove(channelID: String) { channels.removeValue(forKey: channelID) }
    func removeAll() { channels.removeAll() }
}

extension Session {
    mutating func redactInteractionContent() {
        capabilities?.responseChannelID = nil
        guard var requests = requestSnapshots else { return }
        for index in requests.indices { requests[index].question = nil; requests[index].permission = nil }
        requestSnapshots = requests
    }
}
