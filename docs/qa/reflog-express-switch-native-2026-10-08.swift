import AppKit
import TurtleGitCore

@main struct ReferenceLogExpressSwitchVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native operation timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Switch QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<3 { try Data("commit \(n)\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil)
        let current = model.entries[0], older = model.entries[1]
        _ = try await repo.run(["branch", "same", current.hash]); _ = try await repo.run(["branch", "topic", older.hash])
        _ = try await repo.run(["update-ref", "refs/remotes/remote/topic", older.hash]); _ = try await repo.run(["tag", "tag", older.hash])
        model.reload(); try await wait { model.busy }
        precondition(model.switchBranches([current.id]) == ["refs/heads/same"], "Other branches at HEAD remain eligible; current main is excluded")
        precondition(model.switchBranches([older.id]) == ["refs/heads/topic"])
        _ = try await repo.run(["branch", "alpha", older.hash]); model.reload(); try await wait { model.busy }
        precondition(model.switchBranches([older.id]) == ["refs/heads/alpha", "refs/heads/topic"])
        var dispatches: [String] = []
        model.onSwitchBranch = { dispatches.append($0) }
        model.switchBranch("refs/heads/topic", ids: [older.id]); precondition(dispatches == ["refs/heads/topic"])
        for ids: Set<String> in [[], ["invalid"], [older.id, current.id]] { precondition(model.switchBranches(ids).isEmpty); model.switchBranch("refs/heads/topic", ids: ids) }
        model.switchBranch("refs/heads/main", ids: [current.id]); model.switchBranch("refs/remotes/remote/topic", ids: [older.id])
        model.busy = true; model.switchBranch("refs/heads/topic", ids: [older.id]); model.busy = false; precondition(dispatches.count == 1)
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait { chooser.busy }; precondition(chooser.switchBranches([older.id]).isEmpty)
        let progress = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/same")
        var completed: [Bool] = [], post: [SwitchPostAction] = [], mergeBranch = "", closes = 0
        progress.onFinished = { _, success in completed.append(success) }
        progress.onPostAction = { action, branch in post.append(action); mergeBranch = branch }
        progress.close = { closes += 1 }
        progress.perform(.commit); precondition(post.isEmpty)
        await progress.run(); precondition(progress.success && !progress.busy && progress.previousBranch == "main")
        precondition(progress.postActions == [.mergePreviousBranch, .pull, .commit] && completed == [true])
        let same = try await repo.branch(); precondition(same == "same")
        progress.perform(.mergePreviousBranch); precondition(post == [.mergePreviousBranch] && mergeBranch == "main" && closes == 1)
        progress.perform(.retry); precondition(!progress.busy, "Unavailable post-action must not run")
        _ = try await repo.run(["switch", "main"])
        try Data("dirty local\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let failure = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/topic")
        var results: [Bool] = []; failure.onFinished = { _, success in results.append(success) }
        await failure.run(); precondition(!failure.success && failure.postActions == [.stash, .retry, .switchWithMerge])
        let failedHead = try await repo.run(["rev-parse", "HEAD"]).stdout, failedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), failedFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == failedHead && index == failedIndex && file == failedFile, "Ordinary failed switch must preserve local changes")
        failure.perform(.switchWithMerge); try await wait { failure.busy }
        precondition(!failure.success && failure.postActions == [.resolve, .retry] && failure.output.contains("Has merge conflict"))
        let conflicts = try await repo.status(refreshIndex: false); precondition(conflicts.contains { $0.state == .conflicted })
        _ = try await repo.run(["reset", "--hard"])
        failure.perform(.retry); try await wait { failure.busy }; precondition(failure.success && results == [false, false, true])
        let cancelled = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/main")
        let cancelHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        cancelled.cancel(); await cancelled.run(); precondition(cancelled.cancelled && !cancelled.success && !cancelled.busy)
        let afterCancel = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(cancelHead == afterCancel)
        let missing = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/deleted")
        await missing.run(); precondition(!missing.success && missing.postActions == [.stash, .retry, .switchWithMerge])
        _ = try await repo.run(["switch", "--detach", "HEAD"])
        let detached = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/same")
        await detached.run(); precondition(detached.success && detached.previousBranch.isEmpty && detached.postActions == [.pull, .commit])
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + current.hash + ",child"])
        _ = try await repo.commit(message: "gitlink fixture")
        _ = try await repo.run(["branch", "with-modules", "HEAD"])
        let modules = SwitchProgressWindowModel(repository: repo, access: nil, reference: "refs/heads/with-modules")
        await modules.run(); precondition(modules.success && modules.postActions == [.submoduleUpdate, .mergePreviousBranch, .pull, .commit])
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git)
        _ = try await bare.run(["config", "user.name", "Switch QA"]); _ = try await bare.run(["config", "user.email", "qa@example.invalid"])
        _ = try await bare.run(["update-ref", "--create-reflog", "refs/heads/qa", older.hash])
        let bareModel = ReferenceLogWindowModel(repository: bare, access: nil, reference: "refs/heads/qa")
        bareModel.reload(); try await wait { bareModel.busy }; precondition(bareModel.error == nil && bareModel.switchBranches([bareModel.entries[0].id]).isEmpty)
        let bareProgress = SwitchProgressWindowModel(repository: bare, access: nil, reference: "refs/heads/qa")
        await bareProgress.run(); precondition(!bareProgress.success)
        let unbornRoot = root.appendingPathComponent("unborn")
        _ = try await repo.run(["clone", "--no-checkout", root.path, unbornRoot.path])
        let unbornRepo = GitRepository(root: unbornRoot, executable: git)
        _ = try await unbornRepo.run(["config", "user.name", "Switch QA"]); _ = try await unbornRepo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await unbornRepo.run(["symbolic-ref", "HEAD", "refs/heads/unborn"])
        _ = try await unbornRepo.run(["update-ref", "--create-reflog", "refs/heads/topic", older.hash])
        let unborn = ReferenceLogWindowModel(repository: unbornRepo, access: nil, reference: "refs/heads/topic")
        unborn.reload(); try await wait { unborn.busy }; precondition(unborn.error == nil && unborn.currentHeadHash == nil && unborn.switchBranches([unborn.entries[0].id]) == ["refs/heads/topic"])
        let fromUnborn = SwitchProgressWindowModel(repository: unbornRepo, access: nil, reference: "refs/heads/topic")
        await fromUnborn.run(); precondition(fromUnborn.success && fromUnborn.previousBranch == "unborn")
        let attached = try await unbornRepo.branch(); precondition(attached == "topic")
        model.invalidate(); precondition(model.switchBranches([older.id]).isEmpty)
        precondition(SwitchPostAction.allCases.map(\.icon) == [.fetch, .merge, .pull, .commit, .resolve, .stash, .mergeReload, .checkout])
        print("RefLog express Switch: sorted single/multiple local refs, current branch exclusion, other branch at HEAD, remote/tag exclusion, selection/busy/chooser/invalidation guards; direct native model switch with prior-branch post-action, dirty failure preserves HEAD/index/file, merge reports conflicts despite Git exit zero, Resolve/Retry and successful retry, missing branch, pre-cancellation, detached-source/submodule post-actions, bare guards and unborn-to-existing branch switch passed; no windows/preferences/clipboard")
    }
}
