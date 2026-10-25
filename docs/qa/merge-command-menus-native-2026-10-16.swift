import AppKit
import TurtleGitCore

struct MergeCommandMenusVerification {
    struct Failure: Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func items(_ menu:NSMenu) -> [NSMenuItem] { menu.items.flatMap{[$0]+($0.submenu.map(items) ?? [])} }
    @MainActor static func item(_ title:String,in menu:NSMenu) throws -> NSMenuItem {
        guard let found=items(menu).first(where:{$0.title==title}) else { throw Failure(description:"Missing editor menu: "+title) };return found
    }
    @MainActor static func send(_ item:NSMenuItem) throws { try require(item.action != nil && NSApp.sendAction(item.action!,to:item.target,from:item),"Native menu dispatch missing: "+item.title) }
    @MainActor static func event(_ key:String,code:UInt16=0,flags:NSEvent.ModifierFlags=[],window:NSWindow) -> NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
    }
    @MainActor static func verify() async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]);let git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.MergeMenus."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        prefs.set(false,forKey:"TurtleGitMerge.WrapLines")
        let main=NSMenu(title:"Owned editor menu fixture"),previous=NSApp.mainMenu
        let app=NSMenuItem(title:"TurtleGitMerge Fixture",action:nil,keyEquivalent:"");app.submenu=NSMenu(title:"Fixture");main.addItem(app)
        let fileRoot=NSMenuItem(title:"File",action:nil,keyEquivalent:"");fileRoot.submenu=NSMenu(title:"File");main.addItem(fileRoot)
        let sentinel=NSMenuItem(title:"Repository sentinel",action:nil,keyEquivalent:"");fileRoot.submenu!.addItem(sentinel)
        let editRoot=NSMenuItem(title:"Edit",action:nil,keyEquivalent:"");editRoot.submenu=NSMenu(title:"Edit");main.addItem(editRoot)
        let undo=NSMenuItem(title:"Undo",action:NSSelectorFromString("undo:"),keyEquivalent:"z"),copy=NSMenuItem(title:"Copy",action:NSSelectorFromString("copy:"),keyEquivalent:"c")
        editRoot.submenu!.addItem(undo);editRoot.submenu!.addItem(copy)
        NSApp.mainMenu=main;defer {NSApp.mainMenu=previous}
        let a=folder.appendingPathComponent("base.txt"),b=folder.appendingPathComponent("mine.txt"),t=folder.appendingPathComponent("theirs.txt"),output=folder.appendingPathComponent("menu-export.txt")
        let old=Data("stamp 1\nold one\nstay\nold two\ntail\n".utf8),new=Data("stamp 2\nnew one\nstay\nnew two\ntail\n".utf8)
        try old.write(to:a);try new.write(to:b);try Data("stamp 2\ntheirs one\nstay\ntheirs two\ntail\n".utf8).write(to:t)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs),model=owner.model,window=owner.window!
        defer { (owner.replacementOwner?.current ?? owner).close() }
        window.alphaValue=0;window.orderFront(nil);model.load();try await TwoPaneEngineVerification.settled(model)
        var focused:NSWindow?=window
        let menu=owner.editorCommandMenu!;menu.keyWindow={focused};menu.install(in:main)
        try require(main.items.map(\.title)==["TurtleGitMerge Fixture","File","Edit","Navigate","View","Help"],"Native menu root order")
        try require(try item("Next difference",in:main).image?.isTemplate==false && item("Switch left and right view",in:main).image != nil,"Source-colored menu artwork")
        let editors=MergeMarkedWordInterface.panes(in:window.contentView),right=editors.first{$0.string.contains("new one")}!
        window.makeFirstResponder(right)
        let first=window.firstResponder as AnyObject?
        try require(menu.performKeyEquivalent(event(String(UnicodeScalar(NSF6FunctionKey)!),code:97,window:window)),"F6 did not route")
        try require(window.firstResponder as AnyObject? !== first,"F6 did not cycle native pane")
        try require(menu.performKeyEquivalent(event(String(UnicodeScalar(NSF6FunctionKey)!),code:97,flags:.shift,window:window)),"Shift-F6 did not route")
        try require(window.firstResponder === right,"Previous pane did not restore focus")
        let staleWrap=try item("Wrap long lines",in:main)
        try send(staleWrap);try require(model.wrapLines,"View Wrap did not dispatch")
        try require(staleWrap.state == .on,"View checkmark not refreshed")
        menu.remove();try require(fileRoot.submenu!.items==[sentinel] && editRoot.submenu!.items.contains(undo) && editRoot.submenu!.items.contains(copy) && !editRoot.submenu!.items.contains{($0.target as AnyObject?) === menu},"Removal changed unrelated menu items: file=\(fileRoot.submenu!.items.map(\.title)), edit=\(editRoot.submenu!.items.map(\.title))")
        menu.install(in:main);try send(staleWrap);try require(model.wrapLines,"Old focus-epoch menu action accepted")
        let liveWrap=try item("Wrap long lines",in:main)
        model.busy=true;try require(!menu.validateMenuItem(liveWrap),"Busy menu reenabled")
        try send(liveWrap);try require(model.wrapLines,"Busy menu action mutated preference")
        model.busy=false
        let held=MergeEditorOpenWorkflow(window:window,permissions:[],preferences:prefs);owner.editorOpenWorkflow=held
        try send(liveWrap);try require(model.wrapLines,"File/Open owner allowed menu action")
        held.retire();owner.editorOpenWorkflow=nil
        focused=nil;try send(liveWrap);try require(model.wrapLines,"Background owner accepted menu action")
        focused=window;menu.refresh()
        let field=NSTextField(frame:.init(x:0,y:0,width:180,height:24));window.contentView!.addSubview(field);window.makeFirstResponder(field)
        try await TwoPaneEngineVerification.wait{(window.firstResponder as? NSTextView)?.isFieldEditor==true}
        try require(!menu.performKeyEquivalent(event("p",flags:.control,window:window)) && model.wrapLines,"Editor shortcut stole field input")
        field.removeFromSuperview();window.makeFirstResponder(right)
        try send(try item("Wrap long lines",in:main));try require(!model.wrapLines,"Fresh menu did not resume")
        let filter=MergeRegexFilter(name:"Numbers",expression:"[0-9]+",replacement:"")
        try MergeRegexFilters.save([filter],defaults:prefs);model.regexDefaults=prefs;model.refreshRegexFilters();menu.refresh()
        try send(try item("Numbers",in:main));try await TwoPaneEngineVerification.settled(model);menu.refresh()
        try require(model.regexFilterName=="Numbers" && (try item("Numbers",in:main)).state == .on,"Regex submenu did not use owned model")
        try send(try item("No Filter",in:main));try await TwoPaneEngineVerification.settled(model)
        try send(try item("Ignore case changes",in:main));try await TwoPaneEngineVerification.settled(model)
        try require(model.comparisonOptions.ignoreCase && MergeComparisonOptions.load(from:prefs).ignoreCase,"Comparison menu persistence")
        try require(!menu.validateMenuItem(try item("Ignore Comments",in:main)),"Unsupported comment profile enabled")
        model.chooseExportLocation={_,_,_ in output};window.makeFirstResponder(right);model.activatePane(base:false)
        try send(try item("Save As…",in:main));try await TwoPaneEngineVerification.settled(model)
        try require(try Data(contentsOf:output)==new && model.savedPaneURL(base:false)==output,"Native Save As did not use active pane")
        let find=try item("Find",in:main);try send(find)
        try require((right as! MergeFindProviding).mergeFindController?.window != nil,"Find menu dispatch")
        (right as! MergeFindProviding).mergeFindController?.close();focused=window;menu.install(in:main)
        let before=model.draftText(base:false),history=model.canUndo
        try send(try item("Status Bar",in:main));try require(!model.showStatusBar,"Status menu check")
        try send(try item("Toolbar",in:main));owner.editorToolbar!.refresh()
        try require(window.toolbar?.isVisible==false && model.nativeToolbarInstalled,"Menu hide detached toolbar")
        try send(try item("Toolbar",in:main));owner.editorToolbar!.refresh();try require(window.toolbar?.isVisible==true,"Menu cannot restore hidden toolbar")
        try require(model.draftText(base:false)==before && model.canUndo==history,"Presentation menu changed text/history")
        let merge=TextConflictWindowController(repository:GitRepository(root:folder,executable:git),access:nil,path:b.path,workingMerge:try WorkingTextMerge(base:a,theirs:t,mine:b),preferences:prefs)
        defer{merge.close()};merge.window!.alphaValue=0;merge.window!.orderFront(nil);merge.model.load()
        try await ThreePaneEngineVerification.wait{!merge.model.busy && merge.model.document != nil && merge.model.nativeEditorReady}
        menu.remove();focused=merge.window;let triple=merge.editorCommandMenu!;triple.keyWindow={focused};triple.install(in:main)
        merge.model.continueResolving();triple.refresh()
        let resultView=MergeMarkedWordInterface.panes(in:merge.window!.contentView).first{$0.isEditable}!
        let original=merge.model.result, initialPresentation=merge.model.resultPresentation
        let mineView=MergeMarkedWordInterface.panes(in:merge.window!.contentView).first{!$0.isEditable && $0.string.contains("new one")}!
        let sourceClipboard=NSPasteboard.withUniqueName();defer{sourceClipboard.releaseGlobally()}
        let sourceMenu=(mineView as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:sourceClipboard)
        let oldWhole=try item("Use this whole file",in:sourceMenu)
        try send(try item("Use Mine block",in:main));try require(merge.model.result != original && merge.model.canUndo,"Conflict menu did not choose with native history")
        let chosen=merge.model.resultPresentation
        try require(resultView.string==merge.model.resultDisplayText && merge.model.nativeEditorReady,"Choice returned with stale native geometry")
        do {
            guard let projection=merge.model.alignedResultProjection,let row=projection.cells.firstIndex(where:{$0.state == .resolved}) else { throw Failure(description:"Conflict choice did not produce a resolved row for immediate color verification") }
            let offset=projection.displayRanges[row].location
            let painted=resultView.textStorage?.attribute(.backgroundColor,at:offset,effectiveRange:nil) as? NSColor
            try require(painted != nil,"Immediate source choice did not install row colors")
            for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                var actual:NSColor?,expected:NSColor?
                NSAppearance(named:appearance)!.performAsCurrentDrawingAppearance {
                    actual=painted?.usingColorSpace(.sRGB);expected=merge.model.palette.color(.resolved).usingColorSpace(.sRGB)
                }
                try require(actual == expected,"Immediate row color differs before SwiftUI refresh")
            }
        }
        // No event-loop turn between choice, Undo and Redo: model, rows, colors
        // and action availability must commit together.
        merge.model.undo();try require(merge.model.result==original && merge.model.resultPresentation==initialPresentation && merge.model.canRedo,"Conflict menu choice lost Undo")
        try require(resultView.string==merge.model.resultDisplayText && merge.model.nativeEditorReady,"Undo left stale native geometry")
        merge.model.redo();try require(merge.model.resultPresentation==chosen && merge.model.canUndo,"Immediate Redo lost conflict metadata")
        merge.model.undo();try require(merge.model.resultPresentation==initialPresentation,"Second Undo failed")
        let scope=resultView as! MergeContextMenuProviding
        try require(scope.mergeSourceRowsReady,"History left a stale row stamp")
        let resultScroll=resultView.enclosingScrollView!
        resultScroll.documentView=nil
        try require(!merge.model.nativeEditorReady && !merge.model.sourceToolsAllowed,"Detached result retained native actions")
        triple.refresh();let unavailable=try item("Use Mine block",in:main)
        try require(!unavailable.isEnabled,"Detached result menu enabled a model-only choice")
        try send(unavailable);merge.model.redo();try require(merge.model.resultPresentation==initialPresentation,"Detached native action bypassed history ownership")
        resultScroll.documentView=resultView
        try await ThreePaneEngineVerification.wait{merge.model.nativeEditorReady}
        triple.refresh();merge.model.redo();try require(merge.model.resultPresentation==chosen,"Reattached editor lost native Redo")
        merge.model.undo();try require(merge.model.resultPresentation==initialPresentation,"Reattached editor lost native Undo")
        try send(oldWhole);try require(merge.model.resultPresentation==initialPresentation,"Old whole-file menu revived after identical-text Undo")
        try await ThreePaneEngineVerification.wait{(mineView as! MergeContextMenuProviding).mergeSourceRowsReady}
        let freshWhole=(mineView as! MergeContextMenuProviding).mergeContextMenu(defaults:prefs,pasteboard:sourceClipboard)
        try send(try item("Use this whole file",in:freshWhole))
        try require(!merge.model.hasUnresolvedConflicts && merge.model.canUndo,"Whole-file native choice bypassed resolution/history")
        let whole=merge.model.resultPresentation
        merge.model.undo();try require(merge.model.resultPresentation==initialPresentation,"Whole-file Undo lost conflict metadata")
        merge.model.redo();try require(merge.model.resultPresentation==whole,"Whole-file Redo lost aligned presentation")
        merge.model.undo();try require(merge.model.resultPresentation==initialPresentation,"Whole-file second Undo failed")
        try require(try item("Next conflict",in:main).keyEquivalent==String(UnicodeScalar(NSF8FunctionKey)!),"Conflict shortcut missing")
        let tripleWrap=try item("Wrap long lines",in:main);triple.remove();focused=window;menu.install(in:main)
        try send(tripleWrap);try require(!merge.model.wrapLines,"Resigned Merge menu mutated result owner")
        let retained=try item("Wrap long lines",in:main)
        model.setToolbarVisible(false);owner.editorToolbar!.refresh()
        try owner.replaceEditor(.compare(base:a,mine:b,single:false),permissions:[])
        let replacement=window.delegate as! FileComparisonWindowController
        try await TwoPaneEngineVerification.settled(replacement.model)
        let fresh=replacement.editorCommandMenu!;fresh.keyWindow={focused};fresh.install(in:main)
        try send(retained);try require(!replacement.model.wrapLines,"Retired menu reached replacement")
        replacement.model.setToolbarVisible(true);replacement.editorToolbar!.refresh();replacement.editorToolbar!.toolbar.validateVisibleItems()
        let open=replacement.editorToolbar!.toolbar.items.first{$0.itemIdentifier==MergeToolbarCommand.open.identifier}!
        print("Toolbar appearance diagnostic: active=\(NSApp.isActive), key=\(window.isKeyWindow), main=\(window.isMainWindow), visible=\(window.toolbar!.isVisible), openEnabled=\(open.isEnabled), commandEnabled=\(replacement.editorToolbar!.commandState(.open)?.enabled == true)")
        if let captures=ProcessInfo.processInfo.environment["TURTLEGIT_MENU_CAPTURE"] {
            window.alphaValue=1
            for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:800_000_000);window.displayIfNeeded()
                let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");p.arguments=["-x","-o","-l",String(window.windowNumber),URL(fileURLWithPath:captures).appendingPathComponent("merge-command-menus-"+name+".png").path]
                try p.run();p.waitUntilExit();try require(p.terminationStatus==0,"Owned menu capture failed")
                print("Captured toolbar: active=\(NSApp.isActive), key=\(window.isKeyWindow), open=\(open.isEnabled)")
            }
        }
        replacement.close();triple.retire();fresh.retire()
        try require(fileRoot.submenu!.items==[sentinel] && editRoot.submenu!.items.contains(undo) && editRoot.submenu!.items.contains(copy) && !items(main).contains{($0.target as AnyObject?) === menu || ($0.target as AnyObject?) === triple || ($0.target as AnyObject?) === fresh},"Final retirement changed unrelated app menus")
        try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==new,"Menu workflow changed input files")
        print("PASS: native File/Edit/Navigate/View/Help scope, source icons/shortcuts, F6 focus, state/persistence, regex, active Save As, Find/conflict Undo, busy/field/Open/background/epoch/retired gates and unchanged files; owned windows closed")
    }
}
