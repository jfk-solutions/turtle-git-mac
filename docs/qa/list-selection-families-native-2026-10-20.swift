// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Actual dialog/list consumers, separate from the adapter's synthetic geometry
/// fixture. Every repository, preferences domain, clipboard and window is owned.
@MainActor enum ListSelectionFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"List family wait at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return[root]+root.subviews.flatMap{views($0)}}
    static func show(_ owner:NSWindowController) {
        guard let window=owner.window else{return};window.alphaValue=0;window.setFrameOrigin(.init(x:-16000,y:-16000));owner.showWindow(nil)
    }
    static func table(_ owner:NSWindowController,primary:String)->NSTableView? {
        views(owner.window?.contentView).compactMap{$0 as? NSTableView}.first{!($0 is NSOutlineView) && $0.tableColumn(withIdentifier:.init(primary)) != nil}
    }
    static func exercise(_ table:NSTableView,primary:String,preferences:UserDefaults,other:UserDefaults,name:String) async throws {
        try await wait {table.window?.contentView?.layoutSubtreeIfNeeded();return table.numberOfRows>0 && NativeListSelection.usesFullRowSelection(in:table)==false && NativeListSelection.labelRect(in:table,row:0) != nil}
        let column=table.tableColumn(withIdentifier:.init(primary))!
        let originalIndex=table.tableColumns.firstIndex{$0 === column}!,originalHidden=column.isHidden
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let selected=table.selectedRowIndexes
        let label=NativeListSelection.labelRect(in:table,row:0)!,row=table.rect(ofRow:0)
        try require(label.width>0 && label.width<row.width-12 && label.minX>=table.frameOfCell(atColumn:originalIndex,row:0).minX,"\(name): label-only geometry stretched across row")
        other.set(true,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:other)
        try require(NativeListSelection.usesFullRowSelection(in:table)==false,"\(name): read another preferences domain")
        preferences.set(true,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:preferences)
        try await wait {NativeListSelection.usesFullRowSelection(in:table)==true}
        try require(table.selectedRowIndexes==selected,"\(name): full-row change mutated semantic selection")
        preferences.set(false,forKey:"FullRowSelect");NotificationCenter.default.post(name:UserDefaults.didChangeNotification,object:preferences)
        try await wait {NativeListSelection.usesFullRowSelection(in:table)==false}
        if table.tableColumns.count>1 {
            // Status lists pin the checkbox at column zero. Reorder among the
            // permitted data columns rather than asking that existing guard
            // to accept a path before the state checkbox.
            let firstData=table.tableColumns.first?.identifier.rawValue=="check" ? 1:0
            let destination=originalIndex==firstData ? table.tableColumns.count-1:firstData
            table.moveColumn(originalIndex,toColumn:destination);table.layoutSubtreeIfNeeded()
            do {try await wait {table.layoutSubtreeIfNeeded();return NativeListSelection.labelRect(in:table,row:0)?.intersects(table.frameOfCell(atColumn:destination,row:0))==true}}
            catch {throw Failure(description:"\(name): reordered label=\(String(describing:NativeListSelection.labelRect(in:table,row:0))) target=\(table.frameOfCell(atColumn:destination,row:0)) actualIndex=\(table.tableColumns.firstIndex{$0 === column} ?? -1) hidden=\(column.isHidden) columns=\(table.tableColumns.map{$0.identifier.rawValue}) frame=\(table.frame) bounds=\(table.bounds)") }
            let reordered=NativeListSelection.labelRect(in:table,row:0)
            try require(reordered != nil && reordered!.intersects(table.frameOfCell(atColumn:destination,row:0)),"\(name): primary label followed display column zero after reorder")
            column.isHidden=true
            try require(NativeListSelection.labelRect(in:table,row:0)==nil,"\(name): hidden source label painted another column")
            column.isHidden=originalHidden;table.moveColumn(table.tableColumns.firstIndex{$0 === column}!,toColumn:originalIndex)
        }
        try require(table.selectedRowIndexes==selected,"\(name): column presentation lost selection")
        table.menu?.update()
    }
    static func verify(root:URL,git:URL) async throws {
        let folder=root.appendingPathComponent("families-"+UUID().uuidString),work=folder.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
        let repository=GitRepository(root:work,executable:git,libgit2Configuration:.init(enabled:false))
        _ = try await repository.run(["init","-b","main"])
        for(key,value) in [("user.name","List QA"),("user.email","list@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        try Data("base\n".utf8).write(to:work.appendingPathComponent("file"));try await repository.stage(["file"]);_ = try await repository.commit(message:"base")
        _ = try await repository.run(["branch","topic"]);_ = try await repository.run(["tag","release"])
        try Data("new\n".utf8).write(to:work.appendingPathComponent("new.txt"))
        let suite="TurtleGit.ListFamilies."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,otherSuite=suite+".other",other=UserDefaults(suiteName:otherSuite)!
        prefs.set(false,forKey:"FullRowSelect");prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let pasteboard=NSPasteboard.withUniqueName()
        var owners:[NSWindowController]=[],retainedTables:[NSTableView]=[],lfs:LFSLocksWindowModel?
        ProgressActionLog.install(store:ActionLogStore(storageURL:folder.appendingPathComponent("actions.log")),preferences:prefs)
        DialogGeometry.install(preferences:prefs)
        func cleanup() async {
            lfs?.retire();owners.reversed().forEach{$0.close()}
            for owner in owners {owner.window?.contentViewController=nil;owner.window?.contentView=nil}
            for _ in 0..<2000 {
                if CommitContainingReferencesWindowController.activeOperations==0 && RepositoryBrowserWindowModel.activeOperations==0 && SynchronizationWindowModel.activeInlineOperations==0 && LFSLocksWindowModel.activeOperations==0 {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite);other.removePersistentDomain(forName:otherSuite);pasteboard.releaseGlobally();DialogGeometry.install(preferences:.standard)
            try? FileManager.default.removeItem(at:folder)
        }
        do {
            let references=ReferenceBrowserWindowController(repository:repository,access:nil,initial:"refs/heads/topic",preferences:prefs,picking:false){_ in}
            owners.append(references);show(references);references.commandKeyWindow={[weak references] in references?.window};references.model.load()
            try await wait {!references.model.busy && (table(references,primary:"name")?.numberOfRows ?? 0)>0}
            let refs=table(references,primary:"name")!;retainedTables.append(refs)
            try await exercise(refs,primary:"name",preferences:prefs,other:other,name:"Browse refs")
            try require(views(references.window?.contentView).compactMap{$0 as? NSOutlineView}.allSatisfy{NativeListSelection.usesFullRowSelection(in:$0)==nil},"Namespace tree accidentally inherited list policy")
            references.model.select(["refs/heads/topic"],last:"refs/heads/topic")
            try await wait {refs.selectedRowIndexes.count==1}
            references.window?.makeFirstResponder(refs)
            let f2=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:refs.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:120)!
            refs.keyDown(with:f2)
            try await wait {references.model.renameReference != nil}
            try require(views(refs).compactMap{$0 as? NSTextField}.contains{$0.isEditable},"Reference inline rename was lost by selection presentation")
            references.model.cancelRename();references.window?.makeFirstResponder(refs)
            let contains=CommitContainingReferencesWindowController(repository:repository,access:nil,revision:"HEAD",preferences:prefs)
            owners.append(contains);show(contains);contains.refresh()
            try await wait {!contains.busy && !contains.rows.isEmpty}
            retainedTables.append(contains.table)
            var copied="";contains.copyText={copied=$0}
            try await exercise(contains.table,primary:"reference",preferences:prefs,other:other,name:"Contains")
            contains.copySelection();try require(copied.contains(contains.rows[0].rawValue),"Contains native selection no longer reaches Copy")
            let add=AddWindowController(repository:repository,access:nil,defaults:prefs)
            owners.append(add);show(add);try await add.model.read()
            try await wait {table(add,primary:"path")?.numberOfRows ?? 0 > 0}
            let addTable=table(add,primary:"path")!;retainedTables.append(addTable)
            try await exercise(addTable,primary:"path",preferences:prefs,other:other,name:"Add")
            let checkColumn=addTable.column(withIdentifier:.init("check"))
            guard let checkbox=addTable.view(atColumn:checkColumn,row:0,makeIfNecessary:true) as? NSButton else{throw Failure(description:"Add native checkbox unavailable")}
            let previous=add.model.checked;checkbox.performClick(nil)
            try require(add.model.checked != previous,"Add checkbox lost its independent action")
            let progress=FileOperationProgressState(preferences:prefs);progress.begin("git add");progress.append("Added","new.txt",kind:.file)
            progress.publishClipboard={text in pasteboard.clearContents();pasteboard.setString(text,forType:.string)}
            let progressOwner=NSWindowController(window:NSWindow(contentRect:.init(x:-16000,y:-16000,width:700,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false))
            progressOwner.window!.isReleasedWhenClosed=false
            progressOwner.window!.contentViewController=NSHostingController(rootView:FileOperationProgressTable(state:progress,icon:.add,available:true,repository:work))
            owners.append(progressOwner);show(progressOwner)
            try await wait {table(progressOwner,primary:"action")?.numberOfRows==2}
            let progressTable=table(progressOwner,primary:"action")!;retainedTables.append(progressTable)
            try await exercise(progressTable,primary:"action",preferences:prefs,other:other,name:"File progress")
            (progressTable as? FileOperationProgressNativeTable)?.copySelection()
            try require(pasteboard.string(forType:.string)?.contains("Command: git add")==true,"Progress selection/copy stopped forwarding")
            let locks=LFSLocksWindowModel(repository:repository,access:nil,defaults:prefs);lfs=locks;locks.refreshLocksAfterOperation=false
            locks.lockChange={paths,_,report in let results=paths.map{LFSFileResult(path:$0,success:true,output:"locked")};results.forEach(report);return LFSBatchResult(files:results)}
            await locks.perform(paths:["new.txt"],locked:true)
            let lfsOwner=NSWindowController(window:NSWindow(contentRect:.init(x:-16000,y:-16000,width:700,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false))
            lfsOwner.window!.isReleasedWhenClosed=false;lfsOwner.window!.contentViewController=NSHostingController(rootView:LFSProgressTable(model:locks));owners.append(lfsOwner);show(lfsOwner)
            try await wait {table(lfsOwner,primary:"action")?.numberOfRows ?? 0 > 0}
            let lfsTable=table(lfsOwner,primary:"action")!;retainedTables.append(lfsTable)
            try await exercise(lfsTable,primary:"action",preferences:prefs,other:other,name:"LFS progress")
            let server=folder.appendingPathComponent("remote.git")
            _ = try await repository.run(["clone","--bare","--",work.path,server.path])
            _ = try await repository.run(["remote","add","origin",server.path])
            let sync=SynchronizationWindowController(repository:repository,access:nil,preferences:prefs)
            owners.append(sync);show(sync)
            try await wait {!sync.model.busy && sync.model.remoteChoices.contains("origin")}
            sync.model.localBranch="main";sync.model.remote="origin";sync.model.remoteBranch="main"
            sync.model.fetch(.fetch)
            try await wait {!sync.model.busy && !sync.model.referenceRows.isEmpty && sync.model.tab==3}
            try await wait {table(sync,primary:"0")?.numberOfRows ?? 0 > 0}
            let remoteRefs=table(sync,primary:"0")!;retainedTables.append(remoteRefs)
            try await exercise(remoteRefs,primary:"0",preferences:prefs,other:other,name:"Sync references")
            sync.model.compareTags()
            try await wait {!sync.model.busy && sync.model.tab==7 && !sync.model.tagRows.isEmpty}
            try await wait {table(sync,primary:"0")?.numberOfRows ?? 0 > 0}
            let tags=table(sync,primary:"0")!;retainedTables.append(tags)
            try await exercise(tags,primary:"0",preferences:prefs,other:other,name:"Sync tags")
            let browser=RepositoryBrowserWindowController(repository:repository,access:nil,revision:"HEAD",preferences:prefs)
            owners.append(browser);show(browser)
            try await wait {browser.contentsTable?.numberOfRows ?? 0 > 0}
            let contents=browser.contentsTable!;retainedTables.append(contents)
            let primary="name"
            try await exercise(contents,primary:primary,preferences:prefs,other:other,name:"Repository browser")
            let log=LogWindowController(repository:repository,access:nil,labelDefaults:prefs,loadsImmediately:false)
            owners.append(log);show(log)
            try await wait {table(log,primary:"graph") != nil}
            try require(NativeListSelection.usesFullRowSelection(in:table(log,primary:"graph")!)==nil,"Source-forced Log list inherited configurable label-only policy")
            await cleanup()
            try await wait {retainedTables.allSatisfy{NativeListSelection.usesFullRowSelection(in:$0)==nil}}
            try require(CommitContainingReferencesWindowController.activeOperations==0 && RepositoryBrowserWindowModel.activeOperations==0 && SynchronizationWindowModel.activeInlineOperations==0 && LFSLocksWindowModel.activeOperations==0,"List family owned reads did not drain")
        } catch {await cleanup();throw error}
    }
}
