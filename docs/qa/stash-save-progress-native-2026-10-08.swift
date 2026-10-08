import AppKit
import TurtleGitCore

@main struct StashSaveProgressVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native stash operation timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Stash QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        var follow = StashSaveFollowUp(); follow.showPull = true; follow.pullShowPush = true; follow.mergeRevision = "refs/heads/topic"
        let noChange = StashSaveProgressWindowModel(repository: repo, access: nil, options: StashSaveOptions(), followUp: follow)
        var actions: [StashSavePostAction] = [], captured: StashSaveFollowUp?, closes = 0
        noChange.onPostAction = { action, request in actions.append(action); captured = request }; noChange.close = { closes += 1 }
        noChange.perform(.pull); precondition(actions.isEmpty)
        await noChange.run(); precondition(noChange.success && noChange.result?.created == false && noChange.postActions == [.pull, .merge])
        noChange.perform(.pop); precondition(actions.isEmpty)
        noChange.perform(.pull); precondition(actions == [.pull] && captured?.pullShowPush == true && captured?.mergeRevision == follow.mergeRevision && closes == 1)
        let model = StashWindowModel(repository: repo, access: nil)
        var saved = 0, failed = 0, closed = 0
        model.followUp = follow; model.onSaved = { _ in saved += 1 }; model.onFailed = { _ in failed += 1 }; model.close = { closed += 1 }
        try Data("staged\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("working\n".utf8).write(to: root.appendingPathComponent("file"))
        model.options.message = "snapshot 雪"; model.save()
        let progress = model.progress!; model.options.message = "edited after dispatch"; model.followUp.showPull = false
        model.save(); precondition(model.progress === progress)
        try await wait { progress.busy }
        precondition(progress.success && progress.postActions == [.pull, .merge, .pop, .apply] && saved == 1 && failed == 0 && model.busy && closed == 0)
        let subject = try await repo.run(["show", "-s", "--format=%s", "refs/stash"]).text
        let index = try await repo.run(["show", "refs/stash^2:file"]).text, file = try await repo.run(["show", "refs/stash:file"]).text
        precondition(subject.contains("snapshot 雪") && !subject.contains("edited after dispatch") && index == "staged\n" && file == "working\n")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(head == afterHead)
        progress.close(); precondition(!model.busy && model.progress == nil && closed == 1)
        let unchanged = StashSaveProgressWindowModel(repository: repo, access: nil, options: StashSaveOptions(), followUp: StashSaveFollowUp())
        await unchanged.run(); precondition(unchanged.success && unchanged.result?.created == false && unchanged.postActions.isEmpty)
        var invalid = StashSaveOptions(); invalid.message = "nul\0message"
        let failure = StashSaveProgressWindowModel(repository: repo, access: nil, options: invalid, followUp: follow)
        await failure.run(); precondition(!failure.success && failure.result == nil && failure.postActions.isEmpty)
        try Data("cancelled working\n".utf8).write(to: root.appendingPathComponent("file"))
        let stash = try await repo.run(["rev-parse", "refs/stash"]).stdout
        let cancelled = StashSaveProgressWindowModel(repository: repo, access: nil, options: StashSaveOptions(), followUp: follow)
        cancelled.cancel(); await cancelled.run(); precondition(cancelled.cancelled && !cancelled.success && cancelled.postActions.isEmpty)
        let afterStash = try await repo.run(["rev-parse", "refs/stash"]).stdout
        let cancelledFile = try String(contentsOf: root.appendingPathComponent("file"))
        precondition(stash == afterStash && cancelledFile == "cancelled working\n")
        let warning = StashWindowModel(repository: repo, access: nil, preferences: UserDefaults(suiteName: "TurtleGitStashProgressQA." + UUID().uuidString)!); warning.options.includeUntracked = true
        var answer: ((Bool) -> Void)?, prompts = 0
        warning.confirmUntracked = { choose in prompts += 1; answer = choose }
        warning.save(); warning.save(); precondition(prompts == 1 && warning.confirmingUntracked && !warning.busy)
        answer?(false); precondition(!warning.confirmingUntracked && warning.progress == nil)
        warning.save(); precondition(prompts == 2); warning.invalidate(); answer?(true); precondition(warning.progress == nil)
        precondition(StashSavePostAction.allCases.map(\.icon) == [.pull, .merge, .stashPop, .stashPop])
        print("Stash Save progress: actual option snapshot dispatch, separate index/worktree parents and HEAD preservation; Pull/Merge before created-only Pop/Apply, no-change suppression, captured follow-up flags, failure/no actions, pre-cancellation preserves stash/working file, busy dispatch/retained result/close and warning one-shot/Abort/invalidation gates passed; no windows/preferences/clipboard")
    }
}
