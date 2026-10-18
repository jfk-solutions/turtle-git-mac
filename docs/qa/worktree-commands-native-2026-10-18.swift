import AppKit
import TurtleGitCore

private struct WorktreeCommandScope: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

extension PrimaryCommandsVerification {
    @MainActor static func verifyWorktreeCommands() async throws {
        let container = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = container.appendingPathComponent("source.git"), target = container.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Worktree command QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try Data().write(to: root.appendingPathComponent(".gitmodules"))
        try await repo.stage(["file", ".gitmodules"]); _ = try await repo.commit(message: "base")
        let initialIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.rebaseCommit("HEAD")
        let suite = "TurtleGit.WorktreeCommands." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ConfirmKillProcess")
        prefs.set(false, forKey: "ShowListBackgroundImage")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true }, comparisonMarks: WorkingComparisonMarkStore(storageURL: container.appendingPathComponent("marks")))
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = prefs
        workspace.commandLineRepositoryPermission = { paths in RepositoryAccessLease(url: paths[0]) }
        defer { workspace.stopMonitoringForTermination(); for window in NSApp.windows { window.close() } }
        var creations: [WorktreeCreateWindowController] = [], managers: [WorktreeListWindowController] = []
        workspace.worktreeCreateWindowFactory = { repository, access, preferences, initial in
            let controller = WorktreeCreateWindowController(repository: repository, access: access, preferences: preferences, initialDirectory: initial)
            creations.append(controller); return controller
        }
        workspace.worktreeListWindowFactory = { repository, access, preferences in
            let controller = WorktreeListWindowController(repository: repository, access: access, preferences: preferences)
            managers.append(controller); return controller
        }
        func invoke(_ args: [String]) { workspace.handleCommandLine(arguments: args, currentDirectory: root.path) }
        invoke(["--command=worktreelist"])
        try await wait { !workspace.busy && managers.count == 1 && !managers[0].model.busy }
        let manager = managers[0]
        try require(manager.model.preferences === prefs && manager.model.rows.count == 1, "Manager command lost private settings or initial registration")
        invoke(["--command=worktreecreate"])
        try await wait { !workspace.busy && creations.count == 1 && !creations[0].model.busy && !creations[0].model.chooser.busy }
        let first = creations[0]
        try require(first.model.preferences === prefs && first.model.directory == String(root.path.dropLast(4)), "Normal Create lost source .git default or preferences")
        first.model.directory = container.appendingPathComponent("edited").path; first.model.checkout = false; first.model.force = true; first.model.branchName = "edited-branch"
        invoke(["--command=dropworktreecreate", "--droptarget", target.path])
        try await wait { !workspace.busy }
        try require(creations.count == 1 && first.model.directory.hasSuffix("/edited") && !first.model.checkout && first.model.force && first.model.branchName == "edited-branch", "Competing drop command erased open creation draft")
        first.close()
        invoke(["--command=dropworktreecreate", "--droptarget", target.path])
        try await wait { !workspace.busy && creations.count == 2 && !creations[1].model.busy && !creations[1].model.chooser.busy }
        let dropped = creations[1], destination = target.appendingPathComponent("source")
        try require(dropped.model.directory == destination.path && dropped.model.branchName == "source" && dropped.model.checkout && !dropped.model.force && !dropped.model.detach, "Drop target/source basename/default options differ from pinned source")
        try require(!FileManager.default.fileExists(atPath: destination.path), "Drop command mutated before OK")
        dropped.model.create()
        try await wait { !dropped.model.busy && dropped.model.progress }
        try require(dropped.model.success && dropped.model.hasSubmodules && FileManager.default.fileExists(atPath: destination.appendingPathComponent("file").path), "Accepted drop creation did not create checkout/post-action")
        do {
            try await wait { !workspace.busy && !manager.model.busy && manager.model.rows.contains { GitReferenceName.equal($0.path.resolvingSymlinksInPath().path, destination.resolvingSymlinksInPath().path) } }
        } catch {
            print("Worktree refresh state:", workspace.busy, manager.model.busy, manager.model.childActive, manager.model.showProgress, manager.model.error ?? "none", manager.model.rows.map { $0.path.path }, "expected", destination.path); fflush(stdout)
            throw error
        }
        invoke(["--command=worktreecreate"])
        try await wait { !workspace.busy }
        try require(creations.count == 2 && dropped.model.success && dropped.model.progress, "New Create replaced finished progress review")
        dropped.close()
        // A manager-owned Add dialog also owns its draft against command entry.
        manager.model.add()
        try await wait { manager.createWindow?.model.busy == false && manager.createWindow?.model.chooser.busy == false }
        let child = manager.createWindow!
        child.model.directory = container.appendingPathComponent("manager-draft").path
        invoke(["--command=dropworktreecreate", "--droptarget", target.path])
        try await wait { !workspace.busy }
        try require(creations.count == 2 && child.model.directory.hasSuffix("/manager-draft") && manager.model.childActive, "Command bypassed manager Add ownership")
        child.close(); try await wait { !manager.model.busy && !manager.model.childActive }
        // Real mutations through injected folder grants test the Store policy;
        // these leases are explicitly fake and do not establish signed access.
        let sourceLease = RepositoryAccessLease(url: root, provider: WorktreeCommandScope())
        let destinationLease = RepositoryAccessLease(url: container, provider: WorktreeCommandScope())
        @MainActor func scoped(_ name: String) async throws -> WorktreeCreateWindowController {
            let controller = WorktreeCreateWindowController(repository: repo, access: sourceLease, preferences: prefs, initialDirectory: container.appendingPathComponent(name))
            controller.model.requiresSecurityScope = true
            try await wait { !controller.model.busy && !controller.model.chooser.busy }
            return controller
        }
        let denied = try await scoped("denied")
        denied.model.authorizeDestination = { _, _ in nil }; denied.model.create()
        try await wait { !denied.model.busy }
        try require(!denied.model.progress && denied.model.error == nil && !FileManager.default.fileExists(atPath: container.appendingPathComponent("denied").path), "Cancelled authorization started creation")
        denied.model.authorizeDestination = { _, _ in RepositoryAccessLease(url: root, provider: WorktreeCommandScope()) }
        denied.model.create(); try await wait { !denied.model.busy }
        try require(denied.model.error != nil && !denied.model.progress && denied.model.destinationAccess == nil, "Unrelated destination grant accepted")
        denied.close()
        let late = try await scoped("late")
        var lateReply: CheckedContinuation<RepositoryAccessLease?, Never>?, lateToken: OperationCancellation?
        late.model.authorizeDestination = { _, token in lateToken = token; return await withCheckedContinuation { lateReply = $0 } }
        late.model.create(); try await wait { lateReply != nil && late.model.authorizingDestination }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored destination authorization")
        late.close(); try require(lateToken?.isCancelled == true && WorktreeCreateWindowModel.activeOperations > 0, "Forced close dropped preparation before drain")
        lateReply?.resume(returning: destinationLease); lateReply = nil
        try await wait { !late.model.busy && WorktreeCreateWindowModel.activeOperations == 0 }
        try require(!late.model.progress && late.model.destinationAccess == nil && !FileManager.default.fileExists(atPath: container.appendingPathComponent("late").path), "Late folder permission mutated retired creation")
        let captured = try await scoped("captured 雪[*]")
        let capturedPath = URL(fileURLWithPath: captured.model.directory)
        captured.model.checkout = false; captured.model.detach = true
        var reply: CheckedContinuation<RepositoryAccessLease?, Never>?, requests = 0
        captured.model.authorizeDestination = { path, _ in
            requests += 1; try require(GitReferenceName.equal(path.path, capturedPath.path), "Authorization retargeted submitted directory")
            return await withCheckedContinuation { reply = $0 }
        }
        manager.model.childActive = true
        let oldRows = manager.model.rows.count
        captured.model.onCreated = { _ in manager.model.requestReload() }
        captured.model.create(); try await wait { reply != nil }
        captured.model.create(); try require(requests == 1, "Duplicate Create opened another authorization")
        captured.model.directory = container.appendingPathComponent("replacement").path; captured.model.checkout = true; captured.model.detach = false
        reply?.resume(returning: destinationLease); reply = nil
        try await wait { !captured.model.busy }
        try require(captured.model.success && !captured.model.hasSubmodules && !FileManager.default.fileExists(atPath: capturedPath.appendingPathComponent("file").path) && !FileManager.default.fileExists(atPath: container.appendingPathComponent("replacement").path), "Permission reply did not use captured directory/checkout/options")
        try require(manager.model.rows.count == oldRows, "Deferred list refresh replaced manager child state")
        manager.model.childActive = false
        try await wait { !manager.model.busy && manager.model.rows.count == oldRows + 1 }
        let capturedRecord = manager.model.rows.first { GitReferenceName.equal($0.path.resolvingSymlinksInPath().path, capturedPath.resolvingSymlinksInPath().path) }
        try require(capturedRecord?.isDetached == true, "Captured Detach was replaced while authorizing")
        captured.close()
        let handoff = try await scoped("handoff")
        let handoffPath = URL(fileURLWithPath: handoff.model.directory)
        handoff.model.authorizeDestination = { path, _ in RepositoryAccessLease(url: path, provider: WorktreeCommandScope()) }
        handoff.model.create(); try await wait { !handoff.model.busy }
        try require(handoff.model.success && handoff.model.hasSubmodules, "Checkout creation lost post-create Submodule Update")
        var submodulePath: URL?, submoduleAccess: RepositoryAccessLease?
        handoff.model.onSubmodules = { submodulePath = $0; submoduleAccess = $1 }
        handoff.model.updateSubmodules()
        try require(submodulePath?.path == handoffPath.path && submoduleAccess?.contains(handoffPath) == true && submoduleAccess?.contains(root) == false && submoduleAccess?.permits(root.appendingPathComponent(".git/config")) == true, "Submodule post-action lost source metadata or destination containment")
        manager.close()
        let bare = container.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bare.path])
        invoke(["--command=worktreecreate", "--path", bare.path])
        try await wait { !workspace.busy && creations.count == 3 && !creations[2].model.busy && !creations[2].model.chooser.busy }
        let bareCreate = creations[2]
        try require(bareCreate.model.directory == String(bare.path.dropLast(4)), "Bare Create was blocked or lost source default")
        bareCreate.model.detach = true; bareCreate.model.create()
        try await wait { !bareCreate.model.busy }
        try require(bareCreate.model.success, "Bare repository failed accepted linked checkout creation")
        bareCreate.close()
        let finalHead = try await repo.rebaseCommit("HEAD")
        try require(finalHead.hash == head.hash && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == initialIndex && (try Data(contentsOf: root.appendingPathComponent("file"))) == Data("base\n".utf8), "Worktree family changed source HEAD/index/working file")
        try await wait { !workspace.busy && WorktreeCreateWindowModel.activeOperations == 0 && WorktreeListWindowModel.activeOperations == 0 }
        print("PASS: Worktree command family: Create/List/drop entry and source .git defaults; private preferences; preserved top-level/manager drafts and result reviews; accepted working/bare creation; cancel/wrong/late folder grants; immutable destination/options and duplicate gate; deferred manager refresh; Quit/drain; source HEAD/index/files retained; owned windows closed. Folder grants injected, not signed Finder acceptance.")
    }
}
