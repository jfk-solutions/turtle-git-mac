import AppKit
import TurtleGitCore

@main struct LogColumnLayoutVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func table(_ view: NSView) -> NSTableView? {
        if let table = view as? HistoryTableView { return table }
        return view.subviews.compactMap(table).first
    }
    @MainActor static func settle(_ owner: LogWindowController) async throws {
        for _ in 0..<1000 {
            owner.window!.contentView!.layoutSubtreeIfNeeded()
            if !owner.model.busy, owner.model.error != nil { throw Failure(description: owner.model.error!) }
            if !owner.model.busy, !owner.model.entries.isEmpty, let table = table(owner.window!.contentView!), table.numberOfRows == owner.model.entries.count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Log columns did not settle: " + (owner.model.error ?? "no error"))
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Log columns failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.LogColumns.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let globalKeys = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Log.Column") || $0.key.contains("TurtleGit.Log.RevisionColumns") }
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Columns QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base\n\ngit-svn-id: https://example.invalid/trunk@42 abcd-123")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let helper = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false,historyRegexExecutable:helper)
        defer { owner.close() }; owner.model.showWorkingTree = false; owner.model.reload(); try await settle(owner)
        let native = table(owner.window!.contentView!)!, coordinator = native.delegate as! RevisionTable.Coordinator
        let header = coordinator.headerMenu!; coordinator.menuNeedsUpdate(header)
        try require(header.item(withTitle:"SVN Rev") == nil && native.tableColumn(withIdentifier:.init("svn"))!.isHidden && !native.autosaveTableColumns, "Non-SVN/private layout exposed wrong availability or global autosave")
        let email = header.item(withTitle:"Email")!; coordinator.toggleColumn(email)
        try require(prefs.bool(forKey:"Log.Column.Visible.email"), "Column checkbox did not use private preferences")
        native.tableColumn(withIdentifier:.init("email"))!.width = 430
        native.moveColumn(native.column(withIdentifier:.init("email")),toColumn:0); coordinator.saveColumns()
        try require(prefs.stringArray(forKey:"Log.Columns.Order")?.first == "email", "Column order not saved")
        let reopened = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false,historyRegexExecutable:helper)
        defer { reopened.close() }; reopened.model.showWorkingTree = false; reopened.model.reload(); try await settle(reopened)
        let restored = table(reopened.window!.contentView!)!
        try require(restored.tableColumns.first?.identifier.rawValue == "email" && restored.tableColumns.first?.width == 430 && restored.tableColumns.first?.isHidden == false, "Private order/width/visibility did not restore")
        prefs.set(["unknown", "email", "email", "author"], forKey:"Log.Columns.Order")
        prefs.set(["email": -5.0, "author": 350.0], forKey:"Log.Columns.Widths")
        let malformed = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false,historyRegexExecutable:helper)
        defer { malformed.close() }; malformed.model.showWorkingTree = false; malformed.model.reload(); try await settle(malformed)
        let recovered = table(malformed.window!.contentView!)!
        try require(recovered.tableColumns.first?.identifier.rawValue == "email" && recovered.tableColumns[1].identifier.rawValue == "author" && recovered.tableColumn(withIdentifier:.init("email"))!.width == 200 && recovered.tableColumn(withIdentifier:.init("author"))!.width == 350, "Malformed/duplicate layout did not recover")
        malformed.close()
        let metadata = root.appendingPathComponent(".git/svn/.metadata")
        try FileManager.default.createDirectory(at:metadata.deletingLastPathComponent(),withIntermediateDirectories:true); try Data().write(to:metadata)
        owner.model.reload(); try await settle(owner)
        try require(owner.model.hasGitSVN && owner.model.svnRevisions.count == 1, "SVN availability/batched revision read missing")
        coordinator.menuNeedsUpdate(header); try require(header.item(withTitle:"SVN Rev") != nil, "SVN header checkbox missing")
        let svnColumn = native.tableColumn(withIdentifier:.init("svn"))!
        try require(!svnColumn.isHidden, "SVN default visibility missing")
        let row = owner.model.entries.firstIndex { !$0.hash.isEmpty }!
        let svnCell = coordinator.tableView(native,viewFor:svnColumn,row:row) as? NSTableCellView
        try require(svnCell?.textField?.stringValue == owner.model.svnRevisions[owner.model.entries[row].hash], "SVN cell did not show source matcher result")
        coordinator.toggleColumn(header.item(withTitle:"SVN Rev")!)
        try require(svnColumn.isHidden && prefs.object(forKey:"Log.Column.Visible.svn") as? Bool == false, "SVN visibility not saved")
        owner.model.busy = true; coordinator.toggleColumn(email)
        try require(prefs.bool(forKey:"Log.Column.Visible.email"), "Busy checkbox accepted retained command")
        owner.model.busy = false; coordinator.resetColumns()
        try require(native.tableColumns.first?.identifier.rawValue == "graph" && native.tableColumn(withIdentifier:.init("email"))!.isHidden && !svnColumn.isHidden, "Reset lost source order/conditional defaults")
        try require(prefs.object(forKey:"Log.Column.Visible.email") == nil && prefs.stringArray(forKey:"Log.Columns.Order")?.first == "graph", "Reset did not save final layout")
        try FileManager.default.removeItem(at: metadata)
        owner.model.reload(); try await settle(owner); coordinator.menuNeedsUpdate(header)
        try require(header.item(withTitle:"SVN Rev") == nil && svnColumn.isHidden, "Removed SVN metadata retained available column")
        let globalAfter = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Log.Column") || $0.key.contains("TurtleGit.Log.RevisionColumns") }
        try require(NSDictionary(dictionary:globalKeys).isEqual(to:globalAfter), "Private layout changed global column preferences")
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead == head && (try Data(contentsOf:root.appendingPathComponent(".git/index"))) == index, "Column interaction mutated HEAD/index")
        reopened.close(); owner.close(); coordinator.toggleColumn(email)
        print("Log columns: source SVN availability and batched cells, private checkbox/width/order restore, contextual Reset, busy/closed guards and global/repository preservation passed. Owned windows closed.")
    }
}
