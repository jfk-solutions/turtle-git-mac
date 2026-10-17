import AppKit
import TurtleGitCore

struct CommitCommandMenuVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ value:()->Bool) async throws {
        for _ in 0..<3000 {if value(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit command fixture did not settle")
    }
    @MainActor static func find(_ title:String,in menu:NSMenu)->NSMenuItem? {
        for item in menu.items {if item.title==title {return item};if let child=item.submenu,let found=find(title,in:child) {return found}}
        return nil
    }
    @MainActor static func send(_ item:NSMenuItem) {if let action=item.action {_=NSApp.sendAction(action,to:item.target,from:item)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Command QA"),("user.email","commands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        for path in ["file","other"] {try Data("before\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(["file","other"]);_=try await repo.commit(message:"base")
        for path in ["file","other"] {try Data("after\n".utf8).write(to:root.appendingPathComponent(path))};try Data("new\n".utf8).write(to:root.appendingPathComponent("new"))
        let suite="TurtleGit.CommitCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(1,forKey:"CommitLastAction");prefs.set(true,forKey:"HintStagingMode");prefs.set(true,forKey:"Commit.SkipCancelConfirmation")
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.reload(paths:["."])
        try await wait {!model.busy && model.hasHead && model.changelistsLoaded && owner.messageEditor() != nil}
        try require(model.error==nil,"Initial Commit read failed")
        model.message="Native command commit";model.checked=["file"];model.onCommitProgress=nil
        var main=NSMenu(title:"Application"),commits=0
        let menus=owner.commandMenu!;menus.applicationMenu={main};menus.keyWindow={window};menus.install()
        model.onCommitted={_ in commits += 1}
        func rootMenu()->NSMenu {main.items.first{$0.title=="Commit"}!.submenu!}
        func item(_ title:String)->NSMenuItem {find(title,in:rootMenu())!}
        let primary=rootMenu().items[0]
        try require(primary.title=="ReCommit" && primary.image != nil && menus.validateMenuItem(primary),"Remembered primary action/icon/state")
        try require(item("Commit actions").submenu!.items.map(\.title)==["Commit","ReCommit","Commit & Push"],"Source commit action menu")
        let controlReturn=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.control,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        model.busy=true;try require(window.performKeyEquivalent(with:controlReturn) && commits==0 && !menus.validateMenuItem(primary),"Disabled Control-Return was not consumed")
        model.busy=false
        let other=NSWindow(contentRect:.zero,styleMask:[.titled],backing:.buffered,defer:false);defer {other.close()};other.isReleasedWhenClosed=false
        menus.keyWindow={other};send(primary);try require(commits==0 && !menus.validateMenuItem(primary),"Background menu remained active");menus.keyWindow={window}
        send(item("None"));try require(model.checked.isEmpty,"Native None")
        send(item("Modified"));try require(model.checked==["file","other"],"Native category check")
        model.checked.insert("new");model.check({$0.state == .modified},checking:false)
        try require(model.checked==["new"],"Reverse category check changed unrelated rows")
        model.checkAll(true);try require(model.checked==GitPathSet(model.visibleEntries.filter{$0.state != .conflicted}.map(\.id)),"Reverse None/check all")
        send(item("Staging support (EXPERIMENTAL)"));try await wait {!model.busy && !model.savingPreferences && model.stagingEnabled}
        model.check({$0.state == .modified},checking:true);try await wait {!model.busy && CommitWindowModel.activeFileOperations==0}
        try require(model.visibleEntries.filter{$0.state == .modified}.allSatisfy{model.isStaged($0)},"Staging category check")
        model.check({$0.state == .modified},checking:false);try await wait {!model.busy && CommitWindowModel.activeFileOperations==0}
        try require(model.visibleEntries.filter{$0.state == .modified}.allSatisfy{!model.isStaged($0)},"Staging reverse category check")
        send(item("Staging support (EXPERIMENTAL)"));try await wait {!model.busy && !model.savingPreferences && !model.stagingEnabled}
        model.message="Native command commit";model.checked=["file"]
        send(item("Focus commit message"));try await wait {window.firstResponder === owner.messageEditor()}
        model.messageHistory?.add("history command")
        send(item("Recent messages…"));try await wait {owner.hasMessagePicker && window.attachedSheet != nil}
        try require(!menus.validateMenuItem(primary),"History sheet did not disable Commit")
        let sheet=window.attachedSheet!
        let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
        if !sheet.performKeyEquivalent(with:escape) {sheet.sendEvent(escape)}
        try await wait {!owner.hasMessagePicker && window.attachedSheet==nil}
        menus.install()
        var signOff:CheckedContinuation<String,Never>?,queries=0
        model.querySignOff={_ in queries += 1;return await withCheckedContinuation {signOff=$0}}
        send(item("Add Signed-off-by"));try await wait {signOff != nil}
        try require(model.busy && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel,"Sign-off read lost ownership")
        send(item("Add Signed-off-by"));try require(queries==1,"Sign-off duplicate read")
        let priorMessage=model.message
        signOff?.resume(returning:"Signed-off-by: cancelled");signOff=nil
        try await wait {!model.busy && CommitWindowModel.activeFileOperations==0}
        try require(model.message==priorMessage && model.error != nil,"Close-requested cancellation changed sign-off draft")
        model.error=nil;try await wait {window.attachedSheet==nil};menus.install()
        send(item("Add Signed-off-by"));try await wait {signOff != nil}
        try require(queries==2,"Sign-off retry unavailable")
        signOff?.resume(returning:"Signed-off-by: Command QA <commands@example.invalid>");signOff=nil
        try await wait {!model.busy && CommitWindowModel.activeFileOperations==0}
        try require(model.message.contains("Signed-off-by: Command QA"),"Sign-off retry not appended")
        model.querySignOff=nil
        let stale=rootMenu().items[0],tracked=rootMenu();menus.menuWillOpen(tracked)
        main=NSMenu(title:"Replacement");menus.install();try require(main.items.isEmpty,"Tracking menu rebuilt prematurely")
        send(stale);try require(commits==0,"Detached target invoked")
        menus.menuDidClose(tracked);menus.install();menus.install()
        try require(main.items.filter{$0.title=="Commit"}.count==1,"Repaired menu duplicated")
        send(stale);try require(commits==0,"Old menu epoch invoked")
        let before=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(window.performKeyEquivalent(with:controlReturn),"Control-Return unavailable")
        _=window.performKeyEquivalent(with:controlReturn)
        try await wait {commits==1 && !model.busy && model.hasHead}
        let count=try await repo.run(["rev-list","--count",before+"..HEAD"]).text.trimmingCharacters(in:.newlines)
        let treeFile=try await repo.run(["show","HEAD:file"]).text,treeOther=try await repo.run(["show","HEAD:other"]).text
        try require(count=="1" && treeFile=="after\n" && treeOther=="before\n" && model.messageFocusAvailable,"Control-Return did not run one remembered ReCommit")
        owner.close();send(stale)
        try require(main.items.isEmpty,"Retired Commit left menu attached")
        let lateOwner=CommitWindowController(repository:repo,access:nil,defaults:prefs),late=lateOwner.model,lateWindow=lateOwner.window!
        defer {lateOwner.close()};lateWindow.alphaValue=0;lateWindow.orderFront(nil);late.reload(paths:["."])
        try await wait {!late.busy && late.hasHead && late.changelistsLoaded}
        late.message="retired draft";var reply:CheckedContinuation<String,Never>?
        late.querySignOff={_ in await withCheckedContinuation {reply=$0}};late.addSignOff();try await wait {reply != nil}
        let active=CommitWindowModel.activeFileOperations
        lateOwner.close();try require(CommitWindowModel.activeFileOperations==active,"Retirement lost sign-off lifetime")
        reply?.resume(returning:"Signed-off-by: late");reply=nil
        try await wait {CommitWindowModel.activeFileOperations==active-1}
        try require(late.message=="retired draft" && late.error==nil,"Late sign-off mutated retired draft")
        print("PASS: scoped native Commit menu/actions/icons, remembered Control-Return real commit, duplicate/busy/background/sheet gates, category check/reverse in checkbox and staging modes, message focus/history, owned sign-off read and retirement, main-menu replacement/tracking/epoch repair; owned windows closed")
    }
}
