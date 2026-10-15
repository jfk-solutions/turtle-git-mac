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
        try await permissions(root: root, credentials: store)
        let injected = SSHKeychainAuthenticationStore(api: api)
        try require(try await injected.read(identity: digest) == nil, "Missing Keychain entry not optional")
        try await injected.save(identity: digest, name: "fixture", passphrase: request.passphrase)
        try await injected.remove(identity: digest)
        do { try await injected.save(identity: digest, name: "fixture", passphrase: "invalid\nphrase"); throw Failure(message: "Invalid phrase reached storage") } catch SSHAgentFailure.passphrase {}
    }
    @MainActor private static func permissions(root: URL, credentials: FixtureSSHAuthentication) async throws {
        let directory = root.appendingPathComponent("permission-manager")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let a = directory.appendingPathComponent("key-a"), b = directory.appendingPathComponent("key-b"), other = directory.appendingPathComponent("newer-key")
        for file in [a, b, other] { try Data("private fixture".utf8).write(to: file) }
        let store = SSHIdentityAccessStore(storageURL: directory.appendingPathComponent("private/grants.json"), provider: SSHAuthenticationBookmarks())
        try store.remember(a); try store.remember(b)
        let owner = SavedSSHAuthenticationWindowController(store: credentials, identities: store, section: .keyFiles)
        defer { owner.close() }; owner.window!.alphaValue = 0; owner.showWindow(nil)
        let model = owner.permissions
        try require(model.entries.count == 2 && owner.model.section == .keyFiles, "Key file permission navigation/list failed")
        model.selection = [GitReferenceName(a.path)]
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        model.copyPaths(to: board); try require(board.string(forType: .string) == a.path, "Permission copy did not use captured path")
        model.selection = []; board.clearContents(); board.setString("unchanged", forType: .string); model.copyPaths(to: board)
        try require(board.string(forType: .string) == "unchanged", "Empty permission selection cleared clipboard")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            owner.window!.appearance = NSAppearance(named: appearance); owner.window!.contentView?.layoutSubtreeIfNeeded()
            try require(owner.window!.contentLayoutRect.width >= 700 && owner.window!.contentLayoutRect.height >= 460, "Permission native host smaller than controls")
        }
        model.selection = [GitReferenceName(a.path)]; model.confirm = { _ in false }; model.forget()
        try await wait { !model.busy }; try require(try store.grants().count == 2, "Cancel removed permission")
        var answer: CheckedContinuation<Bool, Never>?
        model.confirm = { _ in await withCheckedContinuation { answer = $0 } }; model.forget()
        try await wait { answer != nil }
        try require(SSHIdentityPermissionsModel.activeOperations == 1 && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Permission confirmation lost owner/Quit accounting")
        try store.forget(path: a.path); try store.remember(other)
        answer?.resume(returning: true); answer = nil; try await wait { !model.busy }
        try require(model.error == SSHIdentityAccessFailure.changed.localizedDescription && model.entries.count == 2 && FileManager.default.fileExists(atPath: b.path), "Stale snapshot removed different permission")
        model.confirm = { _ in true }; model.selection = [GitReferenceName(b.path)]; model.forget()
        try await wait { !model.busy }
        try require(try store.grants().map(\.configuredPath) == [other.path] && FileManager.default.fileExists(atPath: b.path), "Forget selection did not preserve key bytes/new grant")
        var panelReply: ((NSApplication.ModalResponse) -> Void)?
        owner.presentFile = { _, _, reply in panelReply = reply }; owner.selectedFile = { _ in a }
        owner.authorizeFile(); try require(model.panelOpen && !owner.windowShouldClose(owner.window!), "Authorize panel did not own window")
        panelReply?(.OK); panelReply?(.OK)
        try require(!model.panelOpen && model.entries.count == 2 && model.selection == [GitReferenceName(a.path)], "Selected key permission not remembered once")
        owner.authorizeFile(); panelReply?(.cancel); try require(model.entries.count == 2, "Cancelled panel replaced grants")
        model.confirm = { _ in await withCheckedContinuation { answer = $0 } }; model.forget(all: true)
        try await wait { answer != nil }; owner.close()
        try require(SSHIdentityPermissionsModel.activeOperations == 1, "Forced owner discarded unsettled confirmation accounting")
        answer?.resume(returning: true); answer = nil; try await wait { SSHIdentityPermissionsModel.activeOperations == 0 }
        try require(try store.grants().count == 2, "Retired confirmation removed file grants")
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        defer { parent.close() }; parent.isReleasedWhenClosed = false; parent.alphaValue = 0
        let navigation = SavedDataAuthenticationOwner(store: credentials, identities: store)
        navigation.show(owner: parent, section: .keyFiles)
        try require(navigation.controller?.model.section == .keyFiles && navigation.controller?.permissions.entries.count == 2, "Saved Data did not select key permission page")
        navigation.controller!.presentFile = { _, _, reply in panelReply = reply }
        navigation.controller!.selectedFile = { _ in b }; navigation.controller!.authorizeFile(); navigation.close(); panelReply?(.OK)
        try require(try store.grants().count == 2, "Retired file chooser remembered late result")
        let clear = SSHIdentityPermissionsModel(store: store); clear.confirm = { _ in true }; clear.refresh(); clear.forget(all: true)
        try await wait { !clear.busy }; try require(try store.grants().isEmpty && FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: other.path), "Forget all deleted a file or retained reviewed permissions")
        clear.retire()
        try require(SSHIdentityPermissionsModel.activeOperations == 0, "Permission operations did not settle")
        print("PASS SSH file permissions: native tabs/Saved Data ownership, light/dark hosts, copy, authorize/Cancel/late callback, reviewed/stale/retired confirmation, selected/all forget, preserved key files/new grants and Quit lifetime; private mocked bookmarks, no system grants modified.")
    }

}
