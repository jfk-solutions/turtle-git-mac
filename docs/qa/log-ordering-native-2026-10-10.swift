import AppKit
import TurtleGitCore
import Darwin

@main struct LogOrderingVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(line: line)
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); print("PASS: Native Log ordering, four Git walks, header route, draft Cancel/OK, retained selection and owned close; repository bytes unchanged. No physical input or signed acceptance."); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }; NSApp.run()
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git), suite = "TurtleGit.Ordering.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Ordering QA"), ("user.email", "order@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file.txt")
        func commit(_ title: String, _ parents: [String], _ committer: Int, _ author: Int) async throws -> String {
            try Data((title + "\n").utf8).write(to: file); try await repo.stage(["file.txt"])
            let tree = try await repo.run(["write-tree"]).text.trimmingCharacters(in: .newlines)
            return try await repo.run(["commit-tree", tree, "-m", title] + parents.flatMap { ["-p", $0] }, environmentOverrides: ["GIT_COMMITTER_DATE": "2020-01-\(String(format: "%02d", committer))T12:00:00+0000", "GIT_AUTHOR_DATE": "2020-01-\(String(format: "%02d", author))T12:00:00+0000"]).text.trimmingCharacters(in: .newlines)
        }
        let base = try await commit("Root", [], 15, 15), left = try await commit("Left one", [base], 9, 2)
        let leftTip = try await commit("Left two", [left], 10, 8), right = try await commit("Right one", [base], 7, 9)
        let rightTip = try await commit("Right two", [right], 11, 3), merge = try await commit("Merge", [leftTip, rightTip], 12, 12)
        _ = try await repo.run(["update-ref", "refs/heads/main", merge]); _ = try await repo.run(["reset", "--hard", merge])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: file)
        let parent = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false)
        parent.window!.alphaValue = 0; parent.window!.orderFront(nil); defer { parent.close() }
        try await wait { !parent.model.busy && parent.model.entries.count == 6 }
        parent.model.select([base]); parent.window!.contentView!.layoutSubtreeIfNeeded()
        let table = views(parent.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.identifier.rawValue == "graph" } }!
        func headerClick() { table.delegate!.tableView?(table, didClick: table.tableColumns[1]) }
        headerClick(); try await wait { parent.ordering != nil }
        let cancel = parent.ordering!
        try require(parent.model.orderingBlocked && parent.window!.attachedSheet === cancel.window && cancel.window!.alphaValue == 0)
        try require(cancel.ordering.itemTitles == HistoryOrdering.allCases.map(\.title) && cancel.ordering.selectedTag() == 1)
        let canClose = parent.windowShouldClose(parent.window!)
        print("Ordering key diagnostics:", cancel.ok.keyEquivalent.debugDescription, cancel.cancel.keyEquivalent.debugDescription, "parent can close:", canClose)
        try require(cancel.window!.defaultButtonCell === cancel.ok.cell && cancel.cancel.keyEquivalent == "\u{1b}" && !canClose)
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        let original = parent.model.entries.map(\.hash), selected = parent.model.selected
        cancel.ordering.selectItem(withTag: 3); cancel.cancel.performClick(nil)
        try require(cancel.finished && parent.ordering == nil && !parent.model.orderingBlocked && prefs.object(forKey: "LogOrderBy") == nil)
        try require(parent.model.entries.map(\.hash) == original && parent.model.selected == selected)
        var orders = Set<[String]>()
        for order in HistoryOrdering.allCases {
            headerClick(); try await wait { parent.ordering != nil }
            let child = parent.ordering!
            try require(child.ordering.selectedTag() == HistoryOrdering.load(defaults: prefs).rawValue)
            let saved = prefs.object(forKey: "LogOrderBy") as? NSNumber
            child.ordering.selectItem(withTag: order.rawValue)
            try require((prefs.object(forKey: "LogOrderBy") as? NSNumber) == saved)
            if order == .authorDate {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: child.window!.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
                try require(child.window!.performKeyEquivalent(with: event))
            } else { child.ok.performClick(nil) }
            try await wait { !parent.model.busy && parent.ordering == nil && parent.window!.attachedSheet == nil }
            let oracle = try await repo.run(["log", "--format=%H"] + order.arguments + ["HEAD", "--"]).text.split(separator: "\n").map(String.init)
            try require(HistoryOrdering.load(defaults: prefs) == order && parent.model.entries.map(\.hash) == oracle && parent.model.graph.count == oracle.count)
            try require(parent.model.selected == [base]); orders.insert(oracle)
        }
        try require(orders.count >= 3)
        headerClick(); try await wait { parent.ordering != nil }
        let escape = parent.ordering!; escape.ordering.selectItem(withTag: 0); escape.window!.cancelOperation(nil)
        try require(escape.finished && parent.ordering == nil && HistoryOrdering.load(defaults: prefs) == .authorDate)
        parent.model.busy = true; headerClick(); try await Task.sleep(nanoseconds: 50_000_000); try require(parent.ordering == nil); parent.model.busy = false
        parent.showContainingReferences(base)
        try await wait { parent.containingReferences.count == 1 && parent.containingReferences.values.first?.busy == false }
        let references = parent.containingReferences.values.first!
        var siblingActions = 0; references.onLog = { _, _, _ in siblingActions += 1 }
        references.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        references.menuNeedsUpdate(references.table.menu!)
        let siblingLog = references.table.menu!.items.first { $0.title == "Show log" }!
        headerClick(); try await wait { parent.ordering != nil }; let forced = parent.ordering!
        references.menuNeedsUpdate(references.table.menu!); try require(references.table.menu!.items.isEmpty)
        _ = NSApp.sendAction(siblingLog.action!, to: siblingLog.target, from: siblingLog)
        try require(siblingActions == 0)

        if CommandLine.arguments.count > 3 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[3]); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                forced.window!.appearance = NSAppearance(named: appearance)
                let content = forced.window!.contentView!; content.layoutSubtreeIfNeeded(); views(content).forEach { $0.needsDisplay = true }; content.displayIfNeeded()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!; content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("log-ordering-" + label + ".png"))
            }
        }
        parent.close(); try require(references.closed && parent.containingReferences.isEmpty && forced.window?.isVisible != true && forced.finished && parent.ordering == nil && !parent.model.orderingBlocked && HistoryOrdering.load(defaults: prefs) == .authorDate)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterBytes = try Data(contentsOf: file)
        try require(head == afterHead && index == afterIndex && config == afterConfig && bytes == afterBytes)
    }
}
