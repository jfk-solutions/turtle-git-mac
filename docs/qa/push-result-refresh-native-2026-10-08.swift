import AppKit
import TurtleGitCore

@main struct PushResultRefreshVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Push result refresh timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.PushResultRefresh.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        let client = root.appendingPathComponent("client"), destination = root.appendingPathComponent("remote.git")
        for dir in [client,destination] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let repo = GitRepository(root:client,executable:git), remote = GitRepository(root:destination,executable:git)
        _ = try await remote.run(["init","--bare"]); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Push refresh QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        try await repo.saveRemote(name:"a-good",fetchURL:destination.path,pushURL:"",existing:false)
        try await repo.saveRemote(name:"z-bad",fetchURL:root.appendingPathComponent("missing.git").path,pushURL:"",existing:false)
        let log = LogWindowModel(repository:repo,access:nil,selecting:true,labelDefaults:prefs); log.allBranches = true; log.reload(); try await wait { !log.busy && !log.entries.isEmpty }
        let owner = PushWindowModel(repository:repo,access:nil,preferences:prefs); owner.load(); try await wait { !owner.busy }
        owner.options.source = "main"; owner.options.allRemotes = true; owner.options.destination = "published"; owner.options.setUpstream = false
        var results:[(String,Bool)] = [], successes = 0, progress:PushProgressWindowModel?
        owner.onProgress = { progress = $0 }; owner.onPushed = { _ in successes += 1 }
        owner.onTransportResult = { text,success in precondition(!owner.transportRunning); results.append((text,success)); log.reload() }
        owner.push(); try await wait { progress?.busy == false }
        precondition(results.count == 1 && !results[0].1 && successes == 0 && owner.busy && !progress!.success && owner.error == nil)
        precondition(results[0].0.contains("Completed: a-good.") && results[0].0.contains("refs/heads/published"))
        try await wait { !log.busy && log.entries.contains { $0.references.contains { $0.name == "refs/remotes/a-good/published" } } }
        let head = try await repo.run(["rev-parse","HEAD"]).text, received = try await remote.run(["rev-parse","refs/heads/published"]).text; precondition(head == received)
        progress!.close(); precondition(results.count == 1 && !owner.busy)
        // A successful retry notifies result once and success once, before acknowledgement.
        owner.options.allRemotes = false; owner.options.remote = "a-good"; owner.push(); try await wait { progress?.busy == false && results.count == 2 }
        precondition(results[1].1 && successes == 1 && progress!.success); progress!.close(); precondition(results.count == 2)
        // Saved branch defaults survive transport failure and can be read in refresh.
        let failed = PushWindowModel(repository:repo,access:nil,preferences:prefs); failed.load(); try await wait { !failed.busy }
        failed.options.source = "main"; failed.options.remote = "z-bad"; failed.options.setUpstream = false; failed.options.destination = "saved-target"; failed.options.savePushRemote = true; failed.options.savePushBranch = true
        var failedResults = 0, savedDefaults:PushDefaults?, failedProgress:PushProgressWindowModel?
        failed.onProgress = { failedProgress = $0 }; failed.onTransportResult = { _,success in precondition(!success && !failed.transportRunning); failedResults += 1; Task { savedDefaults = try await repo.pushDefaults(source:"main") } }
        failed.push(); try await wait { failedProgress?.busy == false && savedDefaults != nil }
        precondition(failedResults == 1 && savedDefaults!.remote == "z-bad" && savedDefaults!.destination == "saved-target"); failedProgress!.close()
        // Read-only preflight rejection emits no transport-result notification.
        failed.options.source = "missing"; failed.push(); try await wait { !failed.busy }; precondition(failedResults == 1 && failed.progress == nil && failed.error != nil)
        // The count can fail after a real remote deletion; its failed result still refreshes.
        let deletion = PushWindowModel(repository:repo,access:nil,preferences:prefs); deletion.load(); try await wait { !deletion.busy }
        deletion.options.source = ""; deletion.options.destination = "published"; deletion.options.remote = "a-good"; deletion.options.setUpstream = false; deletion.options.savePushRemote = false; deletion.options.savePushBranch = false
        prefs.set(true,forKey:"ShowBranchRevisionNumber")
        var deletionResults = 0, deletionProgress:PushProgressWindowModel?
        deletion.onProgress = { deletionProgress = $0 }; deletion.onTransportResult = { text,success in precondition(!success && text.contains("Completed: a-good.")); deletionResults += 1; log.reload() }
        deletion.push(confirmed:true); try await wait { deletionProgress?.busy == false && !log.busy }
        precondition(deletionResults == 1 && !deletionProgress!.success)
        precondition(!log.entries.contains { $0.references.contains { $0.name == "refs/remotes/a-good/published" } })
        let remaining = try await remote.checkoutReferences(); precondition(!remaining.contains { $0.name == "refs/heads/published" }); deletionProgress!.close()
        log.invalidate()
        print("Push result notifications: real partial all-remotes publication visible after native Log reload; once-only success/failure notification before acknowledgement, no cancelled/success confusion, saved branch defaults visible after failed transport, no preflight notification, count failure after real deletion still refreshes. No displayed windows or standard preference/clipboard writes.")
    }
}
