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
        precondition(table.tableColumns.count == 6 && table.tableColumns[0].sortDescriptorPrototype == nil)
        func request(_ column: Int, ascending: Bool) {
            let old = table.sortDescriptors
            let prototype = table.tableColumns[column].sortDescriptorPrototype!
            table.sortDescriptors = [prototype.ascending == ascending ? prototype : prototype.reversedSortDescriptor as! NSSortDescriptor]
            table.dataSource!.tableView?(table, sortDescriptorsDidChange: old)
        }
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
        print("PASS: native Commit five sortable header prototypes and actual data source binding dispatch; numeric/path ascending+descending, source path tie, fixed group order, checked/highlighted/focus identity; busy/Quit refusal, one-column policy, staged/unstaged statistics and reload retention; repository HEAD/raw index/worktree/changelists retained. Owned hidden window closed; no synthetic events or physical header acceptance.")
    }
}
struct CommitSortingHost: View {
    @ObservedObject var model: CommitWindowModel
    var body: some View { CommitDialog(model: model).fileTable(model.visibleEntries, selection: $model.selection, staged: model.stagingEnabled ? model.stagedDiff : nil) }
}
