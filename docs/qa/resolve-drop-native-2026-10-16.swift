import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct ResolveDropVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool) async throws {
        for _ in 0..<1500 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Resolve drop wait at line \(line)")
    }
    static func provider(_ url:URL)->NSItemProvider {NSItemProvider(item:url.dataRepresentation as NSData,typeIdentifier:UTType.fileURL.identifier)}
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Drop Fixture"),("user.email","drop@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let paths=["-first 雪\n[*].txt","folder/second.txt","last.txt"]
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        func write(_ value:String)throws {for path in paths {try Data(value.utf8).write(to:root.appendingPathComponent(path))}}
        try write("base\n");try await repo.stage(paths);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","side"]);try write("theirs\n");try await repo.stage(paths);_=try await repo.commit(message:"side")
        _=try await repo.run(["checkout","main"]);try write("mine\n");try await repo.stage(paths);_=try await repo.commit(message:"main")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflicts")}catch is GitFailure {}
        let initial=try await repo.conflicts(),head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try paths.map{try Data(contentsOf:root.appendingPathComponent($0))}
        let suite="TurtleGit.ResolveDrop."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");defer{prefs.removePersistentDomain(forName:suite)}
        let owner=ResolveWindowController(repository:repo,access:nil,paths:[paths[0]],preferences:prefs),model=owner.model,window=owner.window!
        defer{owner.close()};window.alphaValue=0;window.orderFront(nil);owner.commandKeyWindow={window}
        model.load();try await wait {!model.busy && model.entries.count==1}
        try require(model.checked==[paths[0]],"Initial conflict was not checked")
        model.checked=[]
        var drops=0
        model.readDroppedConflicts={scope,token in drops += 1;return (try await repo.conflicts(paths:scope,cancellation:token),false)}
        var initialReply:CheckedContinuation<Void,Never>?
        model.readConflicts={token in await withCheckedContinuation{initialReply=$0};return (try await repo.conflicts(paths:[paths[0]],cancellation:token),false)}
        model.load();try await wait {initialReply != nil}
        try require(model.receiveFileDrop([provider(root.appendingPathComponent("folder"))]) && model.receiveFileDrop([provider(root.appendingPathComponent(paths[0]))]),"Same-repository file/folder drop refused")
        try require(!model.readingDrops,"Drop replaced an active status reader")
        initialReply?.resume();initialReply=nil
        try await wait {!model.busy && model.entries.count==2};model.readConflicts=nil
        try require(drops==1 && Set(model.paths)==[paths[0],"folder"] && model.checked==Set(paths.prefix(2)),"Coalesced scope/check restoration differs")
        model.checked.remove(paths[0]);model.selection=[paths[0]]
        try require(model.receiveFileDrop([provider(root.appendingPathComponent(paths[1]))]),"Descendant drop refused")
        try await wait {!model.busy}
        try require(model.paths.count==2 && !model.checked.contains(paths[0]) && model.checked.contains(paths[1]) && model.selection==[paths[0]],"Ancestor drop duplicated scope or changed unrelated checks")
        let foreign=root.deletingLastPathComponent().appendingPathComponent("foreign-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:foreign)}
        let outside=foreign.appendingPathComponent("outside");try Data().write(to:outside)
        let nested=root.appendingPathComponent("nested");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        _=try await repo.run(["-C",nested.path,"init"]);let child=nested.appendingPathComponent("file");try Data().write(to:child)
        let scope=model.paths,checks=model.checked
        try require(!model.receiveFileDrop([NSItemProvider(object:"not a file" as NSString)]) && !model.receiveFileDrop([]),"Non-file drop accepted")
        try require(model.receiveFileDrop([provider(outside),provider(child),provider(root.appendingPathComponent(".git/index"))]),"File URL batch refused before membership query")
        try await wait {!model.busy};try require(model.paths==scope && model.checked==checks && drops==2,"Foreign/nested/admin drop changed scope or refreshed")
        try require(model.receiveFileDrop([provider(root)]),"Root drop refused")
        try await wait {!model.busy && model.entries.count==3}
        try require(model.paths.isEmpty && model.checked==Set(paths),"Root did not restore complete scope/checks")
        // A held provider retains operation/Quit ownership but cannot publish after Cancel.
        var reply:CheckedContinuation<URL,Never>?
        model.readDroppedURL={_ in await withCheckedContinuation {reply=$0}}
        model.checked.remove(paths[0]);let cancelledChecks=model.checked
        try require(model.receiveFileDrop([provider(root.appendingPathComponent(paths[0]))]),"Held drop refused")
        try await wait {reply != nil}
        try require(!owner.windowShouldClose(window) && model.cancelling && ResolveWindowModel.activeOperations>0,"Close did not request owned cancellation")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored provider read")
        reply?.resume(returning:root.appendingPathComponent(paths[0]));reply=nil
        try await wait {!model.busy && ResolveWindowModel.activeOperations==0}
        try require(model.checked==cancelledChecks && model.paths.isEmpty && model.error==nil,"Cancelled provider rechecked/published")
        model.readDroppedURL=CommitFileURLReader.read
        // Source preference gates an actual subsequent conflict-list read; F5 stays explicit.
        var reads=0
        model.readConflicts={ [weak model] token in reads += 1;return (try await repo.conflicts(paths:model?.paths ?? [],cancellation:token),false)}
        prefs.set(false,forKey:"RefreshFileListAfterResolvingConflict");ConflictListRefreshPolicy.perform(preferences:prefs){model.load()}
        try require(reads==0 && !model.busy,"Disabled auto-refresh read the list")
        prefs.set(2,forKey:"RefreshFileListAfterResolvingConflict");ConflictListRefreshPolicy.perform(preferences:prefs){model.load()}
        try require(reads==0 && !model.busy,"Source DWORD comparison was not exact")
        prefs.removeObject(forKey:"RefreshFileListAfterResolvingConflict");ConflictListRefreshPolicy.perform(preferences:prefs){model.load()}
        try await wait {!model.busy};try require(reads==1 && !model.checked.contains(paths[0]),"Default refresh lost manual uncheck")
        func event(_ key:UInt16,_ flags:NSEvent.ModifierFlags=[])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:key)!}
        prefs.set(false,forKey:"RefreshFileListAfterResolvingConflict")
        try require(window.performKeyEquivalent(with:event(96,.function)),"Source F5 absent")
        try await wait {!model.busy};try require(reads==2,"Explicit F5 was gated by automatic-refresh preference")
        model.checked=[];try require(window.performKeyEquivalent(with:event(36,.control)) && !model.showingProgress,"Empty Control-Return resolved files")
        let foreignWindow=NSWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false);defer{foreignWindow.close()}
        owner.commandKeyWindow={foreignWindow};try require(!owner.performCommandKey(event(96)),"Background F5 accepted");owner.commandKeyWindow={window}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && paths.map{try Data(contentsOf:root.appendingPathComponent($0))}==bytes,"Drop/read commands mutated repository")
        // The real source acceptance shortcut resolves exactly the checked file.
        model.checked=[paths[0]]
        try require(window.performKeyEquivalent(with:event(36,.control)),"Control-Return absent")
        try await wait {!model.busy && model.showingProgress}
        try require(model.success && model.resolvedCount==1 && model.entries.count==2,"Checked keyboard resolve did not execute exactly once")
        try require(try await repo.conflicts()==initial.filter{$0.path != paths[0]},"Other conflict stages changed")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && paths.map{try Data(contentsOf:root.appendingPathComponent($0))}==bytes,"Checked resolve changed HEAD/worktree")
        let late=ResolveWindowController(repository:repo,access:nil,paths:[paths[1]],preferences:prefs);defer{late.close()}
        late.model.load();try await wait {!late.model.busy && late.model.entries.count==1}
        let lateRows=late.model.entries;var lateReply:CheckedContinuation<URL,Never>?
        late.model.readDroppedURL={_ in await withCheckedContinuation{lateReply=$0}}
        try require(late.model.receiveFileDrop([provider(root)]),"Late provider refused")
        try await wait {lateReply != nil};late.close()
        try require(ResolveWindowModel.activeOperations>0,"Forced close dropped active provider count")
        lateReply?.resume(returning:root);lateReply=nil
        try await wait {ResolveWindowModel.activeOperations==0}
        try require(late.model.paths==[paths[1]] && late.model.entries==lateRows && !late.model.active,"Retired provider replaced rows/scope")
        print("PASS: Resolve same-repository literal file/folder/root drops, coalesced reads, ancestor scopes, rechecks/manual selection, foreign/nested/admin rejection, Cancel/forced-close/Quit ownership, source refresh preference and explicit F5, real checked Control-Return resolution with exact unrelated stages/HEAD/worktree preservation; owned windows closed")
    }
}
