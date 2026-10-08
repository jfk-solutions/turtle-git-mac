import AppKit
import TurtleGitCore

@main struct FetchProgressVerification {
    @MainActor static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Fetch progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let producerRoot = root.appendingPathComponent("producer"), clientRoot = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: producerRoot, withIntermediateDirectories: true)
        let producer = GitRepository(root: producerRoot, executable: git)
        _ = try await producer.run(["init","-b","main"])
        for (key,value) in [("user.name","Fetch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["branch","topic"])
        _ = try await producer.run(["clone",producerRoot.path,clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git); _ = try await repo.run(["config","core.hooksPath","/dev/null"])
        let suite = "TurtleGit.FetchProgress.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        try Data("mixed index\n".utf8).write(to: clientRoot.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("mixed working\n".utf8).write(to: clientRoot.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index")), working = try Data(contentsOf: clientRoot.appendingPathComponent("file"))
        try Data("remote next\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "next")
        let remote = try await producer.run(["rev-parse","HEAD"]).stdout
        let owner = FetchWindowModel(repository: repo, access: nil, isPull: false, preferences: preferences)
        owner.load(); try await waitUntil { !owner.busy }; owner.options.tags = .enabled; owner.options.prune = .enabled
        var completed = 0, changes = 0, closes = 0
        owner.onFetched = { _ in completed += 1 }; owner.onChanged = { _ in changes += 1 }; owner.close = { closes += 1 }
        owner.fetch(); let captured = owner.fetchProgress!; owner.finishFetch(captured); owner.fetch(); owner.options.remote = "wrong"; owner.options.tags = .disabled
        try await waitUntil { !owner.busy }
        precondition(owner.operationActive && owner.fetchProgress === captured && completed == 1 && changes == 1 && closes == 0)
        precondition(captured.success && captured.options.remote == "origin" && captured.options.tags == .enabled && captured.options.prune == .enabled)
        precondition(captured.postActions == [.log,.reset,.fetch,.rebase,.switchBranch])
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout, tracking = try await repo.run(["rev-parse","refs/remotes/origin/main"]).stdout
        let afterIndex = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index")), afterWorking = try Data(contentsOf: clientRoot.appendingPathComponent("file"))
        precondition(afterHead == head && tracking == remote && index == afterIndex && working == afterWorking)
        owner.fetch(); precondition(owner.fetchProgress === captured && !owner.busy)
        var reset: String?, handoffs = 0
        owner.onFetchPostAction = { _, _ in preconditionFailure("Callback must be captured before operation") }
        captured.onPostAction = { action, revision in precondition(action == .reset); reset = revision; handoffs += 1 }
        _ = try await repo.run(["config","branch.main.merge","refs/heads/topic"])
        captured.perform(.reset); captured.perform(.reset); try await waitUntil { !captured.dispatchingAction }
        let resetHead = try await repo.run(["rev-parse","HEAD"]).stdout
        precondition(reset == "refs/remotes/origin/topic" && handoffs == 1 && closes == 1 && owner.fetchProgress == nil && resetHead == head)
        var options = FetchOptions(); options.remote = "origin"; options.tags = .enabled
        _ = try await repo.run(["remote","set-url","origin",root.appendingPathComponent("missing").path])
        let retry = FetchProgressWindowModel(repository: repo, access: nil, options: options, preferences: preferences)
        var results = 0; retry.onCompleted = { results += 1 }
        await retry.run(); precondition(!retry.success && retry.postActions == [.retry] && results == 1)
        _ = try await repo.run(["remote","set-url","origin",producerRoot.path])
        retry.perform(.retry); retry.perform(.retry); try await waitUntil { !retry.busy }
        precondition(retry.success && results == 2 && retry.options.tags == .enabled && retry.postActions == [.log,.reset,.fetch,.rebase,.switchBranch])
        var action: FetchPostAction?, actionClosed = 0
        retry.close = { actionClosed += 1 }; retry.onPostAction = { value, _ in action = value }
        retry.perform(.log); retry.perform(.switchBranch); precondition(action == .log && actionClosed == 1)
        // A failed all-remotes fetch retains a successfully fetched remote and offers Log.
        try Data("partial next\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "partial next")
        let partial = try await producer.run(["rev-parse","HEAD"]).stdout
        _ = try await repo.run(["remote","add","bad",root.appendingPathComponent("missing-all").path])
        var all = options; all.allRemotes = true
        let allFailure = FetchProgressWindowModel(repository: repo, access: nil, options: all, preferences: preferences)
        await allFailure.run(); precondition(!allFailure.success && allFailure.postActions == [.retry,.log])
        let partialTracking = try await repo.run(["rev-parse","refs/remotes/origin/main"]).stdout
        precondition(partialTracking == partial)
        _ = try await repo.run(["remote","remove","bad"]); allFailure.perform(.retry); try await waitUntil { !allFailure.busy }; precondition(allFailure.success)
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await producer.run(["clone","--bare",producerRoot.path,bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git); _ = try await bare.run(["config","core.hooksPath","/dev/null"])
        let bareProgress = FetchProgressWindowModel(repository: bare, access: nil, options: options, preferences: preferences)
        await bareProgress.run(); precondition(bareProgress.success && bareProgress.postActions == [.log,.reset,.fetch,.switchBranch])
        let invalid = FetchProgressWindowModel(repository: repo, access: nil, options: options, preferences: preferences); invalid.invalidate(); await invalid.run(); precondition(invalid.busy && invalid.output.isEmpty)
        precondition(FetchPostAction.retry.icon == .refresh && MenuIcon.refresh.image() != nil && MergeAbortPostAction.retry.icon == .refresh)
        print("Ordinary Fetch progress: captured options and retained owner/result; exact success/failure/bare/all-remotes action lists; HEAD/index/working bytes preserved while tracking updates; fresh Reset defaults without mutation; captured Retry and duplicate action guards; real all-remotes partial update preserved; original refresh ICO available, Abort Retry corrected. No windows, standard preference or clipboard writes.")
    }
}
