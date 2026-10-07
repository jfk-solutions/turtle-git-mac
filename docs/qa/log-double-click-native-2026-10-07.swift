import AppKit
import SwiftUI
import TurtleGitCore

@main struct DoubleClickVerification {
    @MainActor static func wait(_ model: LogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History did not finish")
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Double Click QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("root".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "root")
        let rootHash = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "side"])
        try Data("side".utf8).write(to: root.appendingPathComponent("side")); try await repo.stage(["side"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", "main"])
        try Data("main".utf8).write(to: root.appendingPathComponent("main")); try await repo.stage(["main"]); _ = try await repo.commit(message: "main")
        _ = try await repo.run(["merge", "--no-ff", "side", "-m", "merge"])
        let history = try await repo.history(), merge = history[0]
        precondition(merge.parents.count == 2)
        let paths = [".git/index", ".git/config", ".git/HEAD", "file", "side", "main"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.DoubleClick.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults)
        defer { model.invalidate() }
        model.searchRegex = false; model.reload(); try await wait(model)
        precondition(!model.bare && model.workingTreeSnapshot?.entry.parents == [merge.hash])
        let logWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        logWindow.isReleasedWhenClosed = false; defer { logWindow.close() }
        logWindow.contentViewController = NSHostingController(rootView: LogDialog(model: model)); logWindow.contentView?.layoutSubtreeIfNeeded()
        guard let revisionTable = table(in: logWindow.contentView!), let target = revisionTable.target, let action = revisionTable.doubleAction else { preconditionFailure("Native double action missing") }
        precondition(action == #selector(RevisionTable.Coordinator.doubleClickRevision))
        var pairs: [(ComparisonRevision, ComparisonRevision)] = []
        model.onCompare = { pairs.append(($0, $1)) }
        model.select([merge.hash])
        precondition(NSApp.sendAction(action, to: target, from: revisionTable))
        precondition(pairs.isEmpty, "Double click should be off by default")
        defaults.set(true, forKey: "DiffByDoubleClickInLog")
        _ = NSApp.sendAction(action, to: target, from: revisionTable)
        precondition(pairs.count == 1 && pairs[0].0 == .revision(merge.parents[0]) && pairs[0].1 == .revision(merge.hash), "Merge must compare to its first actual parent")
        model.select(Set(history.map(\.hash))); _ = NSApp.sendAction(action, to: target, from: revisionTable)
        precondition(pairs.count == 2 && pairs[1].1 == .revision(merge.hash), "Multiple selection must use the first visible row")
        model.select([rootHash]); _ = NSApp.sendAction(action, to: target, from: revisionTable)
        precondition(pairs.count == 2 && model.navigationNotice == "No previous version.")
        model.select([""])
        _ = NSApp.sendAction(action, to: target, from: revisionTable)
        precondition(pairs.count == 3 && pairs[2].0 == .revision(merge.hash) && pairs[2].1 == .workingTree)
        let unbornRoot = root.appendingPathComponent("unborn-fixture")
        try FileManager.default.createDirectory(at: unbornRoot, withIntermediateDirectories: true)
        let unbornRepo = GitRepository(root: unbornRoot, executable: repo.executable)
        _ = try await unbornRepo.run(["init", "-b", "main"])
        let unbornModel = LogWindowModel(repository: unbornRepo, access: nil, labelDefaults: defaults)
        defer { unbornModel.invalidate() }
        unbornModel.searchRegex = false; unbornModel.reload(); try await wait(unbornModel)
        precondition(unbornModel.workingTreeSnapshot?.entry.parents == [])
        unbornModel.select([""]); unbornModel.onCompare = { pairs.append(($0, $1)) }
        unbornModel.doubleClickRevision()
        precondition(pairs.count == 3 && unbornModel.navigationNotice == "No previous version.")
        model.entries = history; model.select([merge.hash]); model.busy = true
        _ = NSApp.sendAction(action, to: target, from: revisionTable); precondition(pairs.count == 3); model.busy = false
        defaults.set(false, forKey: "DiffByDoubleClickInLog")
        _ = NSApp.sendAction(action, to: target, from: revisionTable); precondition(pairs.count == 3)
        defaults.set(true, forKey: "DiffByDoubleClickInLog"); model.invalidate()
        _ = NSApp.sendAction(action, to: target, from: revisionTable); precondition(pairs.count == 3)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LogDialogSettings()); window.contentView?.layoutSubtreeIfNeeded(); window.close()
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native double click: actual native table double-action routing, default-off/live preferences, real merge first parent, first visible multiple selection, root and captured/unborn working row notices, busy/closed guards and hidden settings layout passed; repository unchanged")
    }
}
