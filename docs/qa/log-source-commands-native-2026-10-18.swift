// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct LogSourceCommandsVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 { if ready(){return};try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Log source command timeout at line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    @MainActor static func key(_ window:NSWindow,_ code:UInt16,_ text:String = "",_ flags:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    @MainActor static func invoke(_ item:NSMenuItem) { _=NSApp.sendAction(item.action!,to:item.target,from:item) }
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (name,value) in [("user.name","Source Commands QA"),("user.email","commands@example.invalid"),("commit.gpgsign","false")] { _=try await repo.run(["config",name,value]) }
        for n in 0..<3 { try Data("revision \(n)\n".utf8).write(to:root.appendingPathComponent("sample"));try await repo.stage(["sample"]);_=try await repo.commit(message:"Source revision \(n)\n\nMessage body \(n)") }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout, staged=try await repo.run(["ls-files","--stage"]).stdout, bytes=try Data(contentsOf:root.appendingPathComponent("sample"))
        let suite="TurtleGit.LogSourceCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        prefs.set(false,forKey:"Gravatar");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges")
        prefs.set(HistorySearchFields.subject.rawValue,forKey:"SelectedLogFilters")
        let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false),model=owner.model,window=owner.window as! LogHistoryWindow
        defer { owner.close() };window.alphaValue=0;window.orderFront(nil);window.commandKeyWindow={window};model.clipboard=clipboard
        try await wait { window.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.entries.count==3 && views(window.contentView!).contains{$0 is HistoryTableView} }
        let table=views(window.contentView!).compactMap{$0 as? HistoryTableView}.first!
        let history=views(window.contentView!).compactMap{$0 as? NSSearchField}.first{$0.identifier?.rawValue=="TurtleGit.Log.HistoryFilter"}!
        model.select([model.entries[0].hash]);try await wait { !model.files.isEmpty && views(window.contentView!).contains{$0 is LogMessageTextView} }
        window.makeFirstResponder(table)
        var findCount=0;window.find={findCount+=1}
        for (code,text,flags) in [(UInt16(99),"",NSEvent.ModifierFlags()),(3,"f",.control),(3,"f",.command)] { try require(window.performKeyEquivalent(with:key(window,code,text,flags)),"Find not routed") }
        try require(findCount==3,"Find fired wrong number of times")
        for (code,text,flags) in [(UInt16(37),"l",NSEvent.ModifierFlags.control),(2,"d",.option),(37,"l",.command)] {
            window.makeFirstResponder(table);_=window.performKeyEquivalent(with:key(window,code,text,flags));try require(history.currentEditor() === window.firstResponder,"Focus command targets revision filter")
        }
        model.editSearch("Source",submit:false);history.stringValue="Source";window.makeFirstResponder(table)
        _=window.performKeyEquivalent(with:key(window,14,"e",.control))
        try require((history.currentEditor() as? NSTextView)?.selectedRange()==NSRange(location:0,length:6),"Control-E selects history filter")
        let draft=NSTextView(frame:.init(x:0,y:0,width:100,height:40));draft.string="native draft";window.contentView!.addSubview(draft);window.makeFirstResponder(draft)
        for (code,text,flags) in [(UInt16(14),"e",NSEvent.ModifierFlags.control),(2,"d",.option),(3,"f",.control)] {
            try require(!owner.handleSourceCommand(key(window,code,text,flags)) && window.firstResponder === draft,"Native text editing intercepted")
        }
        draft.removeFromSuperview();window.makeFirstResponder(table)
        // Source Refresh clears only revision search; ordinary background reload retains it.
        model.editSearch("revision 1",submit:true);try await wait { !model.busy && model.entries.count==1 }
        model.reload();try await wait { !model.busy };try require(model.search=="revision 1" && model.entries.count==1,"Background reload cleared history search")
        model.editPathFilter("sample",submit:true)
        _=window.performKeyEquivalent(with:key(window,96))
        try await wait { !model.busy && model.entries.count==3 }
        try require(model.search.isEmpty && model.appliedMessageSearch.query.isEmpty && model.pathFilterDraft=="sample","F5 did not clear only history search")
        for flags in [NSEvent.ModifierFlags.control,.shift] {
            model.editSearch("draft",submit:false);window.makeFirstResponder(table);_=window.performKeyEquivalent(with:key(window,96,"",flags));try await wait { !model.busy };try require(model.search.isEmpty,"Modified F5 failed")
        }
        model.editSearch("draft",submit:false);window.makeFirstResponder(table);_=window.performKeyEquivalent(with:key(window,15,"r",.command));try await wait { !model.busy };try require(model.search.isEmpty,"Native Refresh alias failed")
        var closes=0;model.close={closes+=1};model.editSearch("draft",submit:false);window.makeFirstResponder(table)
        _=window.performKeyEquivalent(with:key(window,53));try require(model.search.isEmpty && closes==0,"First Escape must clear filter")
        try await wait { !model.busy };window.makeFirstResponder(table);_=window.performKeyEquivalent(with:key(window,53));try require(closes==1,"Empty-filter Escape must close")
        var returns=0;table.onReturn={returns+=1;return false}
        try require(table.performRevisionReturn(with:key(window,36)) && returns==1 && closes==1,"Revision Return falls through to default Close")
        model.select([model.entries[0].hash]);try await wait { !model.busy && !model.files.isEmpty }
        try await wait { Set(table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].hash:nil }) == model.selected }
        window.makeFirstResponder(table);_=window.performKeyEquivalent(with:key(window,8,"c",.control));try await wait { !model.copyingDetails }
        try require(clipboard.string(forType:.string)?.contains("Source revision")==true,"Control-C did not copy revision details to owned clipboard")
        clipboard.clearContents();_=window.performKeyEquivalent(with:key(window,114,"",.control));try await wait { !model.copyingDetails };try require(clipboard.string(forType:.string)?.contains("Source revision")==true,"Control-Insert did not copy")
        let editor=views(window.contentView!).compactMap{$0 as? LogMessageTextView}.first!
        editor.coordinator?.refresh()
        try await wait { editor.string==model.messageDocument.text && LogMessageView.Coordinator.activeOperations==0 }
        let coordinator=editor.coordinator!,range=NSRange(location:0,length:5),whole=editor.string
        editor.setSelectedRange(range);window.makeFirstResponder(editor);_=window.performKeyEquivalent(with:key(window,8,"c",.command))
        try require(clipboard.string(forType:.string)==(whole as NSString).substring(with:range),"Message copy bypassed injected pasteboard")
        let menu=coordinator.menu(at:0),copy=menu.items.first{$0.title=="Copy"}!,all=menu.items.first{$0.title=="Copy all"}!,notes=menu.items.first{$0.title=="Edit Notes"}!
        try require(copy.image != nil && all.image != nil && notes.image != nil,"Source message menu icons missing")
        let origin=editor.enclosingScrollView?.contentView.bounds.origin
        invoke(all);try require(clipboard.string(forType:.string)==whole && editor.selectedRange()==range && editor.enclosingScrollView?.contentView.bounds.origin==origin,"Copy all changes selection/viewport")
        invoke(copy);try require(clipboard.string(forType:.string)==whole,"Sibling menu callback replayed")
        for state in 0..<5 {
            let blocked=coordinator.menu(at:0).items.first{$0.title=="Copy all"}!
            clipboard.clearContents();clipboard.setString("sentinel",forType:.string)
            switch state {case 0:model.busy=true;case 1:model.findBlocked=true;case 2:model.orderingBlocked=true;case 3:model.referencePickerBlocked=true;default:model.confirmingQuit=true}
            invoke(blocked);try require(clipboard.string(forType:.string)=="sentinel","Blocked message menu executed")
            model.busy=false;model.findBlocked=false;model.orderingBlocked=false;model.referencePickerBlocked=false;model.confirmingQuit=false
        }
        let stale=coordinator.menu(at:0).items.first{$0.title=="Copy all"}!;_=coordinator.menu(at:0);invoke(stale);try require(clipboard.string(forType:.string)=="sentinel","Replaced popup callback executed")
        // Notes enters the existing read/editor flow; another callback cannot replace its draft.
        var noteOpens=0;model.onShowNote={_,_ in noteOpens+=1}
        let noteMenu=coordinator.menu(at:0),noteItem=noteMenu.items.first{$0.title=="Edit Notes"}!
        invoke(noteItem);try await wait { !model.loadingNote && model.noteRequest != nil }
        model.noteText="retained draft";invoke(noteItem);try require(noteOpens==1 && model.noteText=="retained draft","Notes menu replaced an open draft")
        model.cancelNote()
        window.makeFirstResponder(table);model.confirmingQuit=true;let held=model.search;_=window.performKeyEquivalent(with:key(window,96));try require(model.search==held && !model.canUseSourceCommands && !model.canEditNotes,"Quit confirmation did not fence Log")
        model.confirmingQuit=false;window.commandKeyWindow={nil};try require(!owner.handleSourceCommand(key(window,3,"f",.command)) && findCount==3,"Background Log handled key")
        window.commandKeyWindow={window}
        let retired=coordinator.menu(at:0).items.first{$0.title=="Copy all"}!;owner.close();invoke(retired)
        try await wait { LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeNoteReads==0 && LogMessageView.Coordinator.activeOperations==0 }
        try require(model.isInvalidated && clipboard.string(forType:.string)=="sentinel","Retired message menu executed")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterStaged=try await repo.run(["ls-files","--stage"]).stdout
        try require(afterHead==head && afterStaged==staged && (try Data(contentsOf:root.appendingPathComponent("sample")))==bytes,"Source commands modified repository")
        print("PASS: Log source focus/find/refresh/escape/copy, native editing, Return shielding, owned one-shot message menus, Notes draft, busy/child/Quit/retired gates and immutable repository")
    }
}
