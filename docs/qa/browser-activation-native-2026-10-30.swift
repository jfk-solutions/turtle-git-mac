// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@main struct BrowserActivationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Browser activation timeout: "+message)
    }
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func key(_ window:NSWindow,_ code:UInt16,_ flags:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
    }
    /// AppKit's real mouse tracker receives its matching release from this
    /// private application's queue. No event is posted to the user's desktop.
    @MainActor static func doubleClick(_ table:NSTableView,row:Int,flags:NSEvent.ModifierFlags = .shift)throws {
        guard let window=table.window,row>=0,row<table.numberOfRows else{throw Failure(description:"Invalid activation row")}
        let rectangle=table.frameOfCell(atColumn:0,row:row)
        let point=table.convert(NSPoint(x:rectangle.midX,y:rectangle.midY),to:nil)
        let stamp=ProcessInfo.processInfo.systemUptime
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:flags,timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:11,clickCount:2,pressure:1),
              let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:flags,timestamp:stamp+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:12,clickCount:2,pressure:0) else{throw Failure(description:"Cannot create owned AppKit activation")}
        // A prohibited background receiver cannot become a physical key
        // window. Inject only this owned window's public key-state getter while
        // AppKit processes the event, forwarding every other window unchanged.
        // Native dispatch, hit testing, selection and the real double-action
        // remain intact; this proves routing, not desktop focus acceptance.
        let keySelector=#selector(getter:NSWindow.isKeyWindow)
        guard let keyMethod=class_getInstanceMethod(NSWindow.self,keySelector) else{throw Failure(description:"Missing public native window key-state getter")}
        let originalKey=method_getImplementation(keyMethod)
        let ownedKey:@convention(block)(NSWindow)->Bool = {source in
            if source === window{return true}
            typealias Getter=@convention(c)(NSWindow,Selector)->Bool
            return unsafeBitCast(originalKey,to:Getter.self)(source,keySelector)
        }
        let ownedKeyIMP=imp_implementationWithBlock(ownedKey)
        class_replaceMethod(NSWindow.self,keySelector,ownedKeyIMP,method_getTypeEncoding(keyMethod))
        defer{class_replaceMethod(NSWindow.self,keySelector,originalKey,method_getTypeEncoding(keyMethod));imp_removeBlock(ownedKeyIMP)}
        try require(window.isKeyWindow,"Owned Browser key-state injection failed")
        NSApp.postEvent(up,atStart:true)
        NSApp.sendEvent(down)
    }
    @MainActor static func main()async {
        do {try await verify()}
        catch {fputs("Browser activation failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath()
        let repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Browser Activation QA"),("user.email","browser@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        for (path,text) in [("first.txt","first historical bytes\n"),("second.txt","second historical bytes\n"),("folder/child.txt","nested historical bytes\n")] {
            let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try Data(text.utf8).write(to:url)
        }
        try await repository.stage(["."]);_=try await repository.commit(message:"Browser activation files")
        let child=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repository.run(["update-index","--add","--cacheinfo","160000,"+child+",module"])
        _=try await repository.commit(message:"Browser activation gitlink")
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BrowserActivation."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"EnableGravatar")
        defer{preferences.removePersistentDomain(forName:suite)}
        let controller=RepositoryBrowserWindowController(repository:repository,access:nil,revision:"HEAD",preferences:preferences),model=controller.model,window=controller.window!
        defer{controller.close()}
        window.alphaValue=0;window.setFrameOrigin(NSPoint(x:-24000,y:-24000));window.orderFront(nil);controller.commandKeyWindow={window}
        func table()->NSTableView? {views(window.contentView!).compactMap{$0 as? NSTableView}.first{$0.accessibilityLabel()=="Repository contents"}}
        func settle()->Bool {window.contentView!.layoutSubtreeIfNeeded();return !model.busy && table()?.numberOfRows==model.entries.count}
        try await wait("initial native contents"){settle() && model.entries.count==4}
        let list=table()!,coordinator=NativeListSelection.originalDelegate(of:list) as! RepositoryBrowserContentsTable.Coordinator
        let tree=views(window.contentView!).compactMap{$0 as? RepositoryBrowserFolderOutline}.first!
        func geometry()->[NSRect] {
            window.contentView!.layoutSubtreeIfNeeded()
            return [list.enclosingScrollView!.convert(list.enclosingScrollView!.bounds,to:window.contentView),tree.enclosingScrollView!.convert(tree.enclosingScrollView!.bounds,to:window.contentView),list.headerView!.convert(list.headerView!.bounds,to:window.contentView)]
        }
        func select(_ ids:Set<String>)async throws {
            model.selection=ids
            try await wait("native selected rows"){settle() && list.selectedRowIndexes.count==ids.count}
        }
        let entries=model.entries,first=entries.first{$0.path=="first.txt"}!,second=entries.first{$0.path=="second.txt"}!,folder=entries.first{$0.path=="folder"}!,module=entries.first{$0.path=="module"}!
        var opened=[ComparisonFileContent](),submodules=[(String,Bool)]()
        model.presentFile={content,_ in opened.append(content)}
        model.onSubmodule={comparison,entry,log in submodules.append((entry.path,log));if comparison.checkout != nil {model.error="Unexpected initialized fixture child"}}
        try await select([])
        let baseline=geometry()
        let selections:[Set<String>] = [[],[first.id],[module.id],[folder.id],[first.id,second.id],Set(entries.map(\.id))]
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance=NSAppearance(named:appearance)
            for selection in selections {
                try await select(selection)
                for _ in 0..<3 {await Task.yield();try require(geometry()==baseline,"Selection or appearance resized native Browser list/header")}
            }
        }
        try await select([first.id,second.id]);window.makeFirstResponder(list)
        coordinator.openClickedRow();try require(opened.isEmpty && submodules.isEmpty,"Initial no-row double-action opened a selected fallback")
        try require(window.performKeyEquivalent(with:key(window,36)) && opened.isEmpty,"Return opened a multi-selection")
        let chosen=model.entries.firstIndex{$0.id==second.id}!
        try require(list.doubleAction==#selector(RepositoryBrowserContentsTable.Coordinator.openClickedRow),"Native double-action still uses singleton menu routing")
        let actionSelector=#selector(RepositoryBrowserContentsTable.Coordinator.openClickedRow)
        guard let actionMethod=class_getInstanceMethod(RepositoryBrowserContentsTable.Coordinator.self,actionSelector) else{throw Failure(description:"Missing native Browser double-action method")}
        let originalAction=method_getImplementation(actionMethod)
        var actionReceipts=[String]()
        let observer:@convention(block)(AnyObject)->Void = {source in
            MainActor.assumeIsolated {
                if source === coordinator {
                    actionReceipts.append("clicked=\(list.clickedRow) selected=\(list.selectedRowIndexes) available=\(coordinator.available) enabled=\(list.isEnabled) key=\(window.isKeyWindow) event=\(String(describing:NSApp.currentEvent?.type))")
                }
                typealias Action=@convention(c)(AnyObject,Selector)->Void
                unsafeBitCast(originalAction,to:Action.self)(source,actionSelector)
            }
        }
        let observedAction=imp_implementationWithBlock(observer)
        class_replaceMethod(RepositoryBrowserContentsTable.Coordinator.self,actionSelector,observedAction,method_getTypeEncoding(actionMethod))
        defer{class_replaceMethod(RepositoryBrowserContentsTable.Coordinator.self,actionSelector,originalAction,method_getTypeEncoding(actionMethod));imp_removeBlock(observedAction)}
        try doubleClick(list,row:chosen)
        do {
            try await wait("clicked historical file read"){!model.busy && opened.count==1 && RepositoryBrowserWindowModel.activeOperations==0}
        } catch {
            fputs("Browser activation diagnostic: requested=\(chosen) actionReceipts=\(actionReceipts) clicked=\(list.clickedRow) selected=\(list.selectedRowIndexes) modelSelection=\(model.selection) target=\(String(describing:list.target)) action=\(String(describing:list.doubleAction)) available=\(coordinator.available) enabled=\(list.isEnabled) key=\(window.isKeyWindow) responder=\(String(describing:window.firstResponder)) busy=\(model.busy) active=\(model.active) error=\(model.error ?? "nil") opened=\(opened.map(\.path)) operations=\(RepositoryBrowserWindowModel.activeOperations)\n",stderr)
            throw error
        }
        try require(opened[0].path==second.path && opened[0].bytes==Data("second historical bytes\n".utf8),"Double-click did not open its exact historical row")
        try require(model.selection.count>1 && model.selection.contains(second.id),"Modified double-click did not exercise multiple retained highlights")
        try require(geometry()==baseline,"Historical read spinner resized native Browser list/header")
        try await select([folder.id,first.id])
        try doubleClick(list,row:model.entries.firstIndex{$0.id==folder.id}!)
        try await wait("clicked folder navigation"){settle() && model.snapshot?.directory=="folder"}
        try require(opened.count==1 && submodules.isEmpty && model.entries.map(\.path)==["folder/child.txt"],"Folder activation launched a file/submodule instead of navigating")
        model.openFolder("");try await wait("return to pinned root"){settle() && model.snapshot?.directory==""}
        try await select([module.id,first.id])
        try doubleClick(list,row:model.entries.firstIndex{$0.id==module.id}!)
        try await wait("clicked gitlink inspection"){!model.busy && submodules.count==1 && RepositoryBrowserWindowModel.activeOperations==0}
        try require(submodules[0].0==module.path && !submodules[0].1 && opened.count==1 && model.snapshot?.directory=="","Submodule activation used ordinary file or folder routing")
        // Native singleton Return remains live and uses the same pinned bytes.
        try await select([first.id]);window.makeFirstResponder(list)
        try require(window.performKeyEquivalent(with:key(window,36)),"Singleton Return was not consumed")
        try await wait("singleton Return historical read"){!model.busy && opened.count==2}
        try require(opened[1].path==first.path && opened[1].bytes==Data("first historical bytes\n".utf8),"Singleton Return lost exact bytes")
        // Action entry points cannot use a busy reload or retired coordinator,
        // even when AppKit still remembers a previously activated hit row.
        let generation=model.generation;model.refresh();coordinator.openClickedRow()
        try require(model.generation != generation,"Refresh did not retire prior snapshot")
        try await wait("reloaded snapshot"){settle() && model.snapshot?.directory==""}
        controller.close();coordinator.openClickedRow()
        try await wait("closed browser owned reads"){RepositoryBrowserWindowModel.activeOperations==0 && !model.active}
        try require(opened.count==2 && submodules.count==1,"Retired/reloading double-action delivered a late action")
        let after=try await repository.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Activation changed HEAD/index")
        for (path,text) in [("first.txt","first historical bytes\n"),("second.txt","second historical bytes\n"),("folder/child.txt","nested historical bytes\n")] {
            try require((try Data(contentsOf:root.appendingPathComponent(path)))==Data(text.utf8),"Activation changed working bytes")
        }
        print("PASS: Browser clicked-row activation with retained multi-selection (owned public key-state injected; no physical-focus proof); exact historical file bytes, folder/gitlink routing, singleton Return, invalid/busy/retired admission, stable light/dark selection/footer/header geometry and unchanged repository; owned window closed")
    }
}
