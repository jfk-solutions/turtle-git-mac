import AppKit
import TurtleGitCore

@main struct FetchRebaseDecisionsVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Fetch/Rebase decision timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let sourceRoot = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let source = GitRepository(root: sourceRoot, executable: git)
        _ = try await source.run(["init","-b","main"])
        for (key,value) in [("user.name","Fetch Rebase QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await source.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: sourceRoot.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "base")
        let base = try await source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        let suite = "TurtleGit.FetchRebaseDecisions.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        func clear() { for prompt in FetchRebasePrompt.allCases { preferences.removeObject(forKey: prompt.rawValue) } }
        func clone(_ name: String) async throws -> GitRepository {
            let path = root.appendingPathComponent(name); _ = try await source.run(["clone",sourceRoot.path,path.path])
            let repo = GitRepository(root: path, executable: git)
            for (key,value) in [("user.name","Fetch Rebase QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            return repo
        }
        var options = FetchOptions(); options.remote = "origin"; options.branch = "main"
        func model(_ repo: GitRepository, _ mode: FetchRebaseMode = .manual) -> FetchProgressWindowModel {
            FetchProgressWindowModel(repository: repo, access: nil, options: options, preferences: preferences, rebaseMode: mode, preserveMerges: true)
        }
        let equal = try await clone("equal")
        let equality = try await equal.fetchForRebase(options)
        precondition(equality.currentIsUpToDate && equality.canFastForward && equality.unchangedAtHEAD && equality.oldUpstream == base && equality.head == base)
        let no = model(equal); var prompts: [FetchRebasePrompt] = [], handoffs = 0, closes = 0
        no.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 7, suppress: true) }
        no.onRebase = { _,_,_ in handoffs += 1 }; no.close = { closes += 1 }
        await no.run()
        precondition(prompts == [.upToDate] && no.success && handoffs == 0 && closes == 0 && no.postActions == [.log,.reset,.fetch,.switchBranch])
        precondition(preferences.integer(forKey: FetchRebasePrompt.upToDate.rawValue) == 7)
        let savedNo = model(equal); savedNo.presentRebasePrompt = { _ in preconditionFailure("Saved No must bypass presenter") }
        await savedNo.run(); precondition(savedNo.success); clear()

        let unchanged = model(equal); prompts = []
        unchanged.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: prompt == .upToDate ? 6 : 7, suppress: false) }
        await unchanged.run(); precondition(prompts == [.upToDate,.unchanged] && unchanged.postActions == [.log,.reset,.fetch,.switchBranch])
        precondition(preferences.object(forKey: FetchRebasePrompt.unchanged.rawValue) == nil)
        let allYes = model(equal); prompts = []; var target = ""
        allYes.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: prompt == .fastForward ? 2 : 6, suppress: true) }
        allYes.close = { closes += 1 }; allYes.onRebase = { hash, automatic, preserve in precondition(!automatic && preserve); target = hash; handoffs += 1 }
        await allYes.run(); precondition(prompts == [.upToDate,.unchanged,.fastForward] && target == base && handoffs == 1 && closes == 1)
        let savedYes = model(equal); savedYes.presentRebasePrompt = { _ in preconditionFailure("Saved answers must bypass presenter") }
        savedYes.onRebase = { hash,_,_ in precondition(hash == base); handoffs += 1 }; await savedYes.run()
        precondition(handoffs == 2); clear()
        let automatic = model(equal, .automatic); automatic.presentRebasePrompt = { _ in preconditionFailure("Automatic mode must bypass all prompts") }
        automatic.onRebase = { hash, auto, preserve in precondition(hash == base && auto && preserve); handoffs += 1 }
        await automatic.run(); precondition(handoffs == 3)

        let ahead = try await clone("ahead")
        try Data("local\n".utf8).write(to: ahead.root.appendingPathComponent("local")); try await ahead.stage(["local"]); _ = try await ahead.commit(message: "ahead")
        let aheadHead = try await ahead.run(["rev-parse","HEAD"]).text
        let aheadResult = try await ahead.fetchForRebase(options); precondition(aheadResult.currentIsUpToDate && !aheadResult.canFastForward && !aheadResult.unchangedAtHEAD)
        let aheadModel = model(ahead); prompts = []
        aheadModel.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 6, suppress: false) }
        aheadModel.onRebase = { hash,_,_ in precondition(hash == base); handoffs += 1 }
        await aheadModel.run(); let aheadAfter = try await ahead.run(["rev-parse","HEAD"]).text
        precondition(prompts == [.upToDate] && aheadAfter == aheadHead && handoffs == 4)

        let ff = try await clone("ff"), abort = try await clone("abort"), failed = try await clone("dirty"), conflicting = try await clone("conflicting")
        try Data("remote\n".utf8).write(to: sourceRoot.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "remote")
        let remote = try await source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        let diverged = model(ahead); diverged.presentRebasePrompt = { _ in preconditionFailure("Diverged branches need no prompt") }
        diverged.onRebase = { hash,_,_ in precondition(hash == remote); handoffs += 1 }; await diverged.run()
        precondition(handoffs == 5)

        let stopped = model(abort); prompts = []
        stopped.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 3, suppress: true) }
        stopped.onRebase = { _,_,_ in preconditionFailure("Abort must not open Rebase") }; await stopped.run()
        let abortHead = try await abort.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(prompts == [.fastForward] && stopped.success && abortHead == base && stopped.postActions == [.log,.reset,.fetch,.switchBranch])
        let savedAbort = model(abort); savedAbort.presentRebasePrompt = { _ in preconditionFailure("Saved Abort must bypass presenter") }
        await savedAbort.run(); let savedAbortHead = try await abort.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(savedAbort.success && savedAbortHead == base); clear()

        let owner = FetchWindowModel(repository: ff, access: nil, isPull: false, preferences: preferences)
        owner.load(); try await wait { !owner.busy }; owner.launchRebase = true
        var choice: CheckedContinuation<FetchRebaseAnswer,Never>?, changes = 0, ownerCloses = 0
        owner.onChanged = { _ in changes += 1 }; owner.close = { ownerCloses += 1 }
        owner.onRebase = { _,_,_ in preconditionFailure("Merge choice must not open Rebase") }
        owner.onFetchProgress = { progress in
            progress.presentRebasePrompt = { prompt in
                precondition(prompt == .fastForward)
                return await withCheckedContinuation { choice = $0 }
            }
        }
        owner.fetch(); let captured = owner.fetchProgress!; try await wait { choice != nil }
        precondition(captured.confirmingRebaseDecision && captured.busy && !captured.canCancel && owner.operationActive)
        owner.options.remote = "wrong"; owner.launchRebase = false; owner.fetch(); captured.cancel(); owner.finishFetch(captured)
        precondition(owner.fetchProgress === captured && !captured.cancelling && captured.confirmingRebaseDecision)
        choice!.resume(returning: FetchRebaseAnswer(value: 1, suppress: false)); try await wait { !owner.busy }
        let ffHead = try await ff.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(ffHead == remote && ownerCloses == 1 && owner.fetchProgress == nil && changes == 1 && captured.merging && captured.success)
        let ffBytes = try Data(contentsOf: ff.root.appendingPathComponent("file")); precondition(ffBytes == Data("remote\n".utf8))

        try Data("dirty\n".utf8).write(to: failed.root.appendingPathComponent("file"))
        let failure = model(failed); failure.presentRebasePrompt = { _ in FetchRebaseAnswer(value: 1, suppress: false) }
        await failure.run(); let failedHead = try await failed.run(["rev-parse","HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(!failure.success && failure.merging && failure.postActions.isEmpty && failedHead == base)
        let dirtyBytes = try Data(contentsOf: failed.root.appendingPathComponent("file")); precondition(dirtyBytes == Data("dirty\n".utf8))

        let conflict = model(conflicting)
        conflict.presentRebasePrompt = { _ in
            _ = try! await conflicting.run(["checkout","-b","side"])
            try! Data("side\n".utf8).write(to: conflicting.root.appendingPathComponent("file")); try! await conflicting.stage(["file"]); _ = try! await conflicting.commit(message: "side")
            _ = try! await conflicting.run(["checkout","main"])
            try! Data("main\n".utf8).write(to: conflicting.root.appendingPathComponent("file")); try! await conflicting.stage(["file"]); _ = try! await conflicting.commit(message: "main")
            _ = try? await conflicting.run(["merge","side"])
            return FetchRebaseAnswer(value: 1, suppress: false)
        }
        await conflict.run(); precondition(!conflict.success && conflict.postActions == [.resolve])
        var resolve = 0; conflict.onPostAction = { action,_ in precondition(action == .resolve); resolve += 1 }; conflict.perform(.resolve); conflict.perform(.resolve); precondition(resolve == 1)

        clear()
        let retry = model(abort); _ = try await abort.run(["remote","set-url","origin",root.appendingPathComponent("missing").path])
        await retry.run(); precondition(!retry.success && retry.postActions == [.retry] && !retry.confirmingRebaseDecision)
        _ = try await abort.run(["remote","set-url","origin",sourceRoot.path])
        retry.presentRebasePrompt = { _ in FetchRebaseAnswer(value: 2, suppress: false) }; retry.onRebase = { hash,_,_ in precondition(hash == remote); handoffs += 1 }
        retry.perform(.retry); retry.perform(.retry); try await wait { !retry.busy }; precondition(retry.success && handoffs == 6)

        clear()
        _ = try await equal.run(["config","pull.rebase","merges"])
        let automaticOwner = FetchWindowModel(repository: equal, access: nil, isPull: true, preferences: preferences)
        automaticOwner.load(); try await wait { !automaticOwner.busy }
        precondition(automaticOwner.configuredRebase && automaticOwner.launchRebase)
        var automaticCloses = 0
        automaticOwner.close = { automaticCloses += 1 }
        automaticOwner.onFetchProgress = { $0.presentRebasePrompt = { _ in preconditionFailure("Configured Pull/Rebase must not ask manual questions") } }
        automaticOwner.onRebase = { hash, auto, preserve in precondition(hash == remote && auto && preserve); handoffs += 1 }
        automaticOwner.fetch(); try await wait { !automaticOwner.busy }
        precondition(automaticCloses == 1 && automaticOwner.fetchProgress == nil && handoffs == 7)

        try Data("remote two\n".utf8).write(to: sourceRoot.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "remote two")
        let rememberMerge = model(ff)
        rememberMerge.presentRebasePrompt = { prompt in precondition(prompt == .fastForward); return FetchRebaseAnswer(value: 1, suppress: true) }
        await rememberMerge.run(); precondition(rememberMerge.success && rememberMerge.merging && preferences.integer(forKey: FetchRebasePrompt.fastForward.rawValue) == 1)
        try Data("remote three\n".utf8).write(to: sourceRoot.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message: "remote three")
        let third = try await source.run(["rev-parse","HEAD"]).text
        let savedMerge = model(ff); savedMerge.presentRebasePrompt = { _ in preconditionFailure("Saved Merge must bypass presenter") }
        await savedMerge.run(); let thirdLocal = try await ff.run(["rev-parse","HEAD"]).text
        precondition(savedMerge.success && savedMerge.merging && thirdLocal == third)

        print("Fetch/Rebase: equal/ahead/diverged/fast-forward classification; source sequential prompts and saved Yes/No/three-way answers; automatic/preserve-merges handoff; immutable target; Merge/Abort/Rebase; owner locking and duplicate/cancel gates during held prompt; real fast-forward and dirty/conflicted failure actions; captured retry. No windows, user pasteboard or standard preference writes.")
    }
}
