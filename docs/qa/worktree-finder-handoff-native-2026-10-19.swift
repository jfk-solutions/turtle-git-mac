import AppKit
import FinderSync
import TurtleGitCore

private struct WorktreeFinderScopes:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
@MainActor private final class WorktreeFinderTarget:NSObject {
    var request:FinderRequest?
    @objc func invoke(_ item:NSMenuItem){request=(item.representedObject as? FinderMenuCommand)?.request}
}
struct WorktreeFinderHandoffVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Worktree Finder timeout at \(line): \(message)")
    }
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return[root]+root.subviews.flatMap{views($0)}}
    @MainActor static func verify()async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),source=container.appendingPathComponent("source 雪.git"),parent=container.appendingPathComponent("chosen parent")
        for folder in [source,parent] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)}
        let repository=GitRepository(root:source,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Worktree Finder"),("user.email","worktree@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        let file=source.appendingPathComponent("tracked"),bytes=Data("tracked original\n".utf8)
        try bytes.write(to:file);try Data().write(to:source.appendingPathComponent(".gitmodules"));try await repository.stage(["tracked",".gitmodules"]);_ = try await repository.commit(message:"Worktree Finder baseline")
        let head=try await repository.run(["rev-parse","HEAD"]),index=try Data(contentsOf:source.appendingPathComponent(".git/index")),config=try Data(contentsOf:source.appendingPathComponent(".git/config"))
        let suite="TurtleGit.WorktreeFinder."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(true,forKey:"ShowGitexeTimings")
        ProgressActionLog.install(store:ActionLogStore(storageURL:container.appendingPathComponent("private-actions.log")),preferences:prefs)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false})
        workspace.repositoryBookmarkProvider=WorktreeFinderScopes();workspace.requiresRepositoryScope=true;workspace.fileComparisonPreferences=prefs
        let host=NSWindow(contentRect:NSRect(x:-2000,y:-2000,width:700,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;host.alphaValue=0;host.appearance=NSAppearance(named:.darkAqua);host.orderFront(nil);workspace.workspaceWindow=host
        var ownedWindows=[host]
        let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in};delegate.repositoryModel=workspace
        var creations:[WorktreeCreateWindowController]=[],children:[SubmoduleUpdateWindowController]=[],panels:[NSOpenPanel]=[]
        var folderReply:((NSApplication.ModalResponse)->Void)?,selected:URL?,folderQuestions=0
        var permissionReply:CheckedContinuation<RepositoryAccessLease?,Never>?
        workspace.worktreeSourceAccessProvider={paths in paths.first.map{RepositoryAccessLease(url:$0,provider:WorktreeFinderScopes())}}
        workspace.presentWorktreeFolderPanel={panel,owner,reply in
            panels.append(panel);folderReply=reply;folderQuestions += 1;panel.alphaValue=0;panel.appearance=owner?.appearance
            if let owner {owner.beginSheet(panel,completionHandler:nil)}
        }
        workspace.selectedWorktreeFolderURL={_ in selected}
        workspace.worktreeCreateWindowFactory={repo,access,preferences,initial in
            let value=WorktreeCreateWindowController(repository:repo,access:access,preferences:preferences,initialDirectory:initial)
            value.model.requiresSecurityScope=true;value.window?.alphaValue=0;value.window?.appearance=host.appearance;creations.append(value);return value
        }
        func cleanup()async {
            workspace.cancelFinderWorktreeCreation();folderReply?(.cancel);folderReply=nil
            permissionReply?.resume(returning:nil);permissionReply=nil
            for creation in creations {creation.model.confirmingQuit=false;creation.close()}
            for child in children {child.close()}
            for panel in panels {panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close()}
            workspace.stopMonitoringForTermination();workspace.closeRepository();for owned in ownedWindows {owned.close()}
            for _ in 0..<2500 {
                if !workspace.hasPendingRepositoryWork && WorktreeCreateWindowModel.activeOperations==0 && LocalGitCommandProgress.activeOperations==0 && SubmoduleUpdateWindowModel.activeReads==0 {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite)
        }
        do {
            // The actual Finder command captures only the selected repository.
            var snapshot=FinderSnapshot.build(root:source,tracked:["tracked",".gitmodules"],changes:[])
            snapshot.repositories[source.path]=FinderRepositoryMetadata(bare:false)
            var settings=FinderMenuSettings();settings.extendedOnlyMask=0;settings.showIcons=true
            let target=WorktreeFinderTarget()
            let menu=FinderMenuBuilder.make(paths:[source],snapshot:snapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:#selector(WorktreeFinderTarget.invoke(_:)),sourceSelection:[source])
            func items(_ menu:NSMenu)->[NSMenuItem] {menu.items+menu.items.flatMap{$0.submenu.map(items) ?? []}}
            guard let command=items(menu).first(where:{($0.representedObject as? FinderMenuCommand)?.request.action == .worktreeCreate}),let action=command.action else {throw Failure(description:"Actual Finder Worktree Create menu missing")}
            try require(command.isEnabled && command.image != nil && NSApp.sendAction(action,to:command.target,from:command),"Finder Worktree source action/icon dispatch missing")
            guard let request=target.request,let url=request.url else {throw Failure(description:"Finder Worktree source URL missing")}
            try require(request.paths.map(\.path)==[source.path] && request.sources.isEmpty,"Finder command selected a destination/clipboard source")
            workspace.handle(url);try await wait("source destination sheet") {folderReply != nil && panels.last?.sheetParent === host}
            try require(workspace.hasPendingRepositoryWork && delegate.applicationShouldTerminate(NSApp) == .terminateCancel && creations.isEmpty,"Finder destination picker lost Quit/owned preparation or created early")
            try require(panels.last?.canChooseDirectories==true && panels.last?.canChooseFiles==false && panels.last?.canCreateDirectories==true && panels.last?.alphaValue==0 && panels.last?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua,"Native destination picker lost folder/create/hidden/appearance policy")
            workspace.handle(url);try require(folderQuestions==1,"Replayed active Finder request duplicated destination picker")
            let late=folderReply;workspace.cancelFinderWorktreeCreation();folderReply=nil
            try await wait("cancelled destination sheet drained") {!workspace.hasPendingRepositoryWork && host.attachedSheet==nil}
            selected=parent;late?(.OK)
            try await wait("cancelled late reply drained") {!workspace.busy}
            try require(creations.isEmpty && !FileManager.default.fileExists(atPath:parent.appendingPathComponent("source 雪").path),"Late cancelled destination selection created a Worktree dialog/path")
            // Existing working folders are not destinations, even if selected by
            // a stale cached menu or an injected native folder reply.
            workspace.handle(url);try await wait("versioned destination picker") {folderReply != nil}
            selected=source;folderReply?(.OK);folderReply=nil
            try await wait("versioned destination refused") {!workspace.hasPendingRepositoryWork && !workspace.busy && host.attachedSheet==nil}
            try require(creations.isEmpty && workspace.error != nil,"Versioned destination bypassed native source validation")
            workspace.handle(url);try await wait("accepted destination picker") {folderReply != nil}
            selected=parent;folderReply?(.OK);folderReply=nil
            try await wait("prefilled native Create") {creations.count==1 && !creations[0].model.busy && !creations[0].model.chooser.busy && host.attachedSheet==nil}
            let create=creations[0],model=create.model,destination=parent.appendingPathComponent("source 雪")
            try require(model.preferences === prefs && model.directory==destination.path && model.branchName=="source 雪" && model.checkout && !model.force && !model.detach,"Finder Create lost captured prefs/source .git basename/source defaults")
            let before=try await repository.worktrees()
            try require(before.count==1 && !FileManager.default.fileExists(atPath:destination.path),"Folder acceptance mutated Git before OK")
            model.confirmingQuit=true;model.create();try require(!model.progress && !FileManager.default.fileExists(atPath:destination.path),"Deferred Quit permitted Create")
            model.confirmingQuit=false;model.detach=true;model.changedDetach()
            // Dispatch the production default OK keyboard action. Current
            // SwiftUI renders its buttons without backing NSButton instances.
            create.window?.contentView?.layoutSubtreeIfNeeded();create.window?.contentView?.displayIfNeeded()
            try await Task.sleep(nanoseconds:50_000_000)
            let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:create.window!.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            try require(create.window!.performKeyEquivalent(with:enter),"Native Create default OK keyboard action missing")
            try await wait("created progress complete") {!model.busy && model.progress && model.success}
            try require(model.percentage==100 && model.completionRange != nil && model.currentWork=="Success" && model.hasSubmodules && FileManager.default.fileExists(atPath:destination.appendingPathComponent("tracked").path),"Create completion lost 100%/status/footer/post-action")
            let completion=(model.output as NSString).substring(with:model.completionRange!)
            try require(completion.contains("Success") && completion.contains(" ms @ "),"Create completion omitted source elapsed/finished timing")
            // A real sheet release retires the old owner before source followup.
            var closes=0,followups=0,capturedPath:URL?,capturedGrant:RepositoryAccessLease?,handoffDrained=false
            let priorClosed=create.onClosed,priorSubmodules=model.onSubmodules
            create.onClosed={closes += 1;priorClosed()}
            model.onSubmodules={path,grant in
                followups += 1;capturedPath=path;capturedGrant=grant
                handoffDrained=closes==1 && host.attachedSheet==nil && create.window?.sheetParent==nil && create.window?.isVisible != true && !model.busy && !model.chooser.busy
                priorSubmodules(path,grant)
                children += NSApp.windows.compactMap{$0.delegate as? SubmoduleUpdateWindowController}.filter{child in !children.contains{$0 === child}}
            }
            create.window!.orderOut(nil);host.beginSheet(create.window!,completionHandler:nil)
            model.confirmingQuit=true;model.updateSubmodules();try require(followups==0 && closes==0,"Deferred Quit dispatched Submodule Update")
            model.confirmingQuit=false;model.updateSubmodules();model.updateSubmodules()
            try await wait("closed progress then real Submodule Update") {followups==1 && closes==1 && !children.isEmpty && host.attachedSheet==nil && create.window?.sheetParent==nil && create.window?.isVisible != true}
            try require(handoffDrained,"Post-create update preceded actual owner close/detachment")
            try require(capturedPath?.path==destination.path,"Post-create update changed path: \(String(describing:capturedPath)) vs \(destination)")
            try require(capturedGrant?.contains(destination)==true,"Post-create update lost destination grant")
            try require(capturedGrant?.permits(source.appendingPathComponent(".git/config"))==true,"Post-create update lost retained source metadata grant")
            try require(children[0].model.repository.root.path==destination.path,"Post-create update child changed repository: \(children[0].model.repository.root) vs \(destination)")
            try require(children[0].model.presentationPreferences === prefs,"Post-create update lost owning preferences")
            try await wait("submodule child idle") {!children[0].model.busy}
            try require(children[0].window?.alphaValue==0 && children[0].window?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua && !model.active && !model.handoffPending,"Post-action retained progress owner or lost hidden/dark child appearance")
            // Bare source roots use exactly the same destination/review contract.
            children.forEach{$0.close()};capturedGrant=nil
            let bare=container.appendingPathComponent("server.git"),bareParent=container.appendingPathComponent("bare destination")
            try FileManager.default.createDirectory(at:bareParent,withIntermediateDirectories:false)
            _ = try await repository.run(["clone","--bare","--",source.path,bare.path])
            let bareRequest=FinderRequest(action:.worktreeCreate,paths:[bare])
            workspace.handle(bareRequest.url!);try await wait("bare source destination picker") {folderReply != nil}
            selected=bareParent;folderReply?(.OK);folderReply=nil
            try await wait("bare source prefilled Create") {creations.count==2 && !creations[1].model.busy && !creations[1].model.chooser.busy}
            try require(creations[1].model.directory==bareParent.appendingPathComponent("server").path && !FileManager.default.fileExists(atPath:bareParent.appendingPathComponent("server").path),"Bare Finder source default/mutation-before-OK differs")
            let bareModel=creations[1].model,blocked=bareParent.appendingPathComponent("blocked")
            try FileManager.default.createDirectory(at:blocked,withIntermediateDirectories:false);try Data("keep\n".utf8).write(to:blocked.appendingPathComponent("keep"))
            bareModel.directory=blocked.path;bareModel.detach=true;bareModel.changedDetach();bareModel.create()
            try await wait("failed Create completion") {!bareModel.busy && bareModel.progress}
            try require(!bareModel.success && bareModel.percentage==100 && bareModel.completionRange != nil && !bareModel.canUpdateSubmodules && (try Data(contentsOf:blocked.appendingPathComponent("keep")))==Data("keep\n".utf8),"Failed Create lost completion/error recovery or changed existing destination")
            bareModel.updateSubmodules();try require(followups==1,"Failed Create dispatched a post-action")
            creations[1].close()
            // Closing the actual initiating owner invalidates its captured
            // chooser. A late OK cannot adopt a different/open workspace owner.
            let closedOwner=NSWindow(contentRect:.zero,styleMask:[.titled,.closable],backing:.buffered,defer:false)
            closedOwner.isReleasedWhenClosed=false;closedOwner.alphaValue=0;closedOwner.orderFront(nil);ownedWindows.append(closedOwner);workspace.workspaceWindow=closedOwner
            let beforeClosedOwner=creations.count
            workspace.handle(url);try await wait("close-owner destination picker") {folderReply != nil && panels.last?.sheetParent === closedOwner}
            let closedOwnerReply=folderReply;folderReply=nil;closedOwner.close()
            try await wait("closed-owner picker actual drain") {!workspace.hasPendingRepositoryWork && !workspace.busy && panels.last?.sheetParent==nil}
            selected=parent;closedOwnerReply?(.OK)
            try require(creations.count==beforeClosedOwner,"Late destination callback adopted another owner after close")
            workspace.workspaceWindow=host
            // A noncooperative permission response retains the real operation
            // after forced closure; its late grant cannot authorize Git writes.
            let heldPath=container.appendingPathComponent("cancelled-create"),sourceGrant=RepositoryAccessLease(url:source,provider:WorktreeFinderScopes())
            let pending=WorktreeCreateWindowController(repository:repository,access:sourceGrant,preferences:prefs,initialDirectory:heldPath)
            creations.append(pending);pending.window!.alphaValue=0;pending.window!.orderFront(nil);pending.model.requiresSecurityScope=true
            try await wait("held authorization owner ready") {!pending.model.busy && !pending.model.chooser.busy}
            var heldToken:OperationCancellation?
            pending.model.authorizeDestination={_,token in heldToken=token;return await withCheckedContinuation{permissionReply=$0}}
            pending.model.create();try await wait("held destination authorization") {permissionReply != nil && pending.model.authorizingDestination}
            try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored owned destination permission")
            pending.close()
            try require(heldToken?.isCancelled==true && WorktreeCreateWindowModel.activeOperations>0 && sourceGrant.hasSecurityScope,"Forced close lost owned authorization cancellation/grant")
            permissionReply?.resume(returning:RepositoryAccessLease(url:container,provider:WorktreeFinderScopes()));permissionReply=nil
            try await wait("late permission actual drain") {!pending.model.busy && WorktreeCreateWindowModel.activeOperations==0}
            try require(!pending.model.progress && pending.model.destinationAccess==nil && !FileManager.default.fileExists(atPath:heldPath.path),"Late retired grant started worktree mutation")
            await cleanup()
            let finalHead=try await repository.run(["rev-parse","HEAD"])
            try require(finalHead.stdout==head.stdout && (try Data(contentsOf:source.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:source.appendingPathComponent(".git/config")))==config && (try Data(contentsOf:file))==bytes,"Finder Worktree flow modified source HEAD/index/config/bytes")
            try require(WorktreeCreateWindowModel.activeOperations==0 && LocalGitCommandProgress.activeOperations==0 && !workspace.hasPendingRepositoryWork && creations.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Owned Worktree/Finder windows/operations survived cleanup")
            print("PASS: Finder Worktree source/destination/review and drained post-create update")
        }catch{await cleanup();throw error}
    }
}
