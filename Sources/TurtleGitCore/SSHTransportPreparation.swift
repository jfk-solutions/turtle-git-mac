// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Native key/grant/response coordination runs outside the repository actor.
/// Fetch All supplies its complete remote list once; Push supplies one remote
/// immediately before each transport. Returning nil leaves Git's environment
/// unchanged. Keep a shared session in the coordinator to accumulate identities.
public typealias SSHTransportPreparation = @Sendable ([String], OperationCancellation) async throws -> SSHAgentSession?

extension SSHAgentSession {
    var transportEnvironment: [String: String] {
        // Do not leave a login-agent PID paired with our private socket. OpenSSH
        // authenticates through the socket; the inherited PID is unrelated.
        environment.merging(["SSH_AGENT_PID": ""]) { _, value in value }
    }
}

extension GitRepository {
    func prepareSSHTransport(_ remotes: [String], cancellation: OperationCancellation, preparation: SSHTransportPreparation?) async throws -> SSHAgentSession? {
        try cancellation.check()
        guard let preparation else { return nil }
        let session = try await preparation(remotes, cancellation)
        // A native response can arrive after cancellation. Do not start Git.
        try cancellation.check()
        return session
    }
}
