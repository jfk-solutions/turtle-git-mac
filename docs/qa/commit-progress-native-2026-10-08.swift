import AppKit
import TurtleGitCore

@main struct CommitProgressVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Commit progress timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.CommitProgress.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        func fixture(_ name: String) async throws -> GitRepository {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            let repo = GitRepository(root: path, executable: git); _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Commit Progress QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            for file in ["a 雪","b"] { try Data("base\n".utf8).write(to: path.appendingPathComponent(file)) }
            try await repo.stage(["a 雪","b"]); _ = try await repo.commit(message: "base")
            try Data("selected\n".utf8).write(to: path.appendingPathComponent("a 雪"))
            try Data("unchecked index\n".utf8).write(to: path.appendingPathComponent("b")); try await repo.stage(["b"])
            try Data("unchecked working\n".utf8).write(to: path.appendingPathComponent("b"))
            return repo
        }
        func owner(_ repo: GitRepository) async throws -> CommitWindowModel {
            let value = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: preferences, dialogDefaults: preferences)
            value.reload(paths: ["."]); try await wait { !value.busy && value.changelistsLoaded }
            value.message = "progress message"; value.checked = ["a 雪"]
            return value
        }
        for action in CommitPostAction.allCases {
            let repo = try await fixture(action.rawValue), model = try await owner(repo)
            var results = 0, closes = 0, push = 0, pull = 0, tag = 0
            model.onCommitted = { _ in results += 1 }; model.close = { closes += 1 }
            model.onPush = { push += 1 }; model.onPull = { pull += 1 }; model.onCreateTag = { tag += 1 }
            model.onCommitProgress = { _ in }
            model.commit(); try await wait { model.commitProgress?.busy == false }
            let progress = model.commitProgress!
            precondition(model.busy && !model.canCommit && results == 1 && closes == 0 && model.error == nil)
            precondition(progress.success && progress.postActions == [.push,.pull,.recommit,.createTag] && progress.paths == ["a 雪"] && !progress.staging)
            model.message = "changed after snapshot"; model.checked = ["b"]; model.commit(.push)
            let selected = try await repo.run(["show","HEAD:a 雪"]).stdout
            let unchecked = try await repo.run(["show",":b"]).stdout
            let working = try Data(contentsOf: repo.root.appendingPathComponent("b"))
            let body = try await repo.run(["log","-1","--format=%B"]).text
            precondition(selected == Data("selected\n".utf8) && unchecked == Data("unchecked index\n".utf8) && working == Data("unchecked working\n".utf8) && body.contains("progress message") && !body.contains("changed after snapshot"))
            progress.choose(action); progress.choose(action); try await wait { !model.busy }
            precondition(model.commitProgress == nil && results == 1 && push == (action == .push ? 1 : 0) && pull == (action == .pull ? 1 : 0) && tag == (action == .createTag ? 1 : 0))
            if action == .recommit { precondition(closes == 0 && model.message.isEmpty && !model.amend && !model.messageOnly && model.checked.contains("b")) }
            else { precondition(closes == 1) }
        }
        for action in [CommitWindowModel.CompletionAction.recommit,.push] {
            let repo = try await fixture("footer-" + action.rawValue), model = try await owner(repo)
            var closes = 0, pushed = 0, progressCloses = 0
            model.close = { closes += 1 }; model.onPush = { pushed += 1 }
            model.onCommitProgress = { $0.onClose = { progressCloses += 1 } }
            model.commit(action); try await wait { !model.busy }
            precondition(model.commitProgress == nil && progressCloses == 1)
            precondition(action == .push ? closes == 1 && pushed == 1 : closes == 0 && pushed == 0 && model.message.isEmpty)
        }
        let staged = try await fixture("staged"), stagedOwner = try await owner(staged)
        stagedOwner.stagingEnabled = true; stagedOwner.onCommitProgress = { _ in }
        stagedOwner.commit(); try await wait { stagedOwner.commitProgress?.busy == false }
        let bHead = try await staged.run(["show","HEAD:b"]).stdout, aHead = try await staged.run(["show","HEAD:a 雪"]).stdout
        precondition(bHead == Data("unchecked index\n".utf8) && aHead == Data("base\n".utf8) && stagedOwner.commitProgress!.staging)
        stagedOwner.commitProgress!.choose(nil); try await wait { !stagedOwner.busy }

        let failed = try await fixture("failure"), failedOwner = try await owner(failed)
        let hooks = failed.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\nprintf 'fixture hook rejected\\n' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path); _ = try await failed.run(["config","core.hooksPath",hooks.path])
        failedOwner.createBranch = true; failedOwner.newBranch = "after-failure"
        failedOwner.onCommitProgress = { _ in }; var failedCloses = 0
        failedOwner.close = { failedCloses += 1 }
        let failedBefore = try await failed.run(["rev-parse","HEAD"]).stdout
        failedOwner.commit(.push); try await wait { failedOwner.commitProgress?.busy == false }
        let failure = failedOwner.commitProgress!; precondition(!failure.success && failure.postActions.isEmpty && failure.output.contains("fixture hook rejected") && failedCloses == 0 && failedOwner.busy)
        failure.choose(.push); precondition(failedOwner.commitProgress === failure)
        failure.choose(nil); try await wait { !failedOwner.busy }
        let failedAfter = try await failed.run(["rev-parse","HEAD"]).stdout
        let failedBranch = try await failed.branch()
        precondition(failedBefore == failedAfter && failedOwner.message == "progress message" && failedOwner.error == nil && failedCloses == 0 && failedBranch == "after-failure" && !failedOwner.createBranch && failedOwner.newBranch.isEmpty)
        _ = try await failed.run(["config","core.hooksPath","/dev/null"])
        failedOwner.commit(); try await wait { failedOwner.commitProgress?.busy == false }
        precondition(failedOwner.commitProgress!.success); failedOwner.commitProgress!.choose(nil); try await wait { !failedOwner.busy }

        let pre = try await fixture("pre-cancel"), token = OperationCancellation(); token.cancel()
        var preOptions = CommitOptions(); preOptions.newBranch = "must-not-exist"
        let preIndex = try Data(contentsOf: pre.root.appendingPathComponent(".git/index")), preHead = try await pre.run(["rev-parse","HEAD"]).stdout
        for index in 0..<2 {
            do {
                if index == 0 { _ = try await pre.commitSelected(message:"cancel",paths:["a 雪"],options:preOptions,cancellation:token) }
                else { _ = try await pre.commitIndex(message:"cancel",options:preOptions,cancellation:token) }
                preconditionFailure("Pre-cancelled commit executed")
            } catch is OperationCancellationFailure {}
        }
        let afterPreHead = try await pre.run(["rev-parse","HEAD"]).stdout
        let afterPreIndex = try Data(contentsOf: pre.root.appendingPathComponent(".git/index")); precondition(preHead == afterPreHead && preIndex == afterPreIndex)

        for mode in 0..<3 {
            let repo = try await fixture("cancel-" + String(mode)), model = try await owner(repo)
            if mode == 1 { model.stagingEnabled = true }
            if mode == 2 { model.amend = true; model.amendDiffToLastCommit = false }
            let hooks = repo.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("pre-commit"), marker = hooks.appendingPathComponent("pids")
            let script = "#!/bin/sh\nsleep 30 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > '" + marker.path.replacingOccurrences(of:"'",with:"'\\''") + "'\nwait\n"
            try Data(script.utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
            _ = try await repo.run(["config","core.hooksPath",hooks.path]); preferences.set(true,forKey:"ConfirmKillProcess")
            let decoy = Process(); decoy.executableURL = URL(fileURLWithPath:"/bin/sleep"); decoy.arguments = ["30"]; try decoy.run()
            defer { if decoy.isRunning { decoy.terminate() }; decoy.waitUntilExit() }
            var closes = 0, successes = 0, confirmations = 0
            model.close = { closes += 1 }; model.onCommitted = { _ in successes += 1 }
            model.onCommitProgress = { $0.confirmCancellation = { choice in confirmations += 1; choice(confirmations > 1) } }
            let head = try await repo.run(["rev-parse","HEAD"]).stdout
            model.commit(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
            let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0) }; precondition(pids.count == 2)
            let progress = model.commitProgress!
            progress.cancel(); precondition(progress.busy && !progress.cancelling && progress.canCancel && confirmations == 1)
            progress.cancel(); progress.cancel(); precondition(progress.cancelling && !progress.canCancel && confirmations == 2)
            try await wait { !model.busy }
            let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
            precondition(head == afterHead && successes == 0 && closes == 0 && model.commitProgress == nil && model.message == "progress message" && progress.cancelled && decoy.isRunning)
            let end = Date().addingTimeInterval(3)
            while (kill(pids[0],0) == 0 || kill(pids[1],0) == 0) && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
            precondition(kill(pids[0],0) != 0 && kill(pids[1],0) != 0,"Owned hook/helper survived")
            let unchecked = try await repo.run(["show",":b"]).stdout, working = try Data(contentsOf:repo.root.appendingPathComponent("b"))
            precondition(unchecked == Data("unchecked index\n".utf8) && working == Data("unchecked working\n".utf8))
            _ = try await repo.run(["config","core.hooksPath","/dev/null"]); model.commit(); try await wait { model.commitProgress?.busy == false }
            precondition(model.commitProgress!.success); model.commitProgress!.choose(nil); try await wait { !model.busy }
        }
        print("Commit progress: real checked/staged commits; retained owner and exact post-actions; duplicate/snapshot gates; Push/Pull/Tag callbacks and ReCommit reset; footer auto-close; hook rejection/draft retry; pre-cancelled APIs; actual live-hook No/Yes cancellation for ordinary/index/parent-amend commits, owned hook/helper dead and unrelated decoy alive, no success callback and unchecked bytes preserved. No windows, standard preference or pasteboard writes.")
    }
}
