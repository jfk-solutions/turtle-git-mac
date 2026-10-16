import AppKit
import TurtleGitCore

@main struct BrowserPresentationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Browser presentation timeout at line \(line)")
    }
    @MainActor static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    @MainActor static func key(_ window:NSWindow,_ code:UInt16,_ flags:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!
    }
    @MainActor static func send(_ item:NSMenuItem)throws {try require(item.action != nil && NSApp.sendAction(item.action!,to:item.target,from:item),"Native menu target was unavailable")}
    @MainActor static func main()async {do {try await verify()}catch {fputs("Browser presentation failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (name,value) in [("user.name","Browser Presentation"),("user.email","browser@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",name,value])}
        for i in 0..<45 {try Data("file \(i)\n".utf8).write(to:root.appendingPathComponent(String(format:"file-%02d.txt",i)))}
        try await repo.stage((0..<45).map{String(format:"file-%02d.txt",$0)});_=try await repo.commit(message:"Browser presentation")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BrowserPresentation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let globalBefore=UserDefaults.standard.dictionaryRepresentation().filter{$0.key.contains("TurtleGit.RepositoryBrowserDivider")}
        prefs.set(-20.0,forKey:RepositoryBrowserWindowModel.dividerKey)
        try require(RepositoryBrowserWindowModel(repository:repo,access:nil,revision:"HEAD",preferences:prefs).dividerWidth==nil,"Invalid divider preference did not fall back")
        prefs.set(333.0,forKey:RepositoryBrowserWindowModel.dividerKey)
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};model.clipboard=clipboard;owner.commandKeyWindow={window};window.alphaValue=0;window.orderFront(nil)
        func table()->NSTableView? {views(window.contentView!).compactMap{$0 as? NSTableView}.first{$0.accessibilityLabel()=="Repository contents"}}
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.entries.count==45 && table()?.numberOfRows==45}
        let list=table()!,coordinator=list.delegate as! RepositoryBrowserContentsTable.Coordinator,header=list.headerView as! RepositoryBrowserColumnHeader
        let split=views(window.contentView!).compactMap{$0 as? NSSplitView}.first{$0.isVertical && $0.arrangedSubviews.count==2}!
        do {try await wait {abs(split.arrangedSubviews[0].frame.width-333)<2}}
        catch {throw Failure(description:"Divider restore: width=\(split.arrangedSubviews[0].frame.width), bounds=\(split.bounds), model=\(String(describing:model.dividerWidth)), delegate=\(String(describing:split.delegate)), fields=\(Mirror(reflecting:split.delegate as Any).children.map{String(describing:$0)})") }
        split.setPosition(371,ofDividerAt:0);try await wait {abs(prefs.double(forKey:RepositoryBrowserWindowModel.dividerKey)-371)<2}
        let preservedWidth=model.dividerWidth!
        var menu=header.buildMenu()!
        try require(menu.items.map(\.title)==["Reset column order","","Extension","Size"],"Source header order or mandatory Name omission differs")
        let stale=menu.item(withTitle:"Extension")!
        var changed=model.columns;changed.widths["name"]=420;model.saveColumns(changed);let stable=model.columns
        try send(stale);try require(model.columns==stable,"Stale column menu changed replacement layout")
        menu=header.buildMenu()!;let sibling=menu.item(withTitle:"Size")!;try send(menu.item(withTitle:"Extension")!);try send(sibling)
        try require(!model.columns.visible.contains("extension") && model.columns.visible.contains("size"),"Header menu did not retire all sibling commands after action")
        try await wait {list.tableColumns.first{$0.identifier.rawValue=="extension"}!.isHidden}
        list.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);list.scrollRowToVisible(35)
        let selected=model.selection,origin=list.enclosingScrollView!.contentView.bounds.origin
        changed=model.columns;changed.widths["name"]=450;model.saveColumns(changed)
        try await wait {list.tableColumn(withIdentifier:.init("name"))!.width==450}
        try require(model.selection==selected && abs(list.enclosingScrollView!.contentView.bounds.minY-origin.y)<1,"Column-only update changed selection/reading position")
        // Actual production question defaults Yes; No preserves the complete layout.
        let beforeReset=model.columns;menu=header.buildMenu()!;try send(menu.items[0])
        try await wait {window.attachedSheet != nil}
        try require(window.attachedSheet!.defaultButtonCell?.title=="Yes","Source Reset Yes default differs")
        window.endSheet(window.attachedSheet!,returnCode:.alertSecondButtonReturn)
        try await wait {!model.confirmingColumns && window.attachedSheet==nil}
        try require(model.columns==beforeReset,"Production Reset No changed layout")
        menu=header.buildMenu()!;try send(menu.items[0]);try await wait {window.attachedSheet != nil}
        window.endSheet(window.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try await wait {!model.confirmingColumns && model.columns==RepositoryBrowserColumns()}
        try require(model.dividerWidth==preservedWidth,"Column Reset changed divider width")
        menu=header.buildMenu()!;let priorGeneration=menu.item(withTitle:"Size")!;model.refresh()
        try await wait {!model.busy && list.numberOfRows==45};try send(priorGeneration)
        try require(model.columns==RepositoryBrowserColumns(),"Pre-refresh column menu changed current browser")
        // Source Ctrl aliases plus native Cmd copies target only the focused native list.
        window.makeFirstResponder(list)
        try require(window.performKeyEquivalent(with:key(window,0,.control)),"Control-A was not consumed")
        try await wait {model.selection.count==45 && list.selectedRowIndexes.count==45}
        _=window.performKeyEquivalent(with:key(window,8,.command))
        try require(clipboard.string(forType:.string)==model.entries.map{$0.name+"\r\n"}.joined(),"Owned Copy names changed bytes/order")
        let chosen=model.entries[0];model.selection=[chosen.id];var opened:ComparisonFileContent?
        model.presentFile={content,_ in opened=content}
        try await wait {list.selectedRowIndexes.count==1}
        try require(window.performKeyEquivalent(with:key(window,36)),"Native Return not consumed")
        try await wait {opened != nil && RepositoryBrowserWindowModel.activeOperations==0}
        try require(opened?.path==chosen.path && opened?.bytes==Data("file 0\n".utf8),"Return lost pinned historical file contents")
        let generation=model.generation;owner.commandKeyWindow={nil};_=window.performKeyEquivalent(with:key(window,96))
        try require(model.generation==generation,"Background F5 refreshed browser")
        owner.commandKeyWindow={window};model.choosingRevision=true
        _=window.performKeyEquivalent(with:key(window,96));try require(model.generation==generation,"Child F5 refreshed browser")
        let heldWidth=model.dividerWidth;split.setPosition(300,ofDividerAt:0)
        try require(model.dividerWidth==heldWidth,"Child resize callback changed saved divider")
        model.choosingRevision=false;split.setPosition(preservedWidth,ofDividerAt:0)
        try require(window.performKeyEquivalent(with:key(window,96)) && model.busy,"Owned F5 did not start actual refresh")
        try await wait {!model.busy && model.snapshot != nil}
        let savedWidth=model.dividerWidth!,saved=model.columns;menu=header.buildMenu()!;owner.close();try send(menu.item(withTitle:"Extension")!)
        split.setPosition(200,ofDividerAt:0);try require(model.dividerWidth==savedWidth && model.columns==saved,"Retired menu/divider wrote preferences")
        let restored=RepositoryBrowserWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs);defer {restored.close()}
        restored.window!.alphaValue=0;restored.window!.orderFront(nil)
        try await wait {restored.window!.contentView?.layoutSubtreeIfNeeded();return !restored.model.busy && views(restored.window!.contentView!).compactMap{$0 as? NSSplitView}.contains{$0.isVertical && $0.arrangedSubviews.count==2 && abs($0.arrangedSubviews[0].frame.width-savedWidth)<2}}
        try require(restored.model.columns==saved,"Reopened browser columns changed")
        let globalAfter=UserDefaults.standard.dictionaryRepresentation().filter{$0.key.contains("TurtleGit.RepositoryBrowserDivider")}
        try require(NSDictionary(dictionary:globalBefore).isEqual(to:globalAfter),"Private browser changed global AppKit divider autosave")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && RepositoryBrowserWindowModel.activeOperations==0,"Presentation changed repository or stranded operations")
        print("PASS: Browser scoped divider restore/save/retirement, source header/default Reset No/Yes, one-use stale-menu fences, stable viewport/selection, Ctrl-A/native Copy/F5 owner gates, reopened layout and unchanged repository/global autosave")
    }
}
