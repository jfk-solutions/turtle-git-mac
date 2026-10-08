import AppKit
import TurtleGitCore

@main struct MergeProgressVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native merge timed out")
    }
    static func fixture(_ root: URL, git: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Merge QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        return repo
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = try await fixture(root, git: git)
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: root.appendingPathComponent("feature")); try await repo.stage(["feature"]); _ = try await repo.commit(message: "feature")
        _ = try await repo.run(["switch", "main"])
        let model = MergeWindowModel(repository: repo, access: nil)
        model.load(revision: "refs/heads/feature"); try await wait { model.busy }
        model.options.noFastForward = true; model.options.noCommit = true; model.message = "captured message 雪"; model.showStashPop = true
        var changes = 0, closed = 0; model.onChanged = { _ in changes += 1 }; model.close = { closed += 1 }
        model.merge(); let captured = model.progress!; model.message = "edited"; model.merge(); precondition(model.progress === captured)
        try await wait { captured.busy }
        precondition(captured.success && captured.postActions == [.stashPop, .commit] && model.busy && closed == 0 && changes == 1)
        let message = try await repo.commitMessageSeed().message; precondition(message.contains("captured message 雪") && !message.contains("edited"))
        captured.close(); precondition(!model.busy && model.progress == nil && closed == 1)
        _ = try await repo.run(["merge", "--abort"])
        var options = MergeOptions(); options.revision = "refs/heads/feature"
        let ordinary = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false)
        var dispatched: [MergePostAction] = [], target = ""; ordinary.onPostAction = { action, request in dispatched.append(action); target = request.revision }
        await ordinary.run(); precondition(ordinary.success && ordinary.postActions == [.removeBranch, .push])
        var answer: ((Bool) -> Void)?, prompts = 0
        ordinary.confirmDeletion = { branch, choose in precondition(branch == "feature"); prompts += 1; answer = choose }
        let mergedHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        ordinary.perform(.removeBranch); ordinary.perform(.removeBranch); precondition(ordinary.confirmingDeletion && prompts == 1)
        answer?(false); precondition(!ordinary.confirmingDeletion)
        _ = try await repo.run(["show-ref", "--verify", "refs/heads/feature"])
        ordinary.perform(.removeBranch); answer?(true); answer?(true); try await wait { ordinary.busy }
        precondition(ordinary.deletionError == nil && ordinary.postActions == [.push])
        let removed = try await repo.run(["show-ref", "--verify", "--quiet", "refs/heads/feature"], successfulExitCodes: 0...1).exitCode
        let afterDeleteHead = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(removed == 1 && mergedHead == afterDeleteHead)
        ordinary.perform(.push); precondition(dispatched == [.push] && target == options.revision)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/topic", "HEAD"])
        options.revision = "refs/remotes/origin/topic"
        let remote = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false)
        await remote.run(); precondition(remote.success && remote.postActions == [.push])
        options.revision = "HEAD"; options.squash = true
        let squash = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .commit, showStashPop: true)
        await squash.run(); precondition(squash.success && squash.postActions == [.stashPop, .commit])
        let conflictRoot = root.appendingPathComponent("conflict"), conflictRepo = try await fixture(conflictRoot, git: git)
        _ = try await conflictRepo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: conflictRoot.appendingPathComponent("file")); try await conflictRepo.stage(["file"]); _ = try await conflictRepo.commit(message: "theirs")
        _ = try await conflictRepo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: conflictRoot.appendingPathComponent("file")); try await conflictRepo.stage(["file"]); _ = try await conflictRepo.commit(message: "ours")
        options = MergeOptions(); options.revision = "refs/heads/feature"
        let conflict = MergeProgressWindowModel(repository: conflictRepo, access: nil, options: options, target: .branch, showStashPop: true)
        await conflict.run(); precondition(!conflict.success && conflict.postActions == [.resolve, .commit, .stash])
        let unmerged = try await conflictRepo.status(refreshIndex: false); precondition(unmerged.contains { $0.state == .conflicted })
        var recovery: [MergePostAction] = []; conflict.onPostAction = { action, request in recovery.append(action); precondition(request.revision == "refs/heads/feature") }
        conflict.perform(.stash); precondition(recovery == [.stash])
        let unrelatedRoot = root.appendingPathComponent("unrelated"), unrelatedRepo = try await fixture(unrelatedRoot, git: git)
        _ = try await unrelatedRepo.run(["checkout", "--orphan", "other"]); _ = try await unrelatedRepo.run(["rm", "-rf", "--", "."])
        try Data("other\n".utf8).write(to: unrelatedRoot.appendingPathComponent("other")); try await unrelatedRepo.stage(["other"]); _ = try await unrelatedRepo.commit(message: "other")
        _ = try await unrelatedRepo.run(["switch", "main"])
        options.revision = "refs/heads/other"
        let unrelated = MergeProgressWindowModel(repository: unrelatedRepo, access: nil, options: options, target: .branch, showStashPop: true)
        await unrelated.run(); precondition(!unrelated.success && unrelated.postActions == [.mergeUnrelated, .stash])
        unrelated.perform(.mergeUnrelated); try await wait { unrelated.busy }; precondition(unrelated.success && unrelated.postActions == [.stashPop, .removeBranch, .push])
        let parents = try await unrelatedRepo.run(["rev-list", "--parents", "-n", "1", "HEAD"]).text.split(whereSeparator: \.isWhitespace); precondition(parents.count == 3)
        let beforeCancel = try await unrelatedRepo.run(["rev-parse", "HEAD"]).stdout
        let cancelled = MergeProgressWindowModel(repository: unrelatedRepo, access: nil, options: options, target: .branch, showStashPop: true)
        cancelled.cancel(); await cancelled.run(); precondition(cancelled.cancelled && !cancelled.success && cancelled.postActions == [.stash])
        let afterCancel = try await unrelatedRepo.run(["rev-parse", "HEAD"]).stdout; precondition(beforeCancel == afterCancel)
        model.invalidate(); model.merge(); precondition(model.progress == nil)
        precondition(MergePostAction.allCases.map(\.icon) == [.resolve, .commit, .merge, .stash, .stashPop, .remove, .push])
        print("Merge progress: actual options/message snapshot, No Commit/Squash conditional Commit and optional Stash Pop, retained result/close, local force-delete confirmation Abort/Continue/duplicate guard and HEAD preservation, remote exclusion, Push handoff, real conflicts Resolve/Commit/Stash with target, unrelated roots explicit retry creates two parents, pre-cancellation and invalidation passed; no windows/preferences/clipboard")
    }
}
