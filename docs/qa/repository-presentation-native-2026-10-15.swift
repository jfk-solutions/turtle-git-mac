// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct RepositoryPresentationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [NSWindowController] = []
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Repository presentation did not settle")
    }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Repository presentation family completed") }
        catch { owners.forEach { $0.close() }; owners = []; fputs("Presentation failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("repo 🐢")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.RepositoryPresentation.QA." + UUID().uuidString
        let otherSuite = suite + ".Other"
        let preferences = UserDefaults(suiteName: suite)!, other = UserDefaults(suiteName: otherSuite)!
        defer { owners.forEach { $0.close() }; owners = []; preferences.removePersistentDomain(forName: suite); other.removePersistentDomain(forName: otherSuite) }
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Presentation QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked.txt"))
        try await repository.stage(["tracked.txt"]); _ = try await repository.commit(message: "base")
        try Data("new\n".utf8).write(to: root.appendingPathComponent("new 🐢.txt"))
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        // All are real controller initializers, with their normal view/model wiring.
        let add = AddWindowController(repository: repository, access: nil, defaults: preferences)
        let commit = CommitWindowController(repository: repository, access: nil, defaults: preferences)
        let status = StatusWindowController(repository: repository, access: nil, defaults: preferences)
        let log = LogWindowController(repository: repository, access: nil, labelDefaults: preferences, savesColumnLayout: false, savesGeometry: false)
        let comparison = RevisionComparisonWindowController(repository: repository, access: nil, from: .revision("HEAD"), to: .workingTree, preferences: preferences)
        let merge = MergeWindowController(repository: repository, access: nil, preferences: preferences)
        let fetch = FetchWindowController(repository: repository, access: nil, preferences: preferences)
        let browser = RepositoryBrowserWindowController(repository: repository, access: nil, revision: "HEAD", preferences: preferences)
        let lfs = LFSLocksWindowController(repository: repository, access: nil, defaults: preferences)
        let independent = AddWindowController(repository: repository, access: nil, defaults: other)
        owners = [add, commit, status, log, comparison, merge, fetch, browser, lfs, independent]
        for owner in owners { try require(owner.window?.title.hasPrefix(root.path + " – ") == true, "Full path default: " + (owner.window?.title ?? "missing")) }
        // Exercise scope publication through the actual Commit model and status router.
        commit.model.scopePaths = ["Sources/a.swift", "Sources/b.swift"]; commit.model.showWholeProject = false
        try require(commit.window!.title.hasPrefix(root.appendingPathComponent("Sources").path + " – Commit"), "Commit common-directory title")
        commit.model.scopePaths = ["tracked.txt"]
        try require(commit.window!.title.hasPrefix(root.appendingPathComponent("tracked.txt").path + " – Commit"), "Commit single-file title")
        status.model.setScope(["tracked.txt"])
        log.model.setPathScope(["tracked.txt"])
        try await wait { !status.model.busy && !log.model.busy }
        try require(status.window!.title.contains("tracked.txt – Working Tree"), "Working Tree scoped title")
        try require(log.window!.title.contains("tracked.txt – Log Messages"), "Log scoped title")
        let advanced = AdvancedSettingsModel(defaults: preferences, publishFinderMenu: { _ in })
        try require(advanced.edit("DialogTitles", text: "1"), "Edit title mode")
        advanced.apply(); try require(advanced.error == nil, "Apply title mode")
        for owner in owners.dropLast() { try require(owner.window!.title.hasPrefix(root.lastPathComponent + "/") || owner.window!.title.hasPrefix(root.lastPathComponent + " – "), "Live compact title: " + owner.window!.title) }
        try require(independent.window!.title.hasPrefix(root.path + " – "), "Separate preference domain remains full")
        try require(commit.window!.title.contains("tracked.txt – Commit"), "Applying mode preserves scoped context")
        commit.model.showWholeProject = true
        try require(commit.window!.title == root.lastPathComponent + " – Commit – TurtleGit", "Whole Project title")
        // Add's actual AppKit view-based cells expose the tooltip and its reset.
        add.model.setScope(["new 🐢.txt"]); try await add.model.read()
        let coordinator = AddFileTable.Coordinator(model: add.model)
        _ = coordinator.make()
        let table = coordinator.table, pathColumn = table.tableColumn(withIdentifier: .init("path"))!
        func tooltip() -> String? { coordinator.tableView(table, viewFor: pathColumn, row: 0)?.toolTip }
        try require(tooltip() == root.appendingPathComponent("new 🐢.txt").path, "Native Add full-path tooltip")
        try require(advanced.edit("ShowListFullPathTooltip", text: "false"), "Edit tooltip preference")
        advanced.apply(); coordinator.refresh(); try require(tooltip() == nil, "Native Add disabled tooltip")
        _ = advanced.edit("ShowListFullPathTooltip", text: ""); _ = advanced.edit("DialogTitles", text: "")
        advanced.apply(); coordinator.refresh()
        try require(tooltip() == root.appendingPathComponent("new 🐢.txt").path, "Native Add tooltip reset")
        try require(commit.window!.title == root.path + " – Commit – TurtleGit", "Title reset updates existing window")
        // A later preference notification must not rewrite a closed owner.
        let closed = independent.window!; independent.close(); let closedTitle = closed.title
        other.set(1, forKey: "DialogTitles")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: other)
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(closed.title == closedTitle, "Closed window retires its presentation binding")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Presentation leaves index bytes unchanged")
        let finalHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head, "Presentation leaves HEAD unchanged")
        print("PASS: Ten native controllers, scoped titles, private live preferences, native Add tooltip, reset and close retirement")
    }
}
