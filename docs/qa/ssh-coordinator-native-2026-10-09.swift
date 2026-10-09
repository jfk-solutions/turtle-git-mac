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
    @MainActor static func wait(_ stage: String = "Timed out", _ value: () -> Bool) async throws { for _ in 0..<1000 { if value() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(message: stage) }
    @MainActor static var ownedAddModels: [SubmoduleAddProgressWindowModel] = []
    @MainActor static func cleanupAddModels() async throws {
        for model in ownedAddModels { model.invalidate() }
        try await wait("Owned Add cleanup") { ownedAddModels.allSatisfy { !$0.busy } }
        ownedAddModels.removeAll()
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run(); try await cleanupAddModels() } catch {
            let failure = error; do { try await cleanupAddModels() } catch { fputs("CLEANUP FAIL \(error)\n", stderr) }
            fputs("FAIL \(failure)\n", stderr); exit(1)
        }
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
        for argument in "$@"; do case "$argument" in push|fetch|pull|ls-remote|clone|submodule) operation="$argument";; esac; done
        if [ -n "$operation" ]; then
          case "${SSH_AUTH_SOCK:-}" in \(quote(root.path))/tg-agent-*/s) ;; *) exit 74;; esac
          /usr/bin/ssh-add -L > "$0.public" || exit 75
          /usr/bin/grep -q native-coordinator-fixture "$0.public" || exit 76
          printf '%s\\n' "$operation" >> "$0.calls"
          if [ "$operation" = submodule ] && [ -f "$0.large-failure" ]; then
            /usr/bin/awk 'BEGIN { for (i=0;i<3000;i++) print "Submodule failure fixture output line" }'
            exit 1
          fi
        fi
        exec \(quote(git.path)) -c \(quote("url." + root.path + ".insteadOf=ssh://clone-fixture.invalid/source")) -c protocol.file.allow=always "$@"
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
        for tag in ["keep", "drop"] { _ = try await repo.run(["tag", tag]) }
        _ = try await repo.run(["push", "origin", "--tags"])
        let remoteTags = RemoteTagWindowModel(repository: transportRepo, access: nil, remote: "origin", preferences: preferences)
        remoteTags.sshSettings.makeCoordinator = factory; remoteTags.sshSettings.enabled = true
        remoteTags.load(); try await wait { !remoteTags.busy }
        try require(remoteTags.error == nil && Set(remoteTags.tags.map(\.name)) == ["keep", "drop"] && modelPrompts == 5, "Remote tag listing missed key preparation")
        remoteTags.select(["drop"]); remoteTags.confirm = { _ in true }; remoteTags.delete()
        try await wait { !remoteTags.busy }
        try require(remoteTags.error == nil && remoteTags.tags.map(\.name) == ["keep"] && modelPrompts == 7, "Remote tag delete/refresh missed owned key preparation")
        remoteTags.invalidate()
        let head = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await remote.run(["update-ref", "refs/heads/topic", head]); _ = try await repo.run(["fetch", "origin"])
        let browser = ReferenceBrowserWindowModel(repository: transportRepo, access: nil, initial: "refs/remotes/origin", preferences: preferences, picking: false)
        browser.sshSettings.makeCoordinator = factory; browser.sshSettings.enabled = true
        browser.load(); try await wait { !browser.busy && browser.snapshot != nil }
        browser.select(["refs/remotes/origin/topic"], last: "refs/remotes/origin/topic"); browser.confirmDeletion = { _ in true }; browser.deleteChosen()
        try await wait { !browser.busy }
        try require(browser.error == nil && modelPrompts == 8, "Browser remote deletion missed key preparation")
        let refs = try await remote.checkoutReferences(); try require(!refs.contains { $0.name == "refs/heads/topic" }, "Browser did not delete selected remote branch"); browser.invalidate()
        let pendingTags = RemoteTagWindowController(repository: transportRepo, access: nil, remote: "origin", preferences: preferences)
        defer { pendingTags.close() }
        pendingTags.presentProgress = { _, _ in true }
        var tagPrompt: SSHKeyPassphraseWindowController?, tagCoordinator: SSHTransportCoordinator?
        pendingTags.model.sshSettings.makeCoordinator = {
            let value = SSHTransportCoordinator(repository: transportRepo, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { tagPrompt = $0; return true }; tagCoordinator = value; coordinators.append(value); return value
        }
        pendingTags.model.sshSettings.enabled = true; pendingTags.model.load(); try await wait { tagPrompt != nil }
        pendingTags.close(); try await wait { tagCoordinator?.closed == true }; tagPrompt?.submit()
        try require(pendingTags.model.closed && pendingTags.model.tags.isEmpty && pendingTags.model.error == nil && tagPrompt?.finished == true, "Closed remote tags accepted a late key response")
        let refCalls = try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls"))
        try require(refCalls == calls + "ls-remote\npush\nls-remote\npush\n", "Remote ref transport ordering or closed prompt transport")
        _ = try await remote.run(["update-ref", "refs/heads/log-topic", head]); _ = try await repo.run(["fetch", "origin"])
        let log = LogWindowModel(repository: transportRepo, access: nil, labelDefaults: preferences)
        log.entries = try await repo.history(); log.graph = CommitGraph.layout(log.entries); log.selected = [head]
        log.sshSettings.makeCoordinator = factory; log.sshSettings.enabled = true; log.confirmReferenceDeletion = { _ in .remoteAndLocal }
        log.deleteReferences([LogReferenceMenuTarget(hash: head, name: "refs/remotes/origin/log-topic")]); try await wait("Log deletion/reload") { !log.busy }
        try require(log.error == nil && modelPrompts == 9, "Log remote delete missed native key loading")
        let logRefs = try await remote.checkoutReferences(); try require(!logRefs.contains { $0.name == "refs/heads/log-topic" }, "Log did not delete remote branch"); log.invalidate()
        _ = try await remote.run(["update-ref", "refs/heads/log-retain", head]); _ = try await repo.run(["fetch", "origin"])
        DialogGeometry.install(preferences: preferences)
        let pendingLog = LogWindowController(repository: transportRepo, access: nil, labelDefaults: preferences, savesColumnLayout: false)
        defer { pendingLog.close() }
        try await wait("Log initial history load") { !pendingLog.model.busy }
        pendingLog.model.entries = try await repo.history(); pendingLog.model.graph = CommitGraph.layout(pendingLog.model.entries); pendingLog.model.selected = [head]
        var logPrompt: SSHKeyPassphraseWindowController?, logCoordinator: SSHTransportCoordinator?, logFailures = 0
        pendingLog.model.confirmReferenceDeletion = { _ in .remoteAndLocal }; pendingLog.model.acknowledgeReferenceDeletionFailure = { _ in logFailures += 1 }
        pendingLog.model.sshSettings.makeCoordinator = {
            let value = SSHTransportCoordinator(repository: transportRepo, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { logPrompt = $0; return true }; logCoordinator = value; coordinators.append(value); return value
        }
        pendingLog.model.sshSettings.enabled = true
        try require(pendingLog.model.deletionCandidates(target: LogReferenceMenuTarget(hash: head, name: "refs/remotes/origin/log-retain")).count == 1, "Missing Log remote deletion target")
        pendingLog.model.deleteReferences([LogReferenceMenuTarget(hash: head, name: "refs/remotes/origin/log-retain")]); try await wait("Log pending prompt") { logPrompt != nil }
        pendingLog.close(); try await wait("Log coordinator cleanup") { logCoordinator?.closed == true }; logPrompt?.submit()
        let retainedLogRefs = try await remote.checkoutReferences()
        try require(logFailures == 0 && pendingLog.model.error == nil && logPrompt?.finished == true && retainedLogRefs.contains { $0.name == "refs/heads/log-retain" }, "Closed Log accepted late transport/result")
        let logCalls = try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls")); try require(logCalls == refCalls + "push\n", "Log close launched extra transport")
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
        try require(try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls")) == logCalls, "Closed prompt launched transport")
        var clonePrompts = 0
        let cloneFactory: SSHCloneTransportFactory = { runner in
            let value = SSHTransportCoordinator(repository: runner, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { prompt in clonePrompts += 1; prompt.passphrase.stringValue = phrase; prompt.submit(); return true }; coordinators.append(value); return value
        }
        for streamed in [false, true] {
            let destination = root.appendingPathComponent(streamed ? "clone-streamed" : "clone-direct")
            let clone = CloneWindowModel(directory: root, access: RepositoryAccessLease(url: root), preferences: preferences, executable: wrapper)
            clone.identities = identities; clone.makeSSHCoordinator = cloneFactory
            clone.source = "ssh://clone-fixture.invalid/source"; clone.sourceChanged(); clone.directory = destination.path
            clone.useOrigin = true; clone.origin = "custom"; clone.acceptKeySelection(encrypted)
            var results = 0, progress: CloneProgressWindowModel?
            clone.onCloned = { _, _, keyAccess, _, _ in results += 1; if keyAccess != nil { results += 100 } }
            if streamed { clone.onProgress = { progress = $0 } }
            clone.clone()
            if streamed {
                try await wait("Streamed SSH clone") { progress?.busy == false }
                try require(progress?.success == true, "Streamed SSH clone failed")
                if let progress { clone.finish(progress) }
            } else { try await wait("Direct SSH clone") { !clone.busy } }
            try require(results == 1 && clone.error == nil && clone.completed?.standardizedFileURL.path == destination.standardizedFileURL.path, "Native clone result or legacy bookmark callback: streamed=\(streamed), results=\(results), error=\(clone.error ?? "none"), completed=\(clone.completed?.path ?? "none"), destination=\(destination.path)")
            let cloned = GitRepository(root: destination, executable: git)
            let settings = try await cloned.remoteSettings(name: "custom")
            let clonedHead = try await cloned.run(["rev-parse", "HEAD"]), sourceHead = try await repo.run(["rev-parse", "HEAD"])
            try require(clonedHead.text == sourceHead.text, "Native clone HEAD differs from fixture source")
            let legacy = try await cloned.run(["config", "--get", "core.sshCommand"], successfulExitCodes: 0...1)
            try require(settings.sshKeyFile == encrypted.path && settings.puttyKeyFile.isEmpty && legacy.exitCode == 1, "Clone did not save independent native remote key")
            clone.invalidate(); progress = nil
        }
        try require(clonePrompts == 2, "Clone did not prepare one private key per submission")
        let pendingClone = CloneWindowController(directory: root, access: RepositoryAccessLease(url: root), preferences: preferences, executable: wrapper)
        defer { pendingClone.close() }
        var clonePrompt: SSHKeyPassphraseWindowController?, cloneCoordinator: SSHTransportCoordinator?, clonedAfterClose = 0
        pendingClone.model.identities = identities; pendingClone.model.makeSSHCoordinator = { runner in
            let value = SSHTransportCoordinator(repository: runner, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { clonePrompt = $0; return true }; cloneCoordinator = value; coordinators.append(value); return value
        }
        pendingClone.model.source = "ssh://clone-fixture.invalid/source"; pendingClone.model.sourceChanged()
        let cancelledDestination = root.appendingPathComponent("clone-cancelled")
        pendingClone.model.directory = cancelledDestination.path; pendingClone.model.acceptKeySelection(encrypted)
        pendingClone.model.onProgress = nil; pendingClone.model.onCloned = { _, _, _, _, _ in clonedAfterClose += 1 }
        pendingClone.model.clone(); try await wait("Clone pending key") { clonePrompt != nil }
        pendingClone.close(); try await wait("Clone closed cleanup") { cloneCoordinator?.closed == true && !pendingClone.model.busy }; clonePrompt?.submit()
        let savedGrants = try Data(contentsOf: identities.storageURL); pendingClone.model.acceptKeySelection(crlfKey)
        try require(try Data(contentsOf: identities.storageURL) == savedGrants, "Closed Clone saved a late key selection")
        try require(clonedAfterClose == 0 && pendingClone.model.error == nil && !FileManager.default.fileExists(atPath: cancelledDestination.path) && clonePrompt?.finished == true, "Closed Clone allowed late transport/result")
        try require(try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls")) == logCalls + "clone\nclone\n", "Clone did not stop at key cancellation")
        let add = SubmoduleAddWindowController(repository: transportRepo, access: RepositoryAccessLease(url: root), preferences: preferences)
        defer { add.close() }
        add.model.identities = identities; add.model.makeSSHCoordinator = cloneFactory
        add.model.source = "ssh://clone-fixture.invalid/source"; add.model.sourceEndedEditing()
        try require(add.model.path == "source", "Submodule repository end-edit path derivation")
        add.model.path = "modules/native-child"; add.model.useBranch = true; add.model.branch = "main"
        add.model.useKey = true; add.model.acceptSelection(encrypted, kind: .key)
        var added = 0, addOptionsClosed = 0
        var addProgress: SubmoduleAddProgressWindowController?
        add.onClosed = { addOptionsClosed += 1 }
        add.model.onSubmit = { model in
            ownedAddModels.append(model); let controller = SubmoduleAddProgressWindowController(model: model); addProgress = controller
            model.onAdded = { _ in added += 1 }; model.start()
        }
        defer { addProgress?.close() }
        let appDelegate = TurtleGitApplicationDelegate()
        add.model.apply(); add.model.source = "wrong snapshot"; add.model.path = "modules/wrong-snapshot"; add.model.apply()
        try require(appDelegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Quit allowed a running Submodule Add")
        try await wait("Native Submodule Add") { addProgress?.model.busy == false }
        try require(addProgress!.model.success && addProgress!.model.error == nil && added == 1, "Native Submodule Add failed or adopted twice")
        try require(addProgress!.model.currentWork == "Success" && addProgress!.model.percentage == 100 && addProgress!.model.completionRange != nil && addProgress!.model.output.contains(" ms @ "), "Submodule Add missing default completion/timing")
        try require(addOptionsClosed == 1 && !add.model.canApply && addProgress?.window !== add.window, "Add did not close options and transfer to a separate progress window")
        let child = GitRepository(root: root.appendingPathComponent("modules/native-child"), executable: git)
        let childSettings = try await child.remoteSettings(name: "origin")
        let childHead = try await child.run(["rev-parse", "HEAD"]), parentHead = try await repo.run(["rev-parse", "HEAD"])
        try require(childSettings.sshKeyFile == encrypted.path && childSettings.puttyKeyFile.isEmpty && childHead.text == parentHead.text, "Native child key/HEAD mismatch")
        let gitlink = try await repo.run(["ls-files", "--stage", "--", "modules/native-child"])
        try require(gitlink.text.hasPrefix("160000 "), "Submodule Add did not stage gitlink")
        addProgress?.close()
        let previousLimit = preferences.object(forKey: "GitOutputLimitinKiB")
        preferences.set(16, forKey: "GitOutputLimitinKiB")
        let failedAdd = SubmoduleAddWindowModel(repository: transportRepo, access: RepositoryAccessLease(url: root), path: "", preferences: preferences)
        failedAdd.identities = identities; failedAdd.makeSSHCoordinator = cloneFactory; failedAdd.useKey = true
        failedAdd.source = "ssh://clone-fixture.invalid/source"; failedAdd.path = "modules/failed-child"; failedAdd.acceptSelection(encrypted, kind: .key)
        let failureFlag = URL(fileURLWithPath: wrapper.path+".large-failure"); try Data().write(to: failureFlag)
        var failureCallbacks = 0, failedProgress: SubmoduleAddProgressWindowModel?
        failedAdd.onSubmit = { model in ownedAddModels.append(model); failedProgress = model; model.onAdded = { _ in failureCallbacks += 1 }; model.start() }
        failedAdd.apply()
        if let previousLimit { preferences.set(previousLimit, forKey: "GitOutputLimitinKiB") } else { preferences.removeObject(forKey: "GitOutputLimitinKiB") }
        guard let failedProgress else { throw Failure(message: "Failed Add did not submit progress") }
        defer { failedProgress.invalidate() }
        try await wait("Submodule Add bounded failure") { !failedProgress.busy }
        try require(!failedProgress.success && failedProgress.error == "Git command failed (1)." && failedProgress.output.contains("Output truncated") && failedProgress.output.utf8.count < 32768 && failureCallbacks == 0 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("modules/failed-child").path), "Submodule Add failure replaced bounded output or published success")
        try require(failedProgress.currentWork == "git did not exit cleanly (exit code 1)" && failedProgress.percentage == 100 && failedProgress.completionRange != nil, "Submodule Add missing failed completion")
        try FileManager.default.removeItem(at: failureFlag)
        preferences.set(false, forKey: "ShowGitexeTimings")
        failedProgress.retry()
        try require(failedProgress.completionRange == nil && failedProgress.percentage == nil && failedProgress.currentWork.isEmpty, "Retry retained terminal presentation")
        try await wait("Submodule Add retry") { !failedProgress.busy }
        try require(failedProgress.success && failedProgress.error == nil && failureCallbacks == 1 && failedProgress.output.hasSuffix("\nSuccess\n") && !failedProgress.output.contains(" ms @ "), "Submodule Add retry or disabled timing failed")
        preferences.removeObject(forKey: "ShowGitexeTimings"); failedProgress.invalidate()
        let pendingAdd = SubmoduleAddWindowController(repository: transportRepo, access: RepositoryAccessLease(url: root), preferences: preferences)
        defer { pendingAdd.close() }
        var addPrompt: SSHKeyPassphraseWindowController?, addCoordinator: SSHTransportCoordinator?, addedAfterClose = 0
        var pendingAddProgress: SubmoduleAddProgressWindowController?
        pendingAdd.model.onSubmit = { model in
            ownedAddModels.append(model); let controller = SubmoduleAddProgressWindowController(model: model); pendingAddProgress = controller
            model.onAdded = { _ in addedAfterClose += 1 }; model.start()
        }
        defer { pendingAddProgress?.close() }
        pendingAdd.model.identities = identities; pendingAdd.model.makeSSHCoordinator = { runner in
            let value = SSHTransportCoordinator(repository: runner, identities: identities, temporaryRoot: root, runtime: { tools })
            value.present = { addPrompt = $0; return true }; addCoordinator = value; coordinators.append(value); return value
        }
        pendingAdd.model.source = "ssh://clone-fixture.invalid/source"; pendingAdd.model.path = "modules/cancelled-child"
        pendingAdd.model.useKey = true; pendingAdd.model.acceptSelection(encrypted, kind: .key)
        pendingAdd.model.apply()
        try await wait("Submodule Add pending key") { addPrompt != nil }
        preferences.set(true, forKey: "ConfirmKillProcess")
        var addAnswer: ((Bool) -> Void)?, addQuestions = 0
        pendingAddProgress!.model.confirmCancellation = { addQuestions += 1; addAnswer = $0 }
        try require(!pendingAddProgress!.windowShouldClose(pendingAddProgress!.window!), "Running Add window closed before question")
        pendingAddProgress!.model.cancel()
        try require(addQuestions == 1 && pendingAddProgress!.model.confirmingCancellation && !pendingAddProgress!.model.cancelling, "Add duplicate cancellation question")
        addAnswer?(false)
        try require(pendingAddProgress!.model.busy && !pendingAddProgress!.model.confirmingCancellation && !pendingAddProgress!.model.cancelling, "No cancelled Add")
        pendingAddProgress!.model.cancel(); addAnswer?(true); addAnswer?(true)
        try await wait("Submodule Add cancelled completion") { !pendingAddProgress!.model.busy }
        try require(pendingAddProgress!.model.currentWork == "User cancelled" && pendingAddProgress!.model.percentage == 100 && pendingAddProgress!.model.completionRange != nil && pendingAddProgress!.model.error == nil && addedAfterClose == 0 && addPrompt?.finished == true, "Submodule Add cancellation missing terminal state")
        preferences.removeObject(forKey: "ConfirmKillProcess")
        addPrompt = nil; pendingAddProgress!.model.retry()
        try await wait("Submodule Add retry pending key") { addPrompt != nil }
        pendingAddProgress!.close(); try await wait("Submodule Add closed cleanup") { addCoordinator?.closed == true && !pendingAddProgress!.model.busy }; addPrompt?.submit()
        let beforeLateSelection = try Data(contentsOf: identities.storageURL); pendingAdd.model.acceptSelection(crlfKey, kind: .key)
        try require(try Data(contentsOf: identities.storageURL) == beforeLateSelection && addedAfterClose == 0 && pendingAddProgress!.model.error == nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent("modules/cancelled-child").path), "Closed Submodule Add allowed a late selection/operation/result")
        try require(try String(contentsOf: URL(fileURLWithPath: wrapper.path+".calls")) == logCalls + "clone\nclone\nsubmodule\nsubmodule\nsubmodule\n", "Submodule Add cancellation launched transport")
        // Private local repositories exercise captured automatic-close policy without SSH.
        let localWrapper = root.appendingPathComponent("local-add-git")
        try Data("#!/bin/sh\nexec \(quote(git.path)) -c protocol.file.allow=always \"$@\"\n".utf8).write(to: localWrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localWrapper.path)
        let localAddRepo = GitRepository(root: root, executable: localWrapper)
        let privateActionLog = ActionLogStore(storageURL: root.appendingPathComponent("action-log/logfile.txt"))
        ProgressActionLog.install(store: privateActionLog, preferences: preferences)
        for policy in [1, 2] {
            preferences.set(policy, forKey: "AutoCloseGitProgress")
            var options = SubmoduleAddOptions(); options.source = root.path; options.path = "modules/automatic-\(policy)"
            let automatic = SubmoduleAddProgressWindowModel(repository: localAddRepo, access: RepositoryAccessLease(url: root), sourceAccess: nil, keyAccess: nil, options: options, preferences: preferences)
            ownedAddModels.append(automatic); var closes = 0
            automatic.close = { closes += 1 }
            preferences.set(0, forKey: "AutoCloseGitProgress"); automatic.start(); automatic.start()
            try await wait("Automatic Add completion") { !automatic.busy }
            try require(automatic.success && closes == 1, "Add ignored captured no-options/no-errors auto-close or repeated start")
            let once = try privateActionLog.read(); automatic.saveActionLog(); automatic.saveActionLog()
            try require(try privateActionLog.read() == once, "Add completion/close recorded the attempt repeatedly")
            automatic.invalidate()
        }
        preferences.set(2, forKey: "AutoCloseGitProgress"); preferences.set(true, forKey: "ConfirmKillProcess")
        var deferredOptions = SubmoduleAddOptions(); deferredOptions.source = root.path; deferredOptions.path = "modules/deferred-add"
        let deferredAdd = SubmoduleAddProgressWindowModel(repository: localAddRepo, access: RepositoryAccessLease(url: root), sourceAccess: nil, keyAccess: nil, options: deferredOptions, preferences: preferences)
        ownedAddModels.append(deferredAdd); var deferredAddAnswer: ((Bool) -> Void)?, deferredAddCloses = 0
        deferredAdd.confirmCancellation = { deferredAddAnswer = $0 }; deferredAdd.close = { deferredAddCloses += 1 }
        deferredAdd.start(); deferredAdd.cancel()
        try await wait("Add completion behind question") { !deferredAdd.busy }
        try require(deferredAdd.success && deferredAdd.confirmingCancellation && deferredAddCloses == 0, "Add closed behind pending cancellation question")
        deferredAddAnswer?(true); deferredAddAnswer?(true)
        try require(deferredAddCloses == 1 && !deferredAdd.cancelled && !deferredAdd.confirmingCancellation, "Late/duplicate Add answer canceled success or repeated close")
        deferredAdd.invalidate()
        try require(try privateActionLog.read().components(separatedBy: "\nSuccess (").count == 4, "Add action log missed completed attempts or duplicated records")
        preferences.removeObject(forKey: "ConfirmKillProcess"); preferences.removeObject(forKey: "AutoCloseGitProgress")
        try require(coordinators.allSatisfy { $0.closed } && provider.starts == provider.stops,"Finished transport coordinator or file lease remains")
        try require(!NSApplication.shared.windows.contains { $0.isVisible },"Receiver displayed UI")
        print("PASS native encrypted-key prompt/retry/dedup, Cancel/token/forced-close fences, private agent cleanup; shipping Push/Fetch/Pull/browse auto-load snapshots and local Git effects; CRLF headers, remote tag/browser deletion transports and Log remote deletion and Push/tag/Log/Clone controller close fences; direct and streamed native SSH Clone with remote-key config; Submodule Add captured branch/gitlink/child-key, bounded failure, Quit and forced-close fences")
    }
}
