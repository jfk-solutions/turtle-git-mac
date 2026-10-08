import AppKit
import TurtleGitCore

@main struct CommitLastActionVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Remembered Commit action timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.CommitLastAction.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        func fixture(_ name: String) async throws -> GitRepository {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let repo = GitRepository(root: path, executable: git); _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Remembered Action QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("base\n".utf8).write(to:path.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
            try Data("next\n".utf8).write(to:path.appendingPathComponent("file"))
            return repo
        }
        func owner(_ repo: GitRepository) async throws -> CommitWindowModel {
            let model = CommitWindowModel(repository:repo,access:nil,unversionedDefaults:preferences,dialogDefaults:preferences)
            model.reload(paths:["."]); try await wait { !model.busy && model.changelistsLoaded }
            model.message = "remembered action"; model.checked = ["file"]; return model
        }
        let repo = try await fixture("primary")
        for invalid in [-1,3,100] {
            preferences.set(invalid,forKey:"CommitLastAction")
            let model = try await owner(repo)
            precondition(model.currentCompletionAction == .commit && preferences.integer(forKey:"CommitLastAction") == invalid)
        }
        preferences.removeObject(forKey:"CommitLastAction")
        let defaults = try await owner(repo); precondition(defaults.currentCompletionAction == .commit)
        for action in CommitWindowModel.CompletionAction.allCases {
            preferences.set(action.sourceIndex,forKey:"CommitLastAction")
            let model = try await owner(repo); precondition(model.currentCompletionAction == action && model.completionAction == action)
        }
        preferences.set(2,forKey:"CommitLastAction")
        let existing = try await owner(repo)
        preferences.set(1,forKey:"CommitLastAction")
        let otherRepo = try await fixture("other"), fresh = try await owner(otherRepo)
        precondition(existing.currentCompletionAction == .push && fresh.currentCompletionAction == .recommit)
        var pushes = 0, closes = 0, progressCloses = 0
        existing.onPush = { pushes += 1 }; existing.close = { closes += 1 }
        existing.onCommitProgress = { $0.onClose = { progressCloses += 1 } }
        existing.commitCurrentAction(); try await wait { !existing.busy }
        precondition(pushes == 1 && closes == 1 && progressCloses == 1 && preferences.integer(forKey:"CommitLastAction") == 2)
        let committed = try await repo.run(["show","HEAD:file"]).stdout
        precondition(committed == Data("next\n".utf8))
        fresh.onCommitProgress = { _ in }; fresh.commitCurrentAction(); try await wait { !fresh.busy }
        precondition(fresh.message.isEmpty && fresh.currentCompletionAction == .recommit && preferences.integer(forKey:"CommitLastAction") == 1)

        let normalRepo = try await fixture("normal"), normal = try await owner(normalRepo)
        normal.onCommitProgress = { _ in }; normal.commit(.commit)
        try await wait { normal.commitProgress?.busy == false }
        precondition(normal.currentCompletionAction == .commit && preferences.integer(forKey:"CommitLastAction") == 1)
        normal.commit(.push); precondition(normal.currentCompletionAction == .commit)
        normal.commitProgress!.choose(.recommit); try await wait { !normal.busy }
        precondition(normal.currentCompletionAction == .commit && preferences.integer(forKey:"CommitLastAction") == 0)

        let failedRepo = try await fixture("failure"), failed = try await owner(failedRepo)
        let hooks = failedRepo.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to:hook); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
        _ = try await failedRepo.run(["config","core.hooksPath",hooks.path])
        failed.onCommitProgress = { _ in }; let before = try await failedRepo.run(["rev-parse","HEAD"]).stdout
        failed.commit(.push); try await wait { failed.commitProgress?.busy == false }
        precondition(!failed.commitProgress!.success && failed.currentCompletionAction == .push && preferences.integer(forKey:"CommitLastAction") == 0)
        failed.commitProgress!.choose(nil); try await wait { !failed.busy }
        let after = try await failedRepo.run(["rev-parse","HEAD"]).stdout
        precondition(before == after && failed.message == "remembered action" && preferences.integer(forKey:"CommitLastAction") == 2)
        let retry = try await owner(failedRepo); precondition(retry.currentCompletionAction == .push)
        _ = try await failedRepo.run(["config","core.hooksPath","/dev/null"])
        retry.onCommitProgress = { _ in }; retry.onPush = { pushes += 1 }
        retry.commitCurrentAction(); try await wait { !retry.busy }; precondition(pushes == 2)

        let cancelledRepo = try await fixture("preflight"), cancelled = try await owner(cancelledRepo)
        let cancelledHead = try await cancelledRepo.run(["rev-parse","HEAD"]).text
        cancelled.message = "subject\n\n# Conflicts:\n#\tfile\n"; cancelled.confirmConflictHints = { $0(false,false) }
        cancelled.commit(.recommit); try await wait { !cancelled.busy }
        precondition(cancelled.completionAction == .recommit && cancelled.commitProgress == nil && preferences.integer(forKey:"CommitLastAction") == 2)
        let unchangedHead = try await cancelledRepo.run(["rev-parse","HEAD"]).text; precondition(cancelledHead == unchangedHead)

        let splitRepo = try await fixture("split"); _ = try await splitRepo.run(["reset","--hard","HEAD"])
        for file in ["left","right"] { try Data(file.utf8).write(to:splitRepo.root.appendingPathComponent(file)) }
        try await splitRepo.stage(["left","right"]); _ = try await splitRepo.commit(message:"split source")
        var options = RebaseOptions(); options.branch = "main"; options.upstream = "HEAD~1"; options.force = true
        var plan = try await splitRepo.rebasePlan(options); precondition(plan.entries.count == 1); plan.entries[0].action = .edit
        let editor = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")
        let pause = try await splitRepo.startRebase(plan,editorExecutable:editor); precondition(pause.state.canSplit)
        let split = try await splitRepo.beginRebaseSplit()
        let splitOwner = CommitWindowModel(repository:splitRepo,access:nil,unversionedDefaults:preferences,dialogDefaults:preferences)
        splitOwner.loadReplaySplit(split,message:"split left"); try await wait { !splitOwner.busy && splitOwner.changelistsLoaded }
        splitOwner.checked = ["left"]; precondition(splitOwner.completionAction == .push && splitOwner.currentCompletionAction == .commit)
        splitOwner.onCommitProgress = { _ in }; splitOwner.commit(.push); precondition(!splitOwner.busy)
        splitOwner.commitCurrentAction(); try await wait { !splitOwner.busy }
        let splitState = try await splitRepo.rebaseState()
        precondition(splitOwner.error == nil && splitState.split?.parts == 1 && preferences.integer(forKey:"CommitLastAction") == 2)
        _ = try await splitRepo.abortRebase()
        print("Commit remembered action: absent/invalid fallback, source indices, shared reopening and existing-window snapshot; actual repeated Push/ReCommit button actions; save only after result acknowledgement including hook failure; progress ReCommit leaves footer Commit; preflight Abort does not save; real Rebase Split forces Commit and preserves saved action. No windows, standard preference or user pasteboard writes.")
    }
}
