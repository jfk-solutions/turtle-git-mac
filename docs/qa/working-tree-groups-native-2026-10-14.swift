import AppKit
import TurtleGitCore

@main struct WorkingTreeGroupsVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Groups timeout")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/working-tree-groups-captures-2026-10-14")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let view = window.contentView else { throw Failure(message: "Missing capture view") }
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            view.wantsLayer = true
            window.appearance?.performAsCurrentDrawingAppearance { view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            view.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "Missing bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "Missing PNG") }
            try png.write(to: directory.appendingPathComponent(name + "-" + suffix + ".png"), options: .atomic)
        }
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Working Tree groups failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for path in ["one", "two", "flagged", ".gitignore"] { try Data((path == ".gitignore" ? "*.ignored\n" : path + "\n").utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["one", "two", "flagged", ".gitignore"]); _ = try await repo.commit(message: "base")
        for path in ["one", "two"] { try Data((path + " changed\n").utf8).write(to: root.appendingPathComponent(path)) }
        try Data("unversioned\n".utf8).write(to: root.appendingPathComponent("new 雪\nfile"))
        try Data("ignored\n".utf8).write(to: root.appendingPathComponent("sample.ignored"))
        _ = try await repo.run(["update-index", "--assume-unchanged", "--", "flagged"])
        let suite = "TurtleGit.WorkingTreeGroups." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StatusWindowController(repository: repo, access: nil, defaults: defaults), model = controller.model
        defer { model.invalidate(); controller.close() }
        var filter = model.filter; filter.showIgnored = true; filter.showLocalChangesIgnored = true; model.setFilter(filter)
        model.reload(); try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(model.tableRows.compactMap { $0.row.group } == [.modified, .unversioned, .ignored, .localChangesIgnored], "Source group order wrong")
        try await wait { views(controller.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let probe = views(controller.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        let table = views(controller.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        try await wait { probe.rows.count == model.tableRows.count && table.numberOfRows == model.tableRows.count }
        try require(probe.rows == model.tableRows.map(\.row) && probe.leadingColumnCount == 0, "Native physical row slots lost group headers")
        let slots = IndexSet(integersIn: 0..<probe.rows.count)
        try require(StatusListGroups.files(at: slots, in: probe.rows).count == model.sortedRows.count, "Group slots resolved as files")
        model.selectGroup(.unversioned)
        try require(model.selection == ["new 雪\nfile"], "Select group selected a header")
        let snapshot = model.fileMenu(["one", "two"])
        model.chooseChangelistName = { "Feature 雪" }; model.assignChangelist(snapshot, name: nil, creating: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.changelists.assignments["one"] == "Feature 雪" && model.changelists.assignments["two"] == "Feature 雪", "Create did not assign captured paths")
        try require(model.tableRows.compactMap { $0.row.group }.last == .changelist("Feature 雪"), "Named group missing")
        let reopened = StatusWindowModel(repository: repo, access: nil, defaults: defaults)
        reopened.reload(); try await wait { !reopened.busy && StatusWindowModel.activeOperations == 0 }
        try require(reopened.changelists == model.changelists, "Reopen lost assignments"); reopened.invalidate()
        model.assignChangelist(model.fileMenu(["two"]), name: GitChangelists.ignored)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.tableRows.compactMap { $0.row.group }.last == .changelist(GitChangelists.ignored), "Ignore-on-commit must be last")
        try await wait { probe.rows.count == model.tableRows.count && table.numberOfRows == model.tableRows.count }
        try await capture(controller.window!, name: "working-tree-groups")
        let ordered = model.sortedRows.map(\.id)
        try require(model.clipboardText(Set(ordered), copy: .relativePaths) == ordered.joined(separator: "\n") + "\n", "Clipboard used pre-group sort order")
        model.setKeepChangelists(true, snapshot: model.fileMenu(["one"]))
        let next = StatusWindowModel(repository: repo, access: nil, defaults: defaults)
        try require(next.keepChangelists && defaults.bool(forKey: "Commit.KeepChangelists"), "Keep preference is not shared with Commit"); next.invalidate()
        model.assignChangelist(model.fileMenu(["one"]), name: nil)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(model.changelists.assignments["one"] == nil, "Remove failed")
        let staleGroup = model.groupMenu(.changelist(GitChangelists.ignored))
        model.reload(); try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        model.selection = []; model.selectGroup(.changelist(GitChangelists.ignored), snapshot: staleGroup)
        try require(model.selection.isEmpty, "Stale group selected fresh members")
        var reply: CheckedContinuation<String?, Never>?
        model.chooseChangelistName = { await withCheckedContinuation { reply = $0 } }
        model.assignChangelist(model.fileMenu(["one"]), name: nil, creating: true)
        try await wait { reply != nil }; model.invalidate()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired name choice lost Quit ownership")
        reply?.resume(returning: "Late"); try await wait { StatusWindowModel.activeOperations == 0 }
        let final = try await repo.changelists(), finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(final.assignments["one"] == nil && final.assignments["two"] == GitChangelists.ignored, "Late name choice changed assignments")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && finalHead == head, "Changelists changed Git state")
        controller.close()
        print("Working Tree groups: real native header slots/keyboard mapping, source categories/order, create/move/remove/reopen, ignore-on-commit, displayed clipboard, shared Keep, stale group and retired name/Quit checks passed. Private repository/preferences; owned window closed.")
    }
}
