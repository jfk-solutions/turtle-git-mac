import AppKit
import SwiftUI
import TurtleGitCore

@main struct CommitSortingVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Native table did not settle")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Sorting QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        let tracked = ["file10.swift", "file2.swift", "z.txt", "a.txt"]
        for path in tracked { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(tracked); _ = try await repo.commit(message: "base")
        for (path, count) in zip(tracked, [10, 2, 2, 1]) { try Data(("base\n" + (0..<count).map { "added \($0)\n" }.joined()).utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["file10.swift", "z.txt"])
        for path in ["unknown10", "unknown2", "雪\t🦎.txt"] { try Data("unknown\n".utf8).write(to: root.appendingPathComponent(path)) }
        _ = try await repo.assignChangelist(paths: ["z.txt", "a.txt"], name: "review")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let protected = tracked + ["unknown10", "unknown2", "雪\t🦎.txt", ".git/turtlegit-changelists.json"]
        let before = try protected.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.CommitSorting.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "Autocompletion")
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        model.reload(paths: ["."]); try await settle { !model.busy }
        precondition(model.error == nil && model.visibleEntries.count == 7)
        let checked = model.checked
        model.selection = ["file2.swift", "z.txt"]; model.focusedFiles["checkbox"] = "z.txt"
        let selection = model.selection
        // The production Table, with its original interaction probe and native
        // sort descriptor bridge. Invoke the actual data source, never synthesize input.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: CommitSortingHost(model: model).defaultAppStorage(defaults))
        window.contentView!.layoutSubtreeIfNeeded()
        try await settle { descendants(window.contentView!).contains { $0 is NSTableView } }
        let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        try await settle { descendants(window.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        func probe() -> CommitFileInteraction.Probe { descendants(window.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first! }
        let groups = probe().rows.compactMap(\.group)
        precondition(groups == [.modified, .unversioned, .changelist("review")])
        precondition(table.tableColumns.count == 9 && table.tableColumns[0].sortDescriptorPrototype == nil)
        func request(_ column: Int, ascending: Bool) {
            let old = table.sortDescriptors
            let prototype = table.tableColumns[column].sortDescriptorPrototype!
            table.sortDescriptors = [prototype.ascending == ascending ? prototype : prototype.reversedSortDescriptor as! NSSortDescriptor]
            table.dataSource!.tableView?(table, sortDescriptorsDidChange: old)
        }
        try await settle { table.headerView?.menu != nil }
        let initialFilenameWidth = table.tableColumns[2].width
        let menu = probe().columnMenu()
        precondition(menu.item(withTitle: "Path") == nil)
        for column in StatusListColumn.allCases {
            let index = StatusListColumn.allCases.firstIndex(of: column)! + 1
            precondition(table.tableColumns[index].isHidden == !StatusListColumn.defaultColumns.contains(column))
        }
        for column in [StatusListColumn.fileName, .lastModified, .fileSize, .status] {
            let item = probe().columnMenu().item(withTitle: column.rawValue)!
            _ = NSApplication.shared.sendAction(item.action!, to: item.target, from: item)
            let visible = !StatusListColumn.defaultColumns.contains(column)
            try await settle { model.fileColumns.visible.contains(column) == visible && table.tableColumns[StatusListColumn.allCases.firstIndex(of: column)! + 1].isHidden == !visible }
            precondition(model.checked == checked && model.selection == selection)
        }
        let reopened = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        precondition(reopened.fileColumns == model.fileColumns)
        let visible = model.visibleFileColumns
        let copied = StatusListClipboard.text(model.sortedFiles(model.visibleEntries, statistics: model.statistics), root: root, statistics: model.statistics, copy: .all, metadata: model.fileMetadata, visibleColumns: visible)
        precondition(copied.hasPrefix(visible.map(\.rawValue).joined(separator: "\t") + "\n") && !copied.hasPrefix("Path\tFilename\tExtension\tStatus"))
        precondition(model.fileMetadata["file10.swift"]!.size! > model.fileMetadata["file2.swift"]!.size!)
        // Native column identity is independent of its physical position.
        let original = table.tableColumns[2], originalWidth = table.tableColumns[2].width
        original.width = min(original.maxWidth, originalWidth + 37)
        let customizedWidth = original.width
        precondition(customizedWidth > originalWidth)
        table.moveColumn(2, toColumn: 4)
        probe().rememberNativeColumnLayout() // Production header-tracking capture, no synthesized gesture.
        precondition(probe().columnDefinition(atNativeIndex: 4) == .fileName)
        let reset = probe().columnMenu().item(withTitle: "Reset columns")!
        let customized = model.fileColumns
        probe().confirmResetColumns = { owner in precondition(owner === window && model.busy); return false }
        _ = NSApplication.shared.sendAction(reset.action!, to: reset.target, from: reset)
        precondition(model.busy)
        try await settle { !model.busy && probe().enabled && table.tableColumns[4] === original }
        precondition(model.fileColumns == customized && table.tableColumns[4] === original && abs(original.width - customizedWidth) < 0.5)
        probe().confirmResetColumns = { owner in
            precondition(owner === window && model.busy)
            model.setFileColumn(.fileSize, visible: false)
            model.setFileSortOrder([CommitFileSort(column: .status)])
            precondition(model.fileColumns == customized && model.fileSortOrder.first!.column == .path)
            return true
        }
        _ = NSApplication.shared.sendAction(reset.action!, to: reset.target, from: reset)
        try await settle { model.fileColumns.visible == Set(StatusListColumn.defaultColumns) && table.tableColumns[2] === original && table.tableColumns[2].isHidden }
        print("RESET WIDTH DIAGNOSTIC", "initial", initialFilenameWidth, "before resize", originalWidth, "custom", customizedWidth, "reset", original.width); fflush(stdout)
        precondition(abs(original.width - initialFilenameWidth) < 0.5)
        precondition(StatusListColumnSettings.load(from: defaults).visible == Set(StatusListColumn.defaultColumns))
        for column in StatusListColumn.allCases {
            let index = StatusListColumn.allCases.firstIndex(of: column)! + 1
            for ascending in [true, false] {
                request(index, ascending: ascending)
                try await settle { model.fileSortOrder.first?.column == column && model.fileSortOrder.first?.order == (ascending ? .forward : .reverse) }
                let files = model.sortedFiles(model.visibleEntries, statistics: model.statistics)
                let expected = StatusListGroups.rows(entries: files, changelists: model.changelists)
                try await settle { probe().rows.map(\.id) == expected.map(\.id) }
                precondition(probe().rows.compactMap(\.group) == groups && model.checked == checked && model.selection == selection && model.focusedFiles["checkbox"] == "z.txt")
                precondition(table.numberOfRows == expected.count)
                if column == .path { precondition((files.firstIndex { $0.path == "file2.swift" }! < files.firstIndex { $0.path == "file10.swift" }!) == ascending) }
                if column == .added { precondition((files.firstIndex { $0.path == "file2.swift" }! < files.firstIndex { $0.path == "file10.swift" }!) == ascending) }
            }
        }
        let retained = model.fileSortOrder
        for quit in [false, true] {
            model.busy = !quit; model.confirmingQuit = quit
            model.setFileSortOrder([CommitFileSort(column: .path)])
            let columns = model.fileColumns
            model.setFileColumn(.fileName, visible: true)
            precondition(!model.resetFileColumns() && model.fileColumns == columns)
            precondition(model.fileSortOrder == retained)
        }
        model.busy = false; model.confirmingQuit = false
        model.setFileSortOrder([CommitFileSort(column: .added), CommitFileSort(column: .path)])
        precondition(model.fileSortOrder.count == 1)
        model.stagingEnabled = true
        for staged in [true, false] {
            let statistics = staged ? model.stagedStatistics : model.unstagedStatistics
            let files = model.sortedFiles(model.visibleEntries, statistics: statistics)
            let counts = files.map { statistics[$0.path]?.added ?? -2 }
            precondition(counts == counts.sorted())
        }
        model.reload(); try await settle { !model.busy }
        precondition(model.fileSortOrder.first?.column == .added)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; precondition(finalHead == head)
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(finalIndex == index)
        let after = try protected.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        window.close()
        print("PASS: native Commit eight sortable header prototypes, default optional hiding, header visibility dispatch, saved choices/reopen, injected reset No/Yes and owner operation locks, native moved-column identity and width retention/reset, visible-only metadata clipboard and actual data source binding dispatch; numeric/path ascending+descending, source path tie, fixed group order, checked/highlighted/focus identity; busy/Quit refusal, one-column policy, staged/unstaged statistics and reload retention; repository HEAD/raw index/worktree/changelists retained. Owned hidden window closed; no synthetic events or physical header acceptance.")
    }
}
struct CommitSortingHost: View {
    @ObservedObject var model: CommitWindowModel
    var body: some View { CommitDialog(model: model).fileTable(model.visibleEntries, selection: $model.selection, staged: model.stagingEnabled ? model.stagedDiff : nil) }
}
