import AppKit
import TurtleGitCore

@main struct WorkingTreeFileMenuVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "File-menu timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Working Tree file menu failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for path in ["one", "two", "old"] { try Data((path + "\n").utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["one", "two", "old"]); _ = try await repo.commit(message: "base")
        let renamed = "renamed 雪\nfile", untracked = "unversioned 🦎"
        _ = try await repo.run(["mv", "old", renamed])
        try Data("one changed\n".utf8).write(to: root.appendingPathComponent("one"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("two"))
        try Data("untracked\n".utf8).write(to: root.appendingPathComponent(untracked))
        let suite = "TurtleGit.WorkingTreeMenus." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = StatusWindowController(repository: repo, access: nil, defaults: defaults), model = controller.model
        defer { model.invalidate(); controller.close() }
        model.reload(); try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let single = model.fileMenu(["one"]), rename = model.fileMenu([renamed]), missing = model.fileMenu(["two"]), unknown = model.fileMenu([untracked])
        try require(single.commands.contains(.blame) && single.commands.contains(.openWith) && single.commands.contains(.editor), "Modified file commands missing")
        try require(rename.commands.contains(.oldNameLog) && rename.commands.contains(.blame), "Rename commands missing")
        try require(missing.commands.contains(.delete) && missing.commands.contains(.blame) && !missing.commands.contains(.open) && !missing.commands.contains(.export), "Missing row gates differ")
        try require(!unknown.commands.contains(.log) && !unknown.commands.contains(.blame) && unknown.commands.contains(.delete), "Unversioned gates differ")
        var logs: [[String]] = [], blames: [String] = [], pairs: [[String]] = []
        model.onAction = { action, paths in if action == .log { logs.append(paths) } }
        model.onBlame = { blames.append($0) }; model.onCompareTwoFiles = { pairs.append($0) }
        model.fileAction(.oldNameLog, snapshot: rename); model.fileAction(.blame, snapshot: missing)
        model.fileAction(.compareTwo, snapshot: model.fileMenu(["one", "two"]))
        try require(logs == [["old"]] && blames == ["two"] && Set(pairs.first ?? []) == ["one", "two"], "File history/Blame/pair routing lost exact paths")
        var opened: [(URL, URL?)] = [], edited: [URL] = []
        let application = root.appendingPathComponent("Injected.app")
        model.openWorkingFile = { opened.append(($0, $1)) }; model.openAlternativeEditor = { edited.append($0) }
        model.chooseApplication = { application }
        for command in [StatusFileCommand.open, .openWith, .editor] {
            model.fileAction(command, snapshot: single)
            try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        }
        try require(opened.count == 2 && opened[0].0 == root.appendingPathComponent("one") && opened[0].1 == nil && opened[1].1 == application && edited == [root.appendingPathComponent("one")], "Open/editor application routing failed")
        let folder = root.appendingPathComponent("export-output"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.chooseExportFolder = { folder }; model.fileAction(.export, snapshot: rename)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(try Data(contentsOf: folder.appendingPathComponent(renamed)) == Data("old\n".utf8), "Export lost literal relative path/content")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Export changed index")
        let outsideMark = model.fileMenu(["one"], mark: untracked)
        try require(outsideMark.commands.contains(.delete) && outsideMark.mark?.path == untracked, "Outside-highlight focus mark was lost")
        var declined: [[String]] = []
        model.confirmDeletion = { paths, _ in declined.append(paths); return false }
        model.fileAction(.delete, snapshot: outsideMark, permanently: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(declined == [["one"]] && FileManager.default.fileExists(atPath: root.appendingPathComponent("one").path), "Focus mark changed delete targets")
        model.fileAction(.delete, snapshot: unknown, permanently: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent(untracked).path), "No deleted a file")
        var confirmations: [([String], Bool)] = []
        model.confirmDeletion = { paths, permanent in confirmations.append((paths, permanent)); return true }
        model.fileAction(.delete, snapshot: unknown, permanently: true)
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(confirmations.count == 1 && confirmations[0].0 == [untracked] && confirmations[0].1 && !FileManager.default.fileExists(atPath: root.appendingPathComponent(untracked).path), "Confirmed deletion failed")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Unversioned deletion changed unrelated staged rename")
        let stale = model.fileMenu(["one"]); model.selection = ["two"]; model.selection = ["one"]
        model.fileAction(.blame, snapshot: stale); try require(blames == ["two"], "Selection-away/return revived stale menu")
        let beforeRefresh = model.fileMenu(["one"]); model.reload()
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        model.fileAction(.blame, snapshot: beforeRefresh); try require(blames == ["two"], "Refresh revived stale menu")
        var applicationReply: CheckedContinuation<URL?, Never>?
        model.chooseApplication = { await withCheckedContinuation { applicationReply = $0 } }
        model.fileAction(.openWith, snapshot: model.fileMenu(["one"]))
        try await wait { applicationReply != nil }
        try require(StatusWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Application choice lost Quit ownership")
        model.invalidate(); applicationReply?.resume(returning: application)
        try await wait { StatusWindowModel.activeOperations == 0 }
        try require(opened.count == 2, "Retired application choice launched a file")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head, "Menu actions changed HEAD")
        controller.close()
        print("Working Tree menus: source row gates, exact rename/Blame/pair routing, captured Open/Open With/editor, literal export, No/Yes permanent deletion and unrelated-index preservation, stale selection/refresh and late panel retirement/Quit passed. Launches/answers injected; private repository/preferences; owned window closed.")
    }
}
