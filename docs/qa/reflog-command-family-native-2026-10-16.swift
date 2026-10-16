import AppKit
import Darwin
import TurtleGitCore

@main struct RefLogCommandFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"RefLog command wait at \(line)")
    }
    @MainActor static func table(_ view:NSView?)->ReferenceLogTableView? {
        guard let view else {return nil};if let table=view as? ReferenceLogTableView {return table};return view.subviews.compactMap{table($0)}.first
    }
    @MainActor static func invoke(_ item:NSMenuItem)throws {guard let action=item.action else {throw Failure(description:"No action: "+item.title)};try require(NSApp.sendAction(action,to:item.target,from:item),"Dispatch failed: "+item.title)}
    @MainActor static func main()async {do {try await verify()}catch {fputs("RefLog commands failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","RefLog Commands"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        for index in 0..<22 {_ = try await repo.run(["commit","--allow-empty","-m","event \(index)"])}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite="TurtleGit.RefLogCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard(name:.init(suite))
        defer {prefs.removePersistentDomain(forName:suite);board.releaseGlobally()}
        prefs.set(["Hash"],forKey:"RefLog.Columns.Hidden")
        let owner=ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",preferences:prefs),model=owner.model
        defer {owner.close()};let window=owner.window as! ReferenceLogNativeWindow
        window.alphaValue=0;window.orderFront(nil);owner.commandKeyWindow={ [weak window] in window }
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return !model.busy && table(window.contentView)?.numberOfRows==23}
        let native=table(window.contentView)!,coordinator=native.owner!;native.pasteboard=board
        try require(!native.tableColumn(withIdentifier:.init("Hash"))!.isHidden,"Restored hidden Hash escaped mandatory column")
        func key(_ code:UInt16,_ flags:NSEvent.ModifierFlags = [],in target:NSWindow? = nil)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:(target ?? window).windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)!}
        let foreign=NSWindow();foreign.isReleasedWhenClosed=false;defer {foreign.close()}
        try require(!window.handleFunctionKey(key(96,.shift)) && !window.handleFunctionKey(key(99,[],in:foreign)),"Modified/foreign function key accepted")
        owner.commandKeyWindow={foreign};try require(!window.handleFunctionKey(key(96)),"Background F5 accepted");owner.commandKeyWindow={ [weak window] in window }
        model.openFind={ [weak owner] in owner?.openFind(visible:false)}
        window.makeFirstResponder(native)
        try require(window.handleFunctionKey(key(3,.control)) && owner.findController != nil,"Ctrl-F did not open owned Find")
        let finder=owner.findController;try require(window.handleFunctionKey(key(99)) && owner.findController === finder,"F3 did not reuse Find")
        let field=NSTextView(frame:.init(x:0,y:0,width:60,height:20));window.contentView!.addSubview(field);window.makeFirstResponder(field)
        try require(!window.handleFunctionKey(key(3,.control)) && !native.handleTableKey(key(0,.control)),"Editable field input escaped responder scope")
        field.removeFromSuperview();window.makeFirstResponder(native)
        try require(native.handleTableKey(key(0,.control)) && model.selection.count==23,"Ctrl-A lost independent event selection")
        try require(native.handleTableKey(key(0,.command)) && native.handleTableKey(key(8,.command)) && native.handleTableKey(key(8,.control)) && board.string(forType:.string)==model.entries.map(\.hash).joined(separator:"\r\n"),"Ctrl-C did not use private board")
        native.selectRowIndexes(IndexSet(integer:18),byExtendingSelection:false)
        var opened:[String]=[];model.onLog={opened.append($0)}
        var shown:NSMenu?,anchor:NSPoint?
        native.presentContextMenu={menu,point,view in shown=menu;anchor=point}
        try require(native.handleTableKey(key(109,.shift)) && shown != nil && anchor != nil,"Shift-F10 did not present selected-row context")
        try require(native.visibleRect.contains(anchor!),"Keyboard context anchor is offscreen")
        let show=shown!.item(withTitle:"Show log")!;try require(show.image != nil,"Keyboard context lost source icon")
        try invoke(show);try invoke(show);try require(opened.count==1 && opened[0]==model.entries[18].hash,"Consumed popup dispatched twice or redirected")
        let old=coordinator.menu(pasteboard:board).item(withTitle:"Show log")!;_ = coordinator.headerMenu();try invoke(old);try require(opened.count==1,"New popup did not retire old row menu")
        try require(native.accessibilityPerformShowMenu(),"AX Show Menu failed")
        let stale=shown!.item(withTitle:"Show log")!;model.reload();try await wait {!model.busy};try invoke(stale);try require(opened.count==1,"Reload retained an old row menu")
        native.selectRowIndexes(IndexSet(integer:18),byExtendingSelection:false);native.scrollRowToVisible(18)
        let clip=native.enclosingScrollView!.contentView,origin=clip.bounds.origin,selection=native.selectedRowIndexes
        native.moveColumn(0,toColumn:4);native.tableColumn(withIdentifier:.init("Hash"))!.width=234;coordinator.saveColumns()
        let header=coordinator.headerMenu();try require(header.item(withTitle:"Hash")==nil && header.items.first?.title=="Reset column order","Header order/mandatory Hash mismatch")
        try invoke(header.item(withTitle:"Message")!);let hidden=native.tableColumn(withIdentifier:.init("Message"))!.isHidden
        try invoke(header.item(withTitle:"Date")!);try require(!native.tableColumn(withIdentifier:.init("Date"))!.isHidden,"Header session dispatched two leaves")
        try require(hidden,"Message toggle failed")
        var answer:CheckedContinuation<Bool,Never>?
        model.confirmColumnReset={await withCheckedContinuation {answer=$0}}
        try invoke(coordinator.headerMenu().item(withTitle:"Reset column order")!);try await wait {answer != nil}
        try require(model.confirmingColumns && !model.canClose && !model.canRefresh && ReferenceLogWindowModel.activeOwnedOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Reset question lost ownership/gates")
        answer?.resume(returning:false);answer=nil;try await wait {!model.confirmingColumns}
        try require(native.tableColumns.last?.title=="Hash" && native.tableColumn(withIdentifier:.init("Message"))!.isHidden,"No changed layout")
        try invoke(coordinator.headerMenu().item(withTitle:"Reset column order")!);try await wait {answer != nil};answer?.resume(returning:true);answer=nil;try await wait {!model.confirmingColumns}
        try require(native.tableColumns.map(\.title)==["Hash","Ref","Action","Message","Date"] && !native.tableColumns.contains(where: \.isHidden) && native.tableColumns[0].width==120,"Accepted Reset did not restore defaults")
        try require(native.selectedRowIndexes==selection && abs(clip.bounds.origin.y-origin.y)<2,"Reset changed selection/reading position")
        // Exercise the actual owned Yes/No sheet and force retirement before reply.
        let closing=ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",preferences:prefs);defer {closing.close()}
        closing.window!.alphaValue=0;closing.window!.orderFront(nil)
        try await wait {closing.window?.contentView?.layoutSubtreeIfNeeded();return !closing.model.busy && table(closing.window?.contentView) != nil}
        let closingTable=table(closing.window?.contentView)!,saved=prefs.dictionaryRepresentation()
        try invoke(closingTable.owner!.headerMenu().item(withTitle:"Reset column order")!)
        try await wait {closing.window?.attachedSheet != nil}
        let alert=closing.window!.attachedSheet!;try require(alert.defaultButtonCell?.title=="Yes","Reset default is not source Yes")
        closing.window!.close();try await wait {ReferenceLogWindowModel.activeOwnedOperations==0}
        try require(closing.model.isInvalidated && closing.window?.attachedSheet==nil && prefs.dictionaryRepresentation() as NSDictionary == saved as NSDictionary,"Forced reset closure persisted late defaults")
        try require(window.handleFunctionKey(key(96)),"Owning F5 rejected");try await wait {!model.busy}
        try require(try await repoRootUnchanged(repo:repo,root:root,head:head,index:index,config:config),"Command family changed repository state")
        try require(window.handleFunctionKey(key(53)) && model.isInvalidated && owner.findController==nil,"Escape did not close owner and owned Find")
        print("PASS RefLog commands: scoped Find/F3/F5/Escape, field preservation, Ctrl/Cmd table routes, keyboard/AX context, consumed/replaced/reloaded popups, mandatory Hash, No/Yes/forced-close Reset, selection/scroll and private persistence, unchanged repository and owned cleanup")
    }
    static func repoRootUnchanged(repo:GitRepository,root:URL,head:Data,index:Data,config:Data)async throws->Bool {
        let actual=try await repo.run(["rev-parse","HEAD"]).stdout
        return try actual==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config && Data(contentsOf:root.appendingPathComponent("file"))==Data("base\n".utf8)
    }
}
