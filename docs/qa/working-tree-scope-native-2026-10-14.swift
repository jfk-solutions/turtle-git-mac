import AppKit
import TurtleGitCore

@main struct WorkingTreeScopeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Working Tree scope timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Working Tree scope failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for path in ["folder/one", "folder/two", "outside"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["folder/one", "folder/two", "outside"]); _ = try await repo.commit(message: "base")
        for path in ["folder/one", "folder/two", "outside"] { try Data("changed \(path)\n".utf8).write(to: root.appendingPathComponent(path)) }
        let suite = "TurtleGit.WorkingTreeScope." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1,forKey:"DialogTitles")
        let controller = StatusWindowController(repository: repo, access: nil, defaults: defaults), model = controller.model
        defer { model.invalidate(); controller.close() }
        model.setScope(["folder"])
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.folderFiltersEnabled && controller.window!.title == "\(root.lastPathComponent)/folder – Working Tree – TurtleGit", "Directory filters/title missing")
        try require(model.stashActions == [.stash], "Absent stash exposes restore/list")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        var captured: [(Data, Bool)] = []
        model.onUnifiedDiff = { bytes, alternate in captured.append((bytes, alternate)) }
        model.selection = ["folder/one"]
        model.scopeUnifiedDiff(alternate: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        let expectedFolder = try await repo.workingTreeDiffData(paths: ["folder"])
        try require(captured.count == 1 && captured[0].0 == expectedFolder && captured[0].1, "Aggregate diff followed highlight or lost alternative flag")
        model.unifiedDiff(["folder/one"], alternate: false)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        let expectedFile = try await repo.workingTreeDiffData(paths: ["folder/one"])
        try require(captured.last?.0 == expectedFile, "Selected-row unified command lost its file scope")
        model.setScope(["folder/one"])
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(!model.folderFiltersEnabled && model.commitPaths() == ["folder/one"], "Explicit file invocation gates/Commit scope differ")
        var filter = model.filter; filter.wholeProject = true; model.setFilter(filter)
        try require(controller.window!.title == "\(root.lastPathComponent) – Working Tree – TurtleGit" && model.commitPaths().isEmpty, "Whole Project title/Commit not updated")
        model.scopeUnifiedDiff(alternate: false)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(captured.last?.0 == expectedFile, "Source single-file aggregate precedence lost with Whole Project")
        model.setScope(["folder/one", "folder/two"])
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(!model.folderFiltersEnabled && model.invocation.commonDirectory == "folder", "Multiple-file common scope/filter gate wrong")
        let readHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let readIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(readHead == head && readIndex == index, "Read-only comparison preparation changed HEAD/index")
        // A stale menu must not apply a stash that disappeared since the refresh.
        _ = try await repo.saveStash(StashSaveOptions()); model.reload()
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.stashActions == [.stash, .stashPop, .stashApply, .stashList], "Existing stash menu/order missing")
        _ = try await repo.run(["stash", "clear"])
        var actions: [RepositoryAction] = []
        model.onAction = { action, _ in actions.append(action) }
        model.performDialogAction(.stashPop)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(actions.isEmpty && !model.hasStash, "Disappeared stash still dispatched")
        model.performDialogAction(.stash)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(actions == [.stash], "Save unavailable without stash")
        // Coalesce related-dialog changes while a refresh is in flight; preserve a later invocation.
        var reply: CheckedContinuation<[WorkingTreeFile], Error>?, reads = 0
        let previous = model.files
        model.readStatus = { token in
            reads += 1
            if reads == 1 { return try await withCheckedThrowingContinuation { reply = $0 } }
            return try await repo.workingTreeStatus(cancellation: token)
        }
        model.reload(); try await wait { reply != nil }
        try Data("later\n".utf8).write(to: root.appendingPathComponent("outside"))
        model.requestReload(); model.requestReload(); model.setScope(["outside"])
        reply?.resume(returning: previous); reply = nil
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(reads == 2 && model.filter.paths == ["outside"] && model.visibleFiles.map(\.id) == ["outside"], "Deferred changes/scope were dropped or redundantly reloaded")
        model.confirmingQuit = true; model.setScope(["folder"])
        try require(model.filter.paths == ["outside"], "Quit confirmation changed invocation")
        model.confirmingQuit = false
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.filter.paths == ["folder"] && model.folderFiltersEnabled, "Cancelled Quit did not drain pending scope")
        // Late aggregate preparation cannot publish after the source is retired.
        var held: CheckedContinuation<Void, Never>?
        model.onUnifiedDiff = { _, _ in await withCheckedContinuation { held = $0 } }
        model.scopeUnifiedDiff(alternate: false)
        try await wait { held != nil }
        model.requestReload(); model.invalidate(); held?.resume(); held = nil
        try await wait { StatusWindowModel.activeOperations == 0 }
        try require(reads == 3, "Retired source launched its deferred refresh")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(afterHead == head, "Dialog preparation changed HEAD")
        controller.close()
        print("Working Tree scope: single file/folder/multiple invocation, title/filter gates, aggregate vs selected patches, Shift alternative, conditional/fresh Stash, deferred refresh/scope/Quit, retired preparation passed. Owned window closed.")
    }
}
