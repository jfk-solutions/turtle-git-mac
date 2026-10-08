import AppKit
import SwiftUI
import TurtleGitCore

@main struct ProgressAutoCloseVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(),"Auto-close progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.ProgressAutoClose.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        precondition(GitProgressAutoClose(preferences:prefs) == .manual)
        for invalid in [-1,3,100] { prefs.set(invalid,forKey:"AutoCloseGitProgress"); precondition(GitProgressAutoClose(preferences:prefs) == .manual && prefs.integer(forKey:"AutoCloseGitProgress") == invalid) }
        let sourceRoot = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at:sourceRoot,withIntermediateDirectories:true)
        let source = GitRepository(root:sourceRoot,executable:git); _ = try await source.run(["init","-b","main"])
        for (key,value) in [("user.name","Auto-close QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await source.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:sourceRoot.appendingPathComponent("file")); try await source.stage(["file"]); _ = try await source.commit(message:"base")
        for policy in GitProgressAutoClose.allCases {
            prefs.set(policy.rawValue,forKey:"AutoCloseGitProgress")
            let clientRoot = root.appendingPathComponent("client-" + String(policy.rawValue)); _ = try await source.run(["clone",sourceRoot.path,clientRoot.path])
            let repo = GitRepository(root:clientRoot,executable:git)
            for (key,value) in [("user.name","Auto-close QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("pull.rebase","false")] { _ = try await repo.run(["config",key,value]) }
            _ = try await repo.run(["tag","base-tag"]); _ = try await repo.run(["branch","topic"])
            var fetchOptions = FetchOptions(); fetchOptions.remote = "origin"; fetchOptions.branch = "main"
            let fetch = FetchProgressWindowModel(repository:repo,access:nil,options:fetchOptions,preferences:prefs); var fetchClosed = 0
            fetch.close = { fetchClosed += 1 }; await fetch.run()
            precondition(fetch.success && !fetch.postActions.isEmpty && fetchClosed == (policy == .noErrors ? 1 : 0))
            var pullOptions = PullOptions(); pullOptions.fetch = fetchOptions
            let pull = PullProgressWindowModel(repository:repo,access:nil,options:pullOptions,followUp:PullFollowUp(),preferences:prefs); var pullClosed = 0
            pull.close = { pullClosed += 1 }; await pull.run()
            precondition(pull.success && !pull.postActions.isEmpty && pullClosed == (policy == .noErrors ? 1 : 0))
            var mergeOptions = MergeOptions(); mergeOptions.revision = "refs/tags/base-tag"
            let merge = MergeProgressWindowModel(repository:repo,access:nil,options:mergeOptions,target:.tag,showStashPop:false,preferences:prefs); var mergeClosed = 0
            merge.close = { mergeClosed += 1 }; await merge.run()
            precondition(merge.success && merge.postActions.isEmpty && mergeClosed == (policy == .manual ? 0 : 1))
            mergeOptions.noCommit = true
            let mergeOptionsRemain = MergeProgressWindowModel(repository:repo,access:nil,options:mergeOptions,target:.tag,showStashPop:false,preferences:prefs); var mergeRetainedClosed = 0
            mergeOptionsRemain.close = { mergeRetainedClosed += 1 }; await mergeOptionsRemain.run()
            precondition(mergeOptionsRemain.success && mergeOptionsRemain.postActions == [.commit] && mergeRetainedClosed == (policy == .noErrors ? 1 : 0))
            let abort = MergeAbortWindowModel(repository:repo,access:nil,preferences:prefs); var abortClosed = 0
            abort.close = { abortClosed += 1 }; abort.abort(); try await wait { !abort.busy }
            precondition(abort.success && abort.postActions.isEmpty && abortClosed == (policy == .manual ? 0 : 1))
            let hard = MergeAbortWindowModel(repository:repo,access:nil,preferences:prefs); var hardClosed = 0
            hard.mode = .hard; hard.close = { hardClosed += 1 }; hard.abort(); try await wait { !hard.busy }
            precondition(hard.success && hard.postActions.contains(.clean) && hardClosed == (policy == .noErrors ? 1 : 0))
            let stash = StashSaveProgressWindowModel(repository:repo,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(),preferences:prefs); var stashClosed = 0
            stash.close = { stashClosed += 1 }; await stash.run()
            precondition(stash.success && stash.result?.created == false && stash.postActions.isEmpty && stashClosed == (policy == .manual ? 0 : 1))
            let follow = StashSaveProgressWindowModel(repository:repo,access:nil,options:StashSaveOptions(),followUp:StashSaveFollowUp(showPull:true),preferences:prefs); var followClosed = 0
            follow.close = { followClosed += 1 }; await follow.run()
            precondition(follow.success && follow.postActions == [.pull] && followClosed == (policy == .noErrors ? 1 : 0))
            let checkout = SwitchProgressWindowModel(repository:repo,access:nil,reference:"refs/heads/topic",preferences:prefs); var switchClosed = 0
            checkout.close = { switchClosed += 1 }; await checkout.run()
            precondition(checkout.success && !checkout.postActions.isEmpty && switchClosed == (policy == .noErrors ? 1 : 0))
            let commit = CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
            commit.reload(paths:["."]); try await wait { !commit.busy && commit.changelistsLoaded }
            commit.message = "policy empty commit"; commit.messageOnly = true
            var commitClosed = 0; commit.close = { commitClosed += 1 }; commit.onCommitProgress = { _ in }
            commit.commit()
            try await wait { policy == .noErrors ? !commit.busy : commit.commitProgress?.busy == false }
            if policy == .noErrors { precondition(commitClosed == 1 && commit.commitProgress == nil) }
            else { precondition(commitClosed == 0 && commit.commitProgress!.success); commit.commitProgress!.choose(nil); try await wait { !commit.busy }; precondition(commitClosed == 1) }
            var badOptions = FetchOptions(); badOptions.remote = "missing"
            let badFetch = FetchProgressWindowModel(repository:repo,access:nil,options:badOptions,preferences:prefs); var badClosed = 0
            badFetch.close = { badClosed += 1 }; await badFetch.run(); precondition(!badFetch.success && badClosed == 0)
            var badMergeOptions = MergeOptions(); badMergeOptions.revision = "missing"
            let badMerge = MergeProgressWindowModel(repository:repo,access:nil,options:badMergeOptions,target:.branch,showStashPop:false,preferences:prefs)
            badMerge.close = { badClosed += 1 }; await badMerge.run(); precondition(!badMerge.success && badClosed == 0)
            let badSwitch = SwitchProgressWindowModel(repository:repo,access:nil,reference:"refs/heads/missing",preferences:prefs)
            badSwitch.close = { badClosed += 1 }; await badSwitch.run(); precondition(!badSwitch.success && badClosed == 0)
            var badPullOptions = PullOptions(); badPullOptions.fetch = badOptions
            let badPull = PullProgressWindowModel(repository:repo,access:nil,options:badPullOptions,followUp:PullFollowUp(),preferences:prefs)
            badPull.close = { badClosed += 1 }; await badPull.run(); precondition(!badPull.success && badClosed == 0)
        }
        prefs.set(2,forKey:"AutoCloseGitProgress")
        var options = FetchOptions(); options.remote = "origin"
        let repo = GitRepository(root:root.appendingPathComponent("client-0"),executable:git)
        let captured = FetchProgressWindowModel(repository:repo,access:nil,options:options,preferences:prefs); var closed = 0
        captured.close = { closed += 1 }; prefs.set(0,forKey:"AutoCloseGitProgress"); await captured.run(); precondition(captured.success && closed == 1)
        let fresh = FetchProgressWindowModel(repository:repo,access:nil,options:options,preferences:prefs); fresh.close = { closed += 1 }; await fresh.run(); precondition(fresh.success && closed == 1)
        let hooks = repo.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        let hook = hooks.appendingPathComponent("pre-commit"); try Data("#!/bin/sh\nexit 1\n".utf8).write(to:hook); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        _ = try await repo.run(["config","core.hooksPath",hooks.path]); prefs.set(2,forKey:"AutoCloseGitProgress")
        let failure = CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        failure.reload(paths:["."]); try await wait { !failure.busy && failure.changelistsLoaded }; failure.message = "rejected"; failure.messageOnly = true; failure.onCommitProgress = { _ in }
        var failureClosed = 0; failure.close = { failureClosed += 1 }; failure.commit(); try await wait { failure.commitProgress?.busy == false }
        precondition(!failure.commitProgress!.success && failureClosed == 0); failure.commitProgress!.choose(nil); try await wait { !failure.busy }; precondition(failureClosed == 0)
        let host = NSHostingView(rootView:LogDialogSettings().defaultAppStorage(prefs)); host.frame = NSRect(x:0,y:0,width:800,height:600); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        print("Git progress auto-close: three source policies across actual Commit/Fetch/Pull/Merge/Abort/Stash/Switch results; zero versus available post-actions; successful empty cases, retained failures and hook rejection; preference snapshot/reopen; private hidden settings layout. No windows, standard preferences or clipboard writes.")
    }
}
