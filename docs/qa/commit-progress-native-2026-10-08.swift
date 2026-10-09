import AppKit
import TurtleGitCore
import Darwin

@main struct CommitProgressVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String = "Commit progress invariant failed") throws { if try !value() { throw Failure(message: message) } }
    @MainActor static var ownedOwners: [CommitWindowModel] = []
    @MainActor static func cleanup() async throws {
        for model in ownedOwners { model.commitProgress?.cancellation.cancel() }
        try await wait { ownedOwners.allSatisfy { $0.commitProgress?.busy != true } }
        for model in ownedOwners { model.commitProgress?.choose(nil) }
        try await wait { ownedOwners.allSatisfy { !$0.busy } }
        ownedOwners.removeAll()
    }
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), "Commit progress timed out")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await run(); try await cleanup() } catch {
            let failure = error; do { try await cleanup() } catch { fputs("CLEANUP FAIL \(error)\n", stderr) }
            fputs("FAIL \(failure)\n", stderr); exit(1)
        }
    }
    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.CommitProgress.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        DialogGeometry.install(preferences: preferences)
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
            ownedOwners.append(value); value.reload(paths: ["."]); try await wait { !value.busy && value.changelistsLoaded }
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
            try require(progress.currentWork == "Success" && progress.completionRange != nil && progress.output.contains(" ms @ "), "Commit success missing completion styling/timing")
            try require(model.busy && !model.canCommit && results == 1 && closes == 0 && model.error == nil)
            try require(progress.success && progress.postActions == [.push,.pull,.recommit,.createTag] && progress.paths == ["a 雪"] && !progress.staging)
            model.message = "changed after snapshot"; model.checked = ["b"]; model.commit(.push)
            let selected = try await repo.run(["show","HEAD:a 雪"]).stdout
            let unchecked = try await repo.run(["show",":b"]).stdout
            let working = try Data(contentsOf: repo.root.appendingPathComponent("b"))
            let body = try await repo.run(["log","-1","--format=%B"]).text
            try require(selected == Data("selected\n".utf8) && unchecked == Data("unchecked index\n".utf8) && working == Data("unchecked working\n".utf8) && body.contains("progress message") && !body.contains("changed after snapshot"))
            progress.choose(action); progress.choose(action); try await wait { !model.busy }
            try require(model.commitProgress == nil && results == 1 && push == (action == .push ? 1 : 0) && pull == (action == .pull ? 1 : 0) && tag == (action == .createTag ? 1 : 0))
            if action == .recommit { try require(closes == 0 && model.message.isEmpty && !model.amend && !model.messageOnly && model.checked.contains("b")) }
            else { try require(closes == 1) }
        }
        for action in [CommitWindowModel.CompletionAction.recommit,.push] {
            let repo = try await fixture("footer-" + action.rawValue), model = try await owner(repo)
            var closes = 0, pushed = 0, progressCloses = 0
            model.close = { closes += 1 }; model.onPush = { pushed += 1 }
            model.onCommitProgress = { $0.onClose = { progressCloses += 1 } }
            model.commit(action); try await wait { !model.busy }
            try require(model.commitProgress == nil && progressCloses == 1)
            try require(action == .push ? closes == 1 && pushed == 1 : closes == 0 && pushed == 0 && model.message.isEmpty)
        }
        let staged = try await fixture("staged"), stagedOwner = try await owner(staged)
        stagedOwner.stagingEnabled = true; stagedOwner.onCommitProgress = { _ in }
        stagedOwner.commit(); try await wait { stagedOwner.commitProgress?.busy == false }
        let bHead = try await staged.run(["show","HEAD:b"]).stdout, aHead = try await staged.run(["show","HEAD:a 雪"]).stdout
        try require(bHead == Data("unchecked index\n".utf8) && aHead == Data("base\n".utf8) && stagedOwner.commitProgress!.staging)
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
        let failure = failedOwner.commitProgress!; try require(failure.currentWork == "git did not exit cleanly (exit code 1)" && failure.completionRange != nil, "Commit failure missing status/range"); try require(!failure.success && failure.postActions.isEmpty && failure.output.contains("fixture hook rejected") && failedCloses == 0 && failedOwner.busy)
        failure.choose(.push); try require(failedOwner.commitProgress === failure)
        failure.choose(nil); try await wait { !failedOwner.busy }
        let failedAfter = try await failed.run(["rev-parse","HEAD"]).stdout
        let failedBranch = try await failed.branch()
        try require(failedBefore == failedAfter && failedOwner.message == "progress message" && failedOwner.error == nil && failedCloses == 0 && failedBranch == "after-failure" && !failedOwner.createBranch && failedOwner.newBranch.isEmpty)
        _ = try await failed.run(["config","core.hooksPath","/dev/null"])
        failedOwner.commit(); try await wait { failedOwner.commitProgress?.busy == false }
        try require(failedOwner.commitProgress!.success); failedOwner.commitProgress!.choose(nil); try await wait { !failedOwner.busy }

        let pre = try await fixture("pre-cancel"), token = OperationCancellation(); token.cancel()
        var preOptions = CommitOptions(); preOptions.newBranch = "must-not-exist"
        let preIndex = try Data(contentsOf: pre.root.appendingPathComponent(".git/index")), preHead = try await pre.run(["rev-parse","HEAD"]).stdout
        for index in 0..<2 {
            do {
                if index == 0 { _ = try await pre.commitSelected(message:"cancel",paths:["a 雪"],options:preOptions,cancellation:token) }
                else { _ = try await pre.commitIndex(message:"cancel",options:preOptions,cancellation:token) }
                throw Failure(message: "Pre-cancelled commit executed")
            } catch is OperationCancellationFailure {}
        }
        let afterPreHead = try await pre.run(["rev-parse","HEAD"]).stdout
        let afterPreIndex = try Data(contentsOf: pre.root.appendingPathComponent(".git/index")); try require(preHead == afterPreHead && preIndex == afterPreIndex)

        for mode in 0..<3 {
            let repo = try await fixture("cancel-" + String(mode)), model = try await owner(repo)
            if mode == 1 { model.stagingEnabled = true }
            if mode == 2 { model.amend = true; model.amendDiffToLastCommit = false }
            let hooks = repo.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
            let hook = hooks.appendingPathComponent("pre-commit"), marker = hooks.appendingPathComponent("pids")
            let script = "#!/bin/sh\nprintf 'Receiving objects: 42%% (42/100)\\nlive hook 雪\\n' >&2\nsleep 30 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > '" + marker.path.replacingOccurrences(of:"'",with:"'\\''") + "'\nwait\n"
            try Data(script.utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:hook.path)
            _ = try await repo.run(["config","core.hooksPath",hooks.path]); preferences.set(true,forKey:"ConfirmKillProcess")
            let decoy = Process(); decoy.executableURL = URL(fileURLWithPath:"/bin/sleep"); decoy.arguments = ["30"]; try decoy.run()
            defer { if decoy.isRunning { decoy.terminate() }; decoy.waitUntilExit() }
            var closes = 0, successes = 0, confirmations = 0
            model.close = { closes += 1 }; model.onCommitted = { _ in successes += 1 }
            model.onCommitProgress = { $0.confirmCancellation = { choice in confirmations += 1; choice(confirmations > 1) } }
            let head = try await repo.run(["rev-parse","HEAD"]).stdout
            model.commit(); try await wait { FileManager.default.fileExists(atPath:marker.path) }
            let pids = try String(contentsOf:marker).split(separator:" ").compactMap { Int32($0) }; try require(pids.count == 2)
            let progress = model.commitProgress!
            try await wait { progress.output.contains("live hook 雪") }
            try require(progress.busy && progress.percentage == 42 && progress.currentWork == "Receiving objects", "Hook output/percentage was not visible before cancellation")
            progress.cancel(); try require(progress.busy && !progress.cancelling && progress.canCancel && confirmations == 1)
            progress.cancel(); progress.cancel(); try require(progress.cancelling && !progress.canCancel && confirmations == 2)
            try await wait { !model.busy }
            let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
            try require(progress.output.components(separatedBy: "live hook 雪").count == 2, "Commit stream duplicated hook output")
            try require(progress.currentWork == "User cancelled" && progress.completionRange != nil, "Commit cancellation missing terminal presentation")
            try require(head == afterHead && successes == 0 && closes == 0 && model.commitProgress == nil && model.message == "progress message" && progress.cancelled && decoy.isRunning)
            let end = Date().addingTimeInterval(3)
            while (kill(pids[0],0) == 0 || kill(pids[1],0) == 0) && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
            try require(kill(pids[0],0) != 0 && kill(pids[1],0) != 0,"Owned hook/helper survived")
            let unchecked = try await repo.run(["show",":b"]).stdout, working = try Data(contentsOf:repo.root.appendingPathComponent("b"))
            try require(unchecked == Data("unchecked index\n".utf8) && working == Data("unchecked working\n".utf8))
            _ = try await repo.run(["config","core.hooksPath","/dev/null"]); model.commit(); try await wait { model.commitProgress?.busy == false }
            try require(model.commitProgress!.success); model.commitProgress!.choose(nil); try await wait { !model.busy }
        }
        let forcedRepo = try await fixture("forced-stream-close"), forcedOwner = try await owner(forcedRepo)
        let forcedHooks = forcedRepo.root.appendingPathComponent("hooks"); try FileManager.default.createDirectory(at: forcedHooks, withIntermediateDirectories: true)
        let forcedHook = forcedHooks.appendingPathComponent("pre-commit")
        let forcedMarker = forcedHooks.appendingPathComponent("pids")
        let forcedScript = "#!/bin/sh\nprintf 'forced live hook\\n' >&2\nsleep 30 &\nchild=$!\nprintf '%s %s' \"$$\" \"$child\" > '" + forcedMarker.path.replacingOccurrences(of:"'",with:"'\\''") + "'\nwait\n"
        try Data(forcedScript.utf8).write(to: forcedHook)
        try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath:forcedHook.path); _ = try await forcedRepo.run(["config","core.hooksPath",forcedHooks.path])
        var forcedController: CommitProgressWindowController?, forcedSuccesses = 0
        forcedOwner.onCommitted = { _ in forcedSuccesses += 1 }
        forcedOwner.onCommitProgress = { forcedController = CommitProgressWindowController(model:$0) }
        defer { forcedController?.close() }
        let forcedHead = try await forcedRepo.run(["rev-parse","HEAD"]).stdout
        forcedOwner.commit(); try await wait { forcedOwner.commitProgress?.output.contains("forced live hook") == true }
        try await wait { FileManager.default.fileExists(atPath: forcedMarker.path) }
        let forcedPids = try String(contentsOf: forcedMarker).split(separator: " ").compactMap { Int32($0) }
        try require(forcedPids.count == 2, "Forced-hook ownership marker")
        let abandoned = forcedOwner.commitProgress!
        forcedController?.close(); try await wait { !forcedOwner.busy }
        try await wait { forcedPids.allSatisfy { kill($0, 0) != 0 } }
        let forcedAfter = try await forcedRepo.run(["rev-parse","HEAD"]).stdout
        try require(abandoned.isAbandoned && abandoned.cancellation.isCancelled && !abandoned.busy && abandoned.output.isEmpty && abandoned.completionRange == nil && abandoned.postActions.isEmpty && forcedSuccesses == 0 && forcedHead == forcedAfter, "Forced Commit progress close leaked result/operation")
        preferences.set(false, forKey: "ShowGitexeTimings"); preferences.set(16, forKey: "GitOutputLimitinKiB")
        let displayOptions = CommitOptions()
        let display = CommitProgressWindowModel(repository: staged, action: .commit, staging: false, paths: [], options: displayOptions, preferences: preferences, cancellable: true)
        let controller = CommitProgressWindowController(model: display); defer { controller.close() }
        var displayCloses = 0; display.onClose = { displayCloses += 1 }
        display.complete(output: "warning: fixture warning\nhttps://example.invalid/progress\n" + String(repeating: "bounded fixture 雪\n", count: 3000), success: false, cancelled: false, postActions: [], exitCode: 7)
        try require(display.output.utf8.count < 18000 && display.output.contains("Output truncated") && display.output.hasSuffix("\n\ngit did not exit cleanly (exit code 7)\n") && !display.output.contains(" ms @ "), "Commit output cap or disabled timings failed")
        let clipboard = NSPasteboard(name: NSPasteboard.Name("TurtleGit.CommitProgress.QA." + UUID().uuidString)); defer { clipboard.releaseGlobally() }
        let scroll = SubmoduleProgressTextView.scrollView(preferences: preferences, clipboard: clipboard)
        let text = scroll.documentView as! SubmoduleProgressTextView
        text.present(display.output, completed: true, completionRange: display.completionRange, success: false)
        try require(text.textStorage?.attribute(.link, at: (display.output as NSString).range(of: "https://example.invalid/progress").location, effectiveRange: nil) != nil, "Commit completion missing native link")
        text.copyAllInformation(nil); try require(clipboard.string(forType: .string) == display.output, "Commit copy-all missed completion")
        let copyMenu = text.outputMenu(); try require(copyMenu.items.map(\.title) == ["Copy", "", "Copy all information to clipboard"], "Commit output menu differs")
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else { throw Failure(message: "Escape event") }
        try require(controller.window!.performKeyEquivalent(with: escape) && displayCloses == 1, "Commit Escape did not resolve completed progress")
        display.choose(nil); try require(displayCloses == 1, "Commit duplicate close")
        try require(!NSApplication.shared.windows.contains { $0.isVisible }, "Commit receiver displayed a window")
        print("Commit progress: real checked/staged commits; retained owner and exact post-actions; duplicate/snapshot gates; Push/Pull/Tag callbacks and ReCommit reset; footer auto-close; hook rejection/draft retry; pre-cancelled APIs; actual live-hook No/Yes cancellation for ordinary/index/parent-amend commits, owned hook/helper dead and unrelated decoy alive, no success callback and unchecked bytes preserved. Bounded completed output, disabled timing, native links/private copy-all/menu and hidden completed Escape/duplicate Close passed. No displayed windows, standard preference or general pasteboard writes.")
    }
}
