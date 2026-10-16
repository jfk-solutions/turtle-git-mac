import AppKit
import TurtleGitCore

struct PatchFilePanelVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func wait(_ predicate:()->Bool) async throws {
        for _ in 0..<1500 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Patch file panel did not settle")
    }
    @MainActor static func table(in view:NSView?)->NSTableView? {
        guard let view else {return nil}
        if let table=view as? NSTableView,table.identifier?.rawValue=="TurtleGit.Patch.Files" {return table}
        return view.subviews.compactMap {table(in:$0)}.first
    }
    @MainActor static func send(_ item:NSMenuItem) {if let action=item.action {_=NSApp.sendAction(action,to:item.target,from:item)}}
    @MainActor static func capture(_ window:NSWindow,name:String) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PATCH_PANEL_CAPTURE"] else {return}
        window.alphaValue=1;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);try await Task.sleep(nanoseconds:500_000_000)
            window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
            let task=Process();task.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");task.arguments=["-x","-o","-l",String(window.windowNumber),URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png").path]
            try task.run();task.waitUntilExit();try require(task.terminationStatus==0,"Owned patch-panel capture failed")
        }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch panel QA"),("user.email","panel@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let paths=["one.txt","two.txt","three.txt"]
        for path in paths {try Data("before 🐢\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_=try await repo.commit(message:"before")
        for path in paths {try Data("after 🐢\n".utf8).write(to:root.appendingPathComponent(path))}
        let patch=try await repo.run(["diff","--"]).stdout
        for path in paths {try Data("before 🐢\n".utf8).write(to:root.appendingPathComponent(path))}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.PatchPanel."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Native patch files",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil)
        try await wait{!model.busy && model.editor?.filtering==false && table(in:window.contentView) != nil}
        let files=model.review!.files,first=model.focusedFile!,second=files.first{$0.id != first}!.id
        let native=table(in:window.contentView)!,coordinator=native.delegate as! WorkingTreePatchNativeFileList.Coordinator
        let rootMenu=NSMenu(title:"Patch review"),menus=owner.editorCommandMenu!
        menus.keyWindow={window};menus.applicationMenu={rootMenu};menus.install(in:rootMenu)
        try require(rootMenu.items.allSatisfy {$0.submenu?.items.isEmpty != true},"Review installed an empty command root")
        try require(native.tableColumns.map(\.title)==["Path","State"] && native.allowsMultipleSelection,"Native columns/selection differ")
        let initialEditor=model.editor
        let secondRow=files.firstIndex{$0.id==second}!
        native.selectRowIndexes(IndexSet(integer:secondRow),byExtendingSelection:false)
        try require(model.highlightedFiles==[second] && model.focusedFile==first && model.editor===initialEditor && !model.busy,"Highlight unexpectedly previewed/replaced file")
        let context=coordinator.contextMenu()
        try require(context.items.map(\.title)==["Preview patched file","Patch all files","Patch selected files"] && context.items.allSatisfy{$0.image != nil},"Source context order/icons")
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        window.makeFirstResponder(native);native.keyDown(with:event)
        try await wait{!model.busy && model.focusedFile==second && model.editor?.filtering==false}
        try require(model.editor !== initialEditor,"Return did not preview selected file")
        native.selectRowIndexes(IndexSet(integersIn:0..<2),byExtendingSelection:false)
        let multiple=coordinator.contextMenu();try require(!multiple.items[0].isEnabled && multiple.items[2].isEnabled,"Multiple selection gates")
        let listItem=try MergeCommandMenusVerification.item("Patch file list",in:rootMenu)
        window.makeFirstResponder(native);send(listItem)
        try await wait{!model.fileListVisible && table(in:window.contentView)==nil}
        try require(window.firstResponder !== native,"Hidden list retained keyboard focus")
        send(listItem);try await wait{model.fileListVisible && table(in:window.contentView) != nil}
        let current=table(in:window.contentView)!,currentCoordinator=current.delegate as! WorkingTreePatchNativeFileList.Coordinator
        try require(model.highlightedFiles==Set(files.prefix(2).map(\.id)),"Panel toggle lost highlighted selection")
        try require(!coordinator.validateMenuItem(context.items[1]),"Unmounted list kept captured actions live")
        current.selectRowIndexes(IndexSet(integer:secondRow),byExtendingSelection:false)
        let stale=currentCoordinator.contextMenu();model.refresh()
        try await wait{!model.busy && model.editor?.filtering==false}
        send(stale.items[1]);try require(!model.busy && model.appliedPaths.isEmpty,"Stale generation applied files")
        model.editor?.setPatchEditing(true)
        try require(!currentCoordinator.selectionShouldChange(in:current) && !currentCoordinator.contextMenu().items[1].isEnabled,"Editing list/action gates")
        model.editor?.setPatchEditing(false)
        try await capture(window,name:"patch-file-panel")
        // Native Patch all keeps exact per-file status and the captured target.
        let bad=files[1];try Data("external conflict\n".utf8).write(to:root.appendingPathComponent(bad.path))
        let apply=currentCoordinator.contextMenu();send(apply.items[1])
        try await wait{!model.busy}
        try require(model.fileState(bad)=="error" && model.appliedPaths.count==2,"Native Patch all did not retain per-file continuation/status")
        for file in files where file.id != bad.id {try require(try Data(contentsOf:root.appendingPathComponent(file.path))==Data("after 🐢\n".utf8),"Patch all changed wrong bytes")}
        currentCoordinator.update()
        let row=files.firstIndex{$0.id==bad.id}!;current.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        let errors=currentCoordinator.contextMenu();send(errors.items[0]);try require(!model.comparisonNotice.isEmpty,"Failed-row preview lost error diagnostic")
        model.previewTab=1;try await capture(window,name:"patch-file-panel-results")
        let retired=currentCoordinator.contextMenu();owner.close();send(retired.items[1])
        try require(model.retired && !model.busy,"Retired file action dispatched")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Native panel altered HEAD/index")
        print("PASS: native source columns/icons, separate highlight/preview, Return, multiple-selection context actions, hidden-list focus/restoration, stale/unmounted/dirty/retired fences, per-file Patch all/error preview, exact file bytes and untouched HEAD/index; owned window closed")
    }
}
