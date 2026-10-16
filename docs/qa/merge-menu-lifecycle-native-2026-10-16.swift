import AppKit
import TurtleGitCore

struct MergeMenuLifecycleVerification {
    struct Failure: Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func rows(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map(rows) ?? [])}}
    @MainActor static func item(_ name:String,_ menu:NSMenu)throws->NSMenuItem {guard let found=rows(menu).first(where:{$0.title==name}) else {throw Failure(description:"Missing menu "+name)};return found}
    @MainActor static func send(_ item:NSMenuItem) {if let action=item.action {_=NSApp.sendAction(action,to:item.target,from:item)}}
    @MainActor static func key(_ scalar:Int,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[],_ window:NSWindow)->Bool {
        let character=String(UnicodeScalar(scalar)!)
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!
        return window.performKeyEquivalent(with:event)
    }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.MenuLifecycle."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
        let a=folder.appendingPathComponent("base.txt"),b=folder.appendingPathComponent("mine.txt"),t=folder.appendingPathComponent("theirs.txt")
        let old=Data("head\nold1\nkeep\nold2\ntail\n".utf8),mine=Data("head\nmine1\nkeep\nmine2\ntail\n".utf8),theirs=Data("head\ntheirs1\nkeep\ntheirs2\ntail\n".utf8)
        try old.write(to:a);try mine.write(to:b);try theirs.write(to:t)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        var focused:NSWindow?=window,current=NSMenu(title:"first root")
        let menu=owner.editorCommandMenu!;menu.keyWindow={focused};menu.applicationMenu={current};menu.install(in:current)
        let editors=MergeMarkedWordInterface.panes(in:window.contentView),right=editors.first{$0.string.contains("mine1")}!
        window.makeFirstResponder(right);right.setSelectedRange(.init(location:0,length:0))
        let staleWrap=try item("Wrap long lines",current),first=current
        current=NSMenu(title:"replacement root")
        let file=NSMenuItem(title:"File",action:nil,keyEquivalent:"");file.submenu=NSMenu(title:"File");current.addItem(file)
        let sentinel=NSMenuItem(title:"Unrelated sentinel",action:nil,keyEquivalent:"");file.submenu!.addItem(sentinel)
        send(staleWrap);try require(!model.wrapLines,"Detached whole-root item dispatched before repair")
        NotificationCenter.default.post(name:NSApplication.didUpdateNotification,object:NSApp)
        try await TwoPaneEngineVerification.wait{rows(current).contains{$0.title=="Wrap long lines"}}
        try require(rows(first).allSatisfy{!($0.target is MergeEditorCommandMenu)},"Old main root kept editor targets")
        let view=try item("View",current),detached=try item("Wrap long lines",current)
        let viewSentinel=NSMenuItem(title:"External View sentinel",action:nil,keyEquivalent:"")
        view.submenu=NSMenu(title:"rebuilt View");view.submenu!.addItem(viewSentinel)
        send(detached);try require(!model.wrapLines,"Detached submenu item dispatched before repair")
        NotificationCenter.default.post(name:NSApplication.didUpdateNotification,object:NSApp)
        try await TwoPaneEngineVerification.wait{view.submenu!.items.contains{$0.title=="Wrap long lines"}}
        let identities=rows(current).map(ObjectIdentifier.init)
        for _ in 0..<12 {NotificationCenter.default.post(name:NSApplication.didUpdateNotification,object:NSApp)}
        try await Task.sleep(nanoseconds:80_000_000)
        try require(rows(current).map(ObjectIdentifier.init)==identities,"Unchanged application updates rebuilt menus")
        let filters=try item("Filter Regexes",current).submenu!
        NotificationCenter.default.post(name:NSMenu.didBeginTrackingNotification,object:filters)
        let originalRows=filters.items.map(ObjectIdentifier.init)
        try MergeRegexFilters.save([.init(name:"New filter",expression:"[0-9]+",replacement:"")],defaults:prefs)
        model.regexDefaults=prefs;model.refreshRegexFilters();menu.refresh()
        try require(filters.items.map(ObjectIdentifier.init)==originalRows,"Tracked filter menu mutated structurally")
        NotificationCenter.default.post(name:NSMenu.didEndTrackingNotification,object:filters)
        try await TwoPaneEngineVerification.wait{filters.items.contains{$0.title=="New filter"}}
        let tracked=view.submenu!,oldTracked=try item("Wrap long lines",current)
        NotificationCenter.default.post(name:NSMenu.didBeginTrackingNotification,object:tracked)
        current=NSMenu(title:"root replaced while tracking")
        NotificationCenter.default.post(name:NSApplication.didUpdateNotification,object:NSApp)
        try await Task.sleep(nanoseconds:80_000_000)
        try require(current.items.isEmpty,"Root rebuilt while a menu was tracking")
        send(oldTracked);try require(!model.wrapLines,"Old tracked root action accepted")
        NotificationCenter.default.post(name:NSMenu.didEndTrackingNotification,object:tracked)
        try await TwoPaneEngineVerification.wait{rows(current).contains{$0.title=="Wrap long lines"}}
        // F11 and its reverse aliases follow the same ready native block target.
        window.makeFirstResponder(right);right.setSelectedRange(.init(location:0,length:0))
        try require(key(NSF11FunctionKey,103,[],window) && model.difference==0,"F11 did not enter first difference once")
        try require(key(NSF11FunctionKey,103,[],window) && model.difference==1,"F11 did not enter second difference once")
        try require(key(NSF11FunctionKey,103,.control,window) && model.difference==0,"Ctrl-F11 reverse alias")
        let baseline=model.draftText(base:false)
        try require(key(NSF12FunctionKey,111,[],window) && model.draftText(base:false).contains("old1"),"F12 block choice")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        try require(model.draftText(base:false)==baseline,"Block shortcut lost one-step Undo")
        let selection=(right.string as NSString).range(of:"mine1")
        right.setSelectedRange(selection);model.updateSelection(selection,cells:model.displayCells(base:false))
        try require(key(NSRightArrowFunctionKey,124,.option,window),"Alt-Right use-left alias")
        try require(model.draftText(base:false).contains("old1"),"Alt-Right did not choose left block")
        model.undo();try await TwoPaneEngineVerification.settled(model)
        let query=(right.string as NSString).range(of:"mine")
        right.setSelectedRange(query)
        try require(key(NSF3FunctionKey,99,.control,window),"Ctrl-F3 selected-text search alias")
        try require((right as! MergeFindProviding).mergeFindHighlights.query=="mine" && right.selectedRange().location>query.location,"Selected-text search did not advance")
        send(try item("Clear Search Highlights",current));try require((right as! MergeFindProviding).mergeFindHighlights.query.isEmpty,"Main menu clear search")
        menu.remove();focused=nil
        let merge=TextConflictWindowController(repository:GitRepository(root:folder,executable:URL(fileURLWithPath:CommandLine.arguments[2])),access:nil,path:b.path,workingMerge:try WorkingTextMerge(base:a,theirs:t,mine:b),preferences:prefs)
        defer {merge.close()};merge.model.load();try await ThreePaneEngineVerification.wait{!merge.model.busy && merge.model.document != nil}
        focused=merge.window;let triple=merge.editorCommandMenu!;triple.keyWindow={focused};triple.applicationMenu={current};triple.install(in:current)
        let original=merge.model.result
        for (scalar,code,flags,prefix) in [(NSF10FunctionKey,109,NSEvent.ModifierFlags.control,"head\nmine1\n"),(NSF12FunctionKey,111,.shift,"head\nmine1\n"),(NSF9FunctionKey,101,.control,"head\ntheirs1\n"),(NSF10FunctionKey,109,[.control,.shift],"head\nmine1\ntheirs1\n"),(NSF9FunctionKey,101,[.control,.shift],"head\ntheirs1\nmine1\n")] {
            merge.model.continueResolving();triple.refresh()
            try require(key(scalar,UInt16(code),flags,merge.window!),"Conflict block shortcut missing")
            try require(merge.model.result.hasPrefix(prefix),"Conflict block shortcut order: \(prefix)")
            merge.model.undo();try require(merge.model.result==original,"Conflict shortcut did not Undo in one step")
        }
        let retired=try item("Use Mine block",current)
        merge.close();focused=window;menu.install(in:current)
        send(retired);try require(merge.model.result==original,"Retired shortcut item changed result")
        menu.retire();NotificationCenter.default.post(name:NSApplication.didUpdateNotification,object:NSApp)
        try require(rows(current).allSatisfy{!($0.target is MergeEditorCommandMenu)},"Retired observer reattached commands")
        try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==mine && Data(contentsOf:t)==theirs,"Shortcut family wrote original files")
        print("PASS: whole/submenu reconstruction, detached/retired refusal, tracking-deferred filters/roots, idempotent app updates, window F11/F12/Alt-Right and selected search aliases, five conflict block shortcuts with one-step Undo and unchanged inputs; owned windows closed")
    }
}
