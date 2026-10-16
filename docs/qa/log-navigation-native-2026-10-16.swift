import AppKit
import TurtleGitCore

struct LogNavigationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log navigation timeout at line \(line)")
    }
    @MainActor static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    @MainActor static func key(_ window:NSWindow,_ code:UInt16,_ text:String = "",_ flags:NSEvent.ModifierFlags = [])->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (name,value) in [("user.name","Navigation QA"),("user.email","nav@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",name,value])}
        for i in 0..<5 {try Data("revision \(i)\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Navigation \(i)")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:root.appendingPathComponent("file"))
        let suite="TurtleGit.LogNavigation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs),model=owner.model,window=owner.window as! LogHistoryWindow
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);window.commandKeyWindow={window};model.clipboard=clipboard
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !model.busy && model.entries.filter{!$0.hash.isEmpty}.count==5 && views(window.contentView!).contains{$0 is HistoryTableView}}
        let table=views(window.contentView!).compactMap{$0 as? HistoryTableView}.first!,hashes=model.entries.filter{!$0.hash.isEmpty}.map(\.hash)
        model.selectionNavigation = .init();model.select([hashes[0]]);model.select([hashes[1]]);model.select([hashes[2]])
        let history=model.selectionNavigation.hashes
        window.makeFirstResponder(table)
        try require(window.performKeyEquivalent(with:key(window,123,"",.option)),"Option-Left not routed")
        try require(model.selected==[hashes[1]] && model.selectionNavigation.hashes==history && model.selectionNavigation.location==1,"Back selected/truncated wrong history")
        _=window.performKeyEquivalent(with:key(window,123,"",[.option,.shift]))
        try require(model.selected==[hashes[1]] && model.highlightedRevision==hashes[0] && model.selectionNavigation.location==0,"Scroll-only Back changed selection")
        _=window.performKeyEquivalent(with:key(window,30,"]",.command))
        try require(model.selected==[hashes[1]] && model.highlightedRevision==nil && model.selectionNavigation.location==1,"Native Forward did not retain cursor")
        _=window.performKeyEquivalent(with:key(window,124,"",.option))
        try require(model.selected==[hashes[2]] && model.selectionNavigation.hashes==history,"Repeated Forward lost future entries")
        try await wait {table.selectedRowIndexes.count==1 && model.entries[table.selectedRowIndexes.first!].hash==hashes[2]}
        _=window.performKeyEquivalent(with:key(window,33,"{",[.command,.shift]))
        try require(model.selected==[hashes[2]] && model.highlightedRevision==hashes[1],"Shifted native bracket did not retain scroll-only behavior")
        _=window.performKeyEquivalent(with:key(window,30,"}",[.command,.shift]))
        try require(model.selected==[hashes[2]] && model.highlightedRevision==hashes[2],"Shifted Forward bracket did not restore history cursor")
        // Clipboard hash navigation wraps and uses a private pasteboard, including multi-selection mark.
        func copy(_ text:String){clipboard.clearContents();clipboard.setString(text,forType:.string)}
        copy(" \n"+String(hashes[4].prefix(8))+"\t")
        _=window.performKeyEquivalent(with:key(window,9,"v",.command))
        try require(model.selected==[hashes[4]] && model.scrollRevision==hashes[4],"Copied prefix did not navigate")
        model.select([hashes[0],hashes[4]],mark:hashes[4]);copy(String(hashes[0].prefix(8)))
        _=window.performKeyEquivalent(with:key(window,9,"v",.control))
        try require(model.selected==[hashes[0]],"Clipboard hash did not use multi-selection mark/wrap")
        for invalid in [String(hashes[2].prefix(2)),"ABCDEF12","https://example.invalid/"+hashes[2],String(hashes[2].prefix(8))+"@mail"] {
            copy(invalid);model.pasteGitHash();try require(model.selected==[hashes[0]],"Invalid clipboard text navigated")
        }
        let shortTarget=hashes.dropFirst().first{candidate in !hashes.contains{$0 != candidate && $0.hasPrefix(String(candidate.prefix(3)))}}!
        prefs.set(3,forKey:"ShortHashLengthForHyperLinkInLogMessage");copy(String(shortTarget.prefix(3)));model.pasteGitHash()
        try require(model.selected==[shortTarget],"Configured minimum hash length ignored")
        // Editable native field/text responders keep paste and Option-arrow editing.
        let editor=NSTextView(frame:.init(x:0,y:0,width:100,height:40));editor.string="draft";window.contentView!.addSubview(editor);window.makeFirstResponder(editor)
        let before=model.selected,location=model.selectionNavigation.location
        _=window.performKeyEquivalent(with:key(window,9,"v",.command));_=window.performKeyEquivalent(with:key(window,123,"",.option))
        try require(model.selected==before && model.selectionNavigation.location==location,"Editable responder lost paste/word-navigation ownership")
        editor.removeFromSuperview();window.makeFirstResponder(table)
        window.commandKeyWindow={nil};_=window.performKeyEquivalent(with:key(window,123,"",.option))
        try require(model.selected==before && model.selectionNavigation.location==location,"Background Log navigated")
        window.commandKeyWindow={window};model.findBlocked=true;_=window.performKeyEquivalent(with:key(window,123,"",.option));model.findBlocked=false
        try require(model.selected==before,"Child-blocked Log navigated")
        // Hidden history targets consume the history cursor but preserve the selected revision.
        model.selectionNavigation = .init();model.selectionNavigation.add("hidden-revision");model.selectionNavigation.add(hashes[3])
        model.moveSelectionHistory(up:true,selectTarget:true)
        try require(model.selected==before && model.navigationNotice?.contains("hidden-revision")==true && model.highlightedRevision==nil,"Hidden history target changed selection or lost notice")
        model.selectionNavigation = .init();for hash in hashes.prefix(3){model.selectionNavigation.add(hash)}
        model.moveSelectionHistory(up:true,selectTarget:true);model.select([hashes[4]])
        try require(model.selectionNavigation.hashes==[hashes[0],hashes[1],hashes[4]] && !model.canMoveHistory(up:false),"Manual selection did not branch history")
        // Source mouse side-button dispatcher; no global mouse events are posted.
        let mouse=CGEvent(mouseEventSource:nil,mouseType:.otherMouseUp,mouseCursorPosition:.zero,mouseButton:CGMouseButton(rawValue:3)!)!
        let event=NSEvent(cgEvent:mouse)!
        try require(model.handleNavigation(event) && model.selected==[hashes[1]],"Mouse Back dispatcher failed")
        let held=model.selected;owner.close();_=model.handleNavigation(event)
        try require(model.selected==held && !model.canNavigateLog,"Retired Log navigated")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent("file"))==bytes,"Read-only navigation altered repository")
        print("PASS: native Log Back/Forward and scroll-only shortcuts, preserved cursor/branching/hidden targets, clipboard prefix/mark/wrap, editable/background/child/retired gates, source side-button dispatcher and immutable repository")
    }
}
