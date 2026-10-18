import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyLFSCommands() async throws {
        let container = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "LFS command QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "literal 雪[*]\n.bin", other = "second.bin"
        for name in [path, other] { try Data("base\n".utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage([path, other]); _ = try await repo.commit(message: "base")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), tip = try await repo.rebaseCommit("HEAD")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let suite = "TurtleGit.LFSCommands." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "ShowListBackgroundImage")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true }, comparisonMarks: WorkingComparisonMarkStore(storageURL: container.appendingPathComponent("marks")))
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = prefs
        workspace.commandLineRepositoryPermission = { _ in RepositoryAccessLease(url: root) }
        defer { workspace.stopMonitoringForTermination(); for window in NSApp.windows { window.close() } }
        var queries = 0, lists: [LFSLocksWindowController] = [], operations: [LFSFileOperationController] = []
        var locks: [[String]] = [], unlocks: [([String], Bool)] = []
        workspace.lfsLocksWindowFactory = { repository, access, defaults in
            let controller = LFSLocksWindowController(repository: repository, access: access, defaults: defaults)
            controller.model.query = { _ in
                queries += 1
                return [LFSLock(id: "a", path: path, owner: "QA"), LFSLock(id: "b", path: other, owner: "Other")]
            }
            lists.append(controller); return controller
        }
        workspace.lfsFileOperationFactory = { repository, access, defaults in
            let controller = LFSFileOperationController(repository: repository, access: access, defaults: defaults)
            controller.model.lockChange = { paths, _, report in
                locks.append(paths)
                let files = paths.map { LFSFileResult(path: $0, success: true, output: "locked") }
                files.forEach(report); return LFSBatchResult(files: files, cancelled: false)
            }
            controller.model.change = { paths, force, _, report in
                unlocks.append((paths, force))
                let files = paths.map { LFSFileResult(path: $0, success: force, output: force ? "unlocked" : "owned by another user") }
                files.forEach(report); return LFSBatchResult(files: files, cancelled: false)
            }
            operations.append(controller); return controller
        }
        func invoke(_ args: [String]) { workspace.handleCommandLine(arguments: args, currentDirectory: root.path) }
        invoke(["--command=lfslocks", "--path", root.appendingPathComponent(path).path])
        try await wait { !workspace.busy && lists.count == 1 && !lists[0].model.busy && queries == 1 }
        let list = lists[0]
        try require(list.model.presentationPreferences === prefs && list.model.locks.count == 2 && list.model.checked == ["a", "b"], "LFS list lost settings or server-wide scope")
        list.model.checked = ["b"]; list.model.setForce(true)
        invoke(["/command:lfslocks", "/path:" + root.appendingPathComponent(other).path])
        try await wait { !workspace.busy }
        try require(lists.count == 1 && queries == 1 && list.model.checked == ["b"] && list.model.force, "New LFS list command erased existing checks/Force or started another query")
        list.close()
        let selection = container.appendingPathComponent("selection")
        try Data((path + "\0" + other + "\0" + path + "\0").utf8).write(to: selection)
        workspace.commandLinePathListPermission = { _, _ in RepositoryAccessLease(url: container) }
        invoke(["--command=lfsunlock", "--force", "--pathfile", selection.path, "--pathfile0", "--deletepathfile"])
        try await wait { !workspace.busy && operations.count == 1 && operations[0].model.showingProgress && !operations[0].model.busy }
        let forced = operations[0]
        try require(unlocks.count == 1 && unlocks[0].0 == [path, other] && unlocks[0].1, "Forced unlock lost path-file order, deduplication or Force")
        try require(!FileManager.default.fileExists(atPath: selection.path) && forced.model.presentationPreferences === prefs && forced.window?.sheetParent == nil, "LFS standalone path-file/preferences/presentation mismatch")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit allowed during LFS result review")
        forced.model.finishProgress(); try await wait { forced.model.retired }
        invoke(["--command=lfsunlock", "--path", root.appendingPathComponent(path).path])
        try await wait { !workspace.busy && operations.count == 2 && operations[1].model.showingProgress && !operations[1].model.busy }
        let retry = operations[1]
        try require(unlocks.last?.1 == false && retry.model.results.first?.success == false, "Unlock unexpectedly forced its initial attempt")
        await retry.model.unlock(forceRetry: true)
        try require(unlocks.last?.0 == [path] && unlocks.last?.1 == true && retry.model.results.first?.success == true, "Force retry lost captured paths")
        retry.model.finishProgress(); try await wait { retry.model.retired }
        invoke(["--command=lfslock", "--path", root.appendingPathComponent(path).path, "--path", root.appendingPathComponent(other).path])
        try await wait { !workspace.busy && operations.count == 3 && operations[2].model.showingProgress && !operations[2].model.busy }
        try require(locks == [[path, other]] && operations[2].model.operationLocked, "Lock command used unlock route or changed target order")
        operations[2].model.finishProgress(); try await wait { operations[2].model.retired }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        let attached = LFSFileOperationController(repository: repo, access: nil, defaults: prefs)
        var attachedToken: OperationCancellation?, attachedReply: CheckedContinuation<Void, Never>?, closed = 0
        attached.onClosed = { closed += 1 }
        attached.model.lockChange = { paths, token, report in
            attachedToken = token
            await withCheckedContinuation { attachedReply = $0 }
            let file = LFSFileResult(path: paths[0], success: true, output: "late")
            report(file); return LFSBatchResult(files: [file], cancelled: false)
        }
        try require(attached.present(owner: parent, paths: [path], locked: true), "LFS owner sheet refused")
        try await wait { attachedReply != nil && attached.model.busy }
        parent.close()
        try require(attached.model.retired && attachedToken?.isCancelled == true && closed == 1 && parent.attachedSheet == nil, "Owner closure did not retire/cancel LFS sheet exactly once")
        attachedReply?.resume(); attachedReply = nil
        try await wait { LFSLocksWindowModel.activeOperations == 0 }
        try require(attached.model.results.isEmpty && closed == 1, "Retired LFS sheet accepted late result")
        // Capture the presentation store before a delayed selection preflight;
        // a subsequent workspace settings change cannot retarget the child.
        let otherSuite=suite+".other",otherPrefs=UserDefaults(suiteName:otherSuite)!
        defer {otherPrefs.removePersistentDomain(forName:otherSuite)}
        var preferenceReply:CheckedContinuation<Void,Never>?
        workspace.lfsSelectionPreflight={_,paths,_,_ in
            workspace.fileComparisonPreferences=otherPrefs
            await withCheckedContinuation {preferenceReply=$0}
            return paths
        }
        try await wait {!workspace.busy && RepositoryModel.activeCommandFileOperations==0}
        invoke(["--command=lfslock","--path",root.appendingPathComponent(path).path])
        try await wait {preferenceReply != nil && workspace.busy}
        preferenceReply?.resume();preferenceReply=nil
        try await wait {!workspace.busy && operations.count==4 && !operations[3].model.busy && operations[3].model.showingProgress}
        try require(operations[3].model.presentationPreferences === prefs,"LFS preflight retargeted the owning presentation preferences")
        operations[3].model.finishProgress();try await wait {operations[3].model.retired}
        let priorOperationCount=operations.count,priorLockCount=locks.count
        // A slow selection read owns the launching window and remains accounted
        // for until the actual work drains, even if its reply ignores cancellation.
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; workspace.workspaceWindow = owner
        var pending: CheckedContinuation<Void, Never>?, preparationToken: OperationCancellation?
        workspace.lfsSelectionPreflight = { _, paths, direct, token in
            try require(direct, "Primary command used Finder preflight")
            preparationToken = token
            await withCheckedContinuation { pending = $0 }
            return paths
        }
        try await wait { !workspace.busy && RepositoryModel.activeCommandFileOperations == 0 }
        invoke(["--command=lfslock", "--path", root.appendingPathComponent(path).path])
        try await wait { pending != nil && workspace.hasPendingRepositoryWork }
        owner.close()
        try await wait { preparationToken?.isCancelled == true }
        try require(workspace.hasPendingRepositoryWork && workspace.busy, "Closing owner dropped pending read before drain")
        pending?.resume(); pending = nil
        try await wait { !workspace.hasPendingRepositoryWork && !workspace.busy }
        try require(operations.count == priorOperationCount && locks.count == priorLockCount, "Late preflight opened LFS progress after owner closed")
        workspace.workspaceWindow = nil
        invoke(["--command=lfsunlock", "--path", root.appendingPathComponent(path).path])
        try await wait { pending != nil && workspace.hasPendingRepositoryWork }
        workspace.stopMonitoringForTermination()
        try require(preparationToken?.isCancelled == true, "Workspace retirement did not cancel LFS preparation")
        pending?.resume(); pending = nil
        try await wait { !workspace.hasPendingRepositoryWork && !workspace.busy }
        try require(operations.count == priorOperationCount && LFSLocksWindowModel.activeOperations == 0, "Retired workspace accepted delayed LFS preparation")
        let finalTip = try await repo.rebaseCommit("HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && finalTip.hash == tip.hash, "Injected LFS actions changed index/HEAD")
        for name in [path, other] { try require(try Data(contentsOf: root.appendingPathComponent(name)) == Data("base\n".utf8), "LFS actions changed working bytes") }
        print("PASS: LFS command family: server-wide Locks and retained checks/Force; literal NUL path-file forced Unlock; normal Unlock and captured Force retry; Lock; captured preferences across delayed preflight; standalone progress/Quit review; owner-close and retirement cancellation; unchanged index/HEAD/working bytes; owned windows closed")
    }
}
