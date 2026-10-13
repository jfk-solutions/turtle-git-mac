import AppKit
import Security
import TurtleGitCore

private actor FixtureSSHAuthentication: SSHAuthenticationStore {
    var secrets: [String: String] = [:]
    var names: [String: String] = [:]
    var saves = 0
    func read(identity: String) -> String? { secrets[identity] }
    func save(identity: String, name: String, passphrase: String) { secrets[identity] = passphrase; names[identity] = name; saves += 1 }
    func entries() -> [SSHAuthenticationEntry] { names.map { SSHAuthenticationEntry(id: $0.key, name: $0.value) } }
    func remove(identity: String) { secrets.removeValue(forKey: identity); names.removeValue(forKey: identity) }
    func count() -> Int { saves }
}
private final class SSHAuthenticationBookmarks: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
private actor HeldSSHAuthentication: SSHAuthenticationStore {
    private var reply: CheckedContinuation<String?, Never>?
    func read(identity: String) async -> String? { await withCheckedContinuation { reply = $0 } }
    func save(identity: String, name: String, passphrase: String) { assertionFailure("Cancelled read saved authentication") }
    func entries() -> [SSHAuthenticationEntry] { [] }
    func remove(identity: String) {}
    func pending() -> Bool { reply != nil }
    func release() { let value = reply; reply = nil; value?.resume(returning: "native fixture phrase") }
}
@main struct SSHAuthenticationVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out waiting for owned operation")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run(); print("PASS saved SSH authentication, retry, content identity, removal and cancellation") }
        catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/SSHAskpass/TurtleGitSSHAskpass")
        let key = root.appendingPathComponent("encrypted-key")
        var request = SSHKeyGenerationRequest(destination: key); request.passphrase = "native fixture phrase"; request.comment = "saved-auth-fixture"
        _ = try SSHKeyGeneration.generate(request, executable: URL(fileURLWithPath: "/usr/bin/ssh-keygen"), askpass: helper, cancellation: OperationCancellation())
        let identities = SSHIdentityAccessStore(storageURL: root.appendingPathComponent("grants.json"), provider: SSHAuthenticationBookmarks())
        try identities.remember(key)
        let agentRoot = URL(fileURLWithPath: "/tmp/tg-auth-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: agentRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: agentRoot) }
        let store = FixtureSSHAuthentication(), repository = GitRepository(root: root, executable: git)
        let tools = SSHAgentRuntime(agent: URL(fileURLWithPath: "/usr/bin/ssh-agent"), add: URL(fileURLWithPath: "/usr/bin/ssh-add"), askpass: helper)
        var owners: [SSHTransportCoordinator] = []
        defer { owners.forEach { $0.close() } }
        func make() -> SSHTransportCoordinator {
            let value = SSHTransportCoordinator(repository: repository, identities: identities, temporaryRoot: agentRoot, credentials: store, runtime: { tools })
            owners.append(value); return value
        }
        let digest = try SSHAuthenticationIdentity.read(key, cancellation: OperationCancellation())
        let first = make(); var prompts = 0
        first.present = { prompt in
            prompts += 1
            assert(prompt.saveAuthentication.state == .off)
            prompt.passphrase.stringValue = prompts == 1 ? "incorrect entered phrase" : request.passphrase; prompt.saveAuthentication.state = .on; prompt.submit(); return true
        }
        let session = try await first.prepareKey(path: key.path, cancellation: OperationCancellation())
        try require(try session.publicIdentities().contains("saved-auth-fixture"), "Encrypted key was not loaded")
        let savedCount = await store.count()
        try require(prompts == 2 && savedCount == 1, "Save did not follow successful loading")
        first.close()
        let reused = make(); reused.present = { _ in prompts += 1; return false }
        _ = try await reused.prepareKey(path: key.path, cancellation: OperationCancellation()); reused.close()
        try require(prompts == 2, "Saved phrase was not reused")
        try await store.save(identity: digest, name: "fixture", passphrase: "incorrect saved phrase")
        let retry = make(); var retryPrompts = 0
        retry.present = { prompt in retryPrompts += 1; prompt.passphrase.stringValue = request.passphrase; prompt.submit(); return true }
        _ = try await retry.prepareKey(path: key.path, cancellation: OperationCancellation()); retry.close()
        let retainedWrong = await store.read(identity: digest)
        try require(retryPrompts == 1 && retainedWrong == "incorrect saved phrase", "Manual unchecked response changed saved authentication")
        let cancelled = make(); var held: SSHKeyPassphraseWindowController?
        cancelled.present = { held = $0; $0.passphrase.stringValue = request.passphrase; $0.saveAuthentication.state = .on; return true }
        let token = OperationCancellation()
        let work = Task { try await cancelled.prepareKey(path: key.path, cancellation: token) }
        try await wait { held != nil }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored active authentication")
        cancelled.close()
        do { _ = try await work.value; throw Failure(message: "Cancelled prompt continued") } catch OperationCancellationFailure.cancelled {}
        held?.submit()
        let afterCancel = await store.read(identity: digest)
        try require(afterCancel == "incorrect saved phrase" && held?.passphrase.stringValue.isEmpty == true, "Late cancelled response saved authentication")
        let blockedStore = HeldSSHAuthentication()
        let blocked = SSHTransportCoordinator(repository: repository, identities: identities, temporaryRoot: agentRoot, credentials: blockedStore, runtime: { tools })
        owners.append(blocked)
        let blockedToken = OperationCancellation()
        let blockedWork = Task { try await blocked.prepareKey(path: key.path, cancellation: blockedToken) }
        var readStarted = false
        for _ in 0..<1000 {
            if await blockedStore.pending() { readStarted = true; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if !readStarted { blocked.close(); await blockedStore.release(); throw Failure(message: "Saved read did not begin") }
        blocked.close()
        let quitBlocked = TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel
        await blockedStore.release()
        do { _ = try await blockedWork.value; throw Failure(message: "Retired saved read continued") } catch OperationCancellationFailure.cancelled {}
        try require(quitBlocked && SSHTransportCoordinator.activeOperations == 0, "Retired saved read lost Quit ownership")
        let manager = SavedSSHAuthenticationModel(store: store); defer { manager.retire() }
        manager.refresh(); try await wait { !manager.busy }
        manager.selection = [digest]; manager.confirm = { _ in false }; manager.removeSelected(); try await wait { !manager.busy }
        try require(await store.read(identity: digest) != nil, "Cancelled removal deleted authentication")
        manager.confirm = { _ in true }; manager.removeSelected(); try await wait { !manager.busy }
        let removed = await store.read(identity: digest)
        try require(removed == nil && manager.entries.isEmpty, "Removal retained authentication")
        let changed = root.appendingPathComponent("replacement")
        try Data("different key bytes".utf8).write(to: changed)
        try require(try SSHAuthenticationIdentity.read(changed, cancellation: OperationCancellation()) != digest, "Changed content shared authentication identity")
        try require(SavedSSHAuthenticationModel.activeOperations == 0 && !NSApp.windows.contains { $0.isVisible }, "Owned state remained active or visible")
        // Inject Security calls to check storage policy without touching Keychain.
        let api = SSHAuthenticationAPI(copy: { query in
            assert(query[kSecAttrService as String] as? String == "org.turtlegit.macos.ssh-authentication")
            assert(query[kSecAttrSynchronizable as String] as? Bool == false)
            return (errSecItemNotFound, nil)
        }, update: { _, _ in errSecItemNotFound }, add: { item in
            assert(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            return errSecSuccess
        }, delete: { _ in errSecItemNotFound })
        let injected = SSHKeychainAuthenticationStore(api: api)
        try require(try await injected.read(identity: digest) == nil, "Missing Keychain entry not optional")
        try await injected.save(identity: digest, name: "fixture", passphrase: request.passphrase)
        try await injected.remove(identity: digest)
        do { try await injected.save(identity: digest, name: "fixture", passphrase: "invalid\nphrase"); throw Failure(message: "Invalid phrase reached storage") } catch SSHAgentFailure.passphrase {}
    }
}
