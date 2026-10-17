import AppKit
import TurtleGitCore

@main struct SubmoduleHandoffsVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Submodule timeout at line \(line)")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Submodule handoffs failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), parent = GitRepository(root: root, executable: git)
        _ = try await parent.run(["init", "-b", "main"])
        let path = "child 雪\nmodule", location = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: location, withIntermediateDirectories: true)
        let child = GitRepository(root: location, executable: git)
        _ = try await child.run(["init", "-b", "main"])
        for repo in [parent, child] {
            for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        }
        try Data("base\n".utf8).write(to: location.appendingPathComponent("file")); try await child.stage(["file"]); _ = try await child.commit(message: "child base")
        let old = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + old + "," + path]); _ = try await parent.commit(message: "attach")
        try Data("next\n".utf8).write(to: location.appendingPathComponent("file")); try await child.stage(["file"]); _ = try await child.commit(message: "next")
        let current = try await child.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let suite = "TurtleGit.SubmoduleHandoffs." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let status = StatusWindowController(repository: parent, access: nil, defaults: defaults); defer { status.model.invalidate(); status.close() }
        status.model.reload(); try await wait { !status.model.busy && StatusWindowModel.activeOperations == 0 }
        let snapshot = status.model.fileMenu([path]); try require(snapshot.commands.contains(.log) && snapshot.commands.contains(.submoduleLog) && !snapshot.commands.contains(.blame), "Gitlink menu conflates parent/child history")
        var childLogs: [URL] = [], parentLogs: [[String]] = []
        status.model.onSubmoduleLog = { childLogs.append($0.root) }; status.model.onAction = { action, paths in if action == .log { parentLogs.append(paths) } }
        status.model.fileAction(.log, snapshot: snapshot); status.model.fileAction(.submoduleLog, snapshot: snapshot)
        try await wait { !status.model.busy && SubmoduleWorkingLogSession.activeReads == 0 }
        try require(parentLogs == [[path]] && childLogs.map(\.path) == [child.root.path], "Status Log routes are not separate: parents=\(parentLogs), children=\(childLogs), expected=\(child.root), error=\(status.model.error ?? "none")")
        let commit = CommitWindowModel(repository: parent, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        defer { commit.invalidateForClose() }
        commit.submodules = [path]; commit.onSubmoduleLog = { childLogs.append($0.root) }; commit.showSubmoduleLog(path)
        try await wait { !commit.busy && SubmoduleWorkingLogSession.activeReads == 0 }
        try require(childLogs.map(\.path) == [child.root.path, child.root.path], "Commit child history missing")
        let controller = SubmoduleDiffWindowController(repository: parent, access: nil, path: path, from: "HEAD", preferences: defaults), model = controller.model
        defer { model.invalidate(); controller.close() }
        model.load(); try await wait { !model.busy && SubmoduleDiffWindowModel.activeReads == 0 }
        let details = model.details!; try require(details.from.revision == old && details.to.revision == current, "Diff read lost parent gitlink/child HEAD")
        var pinned: [String] = [], comparisons = 0
        model.onLog = { _, revision in pinned.append(revision) }; model.onCompare = { _, _, _ in comparisons += 1 }
        model.log(details.from); try await wait { !model.busy }
        model.log(details.to); try await wait { !model.busy }
        var usedAlternate = false
        model.onCompare = { _, _, _ in comparisons += 1; usedAlternate = ComparisonToolInvocation.alternate == true }
        ComparisonToolInvocation.$alternate.withValue(true) { model.compare() }; try await wait { !model.busy }
        try require(usedAlternate, "Shift choice lost during preparation")
        controller.showWindow(nil)
        model.update(); try await wait { controller.updateOptions != nil }
        let owned = controller.updateOptions
        model.update(); try require(controller.updateOptions === owned && model.hasUpdateChild, "Duplicate Update replaced owned options")
        owned?.model.close(); try await wait { !model.hasUpdateChild && !model.busy }
        try require(controller.updateOptions == nil && controller.updateProgress == nil, "Cancel retained update owner")
        model.update(); try await wait { controller.updateOptions?.model.busy == false }
        let submitted = controller.updateOptions!
        try require(submitted.model.selection == [GitReferenceName(path)], "Update lost selected gitlink")
        submitted.model.options.noFetch = true; submitted.model.apply()
        try await wait { controller.updateProgress != nil }
        let progress = controller.updateProgress!
        try await wait { !progress.model.activeOperation && SubmoduleUpdateProgressWindowModel.activeOperations == 0 }
        try require(model.hasUpdateChild && controller.updateOptions == nil, "Update result lost ownership before acknowledgment")
        progress.model.close(); try await wait { !model.hasUpdateChild && !model.busy }
        let conflict = SubmoduleDiffWindowController(repository: parent, access: nil, path: path, from: "HEAD", preferences: defaults)
        var routedConflict = false
        conflict.model.readDetails = { _ in throw SubmoduleComparisonFailure.conflicted }
        conflict.model.onConflict = { routedConflict = true }
        conflict.model.load(); try await wait { !conflict.model.busy }
        try require(routedConflict && conflict.model.error == nil, "Working conflict did not route to conflict workflow")
        conflict.close()

        try require(pinned == [old, current] && comparisons == 1, "Diff child callbacks lost revisions")
        let comparison = ComparisonToolInvocation.$alternate.withValue(true) {
            RevisionComparisonWindowModel(repository: child, access: nil, from: .revision(old), to: .revision(current), preferences: defaults)
        }
        comparison.load(); try await wait { !comparison.busy }
        var viewerAlternate = false
        comparison.openComparedFile = { _, _ in viewerAlternate = ComparisonToolInvocation.alternate == true }
        comparison.compare(["file"]); try await wait { !comparison.busy }
        try require(viewerAlternate, "Changed Files lost initiating alternate-tool choice")
        comparison.invalidate()
        var prepared: CheckedContinuation<PreparedSubmoduleComparison, Error>?
        model.readCommand = { _, _, _ in try await withCheckedThrowingContinuation { prepared = $0 } }
        model.compare(); try await wait { prepared != nil }
        try require(model.cancelRead(), "Preparation was not cancellable")
        let ignored = try await parent.prepareSubmoduleComparison(details, action: .compareRevisions)
        prepared?.resume(returning: ignored); prepared = nil
        try await wait { !model.busy }
        try require(comparisons == 1, "Cancelled command opened a viewer")
        let closing = SubmoduleDiffWindowController(repository: parent, access: nil, path: path, from: "HEAD", preferences: defaults)
        var closeRead: CheckedContinuation<SubmoduleComparison, Error>?
        closing.model.readDetails = { _ in try await withCheckedThrowingContinuation { closeRead = $0 } }
        closing.model.load(); try await wait { closeRead != nil }
        try require(!closing.windowShouldClose(closing.window!), "Close escaped active read")
        closeRead?.resume(returning: details); closeRead = nil
        try await wait { closing.model.retired && !closing.model.busy }
        var pending: CheckedContinuation<SubmoduleComparison, Error>?
        model.readDetails = { _ in try await withCheckedThrowingContinuation { pending = $0 } }; model.load()
        try await wait { pending != nil }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel && model.cancelRead(), "Diff read escaped close/Quit")
        pending?.resume(returning: details); pending = nil
        try await wait { !model.busy && SubmoduleDiffWindowModel.activeReads == 0 }
        try require(model.details?.to.revision == current, "Cancelled read changed details")
        model.load(); try await wait { pending != nil }; model.invalidate()
        pending?.resume(returning: details); pending = nil; try await wait { SubmoduleDiffWindowModel.activeReads == 0 }
        model.log(details.to); model.compare(); model.update()
        try require(pinned == [old, current] && comparisons == 1, "Retired Diff opened child windows")
        var checkout: CheckedContinuation<GitRepository, Error>?
        status.model.submoduleLog.readCheckout = { _, _ in try await withCheckedThrowingContinuation { checkout = $0 } }
        status.model.fileAction(.submoduleLog, snapshot: status.model.fileMenu([path])); try await wait { checkout != nil }
        status.model.invalidate(); try require(SubmoduleWorkingLogSession.activeReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired child lookup lost Quit ownership")
        checkout?.resume(returning: child); try await wait { SubmoduleWorkingLogSession.activeReads == 0 && StatusWindowModel.activeOperations == 0 }
        try require(childLogs.map(\.path) == [child.root.path, child.root.path], "Retired child lookup opened Log")
        _ = try await parent.run(["update-index", "--force-remove", "--", path])
        let removedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let removedCheckout = try await parent.submoduleWorkingRepository(path: path)
        try require(removedCheckout.root.path == child.root.path && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == removedIndex, "HEAD-recorded deleted gitlink could not open its retained child or changed index")
        try FileManager.default.removeItem(at: location.appendingPathComponent(".git"))
        let uninitialized = SubmoduleWorkingLogSession(repository: parent, access: nil)
        do { _ = try await uninitialized.load(path); throw Failure(message: "Uninitialized child fell back to parent") } catch is SubmoduleWorkingHistoryFailure {}
        uninitialized.retire(); controller.close(); status.close()
        print("Submodule handoffs: separate parent/child status and Commit Log, literal gitlink checkout validation, pinned Diff callbacks, cancellable snapshot/close/Quit, retirement and uninitialized parent-fallback refusal passed. Private repos; owned windows closed.")
    }
}
