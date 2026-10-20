import AppKit
import TurtleGitCore

struct ReferencePresentationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {
        for _ in 0..<2500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Reference presentation timeout at line \(line)")
    }
    @MainActor static func find<T:NSView>(_ type:T.Type,in root:NSView?,label:String)->T? {
        guard let root else{return nil};if let view=root as? T,view.accessibilityLabel()==label{return view}
        return root.subviews.compactMap {find(type,in:$0,label:label)}.first
    }
    @MainActor static func key(_ window:NSWindow,_ code:UInt16,_ text:String = "",_ modifiers:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    @MainActor static func invoke(_ item:NSMenuItem)throws {try require(item.isEnabled && item.action != nil && NSApp.sendAction(item.action!,to:item.target,from:item),"Header action unavailable: "+item.title)}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (name,value) in [("user.name","Reference Fixture"),("user.email","refs@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",name,value])}
        try Data("reference fixture\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Reference presentation fixture with a deliberately long subject")
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let updates=(0..<40).map {"create refs/heads/topic-\(String(format:"%02d",$0)) \(hash)"}.joined(separator:"\n")+"\ncreate refs/tags/release \(hash)\n"
        _=try await repo.run(["update-ref","--stdin"],input:Data(updates.utf8))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),file=try Data(contentsOf:root.appendingPathComponent("file"))
        let suite="TurtleGit.RefPresentation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        var corrupt=ReferenceBrowserColumnLayout();corrupt.order=["bogus","hash","hash"];corrupt.visible=["hash"];corrupt.widths=["hash":404,"name":-2,"bogus":99];corrupt.divider = -1
        prefs.set(try JSONEncoder().encode(corrupt),forKey:ReferenceBrowserColumnLayout.key);prefs.set(999,forKey:"RefBrowserSortCol");prefs.set(7,forKey:"RefBrowserSortDesc")
        let owner=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/topic-01",preferences:prefs,picking:false){_ in},model=owner.model,window=owner.window!
        defer {owner.close()};owner.commandKeyWindow={window};window.alphaValue=0;window.orderFront(nil);model.load()
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.rows.count==41 && find(NSTableView.self,in:window.contentView,label:"References")?.numberOfRows==41}
        let table=find(NSTableView.self,in:window.contentView,label:"References")!,tree=find(NSOutlineView.self,in:window.contentView,label:"Reference namespaces")!,field=find(NSSearchField.self,in:window.contentView,label:"Filter references")!
        let coordinator=NativeListSelection.originalDelegate(of:table) as! ReferenceBrowserNativeView.Coordinator,header=table.headerView as! RepositoryBrowserColumnHeader,split=tree.enclosingScrollView!.superview as! NSSplitView
        try await wait {coordinator.positioned}
        try require(model.sortColumn=="name" && !model.descending && model.columnLayout.order.first=="hash" && model.columnLayout.order.count==9 && model.columnLayout.visible.contains("name") && model.columnLayout.divider==190,"Malformed persistence did not normalize source defaults")
        try require(table.tableColumn(withIdentifier:.init("hash"))!.width==404 && table.tableColumn(withIdentifier:.init("name"))!.width==210,"Invalid width or original hash width restoration")
        var menu=header.buildMenu()!
        try require(menu.items.map(\.title)==["Reset column order","","Tracked branch","Last Author Date","Last Commit","Last Author","Date Last Commit","Last Committer","SHA-1","Description"],"Source header order/name-column mask differs")
        let stale=menu.item(withTitle:"SHA-1")!
        var layout=model.columnLayout;layout.widths["hash"]=420;model.saveColumns(layout)
        let stable=model.columnLayout
        _=NSApp.sendAction(stale.action!,to:stale.target,from:stale);try require(model.columnLayout==stable,"Stale header popup changed replacement layout")
        menu=header.buildMenu()!;try invoke(menu.item(withTitle:"SHA-1")!)
        try await wait {table.tableColumn(withIdentifier:.init("hash"))!.isHidden}
        try require(!table.tableColumn(withIdentifier:.init("name"))!.isHidden,"Column menu hid mandatory branch name")
        // Real native reorder/resize notifications write the private store.
        table.moveColumn(table.column(withIdentifier:.init("name")),toColumn:0)
        table.tableColumn(withIdentifier:.init("name"))!.width=277
        coordinator.tableViewColumnDidResize(Notification(name:NSTableView.columnDidResizeNotification,object:table))
        try await wait {model.columnLayout.order.first=="name" && model.columnLayout.widths["name"]==277}
        split.setPosition(245,ofDividerAt:0);coordinator.splitViewDidResizeSubviews(Notification(name:NSSplitView.didResizeSubviewsNotification,object:split))
        try await wait {abs(model.columnLayout.divider-245)<1 && abs(model.displayedDivider-245)<1}
        let selected=model.selection,clip=table.enclosingScrollView!.contentView
        table.scrollRowToVisible(30);let viewport=clip.bounds.origin
        table.tableColumn(withIdentifier:.init("name"))!.width=280;coordinator.tableViewColumnDidResize(Notification(name:NSTableView.columnDidResizeNotification,object:table))
        await Task.yield();try await Task.sleep(nanoseconds:80_000_000)
        try require(model.selection==selected && abs(clip.bounds.origin.y-viewport.y)<1,"Column update reloaded/recentered the selected row")
        table.scrollRowToVisible(0)
        // Double-click the actual header boundary, including Shift header width.
        let nameIndex=table.column(withIdentifier:.init("name")),point=header.convert(NSPoint(x:header.headerRect(ofColumn:nameIndex).maxX,y:10),to:nil)
        let double=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:.shift,timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:2,pressure:1)!
        header.mouseDown(with:double)
        try require(table.tableColumn(withIdentifier:.init("name"))!.width>=80 && model.columnLayout.widths["name"]==Double(table.tableColumn(withIdentifier:.init("name"))!.width),"Native header auto-size did not persist")
        model.setFolder("refs/tags");try await wait {table.tableColumn(withIdentifier:.init("upstream"))!.isHidden && model.rows.count==1}
        model.setFolder("refs/heads");try await wait {!table.tableColumn(withIdentifier:.init("upstream"))!.isHidden && model.rows.count==41}
        try require(table.tableColumn(withIdentifier:.init("hash"))!.isHidden,"Namespace reset unrelated hidden columns")
        model.confirmResetColumns={false};let beforeReset=model.columnLayout;model.resetColumns();try await wait {!model.hasChild}
        try require(model.columnLayout==beforeReset,"Reset No changed layout")
        model.confirmResetColumns={true};model.resetColumns();try await wait {!model.hasChild && model.columnLayout.order==ReferenceBrowserColumnLayout.ids && model.columnLayout.widths.isEmpty}
        try require(model.columnLayout.divider==beforeReset.divider && model.columnLayout.visible==Set(ReferenceBrowserColumnLayout.ids),"Reset changed divider or lost source defaults")
        coordinator.tableView(table,didClick:table.tableColumn(withIdentifier:.init("hash"))!);coordinator.tableView(table,didClick:table.tableColumn(withIdentifier:.init("hash"))!)
        try require(model.sortColumn=="hash" && model.descending && prefs.integer(forKey:"RefBrowserSortCol")==7 && prefs.bool(forKey:"RefBrowserSortDesc"),"Source sort keys/order not saved")
        // Source Ctrl-E plus native Cmd-E; Escape clears only the active filter.
        model.query="topic";model.refilter();try await wait {field.stringValue=="topic"}
        try require(window.performKeyEquivalent(with:key(window,14,"e",.control)),"Control-E not consumed")
        try require(field.currentEditor() === window.firstResponder && field.currentEditor()?.selectedRange==NSRange(location:0,length:5),"Filter did not receive focus/Select All")
        _=window.performKeyEquivalent(with:key(window,53));try await wait {model.query.isEmpty && field.stringValue.isEmpty && model.rows.count==41 && table.numberOfRows==41}
        try require(window.makeFirstResponder(table) && window.firstResponder === table,"Reference table did not acquire keyboard focus");try require(window.performKeyEquivalent(with:key(window,0,"a",.command)),"List Select All was not consumed");try require(table.selectedRowIndexes.count==41,"Native Select All selected \(table.selectedRowIndexes.count) of \(table.numberOfRows) rows; enabled=\(table.isEnabled), editable=\(model.canEditPresentation)");try await wait {model.selection.count==41}
        window.makeFirstResponder(field);let selectedBefore=model.selection;_=window.performKeyEquivalent(with:key(window,0,"a",.control));try require(model.selection==selectedBefore,"Field-editor Select All changed table rows")
        model.select(["refs/heads/topic-01","refs/heads/topic-02"],last:"refs/heads/topic-02");try await wait {table.selectedRowIndexes.count==2}
        let first=model.selectedRows.first!.reference.name
        window.makeFirstResponder(table);table.keyDown(with:key(window,120))
        try require(model.renameReference==first && model.selection.count==2,"F2 did not retain the first selected branch target")
        model.cancelRename();try await wait {model.renameReference==nil && table.isEnabled}
        // A background/child owner cannot refresh or alter selection/layout.
        owner.commandKeyWindow={nil};let selection=model.selection;_=window.performKeyEquivalent(with:key(window,96));try require(!model.busy && model.selection==selection,"Background F5 started a reader")
        owner.commandKeyWindow={window};model.hasChild=true
        let held=model.columnLayout;let disabled=header.buildMenu()!;try require(disabled.items.filter{!$0.isSeparatorItem}.allSatisfy{!$0.isEnabled},"Child owner left header commands enabled")
        _=window.performKeyEquivalent(with:key(window,96));try require(!model.busy && model.columnLayout==held,"Child F5/presentation mutated")
        model.hasChild=false
        try require(window.performKeyEquivalent(with:key(window,96)) && model.busy,"Foreground F5 did not own a real refresh")
        try await wait {!model.busy && model.snapshot != nil && table.numberOfRows==41}
        let savedLayout=model.columnLayout;owner.close()
        _=NSApp.sendAction(menu.items.first!.action!,to:menu.items.first!.target,from:menu.items.first!)
        let restored=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/heads/topic-01",preferences:prefs,picking:true){_ in};defer {restored.close()}
        restored.window!.alphaValue=0;restored.window!.orderFront(nil);restored.model.load()
        try await wait {restored.window?.contentView?.layoutSubtreeIfNeeded();return !restored.model.busy && restored.model.snapshot != nil}
        try require(restored.model.sortColumn=="hash" && restored.model.descending && restored.model.columnLayout==savedLayout,"Reopened picker did not restore shared browser presentation: sort=\(restored.model.sortColumn)/\(restored.model.descending); saved=\(savedLayout); actual=\(restored.model.columnLayout)")
        let pickerTable=find(NSTableView.self,in:restored.window!.contentView,label:"References")!
        try await wait {pickerTable.numberOfRows==41 && pickerTable.highlightedTableColumn?.identifier.rawValue=="hash"}
        restored.commandKeyWindow={restored.window};restored.window!.makeFirstResponder(pickerTable)
        _=restored.window!.performKeyEquivalent(with:key(restored.window!,0,"a",.command))
        try require(!pickerTable.allowsMultipleSelection && restored.model.selection.count==1,"Single-selection picker accepted Select All")
        // A retired pending confirmation cannot apply defaults after reopening.
        var reply:CheckedContinuation<Bool,Never>?
        restored.model.confirmResetColumns={await withCheckedContinuation{reply=$0}}
        restored.model.resetColumns();try await wait {reply != nil}
        try require(ReferenceBrowserWindowModel.activeMutations>0,"Reset question lost Quit accounting")
        restored.close();reply?.resume(returning:true);reply=nil;try await wait {ReferenceBrowserWindowModel.activeMutations==0}
        try require(ReferenceBrowserColumnLayout.load(prefs)==savedLayout,"Retired Reset confirmation wrote preferences")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent("file"))==file,"Presentation/keyboard altered repository state")
        print("PASS: native reference column normalization/order/width/visibility/fit and divider persistence, namespace policy, owned Reset No/Yes/retirement, source sort keys, filter/Select All/F2 scopes, unchanged repository and owned cleanup")
    }
}
