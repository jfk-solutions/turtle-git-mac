import AppKit
import TurtleGitCore

@main struct PullProgressVerification {
    @MainActor static func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Pull progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let producerRoot = root.appendingPathComponent("producer"), clientRoot = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: producerRoot, withIntermediateDirectories: true)
        let producer = GitRepository(root: producerRoot, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["clone", producerRoot.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("pull.rebase","false")] { _ = try await repo.run(["config",key,value]) }
        let suite = "TurtleGit.PullProgress.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        let old = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "next")
        let next = try await producer.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        let owner = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
        owner.load(); try await waitUntil { !owner.busy }
        owner.followUp = PullFollowUp(showPush: true, showStashPop: true); owner.fastForwardOnly = true
        var closes = 0, completions = 0, changes = 0, actions: [PullPostAction] = [], context: PullProgressContext?
        owner.close = { closes += 1 }; owner.onFetched = { _ in completions += 1 }; owner.onChanged = { _ in changes += 1 }
        owner.onPullPostAction = { action, result in actions.append(action); context = result }
        owner.fetch(); let retained = owner.progress!; owner.finish(retained); owner.fetch()
        owner.options.remote = "missing"; owner.followUp = PullFollowUp()
        try await waitUntil { !owner.busy }
        precondition(owner.progress === retained && closes == 0 && owner.operationActive && retained.success && completions == 1 && changes == 1)
        precondition(retained.options.fetch.remote == "origin" && retained.options.fastForwardOnly && retained.followUp.showPush && retained.followUp.showStashPop)
        precondition(retained.oldHead == old && retained.newHead == next && retained.postActions == [.stashPop,.diff,.log,.push])
        owner.fetch(); precondition(owner.progress === retained && !owner.busy)
        retained.perform(.diff); retained.perform(.log)
        precondition(actions == [.diff] && context?.oldHead == old && context?.newHead == next && closes == 1 && owner.progress == nil)
        var options = PullOptions(); options.fetch.remote = "origin"; options.fetch.branch = "main"
        let unchanged = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(), preferences: preferences)
        await unchanged.run(); precondition(unchanged.success && unchanged.oldHead == unchanged.newHead && unchanged.postActions == [.diff,.log])
        // Source Pull still offers Diff/Log when No Commit retains an unfinished merge.
        try Data("remote addition\n".utf8).write(to: producerRoot.appendingPathComponent("added")); try await producer.stage(["added"]); _ = try await producer.commit(message: "addition")
        var pending = options; pending.noCommit = true; pending.noFastForward = true
        let noCommit = PullProgressWindowModel(repository: repo, access: nil, options: pending, followUp: PullFollowUp(), preferences: preferences)
        await noCommit.run(); precondition(noCommit.success && noCommit.oldHead == noCommit.newHead && noCommit.postActions == [.diff,.log])
        _ = try await repo.run(["rev-parse","--verify","MERGE_HEAD"]); _ = try await repo.abortMerge()
        // Divergence creates a conflict; the hint blocks completion and source returns only Resolve/Commit.
        try Data("ours\n".utf8).write(to: clientRoot.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours")
        try Data("theirs\n".utf8).write(to: producerRoot.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "theirs")
        let conflict = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(showPush: true, showStashPop: true), preferences: preferences)
        var acknowledgement: CheckedContinuation<Bool,Never>?, hints = 0, finished = 0
        conflict.presentConflictHint = { hints += 1; return await withCheckedContinuation { acknowledgement = $0 } }; conflict.onCompleted = { finished += 1 }
        let operation = Task { await conflict.run() }
        try await waitUntil { conflict.confirmingConflictHint && acknowledgement != nil }
        precondition(conflict.busy && finished == 0 && conflict.postActions.isEmpty && !conflict.canCancel)
        conflict.cancel(); conflict.perform(.resolve); acknowledgement?.resume(returning: true); await operation.value
        precondition(!conflict.success && !conflict.cancelled && hints == 1 && finished == 1 && conflict.postActions == [.resolve,.commit])
        precondition(preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
        _ = try await repo.abortMerge()
        let suppressed = PullProgressWindowModel(repository: repo, access: nil, options: options, followUp: PullFollowUp(), preferences: preferences)
        suppressed.presentConflictHint = { preconditionFailure("Saved shared hint preference ignored") }; await suppressed.run()
        precondition(suppressed.postActions == [.resolve,.commit]); _ = try await repo.abortMerge()
        var ffOnly = options; ffOnly.fastForwardOnly = true
        let failure = PullProgressWindowModel(repository: repo, access: nil, options: ffOnly, followUp: PullFollowUp(), preferences: preferences)
        var reset: PullProgressContext?, resetClosed = 0
        failure.close = { resetClosed += 1 }; failure.onPostAction = { action, result in precondition(action == .reset); reset = result }
        await failure.run(); precondition(!failure.success && failure.postActions == [.pull,.stash,.reset])
        let beforeReset = try await repo.run(["rev-parse","HEAD"]).stdout
        failure.perform(.reset); failure.perform(.reset); try await waitUntil { !failure.dispatchingAction }
        let afterReset = try await repo.run(["rev-parse","HEAD"]).stdout
        precondition(reset?.resetRevision == "refs/remotes/origin/main" && resetClosed == 1 && beforeReset == afterReset)
        // Named unrelated remote offers an explicit retry; arbitrary URL does not.
        let otherRoot = root.appendingPathComponent("independent"); try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let other = GitRepository(root: otherRoot, executable: git); _ = try await other.run(["init","-b","main"])
        for (key,value) in [("user.name","Pull QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await other.run(["config",key,value]) }
        try Data("independent\n".utf8).write(to: otherRoot.appendingPathComponent("independent")); try await other.stage(["independent"]); _ = try await other.commit(message: "independent")
        _ = try await repo.run(["remote","add","other",otherRoot.path])
        var unrelated = options; unrelated.fetch.remote = "other"
        let retry = PullProgressWindowModel(repository: repo, access: nil, options: unrelated, followUp: PullFollowUp(showPush: true, showStashPop: true), preferences: preferences)
        await retry.run(); precondition(retry.postActions == [.mergeUnrelated,.pull,.stash,.reset] && !retry.success)
        retry.perform(.mergeUnrelated); retry.perform(.mergeUnrelated); try await waitUntil { !retry.busy }
        let parents = try await repo.run(["rev-list","--parents","-n","1","HEAD"]).text.split(whereSeparator: { $0.isWhitespace })
        precondition(retry.success && parents.count == 3 && !retry.options.allowUnrelatedHistories && retry.postActions == [.stashPop,.diff,.log,.push])
        var missing = options; missing.fetch.branch = "missing"
        let missingRef = PullProgressWindowModel(repository: repo, access: nil, options: missing, followUp: PullFollowUp(), preferences: preferences)
        await missingRef.run(); precondition(missingRef.postActions == [.mergeUnrelated,.pull,.stash,.reset])
        missing.fetch.arbitraryURL = true; missing.fetch.remote = producerRoot.path
        let arbitrary = PullProgressWindowModel(repository: repo, access: nil, options: missing, followUp: PullFollowUp(), preferences: preferences)
        await arbitrary.run(); precondition(arbitrary.postActions == [.pull,.stash,.reset])
        // Production follow-up conversion is shared by the native factory and this real-model chain.
        _ = try await repo.run(["config","branch.main.remote","other"]); _ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        try Data("stashed local edit\n".utf8).write(to: clientRoot.appendingPathComponent("independent"))
        var saveOptions = StashSaveOptions(); saveOptions.message = "Pull follow-up"
        var saveFollowUp = StashSaveFollowUp(); saveFollowUp.showPull = true; saveFollowUp.pullShowPush = true
        let save = StashSaveProgressWindowModel(repository: repo, access: nil, options: saveOptions, followUp: saveFollowUp)
        var chained: FetchWindowModel?
        save.onPostAction = { action, request in
            precondition(action == .pull && request.showPull && request.pullShowPush)
            let model = FetchWindowModel(repository: repo, access: nil, isPull: true, preferences: preferences)
            model.followUp = PullFollowUp(stashSave: request); chained = model
        }
        await save.run(); precondition(save.success && save.result?.created == true && save.postActions == [.pull,.pop,.apply])
        save.perform(.pull); let chainedOwner = chained!; chainedOwner.load(); try await waitUntil { !chainedOwner.busy }
        var popRequested = false
        chainedOwner.onPullPostAction = { action, result in precondition(action == .stashPop && result.followUp.showPush && result.followUp.showStashPop); popRequested = true }
        chainedOwner.fetch(); try await waitUntil { !chainedOwner.busy }
        precondition(chainedOwner.progress!.success && chainedOwner.progress!.postActions == [.stashPop,.diff,.log,.push])
        chainedOwner.progress!.perform(.stashPop); precondition(popRequested && chainedOwner.progress == nil)
        let popped = try await repo.restoreStash(pop: true)
        let restored = try Data(contentsOf: clientRoot.appendingPathComponent("independent")), stashes = try await repo.run(["stash","list"]).stdout
        precondition(!popped.conflicted && restored == Data("stashed local edit\n".utf8) && stashes.isEmpty)
        retry.invalidate(); retry.perform(.push)
        print("Pull progress: actual options/follow-up capture, retained result/close and duplicate gates; old/new HEAD Compare/Log, unchanged and No Commit cases; conflict hint waits/suppression with exact Resolve/Commit-only actions; non-conflict recovery and fresh tracked Hard-reset default without mutation; named unrelated retry creates two parents and preserves follow-ups. No windows or standard preference/clipboard writes.")
    }
}
