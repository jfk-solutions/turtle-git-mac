import AppKit
import SwiftUI
import TurtleGitCore

@main struct LogTableFontVerification {
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
    @MainActor static func allTables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { allTables(in: $0) }
    }
    @MainActor static func probe(in view: NSView) -> CommitFileInteraction.Probe? {
        if let value = view as? CommitFileInteraction.Probe { return value }
        return view.subviews.compactMap { probe(in: $0) }.first
    }
    @MainActor static func wait(_ model: LogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History timeout")
    }
    @MainActor static func label(_ table: NSTableView, column: String, row: Int) -> NSTextField {
        let index = table.tableColumns.firstIndex { $0.identifier.rawValue == column }!
        return (table.view(atColumn: index, row: row, makeIfNecessary: true) as! NSTableCellView).textField!
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.LogTableFont.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Font QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        let path = repo.root.appendingPathComponent("font-file.txt")
        try Data("first\n".utf8).write(to: path); try await repo.stage(["font-file.txt"]); _ = try await repo.commit(message: "first")
        try Data("second\n".utf8).write(to: path); try await repo.stage(["font-file.txt"]); _ = try await repo.commit(message: "second")
        var entries = try await repo.log(); entries[0].isHead = true
        let projection = CommitGraph.project(entries, walk: HistoryWalkOptions())
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        model.busy = true; model.entries = projection.entries; model.graph = projection.graph
        let host = NSHostingView(rootView: RevisionTable(model: model, savesColumnLayout: false).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.close(); model.invalidate() }
        try await settle(host); let list = table(in: host)!
        precondition(list.numberOfRows == 2 && list.rowHeight == 24 && !list.autosaveTableColumns)
        precondition(label(list, column: "author", row: 1).font?.pointSize == 12)
        prefs.set("Menlo", forKey: "LogFontName"); prefs.set(22, forKey: "LogFontSize")
        try await settle(host); precondition(label(list, column: "author", row: 1).font?.pointSize == 12)
        prefs.set(true, forKey: "LogFontForLogCtrl"); try await settle(host)
        let normal = label(list, column: "author", row: 1).font!
        precondition(normal.familyName == "Menlo" && normal.pointSize == 22 && list.rowHeight >= normal.ascender - normal.descender)
        let head = label(list, column: "author", row: 0).font!
        precondition(head.pointSize == 22 && NSFontManager.shared.traits(of: head).contains(.boldFontMask))
        let message = label(list, column: "message", row: 1)
        precondition((message.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22)
        prefs.set(18, forKey: "LogFontSize"); try await settle(host)
        precondition(label(list, column: "author", row: 1).font?.pointSize == 18)
        prefs.set(false, forKey: "LogFontForLogCtrl"); try await settle(host)
        precondition(list.rowHeight == 24 && label(list, column: "author", row: 1).font?.pointSize == 12)
        model.files = try await repo.files(in: entries[0]); model.selectedFiles = [model.files[0].id]; model.bare = false
        let filesHost = NSHostingView(rootView: LogDialog(model: model).defaultAppStorage(prefs))
        let filesWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        filesWindow.isReleasedWhenClosed = false; filesWindow.contentView = filesHost; defer { filesWindow.close() }
        try await settle(filesHost)
        let files = allTables(in: filesHost).first { $0.tableColumns.count == 5 }!
        precondition(files.numberOfRows == 1)
        let ordinaryHeight = files.rect(ofRow: 0).height
        let fileIDs = model.files.map(\.id), selection = model.selectedFiles
        prefs.set(30, forKey: "LogFontSize"); prefs.set(true, forKey: "LogFontForFileListCtrl"); try await settle(filesHost)
        precondition(files.rect(ofRow: 0).height > ordinaryHeight, "Custom file font must increase the actual native row height")
        precondition(model.files.map(\.id) == fileIDs && model.selectedFiles == selection && files.selectedRowIndexes == IndexSet(integer: 0))
        prefs.set(false, forKey: "LogFontForFileListCtrl"); try await settle(filesHost)
        precondition(files.rect(ofRow: 0).height == ordinaryHeight && model.selectedFiles == selection)

        try Data("dirty\n".utf8).write(to: path)
        let unknown = repo.root.appendingPathComponent("unknown-font-file.txt"); try Data("unknown\n".utf8).write(to: unknown)
        let tracked = [".git/HEAD", ".git/index", ".git/config", "font-file.txt", "unknown-font-file.txt"]
        let before = try tracked.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        let add = AddWindowModel(repository: repo, access: nil)
        let addition = try await repo.addDialogSelection(paths: ["."], includeIgnored: false)
        add.entries = addition.entries; add.checked = addition.initiallyChecked; add.highlighted = ["unknown-font-file.txt"]
        let addHost = NSHostingView(rootView: AddFileTable(model: add).defaultAppStorage(prefs))
        let addWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 900, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        addWindow.isReleasedWhenClosed = false; addWindow.contentView = addHost; defer { addWindow.close() }
        try await settle(addHost); let addTable = table(in: addHost)!
        let defaultHeight = addTable.rowHeight, checked = add.checked
        prefs.set(true, forKey: "LogFontForFileListCtrl"); prefs.set(22, forKey: "LogFontSize"); try await settle(addHost)
        let addLabel = (addTable.view(atColumn: 1, row: 0, makeIfNecessary: true) as! NSTableCellView).textField!
        precondition(addLabel.font?.pointSize == 22 && addLabel.font?.familyName == "Menlo")
        precondition(addTable.rowHeight > defaultHeight && addLabel.frame.height >= addLabel.font!.ascender - addLabel.font!.descender)
        precondition(add.checked == checked && add.highlighted == ["unknown-font-file.txt"] && addTable.selectedRowIndexes == IndexSet(integer: 0))
        prefs.set(false, forKey: "LogFontForFileListCtrl"); try await settle(addHost); precondition(addTable.rowHeight == defaultHeight)

        let commit = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        commit.entries = try await repo.status(); commit.selection = Set(commit.entries.map(\.id)); commit.checked = commit.selection
        let commitSelection = commit.selection, commitChecked = commit.checked
        let commitHost = NSHostingView(rootView: CommitDialog(model: commit).fileTable(commit.entries, selection: Binding(get: { commit.selection }, set: { commit.selection = $0 }), staged: nil).defaultAppStorage(prefs))
        let commitWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        commitWindow.isReleasedWhenClosed = false; commitWindow.contentView = commitHost; defer { commitWindow.close() }
        try await settle(commitHost); let commitTable = table(in: commitHost)!, interaction = probe(in: commitHost)!
        let commitRows = StatusListGroups.rows(entries: commit.sortedFiles(commit.entries, statistics: commit.statistics), changelists: commit.changelists, locallyIgnored: [])
        let fileRow = commitRows.firstIndex { $0.entry != nil }!
        precondition(commitTable.numberOfRows == commitRows.count && interaction.fileListFont == nil, "Commit group/file row count or default font mismatch")
        let normalCommitHeight = commitTable.rect(ofRow: fileRow).height
        prefs.set(true, forKey: "LogFontForFileListCtrl"); prefs.set(22, forKey: "LogFontSize"); try await settle(commitHost)
        precondition(interaction.fileListFont?.pointSize == 22 && commitTable.rect(ofRow: fileRow).height > normalCommitHeight)
        let pathColumn = commitTable.tableColumns.first { $0.title == "Path" }!
        let fit = interaction.fittedWidth(pathColumn, definition: .path, includeHeader: false)
        let font = MessageEditorFont.resolve(name: "Menlo", size: 22)
        let maximum = commit.entries.map { (StatusListClipboard.displayedPath($0) as NSString).size(withAttributes: [.font: font]).width + 38 }.max()!
        precondition(fit == max(pathColumn.minWidth, min(pathColumn.maxWidth, ceil(maximum))), "Autosize must measure the configured file font")
        precondition(commit.selection == commitSelection && commit.checked == commitChecked)
        prefs.set(false, forKey: "LogFontForFileListCtrl"); try await settle(commitHost)
        precondition(interaction.fileListFont == nil && commitTable.rect(ofRow: fileRow).height == normalCommitHeight)

        prefs.removeObject(forKey: "LogIncludeWorkingTreeChanges")
        let working = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { working.invalidate() }; working.search = ""; working.searchRegex = false
        working.reload(); try await wait(working)
        precondition(working.canShowWorkingTree && working.showWorkingTree && working.entries.first?.hash == "" && working.entries.count == 3)
        prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        let historyOnly = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { historyOnly.invalidate() }; historyOnly.search = ""; historyOnly.searchRegex = false
        precondition(!historyOnly.showWorkingTree); historyOnly.reload(); try await wait(historyOnly)
        precondition(!historyOnly.canShowWorkingTree && historyOnly.entries.map(\.hash) == entries.map(\.hash))
        historyOnly.showWorkingTree = true; historyOnly.reload(); try await wait(historyOnly)
        precondition(!historyOnly.entries.contains { $0.hash.isEmpty }, "Runtime checkbox must not bypass the source Advanced gate")
        prefs.set(true, forKey: "LogIncludeWorkingTreeChanges")
        let picker = LogWindowModel(repository: repo, access: nil, selecting: true, labelDefaults: prefs)
        defer { picker.invalidate() }; picker.search = ""; picker.searchRegex = false; picker.reload(); try await wait(picker)
        precondition(!picker.canShowWorkingTree && !picker.entries.contains { $0.hash.isEmpty })
        let bareRoot = repo.root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", repo.root.path, bareRoot.path])
        let bare = LogWindowModel(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, labelDefaults: prefs)
        defer { bare.invalidate() }; bare.search = ""; bare.searchRegex = false; bare.reload(); try await wait(bare)
        precondition(!bare.canShowWorkingTree && !bare.entries.contains { $0.hash.isEmpty })
        let after = try tracked.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }; precondition(before == after)
        print("PASS: native Log file-list live font/default height and selection, native Add actual font/height/checkbox/highlight preservation, Commit live row-height/autosize font/selection/checks, working-tree advanced default/enabled/disabled/picker/bare gates, unchanged HEAD/index/config and files")
        print("PASS: actual hidden revision table optional log font default-off, source key enable/live size change/disable, HEAD bold, message attributes and font-aware row height, two real Git rows and graph; column autosave disabled for private fixture, no main app")
    }
}
