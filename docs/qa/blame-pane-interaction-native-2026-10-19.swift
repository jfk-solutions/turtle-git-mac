// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum BlamePaneInteractionVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws{
        for _ in 0..<2400{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame pane timeout \(line): \(message)")
    }
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool{BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0}
    static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Pane author 雪"),("user.email","pane@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let path="pane 雪.txt"
        for number in 1...3{
            _ = try await repo.run(["config","user.name","Author \(number) 雪"])
            try Data("revision \(number) Unicode 雪🦎\nsecond line\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:number==1 ? "Pane subject 1":"Pane subject \(number)\n\nDistinct body \(number) 雪")
        }
        let savedPaths=[".git/index",".git/HEAD",".git/config",path],saved=try savedPaths.map{try Data(contentsOf:root.appendingPathComponent($0))}
        let suite="TurtleGit.BlamePaneInteraction."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        for key in ["EnableGravatar","Blame.EnableLexer","EnableLogCache"]{prefs.set(false,forKey:key)}
        prefs.set(true,forKey:"Blame.ShowLog");prefs.set(true,forKey:"Blame.ShowProperties")
        var owner:BlameWindowController?,otherWindows:[NSWindow]=[]
        defer{owner?.close();otherWindows.forEach{$0.close()};clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite)}
        func makeOwner()->BlameWindowController{
            let value=BlameWindowController(repository:repo,access:nil,path:path,revision:"HEAD",options:GitBlamePreferences.load(from:prefs),preferences:prefs)
            value.window?.alphaValue=0;value.window?.setContentSize(NSSize(width:1180,height:820));value.window?.orderFront(nil)
            value.model.writeClipboard={text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            return value
        }
        let controller=makeOwner();owner=controller
        let model=controller.model,window=controller.window!
        var focused:NSWindow?=window;controller.commandKeyWindow={focused}
        try await wait("real history/source loaded"){!model.busy && model.historyEntries.count==3 && views(window.contentView).contains{$0 is BlamePropertiesTable}}
        let child=model.historyEntries[0],parent=model.historyEntries[1]
        model.focusHistory([child.hash],focus:child.hash)
        func grid(in host:NSWindow)->BlamePropertiesTable?{views(host.contentView).compactMap{$0 as? BlamePropertiesTable}.first}
        let table=grid(in:window)!,details=model.revisionDetails,coordinator=table.delegate as! BlamePropertyGrid.Coordinator
        func select(_ id:String)throws{
            coordinator.update();guard let row=coordinator.rows.firstIndex(where:{$0.id==id})else{throw Failure(description:"Missing property "+id)}
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);coordinator.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:table))
        }
        func key(_ code:UInt16,_ text:String="",_ flags:NSEvent.ModifierFlags = [],host:NSWindow?=nil)->NSEvent{
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:(host ?? window).windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
        }
        window.makeFirstResponder(table)
        try require(abs(details.propertyColumnWidth-128)<1 && abs(table.tableColumns[0].width-128)<1,"Private default property width was not128")
        try require(details.parents.first?.name==String(parent.hash.prefix(8)),"Parent label did not use source eight-character prefix")
        try require(details.parents.first?.description=="0 - \(parent.hash)\n\(parent.subject)","Parent description lost full ordinal/hash/subject")
        let history=views(window.contentView).compactMap{$0 as? BlameHistoryNativeTable}.first!
        let historyCoordinator=history.delegate as! BlameHistoryTable.Coordinator;historyCoordinator.update()
        let hashColumn=history.tableColumns.firstIndex{$0.identifier.rawValue=="hash"}!
        let hashText=views(history.view(atColumn:hashColumn,row:0,makeIfNecessary:true)).compactMap{$0 as? NSTextField}.first!.stringValue
        try require(hashText==child.hash,"Embedded Log cell stored a shortened SHA-1 instead of full hash")
        try select("basic.8");table.keyDown(with:key(123))
        try require(details.basicExpanded && details.selection=="group.basic","Left from property did not select owning group")
        table.keyDown(with:key(123))
        try require(!details.basicExpanded && details.selection=="group.basic" && details.selected==nil,"Left did not collapse selected property into its group")
        table.keyDown(with:key(124));try require(details.basicExpanded && details.selection=="group.basic","Right did not expand group")
        table.keyDown(with:key(49," "));try require(!details.basicExpanded,"Space failed native group toggle")
        table.keyDown(with:key(36,"\r"));try require(details.basicExpanded,"Return failed native group toggle")
        table.keyDown(with:key(119));try require(details.selection==details.parents.last?.id,"End did not select final visible parent")
        table.keyDown(with:key(115));try require(details.selection=="group.basic","Home did not select first visible group")
        try select(details.parents[0].id);table.keyDown(with:key(123))
        try require(details.parentsExpanded && details.selection=="group.parents","Parent Left did not first select its group")
        table.keyDown(with:key(123))
        try require(!details.parentsExpanded && details.selection=="group.parents" && details.selected==nil,"Parent collapse retained hidden property selection")
        table.keyDown(with:key(124));try require(details.parentsExpanded,"Parent Right failed expansion")
        // Exercise the real divider mutation path plus its clamp and persistence.
        table.resizePropertyDivider(to:220)
        try require(abs(table.tableColumns[0].width-220)<1,"Native internal property divider did not resize")
        table.resizePropertyDivider(to:12);try require(abs(table.tableColumns[0].width-60)<1,"Property divider minimum was not enforced")
        table.resizePropertyDivider(to:20_000);try require(abs(details.propertyColumnWidth-10_000)<1,"Property divider maximum was not enforced")
        table.resizePropertyDivider(to:236)
        coordinator.update();try require(abs(table.tableColumns[0].width-236)<1,"Coordinator update lost resized property width")
        window.contentView?.layoutSubtreeIfNeeded()
        let divider=table.rect(ofColumn:0).maxX,y=table.visibleRect.midY
        func mouse(_ type:NSEvent.EventType,_ x:CGFloat)->NSEvent{
            let point=table.convert(NSPoint(x:x,y:y),to:nil)
            return NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        }
        table.mouseDown(with:mouse(.leftMouseDown,divider));table.mouseDragged(with:mouse(.leftMouseDragged,divider+20));table.mouseUp(with:mouse(.leftMouseUp,divider+20))
        try require(abs(table.tableColumns[0].width-256)<1 && abs(details.propertyColumnWidth-256)<1 && abs(prefs.double(forKey:"Blame.Properties.PropertyColumnWidth")-256)<1,"Actual pointer divider did not retain width in private preferences")
        // A context menu must remain stale after moving away and back, even if
        // the visible property/value/revision are identical again.
        try select("basic.8");coordinator.menuNeedsUpdate(table.menu!);let stale=table.menu!.items.first!
        try select("basic.1");try select("basic.8");clipboard.clearContents();coordinator.copyMenu(stale)
        try require(clipboard.string(forType:.string)==nil,"Selection-away-and-back revived an old property context")
        model.focusHistory([model.historyEntries.last!.hash],focus:model.historyEntries.last!.hash);try select("basic.8");window.makeFirstResponder(table)
        clipboard.clearContents();clipboard.setString("private sentinel",forType:.string)
        _ = table.performKeyEquivalent(with:key(8,"c",.command));try require(clipboard.string(forType:.string)=="private sentinel","Empty property keyboard Copy replaced existing clipboard")
        coordinator.menuNeedsUpdate(table.menu!);try require(table.menu!.items.count==1,"Empty selected value lost source context Copy")
        coordinator.copyMenu(table.menu!.items[0]);try require(clipboard.string(forType:.string)=="","Empty property context Copy failed to copy its selected value")
        model.focusHistory([child.hash],focus:child.hash);coordinator.update()
        try select("basic.8");window.makeFirstResponder(table)
        var propertyMenus=0
        table.presentContextMenu={menu,_,view in if menu.items.count==1 && view===table {propertyMenus += 1}}
        try require(table.accessibilityPerformShowMenu(),"Properties accessibility Show Menu failed")
        table.keyDown(with:key(109,"",.shift))
        try require(propertyMenus==2,"Properties keyboard/accessibility did not share the selected native context menu")
        // Source, Log and Properties Copy use the focused native responder and
        // the private clipboard callback; Find/another window cannot steal it.
        let editor=views(window.contentView).compactMap{$0 as? NSTextView}.first{$0.accessibilityLabel()=="Blame source text"}!
        let selected=(editor.string as NSString).range(of:"Unicode 雪🦎");editor.setSelectedRange(selected);window.makeKeyAndOrderFront(nil);window.makeFirstResponder(editor)
        // A prohibited invisible receiver has no active app menu key window.
        // Resolve its private Edit command to this actual window's first responder;
        // production AppKit performs that resolution in the active application.
        let privateCopy=NSApp.mainMenu?.items.first?.submenu?.items.first
        privateCopy?.target=window.firstResponder
        clipboard.clearContents();let copyKey=key(8,"c",.command);let sourceCopyHandled=window.performKeyEquivalent(with:copyKey) || NSApp.mainMenu?.performKeyEquivalent(with:copyKey)==true;try require(sourceCopyHandled && clipboard.string(forType:.string)=="Unicode 雪🦎","Focused source Command-C copied another pane or lost UTF16 text")
        privateCopy?.target=nil
        clipboard.clearContents();editor.copy(nil);try require(clipboard.string(forType:.string)=="Unicode 雪🦎","Source native responder Copy lost focused selected text")
        history.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);historyCoordinator.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:history));window.makeFirstResponder(history)
        clipboard.clearContents();try require(window.performKeyEquivalent(with:key(8,"c",.command)),"Focused Log Command-C was not handled")
        try await wait("actual Log full clipboard read"){!model.copyingLog && clipboard.string(forType:.string) != nil}
        let logClipboard=clipboard.string(forType:.string)!
        try require(logClipboard.contains("Revision: "+child.hash) && logClipboard.contains("Pane subject 3") && logClipboard.contains("Distinct body 3 雪") && logClipboard.contains(path),"Focused Log Copy lost complete revision/message/changed paths")
        clipboard.clearContents();history.copy(nil)
        try await wait("native Log responder full copy"){!model.copyingLog && clipboard.string(forType:.string) != nil}
        try require(clipboard.string(forType:.string)==logClipboard,"Log native responder Copy differed from keyboard complete details")
        clipboard.clearContents();history.copy(nil);window.makeFirstResponder(table)
        try await wait("full Log read retired after focus change"){!model.copyingLog}
        try require(clipboard.string(forType:.string)==nil,"Asynchronous Log Copy replaced clipboard after focus moved")
        window.makeFirstResponder(history);history.copy(nil)
        model.focusHistory([parent.hash],focus:parent.hash)
        try await wait("full Log read retired after revision selection change"){!model.copyingLog}
        try require(clipboard.string(forType:.string)==nil,"Asynchronous Log Copy replaced clipboard after selected revision changed")
        model.focusHistory([child.hash],focus:child.hash)
        try select("basic.8");window.makeFirstResponder(table);clipboard.clearContents()
        try require(window.performKeyEquivalent(with:key(8,"c",.command)) && clipboard.string(forType:.string)=="Distinct body 3 雪","Focused Properties Command-C did not copy selected full value")
        clipboard.clearContents();table.copy(nil);try require(clipboard.string(forType:.string)=="Distinct body 3 雪","Properties native responder Copy lost full value")
        clipboard.clearContents();model.busy=true;_ = window.performKeyEquivalent(with:key(8,"c",.command));try require(clipboard.string(forType:.string)==nil,"Busy Blame copied stale pane selection");model.busy=false;coordinator.update()
        for flag: ReferenceWritableKeyPath<BlameWindowModel,Bool> in [\.navigationSheetPresented, \.searchFeedbackBusy, \.openingDocument, \.historyChildBlocked] {
            model[keyPath:flag]=true;clipboard.clearContents();table.copy(nil)
            let width=details.propertyColumnWidth;table.resizePropertyDivider(to:width+10)
            try require(clipboard.string(forType:.string)==nil && details.propertyColumnWidth==width,"Blocked viewer accepted property Copy/divider action")
            model[keyPath:flag]=false
        }
        model.onFind?();try await wait("actual Find child"){controller.findWindow?.window != nil}
        let find=controller.findWindow!.window!;focused=find;clipboard.clearContents();_ = find.performKeyEquivalent(with:key(8,"c",.command,host:find));try require(clipboard.string(forType:.string)==nil,"Find Copy stole Properties/source clipboard")
        controller.findWindow?.close();focused=window
        let other=NSWindow(contentRect:NSRect(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false);other.isReleasedWhenClosed=false;otherWindows.append(other);focused=other
        clipboard.clearContents();_ = window.performKeyEquivalent(with:key(8,"c",.command));try require(clipboard.string(forType:.string)==nil,"Background Blame accepted another window's Command-C")
        focused=window;model.setPanePlacement(.properties,.floating);controller.refreshPaneLayout()
        try await wait("floating Properties native table"){controller.floatingPaneWindow(.properties).flatMap{grid(in:$0)} != nil}
        let floating=controller.floatingPaneWindow(.properties)!,floatingTable=grid(in:floating)!
        try require(abs(floatingTable.tableColumns[0].width-256)<1,"Floating pane lost property divider preference")
        focused=floating;floating.makeFirstResponder(floatingTable);floatingTable.resizePropertyDivider(to:268)
        model.setPanePlacement(.properties,.bottom);controller.refreshPaneLayout();focused=window
        try await wait("redocked Properties native table"){grid(in:window) != nil}
        try require(abs(grid(in:window)!.tableColumns[0].width-268)<1,"Redocking lost floating property width")
        controller.close();try await wait("first owner actual work drain"){drained()}
        clipboard.clearContents();table.copy(nil);try require(clipboard.string(forType:.string)==nil,"Retired property responder copied stale data")
        let reopened=makeOwner();owner=reopened
        try await wait("reopened persisted Properties"){!reopened.model.busy && grid(in:reopened.window!) != nil}
        try require(abs(grid(in:reopened.window!)!.tableColumns[0].width-268)<1,"Private width preference did not survive a new Blame window")
        reopened.close();try await wait("all Blame owned work drained"){drained()}
        for (index,path) in savedPaths.enumerated(){try require(try Data(contentsOf:root.appendingPathComponent(path))==saved[index],"Blame pane interaction mutated repository "+path)}
        print("PASS Blame panes: keyboard groups, divider persistence, source parent/Log hashes, focused Copy, stale/busy/retired ownership")
    }
}
