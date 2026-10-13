import AppKit
import TurtleGitCore

@main struct RepositoryBrowserTableVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ condition:Bool,_ message:String) throws { if !condition { throw Failure(description:message) } }
    static func requireEntry(_ entry:RepositoryBrowserEntry?) throws -> RepositoryBrowserEntry { guard let entry else { throw Failure(description:"Missing folder") }; return entry }
    @MainActor static func find(_ view:NSView) -> NSTableView? {
        if let table=view as? NSTableView,table.accessibilityLabel()=="Repository contents" { return table }
        return view.subviews.compactMap(find).first
    }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1500 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"Browser table timeout at \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Browser table failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Browser Table QA"),("user.email","table@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for (path,text) in [("file2.txt","second\n"),("file10.bin","longer binary 雪🦎\n"),("folder/deep/雪.txt","nested bytes\n")] {
            try FileManager.default.createDirectory(at:root.appendingPathComponent(path).deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:root.appendingPathComponent(path))
        }
        try await repo.stage(["file2.txt","file10.bin","folder"]);_ = try await repo.commit(message:"Table baseline")
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let suite="TurtleGit.BrowserTable.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:hash,preferences:prefs)
        defer { owner.close() }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { !owner.model.busy && find(owner.window!.contentView!)?.numberOfRows==3 }
        let model=owner.model,table=find(owner.window!.contentView!)!,coordinator=table.delegate as! RepositoryBrowserContentsTable.Coordinator
        try require(table.tableColumns.map { $0.identifier.rawValue }==["name","extension","size"] && table.allowsMultipleSelection,"Native defaults")
        table.selectRowIndexes(IndexSet([1,2]),byExtendingSelection:false)
        try await wait { model.selection.count==2 }
        let menu=table.menu!;coordinator.menuNeedsUpdate(menu)
        try require(menu.items.filter { !$0.isSeparatorItem }.map(\.title)==["Revert to this revision","Copy to clipboard","Copy hash"],"Multi-file source menu")
        try require(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil && $0.isEnabled },"Original context artwork/enabled state")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);coordinator.menuNeedsUpdate(menu)
        try require(menu.items.filter { !$0.isSeparatorItem }.map(\.title)==["Open","Show log","Copy to clipboard","Copy hash"],"Folder menu conditions")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);coordinator.menuNeedsUpdate(menu)
        try require(menu.items.first?.title=="Open" && menu.items.contains { $0.title=="Blame" } && menu.items.contains { $0.title=="Save revision to…" },"File menu conditions")
        var logReply:(String,String)?
        model.onLog={ logReply=($0,$1) }
        let log=menu.items.first { $0.title=="Show log" }!;try require(NSApplication.shared.sendAction(log.action!,to:log.target,from:log),"Native Log dispatch")
        try require(logReply?.0==model.selected.first?.path && logReply?.1==hash,"Pinned context target")
        let originalLogPath=logReply!.0
        table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false)
        logReply=nil;_ = NSApplication.shared.sendAction(log.action!,to:log.target,from:log)
        try require(logReply?.0==originalLogPath,"Retained menu followed a new selection")
        let privateBoard=NSPasteboard(name:.init("TurtleGit.BrowserActions."+UUID().uuidString));defer { privateBoard.releaseGlobally() }
        model.selection=Set(model.entries.filter { $0.kind != .directory }.map(\.id))
        model.copy(pasteboard:privateBoard)
        try require(privateBoard.string(forType:.string)==model.selected.map { $0.name+"\r\n" }.joined(),"Name clipboard source records differ")
        model.copy(hashes:true,pasteboard:privateBoard)
        try require(privateBoard.string(forType:.string)==model.selected.map(\.objectID).joined(separator:"\r\n"),"Hash clipboard source separators differ")
        model.copyFolder("folder",hashes:true,pasteboard:privateBoard)
        let folder=try requireEntry(model.entries.first { $0.kind == .directory })
        try require(privateBoard.string(forType:.string)==folder.objectID,"Folder copy used the commit hash")
        model.copyFolder("",hashes:true,pasteboard:privateBoard);try require(privateBoard.string(forType:.string)==model.snapshot?.treeID,"Root copy used a non-tree hash")
        let rootPromise=model.folderPromise("")!,folderPromise=model.folderPromise("folder")!
        let staleTarget=model.menuTarget()!
        model.busy=true;logReply=nil;_ = NSApplication.shared.sendAction(log.action!,to:log.target,from:log)
        try require(logReply==nil && model.folderPromise("")==nil,"Busy browser dispatched or began drag")
        model.busy=false;model.openFolder("folder")
        try await wait { model.snapshot?.directory=="folder" }
        try require(!model.acceptsMenu(staleTarget),"Navigation retained old menu context")
        logReply=nil;_ = NSApplication.shared.sendAction(log.action!,to:log.target,from:log);try require(logReply==nil,"Stale menu dispatched after navigation")
        model.openFolder("");try await wait { model.snapshot?.directory=="" }
        try require(!model.acceptsMenu(staleTarget),"Returning to a directory revived a retired menu")
        model.selection=[];model.copy(pasteboard:privateBoard)
        try require(privateBoard.string(forType:.string)==model.snapshot?.treeID,"Empty selection cleared clipboard")

        let header=table.headerView as! RepositoryBrowserColumnHeader
        let columns=header.buildMenu()!,hide=columns.items.first { $0.title=="Extension" }!
        try require(NSApplication.shared.sendAction(hide.action!,to:hide.target,from:hide),"Native header toggle")
        try await wait { table.tableColumns.first { $0.identifier.rawValue=="extension" }!.isHidden }
        try require(columns.items.first { $0.title=="Name" }?.isEnabled==false,"Name must remain visible")
        table.moveColumn(2,toColumn:0);table.tableColumns[0].width=187;coordinator.saveLayout()
        let saved=model.columns;try require(saved.order==["size","name","extension"] && saved.widths["size"]==187,"Adjusted order/width")
        table.sortDescriptors=[NSSortDescriptor(key:"size",ascending:false)]
        try await wait { model.sortOrder.first?.order == .reverse && model.entries[0].kind == .directory }
        try await wait { table.numberOfRows==3 }
        try require(model.entries[1].sizeSort>=model.entries[2].sizeSort,"Numeric size sorting with folders first")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
        let selected=model.selection
        let nameIndex=table.tableColumns.firstIndex { $0.identifier.rawValue=="name" }!
        coordinator.fit(nameIndex,headers:true);try require(model.columns.widths["name"] != nil && model.selection==selected,"Content/header fitting selection")
        model.confirmResetColumns={ false };model.requestResetColumns();try await wait { !model.confirmingColumns }
        try require(model.columns.order==saved.order && model.columns.visible==saved.visible,"No reset must retain columns")
        var reply:CheckedContinuation<Bool,Never>?
        model.confirmResetColumns={ await withCheckedContinuation { reply=$0 } };model.requestResetColumns()
        try await wait { reply != nil }
        try require(!model.canEditColumns && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Reset/Quit ownership")
        let blocked=model.columns;model.saveColumns(RepositoryBrowserColumns());model.requestResetColumns();model.refresh()
        try require(model.columns==blocked && model.confirmingColumns,"Duplicate/reset/refresh gates")
        let accept=reply;reply=nil;accept?.resume(returning:true);try await wait { !model.confirmingColumns && model.columns==RepositoryBrowserColumns() }
        try await wait { table.tableColumns.map { $0.identifier.rawValue }==RepositoryBrowserColumns.names && table.tableColumns.allSatisfy { !$0.isHidden } }
        let snapshot=model.snapshot!,originalEntries=model.entries
        // Separate promised items are pinned before the branch moves and owner closes.
        let providers=try originalEntries.enumerated().map { index,entry -> NSFilePromiseProvider in
            guard let provider=coordinator.tableView(table,pasteboardWriterForRow:index) as? NSFilePromiseProvider else { throw Failure(description:"No promise for \(entry.name)") }
            return provider
        }
        try Data("new current bytes\n".utf8).write(to:root.appendingPathComponent("file2.txt"));try await repo.stage(["file2.txt"]);_ = try await repo.commit(message:"Move branch")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let destination=root.appendingPathComponent("deliveries");try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        model.saveColumns(saved)
        let retiredColumns=model.columns
        model.requestResetColumns();try await wait { reply != nil };owner.close();let late=reply;reply=nil;late?.resume(returning:true)
        try await wait { RepositoryBrowserWindowModel.activeOperations==0 };try require(model.columns==retiredColumns && !model.active,"Retired reset wrote preferences")
        for (provider,name) in [(rootPromise,"root-export"),(folderPromise,"folder-export")] {
            let delegate=provider.userInfo as! RepositoryBrowserFilePromise
            var complete=false,error:Error?
            delegate.filePromiseProvider(provider,writePromiseTo:destination.appendingPathComponent(name)) { error=$0;complete=true }
            try await wait { complete && RepositoryBrowserExportFiles.activeLoads==0 }
            try require(error==nil,"Folder/root promise delivery failed")
        }
        try require(try Data(contentsOf:destination.appendingPathComponent("root-export/file2.txt"))==Data("second\n".utf8),"Root promise lost pinned bytes")
        try require(try Data(contentsOf:destination.appendingPathComponent("folder-export/deep/雪.txt"))==Data("nested bytes\n".utf8),"Folder promise lost hierarchy")
        for provider in providers {
            let delegate=provider.userInfo as! RepositoryBrowserFilePromise,name=delegate.filePromiseProvider(provider,fileNameForType:provider.fileType)
            try require(delegate.snapshot.objectID==snapshot.objectID,"Promise lost pinned object")
            var result:Error?,finished=false
            delegate.filePromiseProvider(provider,writePromiseTo:destination.appendingPathComponent(name)) { result=$0;finished=true }
            try await wait { finished && RepositoryBrowserExportFiles.activeLoads==0 };if let result { throw result }
        }
        try require(try Data(contentsOf:destination.appendingPathComponent("file2.txt"))==Data("second\n".utf8),"Promise followed moved branch")
        try require(try Data(contentsOf:destination.appendingPathComponent("folder/deep/雪.txt"))==Data("nested bytes\n".utf8),"Folder promise did not preserve hierarchy")
        // Re-delivery fails without replacing a receiver's existing file.
        let provider=providers.first { ($0.userInfo as! RepositoryBrowserFilePromise).entry?.name=="file2.txt" }!,delegate=provider.userInfo as! RepositoryBrowserFilePromise
        var rejected=false,finished=false
        delegate.filePromiseProvider(provider,writePromiseTo:destination.appendingPathComponent("file2.txt")) { rejected=$0 != nil;finished=true }
        try await wait { finished && RepositoryBrowserExportFiles.activeLoads==0 };try require(rejected,"Existing destination replaced")
        try require(try Data(contentsOf:destination.appendingPathComponent("file2.txt"))==Data("second\n".utf8),"Rejected delivery damaged destination")
        try require(try FileManager.default.contentsOfDirectory(atPath:destination.path).allSatisfy { !$0.hasPrefix(".turtlegit-promise-") },"Promise staging leaked")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==afterHead && index==afterIndex,"Promises mutated Git state")
        let reopened=RepositoryBrowserWindowController(repository:repo,access:nil,revision:hash,preferences:prefs);defer { reopened.close() }
        reopened.window?.contentView?.layoutSubtreeIfNeeded();try await wait { !reopened.model.busy && find(reopened.window!.contentView!)?.numberOfRows==3 }
        try require(reopened.model.columns==retiredColumns,"Reopened layout differs")
        for theme in [NSAppearance.Name.aqua,.darkAqua] { reopened.window?.appearance=NSAppearance(named:theme);reopened.window?.contentView?.layoutSubtreeIfNeeded();try require(find(reopened.window!.contentView!)?.numberOfRows==3,"Theme lost rows") }
        if CommandLine.arguments[3]=="repository-browser-table-captures" {
            reopened.model.saveColumns(RepositoryBrowserColumns())
            try await wait { find(reopened.window!.contentView!)?.tableColumns.allSatisfy { !$0.isHidden } == true }
            reopened.model.selection=["file2.txt"]
            try await capture(reopened.window!)
        }
        reopened.close();try await wait { RepositoryBrowserWindowModel.activeOperations==0 }
        print("Repository Browser native table: source column/menu/icon conditions, multi-selection and pinned Log target, visibility/order/width/fitting persistence, numeric sort, No/Yes/late Reset and Quit guards, separate historical file/folder promises after owner close and moved branch, destination collision preservation/cleanup, light/dark and reopened layout passed. HEAD/index retained and owned windows closed.")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/browser-table-captures-2026-10-13")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.appearance=window.appearance;window.center();window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps:true);try await Task.sleep(nanoseconds:400_000_000)
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments=["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent("browser-table-"+suffix+".png").path]
            try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Owned browser capture failed")
            window.orderOut(nil)
        }
    }

}
