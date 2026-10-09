// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

typealias SSHTransportFactory = @MainActor () -> SSHTransportCoordinator

@MainActor final class SSHTransportSettings: ObservableObject {
    let repository: GitRepository
    @Published var enabled = false
    var makeCoordinator: SSHTransportFactory?
    var present: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    init(repository: GitRepository) { self.repository = repository }
    var available: Bool { makeCoordinator != nil || (try? SSHAgentRuntime.resolve())?.askpass != nil }
    func load(_ preferences: UserDefaults, key: String) { enabled = available && (preferences.object(forKey: key) as? Bool ?? true) }
    func save(_ preferences: UserDefaults, key: String) { preferences.set(enabled && available, forKey: key) }
    func capture() -> SSHTransportFactory? {
        guard enabled, available else { return nil }
        if let makeCoordinator { return makeCoordinator }
        let repository = repository, presenter = present
        return { let value = SSHTransportCoordinator(repository: repository); value.present = presenter; return value }
    }
}
struct SSHAutoloadToggle: View {
    @ObservedObject var settings: SSHTransportSettings
    var body: some View {
        Toggle("Auto-load SSH key", isOn: $settings.enabled).disabled(!settings.available)
            .help(settings.available ? "Load the selected remote's OpenSSH key into a private agent." : "SSH key loading is unavailable in this build.")
    }
}

/// One operation owns one private agent. Push prepares remotes sequentially;
/// Fetch All loads all configured identities into this agent before transport.
@MainActor final class SSHTransportCoordinator {
    let repository: GitRepository
    let identities: SSHIdentityAccessStore
    let runtime: () throws -> SSHAgentRuntime
    let temporaryRoot: URL
    var present: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    private(set) var prompt: SSHKeyPassphraseWindowController?
    private(set) var closed = false
    private var session: SSHAgentSession?
    private struct IdentityRevision: Hashable {
        let path: Data
        let device: Int64, inode: UInt64, size: Int64, seconds: Int64, nanoseconds: Int64
    }
    private var loaded: Set<IdentityRevision> = []
    private var active: OperationCancellation?
    private var promptID: UUID?
    private var watcher: Task<Void,Never>?
    init(repository: GitRepository, identities: SSHIdentityAccessStore = SSHIdentityAccessStore(), temporaryRoot: URL = FileManager.default.temporaryDirectory, runtime: @escaping () throws -> SSHAgentRuntime = { try SSHAgentRuntime.resolve() }) {
        self.repository = repository; self.identities = identities; self.temporaryRoot = temporaryRoot; self.runtime = runtime
    }
    var preparation: SSHTransportPreparation { { [self] names, token in try await prepare(names, cancellation: token) } }
    private func check(_ token: OperationCancellation) throws {
        if token.isCancelled || closed { throw OperationCancellationFailure.cancelled }
    }
    func prepare(_ names: [String], cancellation token: OperationCancellation) async throws -> SSHAgentSession? {
        try check(token); guard active == nil else { throw SSHAgentFailure.closed }
        active = token; defer { active = nil }
        let configured = try await repository.remoteNames(cancellation: token); try check(token)
        for name in names {
            guard configured.contains(where: { GitReferenceName.equal($0,name) }) else { continue }
            let settings = try await repository.remoteSettings(name: name, cancellation: token); try check(token)
            guard !settings.sshKeyFile.isEmpty else { continue }
            try await loadKey(path: settings.sshKeyFile, cancellation: token)
        }
        try check(token); return session
    }
    /// Clone/Submodule Add select a key before a remote config exists.
    func explicitPreparation(path: String) -> SSHTransportPreparation {
        { [self] _, token in try await prepareKey(path: path, cancellation: token) }
    }
    func prepareKey(path: String, cancellation token: OperationCancellation) async throws -> SSHAgentSession {
        try check(token); guard active == nil else { throw SSHAgentFailure.closed }
        active = token; defer { active = nil }
        try await loadKey(path: path, cancellation: token); try check(token)
        guard let session else { throw SSHAgentFailure.closed }; return session
    }
    private func loadKey(path: String, cancellation token: OperationCancellation) async throws {
        let access = try identities.acquire(path: path, requireSecurityScope: GitRuntime.isAppStoreBuild)
        defer { withExtendedLifetime(access) {} }
        var info = stat()
        guard stat(access.file.path, &info) == 0 else { throw SSHIdentityAccessFailure.file }
        let identity = IdentityRevision(path: Data(access.file.path.utf8), device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size, seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
        if loaded.contains(identity) { return }
        if session == nil {
            let tools = try runtime(), root = temporaryRoot
            let created = try await Task.detached { try SSHAgentSession(runtime: tools, temporaryRoot: root, cancellation: token) }.value
            do { try check(token); session = created } catch { created.close(); throw error }
        }
        guard let session else { throw SSHAgentFailure.closed }
        var response: String?, retry = false
        while true {
            try check(token)
            do {
                let file = access.file, capturedResponse = response
                try await Task.detached { try session.add(keys: [file], passphrase: capturedResponse, cancellation: token) }.value
                try check(token); loaded.insert(identity); break
            } catch {
                response = nil; try check(token)
                guard Self.needsPassphrase(error, encrypted: try Self.encryptedHeader(access.file)) else { throw error }
                response = try await ask(key: access.file.lastPathComponent, retry: retry, cancellation: token); retry = true
            }
        }
    }
    static func needsPassphrase(_ error: Error, encrypted: Bool) -> Bool {
        guard case SSHAgentFailure.command(let code, let details) = error, code == 1 else { return false }
        // Failed askpass can exit without diagnostics, including its one-use
        // retry refusal. Require a recognized encrypted header in that case.
        if details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return encrypted }
        return details.split(separator: "\n").contains { $0.hasSuffix(": incorrect passphrase") || $0.hasSuffix(": incorrect passphrase supplied to decrypt private key") }
    }
    static func encryptedHeader(_ url: URL) throws -> Bool {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        // Inspect only a bounded header. Never log/persist the encoded key bytes.
        guard let bytes = try reader.read(upToCount: 256), let decodedText = String(data: bytes, encoding: .utf8) else { return false }
        let text = decodedText.replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") { return true }
        if text.hasPrefix("-----BEGIN RSA PRIVATE KEY-----") || text.hasPrefix("-----BEGIN EC PRIVATE KEY-----") || text.hasPrefix("-----BEGIN DSA PRIVATE KEY-----") { return text.contains("Proc-Type: 4,ENCRYPTED") }
        guard text.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n") else { return false }
        let base64 = text.split(separator: "\n").dropFirst().prefix(while: { !$0.hasPrefix("-----") }).joined()
        let complete = String(base64.prefix(base64.count - base64.count % 4))
        guard let decoded = Data(base64Encoded: complete), decoded.starts(with: Data("openssh-key-v1\0".utf8)), decoded.count >= 19 else { return false }
        let length = decoded[15..<19].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length < 100, decoded.count >= 19 + length,
              let cipher = String(data: decoded[19..<(19+length)], encoding: .utf8) else { return false }
        return cipher != "none"
    }
    private func ask(key: String, retry: Bool, cancellation token: OperationCancellation) async throws -> String {
        try check(token)
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID(); promptID = id
            let controller = SSHKeyPassphraseWindowController(keyName: key, retry: retry) { [weak self] value in
                let live = self?.promptID == id && self?.closed == false
                if self?.promptID == id { self?.watcher?.cancel(); self?.watcher = nil; self?.promptID = nil; self?.prompt = nil }
                guard live, !token.isCancelled, let value else { token.cancel(); continuation.resume(throwing: OperationCancellationFailure.cancelled); return }
                continuation.resume(returning: value)
            }
            prompt = controller
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    if token.isCancelled { if self?.promptID == id { self?.prompt?.abort() }; return }
                    do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
                }
            }
            if !present(controller) { controller.abort() }
        }
    }
    func close() {
        guard !closed else { return }; closed = true; active?.cancel(); prompt?.abort(); watcher?.cancel(); watcher = nil
        session?.close(); session = nil; loaded.removeAll()
    }
}
