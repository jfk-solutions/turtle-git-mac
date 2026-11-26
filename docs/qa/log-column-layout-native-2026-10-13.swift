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
    @MainActor static func wait(_ owner:LogWindowController,_ phase:String,_ ready:()->Bool)async throws {
        for _ in 0..<1000 {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            if ready(){return};try await Task.sleep(nanoseconds:10_000_000)
        }
        let native=owner.window.flatMap{$0.contentView}.flatMap{table($0)}
        let columns=native?.tableColumns.map{"\($0.identifier.rawValue):hidden=\($0.isHidden),width=\($0.width)"} ?? []
        throw Failure(description:"Log column readiness \(phase): busy=\(owner.model.busy),pending=\(owner.model.revisionColumnWorkPending),sheet=\(owner.window?.attachedSheet != nil),columns=\(columns)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func mount(_ owner:LogWindowController) {owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)}
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
        defer { owner.close() };mount(owner); owner.model.showWorkingTree = false; owner.model.reload(); try await settle(owner)
        let native = table(owner.window!.contentView!)!, coordinator = native.delegate as! RevisionTable.Coordinator
        let header = coordinator.headerMenu!; coordinator.menuNeedsUpdate(header)
        try require(header.item(withTitle:"SVN Rev") == nil && native.tableColumn(withIdentifier:.init("svn"))!.isHidden && !native.autosaveTableColumns, "Non-SVN/private layout exposed wrong availability or global autosave")
        @MainActor func command(_ id:String)throws->NSMenuItem {
            coordinator.menuNeedsUpdate(header)
            guard let item=header.items.first(where:{$0.identifier?.rawValue=="Log.Columns."+id}),item.isEnabled,item.image != nil,item.action != nil else {throw Failure(description:"Missing current owned column command "+id)}
            return item
        }
        @MainActor func invoke(_ item:NSMenuItem)throws {try require(NSApp.sendAction(item.action!,to:item.target,from:item),"Column native action dispatch failed")}
        @MainActor func reset(_ accepted:Bool)async throws {
            try invoke(command("Reset"))
            try await wait(owner,"owned Reset question") {owner.window?.attachedSheet != nil && owner.model.revisionColumnWorkPending}
            let sheet=owner.window!.attachedSheet!,title=HistoryLabels.caption(accepted ? "Yes":"No")
            guard let button=views(sheet.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title && $0.isEnabled}) else {throw Failure(description:"Missing Reset response "+title)}
            button.performClick(nil)
            try await wait(owner,"Reset response and native detach") {!owner.model.revisionColumnWorkPending && owner.window?.attachedSheet==nil && sheet.sheetParent==nil && !sheet.isVisible}
        }
        let email=try command("email");try invoke(email)
        try require(prefs.bool(forKey:"Log.Column.Visible.email"), "Column checkbox did not use private preferences")
        try invoke(email);try require(prefs.bool(forKey:"Log.Column.Visible.email"),"Consumed column command applied twice")
        let emailColumn=native.tableColumn(withIdentifier:.init("email"))!
        emailColumn.width = 430
        coordinator.tableViewColumnDidResize(Notification(name:NSTableView.columnDidResizeNotification,object:native,userInfo:["NSTableColumn":emailColumn]))
        native.moveColumn(native.column(withIdentifier:.init("email")),toColumn:0); coordinator.saveColumns()
        try require(prefs.stringArray(forKey:"Log.Columns.Order")?.first == "email", "Column order not saved")
        let reopened = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false,historyRegexExecutable:helper)
        defer { reopened.close() };mount(reopened); reopened.model.showWorkingTree = false; reopened.model.reload(); try await settle(reopened)
        let restored = table(reopened.window!.contentView!)!
        try require(restored.tableColumns.first?.identifier.rawValue == "email" && restored.tableColumns.first?.width == 430 && restored.tableColumns.first?.isHidden == false, "Private order/width/visibility did not restore")
        prefs.set(["unknown", "email", "email", "author"], forKey:"Log.Columns.Order")
        prefs.set(["email": -5.0, "author": 350.0], forKey:"Log.Columns.Widths")
        // Author both legacy widths as adjusted input. A retained modern
        // adjusted-column allowlist from the preceding test would deliberately
        // ignore the newly authored Author width.
        prefs.removeObject(forKey:"Log.Columns.Adjusted")
        let malformed = LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesGeometry:false,historyRegexExecutable:helper)
        defer { malformed.close() };mount(malformed); malformed.model.showWorkingTree = false; malformed.model.reload(); try await settle(malformed)
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
        try invoke(command("svn"))
        try require(svnColumn.isHidden && prefs.object(forKey:"Log.Column.Visible.svn") as? Bool == false, "SVN visibility not saved")
        let blockedEmail=try command("email")
        owner.model.busy = true;try invoke(blockedEmail)
        try require(prefs.bool(forKey:"Log.Column.Visible.email"), "Busy checkbox accepted retained command")
        owner.model.busy = false;try invoke(blockedEmail)
        try require(prefs.bool(forKey:"Log.Column.Visible.email"), "Busy-retired checkbox revived after admission restored")
        // Reset No preserves the exact accepted private layout. Reset Yes uses
        // the actual owned native question and its detached completion receipt.
        let beforeReset=prefs.dictionaryRepresentation().filter{$0.key.hasPrefix("Log.Column")}
        try await reset(false)
        try require(NSDictionary(dictionary:beforeReset).isEqual(to:prefs.dictionaryRepresentation().filter{$0.key.hasPrefix("Log.Column")}),"Reset No changed private column layout")
        try await reset(true)
        try await wait(owner,"Reset native default projection") {native.tableColumns.first?.identifier.rawValue=="graph" && native.tableColumn(withIdentifier:.init("email"))!.isHidden && !svnColumn.isHidden}
        try require(native.tableColumns.first?.identifier.rawValue == "graph" && native.tableColumn(withIdentifier:.init("email"))!.isHidden && !svnColumn.isHidden, "Reset lost source order/conditional defaults")
        try require(prefs.object(forKey:"Log.Column.Visible.email") == nil && prefs.stringArray(forKey:"Log.Columns.Order")?.first == "graph", "Reset did not save final layout")
        try FileManager.default.removeItem(at: metadata)
        owner.model.reload(); try await settle(owner); coordinator.menuNeedsUpdate(header)
        try require(header.item(withTitle:"SVN Rev") == nil && svnColumn.isHidden, "Removed SVN metadata retained available column")
        let globalAfter = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Log.Column") || $0.key.contains("TurtleGit.Log.RevisionColumns") }
        try require(NSDictionary(dictionary:globalKeys).isEqual(to:globalAfter), "Private layout changed global column preferences")
        let finalHead = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead == head && (try Data(contentsOf:root.appendingPathComponent(".git/index"))) == index, "Column interaction mutated HEAD/index")
        let closedEmail=try command("email"),privateBeforeClose=prefs.dictionaryRepresentation().filter{$0.key.hasPrefix("Log.Column")}
        reopened.close();owner.close();try invoke(closedEmail)
        try require(NSDictionary(dictionary:privateBeforeClose).isEqual(to:prefs.dictionaryRepresentation().filter{$0.key.hasPrefix("Log.Column")}),"Closed owner accepted retained column command")
        try await wait(owner,"owned column windows and readers drained") {
            LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 &&
                [owner,reopened,malformed].allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil}
        }
        print("Log columns: source SVN availability and batched cells, private checkbox/width/order restore, contextual Reset, busy/closed guards and global/repository preservation passed. Owned windows closed.")
    }
}
