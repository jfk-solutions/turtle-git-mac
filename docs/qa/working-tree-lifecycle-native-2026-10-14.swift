import AppKit
import TurtleGitCore

@main struct WorkingTreeLifecycleVerification {
    struct Failure: Error, LocalizedError, CustomStringConvertible { let description: String; var errorDescription: String? { description } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Working Tree timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Working Tree lifecycle failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("folder/tracked"))
        try Data("outside\n".utf8).write(to: root.appendingPathComponent("outside"))
        try await repo.stage(["folder/tracked", "outside"]); _ = try await repo.commit(message: "base")
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("folder/tracked"))
        try Data("unversioned\n".utf8).write(to: root.appendingPathComponent("new"))
        let suite = "TurtleGit.WorkingTreeLifecycle." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StatusWindowController(repository: repo, access: nil, defaults: defaults), model = controller.model
        defer { model.invalidate(); controller.close() }
        model.setScope(["folder"])
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.visibleFiles.map(\.id) == ["folder/tracked"], "Scoped rows changed")
        model.selection = ["folder/tracked"]
        var filters = model.filter; filters.showUnversioned = false; filters.showAllStaged = false; filters.wholeProject = true
        model.setFilter(filters)
        let reopened = StatusWindowModel(repository: repo, access: nil, defaults: defaults)
        reopened.setScope(["folder"])
        try await wait { !reopened.busy && StatusWindowModel.activeOperations == 0 }
        try require(!reopened.filter.showUnversioned && !reopened.filter.showAllStaged && reopened.filter.wholeProject, "Source preferences not restored")
        reopened.invalidate()
        model.stage(["folder/tracked"], staged: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.selection == ["folder/tracked"] && model.files.first(where: { $0.id == "folder/tracked" })?.entry.staged == true, "Stage/refresh lost selection or index state")
        model.stage(["folder/tracked"], staged: false)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.files.first(where: { $0.id == "folder/tracked" })?.entry.staged == false, "Unstage refresh failed")
        let original = model.files.map(\.id), originalBranch = model.branch
        var reply: CheckedContinuation<[WorkingTreeFile], Error>?
        model.readStatus = { _ in try await withCheckedThrowingContinuation { reply = $0 } }
        controller.commandKeyWindow = { [weak controller] in controller?.window }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 96)!
        try require(controller.window!.performKeyEquivalent(with: event), "F5 not routed")
        try await wait { reply != nil }
        try require(model.busy && !model.currentOperation.isEmpty && StatusWindowModel.activeOperations == 1, "Refresh lacks ownership/progress")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit escaped refresh")
        try require(!controller.windowShouldClose(controller.window!) && model.cancelling, "Close did not cancel/retain busy owner")
        reply?.resume(returning: []); reply = nil
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.files.map(\.id) == original && model.branch == originalBranch, "Cancelled read published partial snapshot")
        model.readStatus = { _ in throw Failure(description: "read failed") }; model.reload()
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.files.map(\.id) == original && model.error == "read failed", "Failed refresh replaced old snapshot")
        model.error = nil
        model.readStatus = { _ in try await withCheckedThrowingContinuation { reply = $0 } }; model.reload()
        try await wait { reply != nil }; model.invalidate()
        try require(StatusWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired worker lost Quit guard")
        reply?.resume(returning: []); reply = nil
        try await wait { StatusWindowModel.activeOperations == 0 }
        try require(model.files.map(\.id) == original && model.branch == originalBranch && model.error == nil, "Retired refresh changed state")
        let beforePrefs = defaults.dictionaryRepresentation(); model.setFilter(WorkingTreeFilter()); model.reload(); model.stage(["new"], staged: true)
        try require(defaults.dictionaryRepresentation() as NSDictionary == beforePrefs as NSDictionary && StatusWindowModel.activeOperations == 0, "Retired model changed preferences or started work")
        controller.close()
        print("Working Tree lifecycle: source saved filters/scope, real Stage/Unstage/selection refresh, F5, atomic failed/cancelled snapshot, progress, close/Quit/retired fences passed. Private repository/preferences; owned window closed.")
    }
}
