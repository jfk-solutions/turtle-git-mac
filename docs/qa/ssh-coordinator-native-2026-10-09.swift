import AppKit
import TurtleGitCore
import Darwin

private final class NativeIdentityBookmarks: RepositoryBookmarkProvider {
    var starts = 0, stops = 0
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) { stops += 1 }
}
@main struct SSHCoordinatorReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
    @MainActor static func wait(_ value: () -> Bool) async throws { for _ in 0..<1000 { if value() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(message: "Timed out") }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), askpass = URL(fileURLWithPath: CommandLine.arguments[3])
        let domain = "TurtleGit.SSHCoordinator.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Fixture"),("user.email","fixture@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "fixture")
        let encrypted = root.appendingPathComponent("encrypted"), phrase = "private fixture response"
        let generator = Process(); generator.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen"); generator.arguments = ["-q","-t","ed25519","-N",phrase,"-C","native-coordinator-fixture","-f",encrypted.path]; generator.standardInput = FileHandle.nullDevice; generator.standardOutput = FileHandle.nullDevice; generator.standardError = FileHandle.nullDevice
        try generator.run(); generator.waitUntilExit(); try require(generator.terminationStatus == 0,"Fixture key generation")
        try require(SSHTransportCoordinator.encryptedHeader(encrypted), "Encrypted OpenSSH header not recognized")
        let crlfKey = root.appendingPathComponent("encrypted-crlf")
        try Data(String(contentsOf: encrypted).replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: crlfKey)
        try require(SSHTransportCoordinator.encryptedHeader(crlfKey), "Windows CRLF OpenSSH header not recognized")
        let invalidKey = root.appendingPathComponent("invalid-key")
        try Data("unrecognized file".utf8).write(to: invalidKey)
        try require(!SSHTransportCoordinator.encryptedHeader(invalidKey) && !SSHTransportCoordinator.needsPassphrase(SSHAgentFailure.command(1, ""), encrypted: false), "Ordinary invalid key requested a passphrase")
        let provider = NativeIdentityBookmarks(), identities = SSHIdentityAccessStore(storageURL: root.appendingPathComponent("grants/grants.json"), provider: provider)
        try identities.remember(encrypted)
        let receiver = root.appendingPathComponent("receiver.git"); try FileManager.default.createDirectory(at: receiver, withIntermediateDirectories: false)
        let remote = GitRepository(root: receiver, executable: git); _ = try await remote.run(["init","--bare"])
        for name in ["origin","second"] { var settings = RemoteSettings(name: name); settings.url = receiver.path; settings.sshKeyFile = encrypted.path; try await repo.applyRemoteSettings(settings, changed: .all) }
        let agent = root.appendingPathComponent("agent")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$$\" > \"$0.pid\"\nexec /usr/bin/ssh-agent \"$@\"\n".utf8).write(to: agent); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:agent.path)
        let tools = SSHAgentRuntime(agent: agent, add: URL(fileURLWithPath:"/usr/bin/ssh-add"), askpass: askpass)
        var coordinators: [SSHTransportCoordinator] = []
        defer { coordinators.forEach { $0.close() } }
        func make() -> SSHTransportCoordinator { let c = SSHTransportCoordinator(repository: repo, identities: identities, temporaryRoot: root, runtime: { tools }); coordinators.append(c); return c }
        let c = make(); var attempts = 0
        c.present = { controller in attempts += 1; controller.passphrase.stringValue = attempts == 1 ? "wrong fixture response" : phrase; controller.submit(); return true }
        let session = try await c.prepare(["origin","second"], cancellation: OperationCancellation())
        try require(attempts == 2 && session != nil && (try session!.publicIdentities()).contains("native-coordinator-fixture"),"Encrypted prompt/retry/dedup actual key load")
        try require(provider.starts == provider.stops && c.prompt == nil,"Granted file scope or prompt leaked")
        let replacement = root.appendingPathComponent("replacement-key")
        // A Foundation Process cannot be relaunched; use a second owned process.
        let replacementGenerator = Process(); replacementGenerator.executableURL = generator.executableURL; replacementGenerator.arguments = ["-q","-t","ed25519","-N",phrase,"-C","native-coordinator-fixture","-f",replacement.path]; replacementGenerator.standardInput = FileHandle.nullDevice; replacementGenerator.standardOutput = FileHandle.nullDevice; replacementGenerator.standardError = FileHandle.nullDevice
        try replacementGenerator.run(); replacementGenerator.waitUntilExit(); try require(replacementGenerator.terminationStatus == 0,"Replacement fixture key generation")
        try FileManager.default.removeItem(at:encrypted); try FileManager.default.moveItem(at:replacement,to:encrypted)
        _ = try await c.prepare(["second"],cancellation:OperationCancellation())
        try require(attempts == 3 && (try session!.publicIdentities()).split(separator:"\n").count == 2,"Changed file was incorrectly treated as already loaded")
        let directory = session!.directory; c.close(); try require(!FileManager.default.fileExists(atPath: directory.path),"Private agent directory remains")
        let pid = try Int32(String(contentsOf: URL(fileURLWithPath: agent.path+".pid")).trimmingCharacters(in:.newlines)); try require(pid != nil && kill(pid!,0) != 0,"Private agent remains alive")
        let cancelled = make(); cancelled.present = { controller in controller.abort(); controller.submit(); return true }
        let cancellation = OperationCancellation()
        do { _ = try await cancelled.prepare(["origin"],cancellation:cancellation); throw Failure(message:"Prompt Cancel loaded a key") } catch OperationCancellationFailure.cancelled {}
        cancelled.close(); try require(cancellation.isCancelled && cancelled.prompt == nil,"Prompt Cancel did not stop operation")
        for force in [false,true] {
            let pending = make(), token = OperationCancellation(); var retained: SSHKeyPassphraseWindowController?
            pending.present = { retained = $0; $0.passphrase.stringValue = phrase; return true }
            let work = Task { do { _ = try await pending.prepare(["origin"],cancellation:token); throw Failure(message:"Pending prompt accepted late") } catch OperationCancellationFailure.cancelled {} }
            try await wait { pending.prompt != nil }
            if force { pending.close() } else { token.cancel() }
            try await work.value; retained?.submit(); pending.close()
            try require(pending.prompt == nil && retained?.finished == true && retained?.passphrase.stringValue.isEmpty == true,"Canceled pending prompt remains active")
        }
        // Actual transport wrapper checks only our private agent, then runs Git.
        let wrapper = root.appendingPathComponent("git-wrapper")
        func quote(_ value: String) -> String { "'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'" }
        let script = """
        #!/bin/sh
        operation=
        for argument in "$@"; do case "$argument" in push|fetch|pull|ls-remote) operation="$argument";; esac; done
        if [ -n "$operation" ]; then
          case "${SSH_AUTH_SOCK:-}" in \(quote(root.path))/tg-agent-*/s) ;; *) exit 74;; esac
          /usr/bin/ssh-add -L > "$0.public" || exit 75
          /usr/bin/grep -q native-coordinator-fixture "$0.public" || exit 76
          printf '%s\\n' "$operation" >> "$0.calls"
        fi
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let transportRepo = GitRepository(root:root,executable:wrapper)
        var modelPrompts = 0
        let factory: SSHTransportFactory = { let value = SSHTransportCoordinator(repository:transportRepo,identities:identities,temporaryRoot:root,runtime:{tools}); value.present = { controller in modelPrompts += 1; controller.passphrase.stringValue = phrase; controller.submit(); return true }; coordinators.append(value); return value }
        let push = PushWindowModel(repository:transportRepo,access:nil,preferences:preferences)
        push.sshSettings.makeCoordinator = factory; push.load(); try await wait { !push.busy }
        try require(push.sshSettings.enabled,"Available native auto-load default")
        push.options.source = "refs/heads/main"; push.options.remote = "origin"; push.push(confirmed:true)
        try await wait { !push.busy }; try require(push.error == nil && modelPrompts == 1,"Shipping Push key preparation did not run")
        _ = try await remote.run(["show-ref","--verify","refs/heads/main"])
        for pull in [false,true] {
            let model = FetchWindowModel(repository:transportRepo,access:nil,isPull:pull,preferences:preferences)
            model.sshSettings.makeCoordinator = factory; model.load(remote:"origin"); try await wait { !model.busy }
            model.options.branch = "main"; model.fetch(); model.sshSettings.enabled = false
            try await wait { !model.busy }; try require(model.error == nil && (pull ? model.progress?.success : model.fetchProgress?.success) == true,"Shipping Fetch/Pull captured auto-load preparation")
            model.invalidate()
        }
        try require(modelPrompts == 3,"Auto-load snapshot was changed after submission")
        let browse = FetchWindowModel(repository:transportRepo,access:nil,isPull:false,preferences:preferences)
        browse.sshSettings.makeCoordinator = factory; browse.load(remote:"origin"); try await wait { !browse.busy }; browse.sshSettings.enabled = true; browse.browse(); try await wait { !browse.busy }
        try require(browse.branches == ["main"] && modelPrompts == 4,"Shipping remote branch lookup did not load key"); browse.invalidate()
        let calls = try String(contentsOf: URL(fileURLWithPath:wrapper.path+".calls")); try require(calls == "push\nfetch\npull\nls-remote\n","Unexpected transport order")
        // Close the shipping controller while its actual Push task awaits a prompt.
        DialogGeometry.install(preferences: preferences)
        let controller = PushWindowController(repository: transportRepo, access: nil, preferences: preferences)
        defer { controller.close() }
        var pendingControllerPrompt: SSHKeyPassphraseWindowController?, pendingCoordinator: SSHTransportCoordinator?
        var closedCallbacks = 0, resultCallbacks = 0
        controller.onClosed = { closedCallbacks += 1 }
        controller.model.onPushed = { _ in resultCallbacks += 1 }
        controller.model.onTransportResult = { _, _ in resultCallbacks += 1 }
        controller.model.sshSettings.makeCoordinator = {
            let value = SSHTransportCoordinator(repository: transportRepo, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { pendingControllerPrompt = $0; return true }
            pendingCoordinator = value; coordinators.append(value); return value
        }
        controller.model.load(); try await wait { !controller.model.busy }
        controller.model.options.source = "refs/heads/main"; controller.model.options.remote = "origin"
        // Keep the receiver hidden; the transport still uses the shipping controller model.
        controller.model.onProgress = nil
        controller.model.push(confirmed: true)
        try await wait { pendingControllerPrompt != nil }
        controller.close()
        try await wait { pendingCoordinator?.closed == true && !controller.model.transportRunning }
        pendingControllerPrompt?.submit()
        try require(closedCallbacks == 1 && resultCallbacks == 0 && controller.model.error == nil && pendingControllerPrompt?.finished == true, "Controller close allowed a late result or live prompt")
        try require(try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls")) == calls, "Closed prompt launched transport")
        try require(coordinators.allSatisfy { $0.closed } && provider.starts == provider.stops,"Finished transport coordinator or file lease remains")
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Receiver displayed UI")
        print("PASS native encrypted-key prompt/retry/dedup, Cancel/token/forced-close fences, private agent cleanup; shipping Push/Fetch/Pull/browse auto-load snapshots and local Git effects; CRLF key headers and Push controller close fence")
    }
}
