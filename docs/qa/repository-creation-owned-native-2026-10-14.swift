import AppKit
import ScreenCaptureKit
import TurtleGitCore

private final class MetadataScopeProvider:RepositoryBookmarkProvider {
    var active:[String:Int]=[:],starts=0,stops=0,creates=0
    var stale=false,invalid=Set<Data>(),failCreation=false
    func create(for url:URL) throws->Data { guard !failCreation else { throw RepositoryAccessFailure.securityScopeUnavailable };creates += 1;return Data(url.path.utf8) }
    func resolve(_ data:Data) throws->ResolvedBookmark { guard !invalid.contains(data) else { throw RepositoryAccessFailure.securityScopeUnavailable };return ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:stale) }
    func startAccessing(_ url:URL)->Bool { starts += 1;active[url.path,default:0] += 1;return true }
    func stopAccessing(_ url:URL) { stops += 1;active[url.path,default:0] -= 1;if active[url.path]==0 { active.removeValue(forKey:url.path) } }
}

@main struct RepositoryCreationOwnedVerification {
    enum Failure: Error { case assertion(String), timeout(UInt) }
    static func require(_ value: @autoclosure () -> Bool, _ text: String) throws { if !value() { throw Failure.assertion(text) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure.timeout(line) }
    @MainActor static func main() async { do { try await verify(); print("PASS: owned Clone source/destination chooser locks/cancel/late reply, captured Clone metadata cancellation and Init result/retirement/Quit") } catch { fputs("Creation ownership failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),lease=RepositoryAccessLease(url:root)
        let suite="TurtleGit.CreationOwned."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer {prefs.removePersistentDomain(forName:suite)}
        let owner=CloneWindowController(directory:root,access:lease,preferences:prefs,executable:git);defer {owner.close()}
        var reply:((NSApplication.ModalResponse)->Void)?;owner.model.presentOpenPanel={_,_,completion in reply=completion};owner.model.selectedPanelURL={_ in root}
        owner.model.browseSource();try await wait {reply != nil};try require(owner.model.activeOperation && !owner.windowShouldClose(owner.window!),"Chooser did not block competing operation/close")
        reply?(.OK);try await wait {!owner.model.activeOperation};try require(owner.model.source == root.path,"Source chooser did not adopt its URL")
        reply=nil;owner.model.browseDirectory();try await wait {reply != nil};reply?(.cancel);try await wait {!owner.model.activeOperation}
        reply=nil;owner.model.browseSource();try await wait {reply != nil};let old=owner.model.source;owner.close();reply?(.OK);try await wait {CloneWindowModel.activeOperations == 0};try require(owner.model.source == old && owner.model.openPanel == nil,"Retired chooser published a reply")
        let source=root.appendingPathComponent("source");try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let repo=GitRepository(root:source,executable:git,askpass:nil);_ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Creation QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false")] {_ = try await repo.run(["config",k,v])}
        try Data("base\n".utf8).write(to:source.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let helper=root.appendingPathComponent("metadata-git"),ready=root.appendingPathComponent("metadata-ready")
        try Data(#"""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = --show-toplevel ]; then : > "$TG_CREATION_READY"; /bin/sleep 30; fi
        done
        exec "$TG_CREATION_GIT" "$@"
        """#.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_CREATION_GIT",git.path,1);setenv("TG_CREATION_READY",ready.path,1);defer {unsetenv("TG_CREATION_GIT");unsetenv("TG_CREATION_READY")}
        let clone=CloneWindowModel(directory:root,access:lease,preferences:prefs,executable:helper);defer {clone.invalidate()};clone.source=source.path;clone.directory=root.appendingPathComponent("cloned").path
        var adoptions=0;clone.onCloned={_,_,_,_,_ in adoptions += 1};clone.clone();try await wait {FileManager.default.fileExists(atPath:ready.path)}
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Clone metadata lost Quit ownership")
        clone.invalidate();try await wait {CloneWindowModel.activeOperations == 0};try require(adoptions == 0 && clone.completed == nil,"Retired Clone metadata adopted a repository")
        try? FileManager.default.removeItem(at:ready)
        let target=root.appendingPathComponent("init-target");try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        let initModel=CreateRepositoryWindowModel(folder:target,access:lease);initModel.executable=helper;initModel.prepare();initModel.onInitialized={_,_,_,_ in adoptions += 1};initModel.initialize();try await wait {FileManager.default.fileExists(atPath:ready.path)}
        initModel.retire();try await wait {CreateRepositoryWindowModel.activeOperations == 0};try require(!initModel.completed && initModel.error == nil && adoptions == 0,"Retired Init metadata published")
        let doneFolder=root.appendingPathComponent("normal-init");try FileManager.default.createDirectory(at:doneFolder,withIntermediateDirectories:true)
        let done=CreateRepositoryWindowModel(folder:doneFolder,access:lease);done.executable=git;done.prepare();done.showSuccess={};done.initialize();try await wait {!done.busy}
        try require(done.completed && done.confirmingSuccess && !done.canClose,"Init confirmation did not own result")
        var closes=0;done.close={closes += 1};done.acknowledgeSuccess();done.acknowledgeSuccess();try require(closes == 1 && done.canClose,"Init success callback was duplicated");done.retire()
        try await metadataAccess(root:root,git:git)
    }
    @MainActor static func metadataAccess(root:URL,git:URL) async throws {
        let source=root.appendingPathComponent("metadata-source"),linked=root.appendingPathComponent("metadata-linked"),leaf=root.appendingPathComponent("metadata-shared")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let repo=GitRepository(root:source,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Metadata QA"),("user.email","metadata@example.invalid"),("commit.gpgSign","false"),("core.hooksPath","/dev/null")] { _=try await repo.run(["config",key,value]) }
        try Data("metadata baseline\n".utf8).write(to:source.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_=try await repo.commit(message:"baseline")
        _=try await repo.run(["worktree","add","-b","linked",linked.path]);_=try await repo.run(["clone","--shared","--",source.path,leaf.path])
        _=try await repo.run(["-c","protocol.file.allow=always","submodule","add","--",leaf.path,"module"]);_=try await repo.commit(message:"submodule")
        let scopes=MetadataScopeProvider(),store=try RepositoryAccessStore(storageURL:root.appendingPathComponent("metadata-access.json"),provider:scopes)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:store)
        workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=scopes
        var asks:[RepositoryMetadataAccessRequirement]=[]
        workspace.chooseRepositoryMetadataFolder={ requirement,_ in asks.append(requirement);return source.appendingPathComponent(".git") }
        workspace.open(source);try await wait{!workspace.busy && workspace.root != nil}
        try require(workspace.error==nil && asks.isEmpty,"Ordinary repository asked for extra access")
        workspace.open(linked);try await wait{!workspace.busy}
        try require(workspace.error==nil && workspace.root?.resolvingSymlinksInPath().path==linked.resolvingSymlinksInPath().path && asks.count==1 && asks[0].kind == .gitDirectory,"Linked worktree metadata open failed: \(workspace.error ?? "none")")
        let saved=store.repositories.first{$0.lastKnownPath==linked.resolvingSymlinksInPath().path}!
        try require(saved.additionalPermissions?.count==1,"New metadata access was not saved with the worktree")
        // A child Log retains compound scope after the workspace session closes.
        workspace.activate(.log)
        var child:LogWindowController?
        try await wait { child=NSApp.windows.compactMap{$0.windowController as? LogWindowController}.first{$0.model.repository.root.resolvingSymlinksInPath().path==linked.resolvingSymlinksInPath().path};return child != nil && child?.model.busy == false }
        workspace.closeRepository();try require(!scopes.active.isEmpty,"Closing workspace dropped a live child grant")
        weak var retiredChild=child
        weak var retiredModel=child?.model
        weak var retiredWindow=child?.window
        child?.close();child=nil
        do { try await wait{scopes.active.isEmpty} } catch { throw Failure.assertion("Closed child retained scopes: \(scopes.active); controller=\(retiredChild != nil), model=\(retiredModel != nil), window=\(retiredWindow != nil), invalidated=\(retiredModel?.isInvalidated ?? false)") }
        let module=source.appendingPathComponent("module"),beforeModule=asks.count
        workspace.open(module);try await wait{!workspace.busy}
        try require(workspace.error==nil && workspace.root?.resolvingSymlinksInPath().path==module.resolvingSymlinksInPath().path && asks.count==beforeModule+1,"Submodule metadata folder did not open")
        workspace.closeRepository();try await wait{scopes.active.isEmpty}
        let bad=root.appendingPathComponent("expired-unused");try store.addPermission(saved.id,url:bad);scopes.invalid=[Data(bad.path.utf8)];scopes.stale=true
        workspace.chooseRepositoryMetadataFolder={ _,_ in throw Failure.assertion("Saved valid grants were not reused") }
        let before=scopes.creates;workspace.openRecent(saved);try await wait{!workspace.busy}
        try require(workspace.root != nil && workspace.error==nil && scopes.creates>before,"Reopen failed to renew/reuse metadata access")
        workspace.closeRepository();try await wait{scopes.active.isEmpty};scopes.stale=false
        workspace.chooseRepositoryMetadataFolder={ requirement,_ in asks.append(requirement);return source.appendingPathComponent(".git/objects") }
        workspace.open(leaf);try await wait{!workspace.busy}
        try require(workspace.error==nil && asks.last?.kind == .objectDirectory && workspace.root != nil,"Shared object store did not open")
        workspace.closeRepository();try await wait{scopes.active.isEmpty}
        // Wrong answers and denied access preserve the current repository and index.
        workspace.open(source);try await wait{!workspace.busy}
        let oldRoot=workspace.root,index=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        let emptyStore=try RepositoryAccessStore(storageURL:root.appendingPathComponent("metadata-cancel.json"),provider:scopes)
        let denied=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:emptyStore)
        denied.requiresRepositoryScope=true;denied.repositoryBookmarkProvider=scopes;denied.chooseRepositoryMetadataFolder={ _,_ in nil }
        denied.open(linked);try await wait{!denied.busy}
        try require(denied.root==nil && denied.error==nil && emptyStore.repositories.isEmpty,"Denied access partially adopted or saved repository")
        let wrong=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:emptyStore)
        wrong.requiresRepositoryScope=true;wrong.repositoryBookmarkProvider=scopes;wrong.open(source);try await wait{!wrong.busy}
        wrong.chooseRepositoryMetadataFolder={ _,_ in linked }
        wrong.open(linked);try await wait{!wrong.busy}
        try require(wrong.root?.resolvingSymlinksInPath().path==source.resolvingSymlinksInPath().path && wrong.error != nil,"Wrong metadata folder replaced previous workspace")
        wrong.closeRepository();workspace.closeRepository();try await wait{scopes.active.isEmpty}
        // The real picker belongs to its initiating workspace; owner close settles it.
        NSApp.setActivationPolicy(.accessory)
        func owner()->NSWindow { let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.makeKeyAndOrderFront(nil);return window }
        let host=owner(),actual=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:try RepositoryAccessStore(storageURL:root.appendingPathComponent("metadata-owner.json"),provider:scopes))
        defer{host.close();actual.stopMonitoringForTermination()}
        actual.workspaceWindow=host;actual.requiresRepositoryScope=true;actual.repositoryBookmarkProvider=scopes;actual.open(linked)
        try await wait{host.attachedSheet is NSOpenPanel}
        let panel=host.attachedSheet as! NSOpenPanel
        try require(panel.canChooseDirectories && !panel.canChooseFiles && panel.prompt=="Allow Access","Metadata picker configuration differs")
        host.close();try await wait{!actual.busy && host.attachedSheet==nil}
        try require(actual.root==nil && actual.error==nil,"Closed metadata picker published a repository")
        let lateHost=owner(),late=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:try RepositoryAccessStore(storageURL:root.appendingPathComponent("metadata-late.json"),provider:scopes))
        defer{lateHost.close();late.stopMonitoringForTermination()}
        late.workspaceWindow=lateHost;late.requiresRepositoryScope=true;late.repositoryBookmarkProvider=scopes
        var reply:CheckedContinuation<URL?,Error>?
        late.chooseRepositoryMetadataFolder={ _,_ in try await withCheckedThrowingContinuation{reply=$0} }
        late.open(linked);try await wait{reply != nil};lateHost.close();reply?.resume(returning:source.appendingPathComponent(".git"));try await wait{!late.busy && scopes.active.isEmpty}
        try require(late.root==nil && late.error==nil && oldRoot != nil && (try? Data(contentsOf:source.appendingPathComponent(".git/index")))==index,"Late permission reply adopted state or changed index")
        print("Workspace metadata access: ordinary/linked/submodule/shared repositories, saved/stale grant reuse with an unused expired grant, child Log scope lifetime, wrong-folder rollback, denied access, owned picker close and late reply rejection passed. All fake scopes released; no signed sandbox claim.")
        try await managedAccess(root:root,source:source,linked:linked)
    }

    @MainActor static func managedAccess(root:URL,source:URL,linked:URL) async throws {
        let scopes=MetadataScopeProvider(),store=try RepositoryAccessStore(storageURL:root.appendingPathComponent("managed-access.json"),provider:scopes)
        let saved=try store.remember(source),other=try store.remember(linked)
        let metadata=source.appendingPathComponent(".git"),expired=root.appendingPathComponent("expired-folder"),extra=root.appendingPathComponent("extra-folder")
        try FileManager.default.createDirectory(at:expired,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:extra,withIntermediateDirectories:true)
        try store.addPermission(saved.id,url:metadata);try store.addPermission(saved.id,url:expired)
        let bad=store.repositories.first{$0.id==saved.id}!.additionalPermissions!.last!
        scopes.invalid=[Data(expired.path.utf8)];scopes.stale=true
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,savedAccessStore:store)
        workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=scopes
        workspace.showRepositoryAccess(selected:saved.id)
        var controller=NSApp.windows.compactMap{$0.delegate as? RepositoryAccessWindowController}.first!
        defer {controller.close();workspace.stopMonitoringForTermination()}
        let model=controller.model,number=controller.window!.windowNumber
        workspace.showRepositoryAccess(selected:saved.id)
        try require(NSApp.windows.filter{($0.delegate as? RepositoryAccessWindowController) != nil}.count==1 && controller.window?.windowNumber==number,"Access manager was not reused")
        let before=store.repositories,starts=scopes.starts
        workspace.busy=true;model.checkAccess();try require(scopes.starts==starts && !model.available,"Busy workspace allowed access mutation");workspace.busy=false
        model.checkAccess()
        try require(store.repositories.map(\.id)==before.map(\.id) && store.repositories.map(\.lastOpened)==before.map(\.lastOpened),"Checking bookmarks reordered Open Recent")
        try require(model.checks[saved.id]=="Available" && model.checks[bad.id]=="Choose folder again" && model.checks.values.filter{$0=="Available"}.count==2 && scopes.active.isEmpty,"Independent bookmark renewal/status/scope cleanup failed")
        scopes.stale=false
        func tables(_ view:NSView)->[NSTableView] { (view as? NSTableView).map{[$0]} ?? view.subviews.flatMap{tables($0)} }
        try await wait { controller.window?.contentView.map{tables($0).count==2}==true }
        let native=controller.window!.contentView.map{tables($0)}!
        try require(native.contains{$0.tableColumns.map(\.title)==["Repository","Folder","Access"]} && native.contains{$0.tableColumns.map(\.title)==["Folder","Access"]},"Native access tables/columns absent")
        if ProcessInfo.processInfo.environment["TURTLEGIT_ACCESS_CAPTURE"]=="1",CommandLine.arguments[2]=="/usr/bin/git" { try await captureAccess(controller.window!) }
        var panel:NSOpenPanel?,reply:((NSApplication.ModalResponse)->Void)?,chosen=extra,presentations=0
        model.presentFolder={ picker,owner,completion in panel=picker;reply=completion;presentations += 1 }
        model.selectedFolder={_ in chosen}
        model.choose(.addPermission);model.choose(.addPermission)
        try require(model.busy && presentations==1 && !controller.windowShouldClose(controller.window!),"Folder picker failed to lock manager")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored owned folder picker")
        model.selection=other.id;reply?(.OK);reply?(.OK)
        try require(!model.busy && store.repositories.first{$0.id==saved.id}?.additionalPermissions?.count==3 && store.repositories.first{$0.id==other.id}?.additionalPermissions==nil,"Folder reply changed later selection or ran twice")
        model.selection=saved.id
        let bytes=try Data(contentsOf:store.storageURL)
        chosen=root;model.choose(.repository);reply?(.OK)
        try require(model.error != nil && (try? Data(contentsOf:store.storageURL))==bytes,"Non-repository folder overwrote primary grant")
        chosen=linked;model.choose(.repository);reply?(.OK)
        try require(model.error != nil && (try? Data(contentsOf:store.storageURL))==bytes,"Duplicate repository replacement merged saved entries")
        chosen=source;scopes.failCreation=true;model.choose(.repository);reply?(.OK);scopes.failCreation=false
        try require(model.error != nil && (try? Data(contentsOf:store.storageURL))==bytes && scopes.active.isEmpty,"Failed bookmark save replaced record or leaked scope")
        chosen=source;model.choose(.repository);reply?(.cancel)
        try require((try? Data(contentsOf:store.storageURL))==bytes && !model.busy,"Picker Cancel changed saved grants")
        model.choose(.repository);reply?(.OK)
        try require(model.error==nil && store.repositories.first?.id==saved.id && workspace.recentRepositories==store.repositories,"Primary renewal did not update workspace Recents")
        // Replace an unavailable grant independently, retaining its identity.
        chosen=expired;model.choose(.replacePermission(bad.id));reply?(.OK)
        try require(model.error==nil && model.permissions.contains{$0.id==bad.id && $0.path==expired.standardizedFileURL.resolvingSymlinksInPath().path},"Individual reauthorization lost saved grant identity")
        var question:((NSApplication.ModalResponse)->Void)?,cancelDefault=false
        model.presentQuestion={alert,owner,completion in
            cancelDefault=alert.window.defaultButtonCell === (alert.buttons[0].cell as? NSButtonCell)
            question=completion
        }
        model.remove(permission:bad.id);try require(cancelDefault,"Removal default was not Cancel");question?(.alertFirstButtonReturn)
        try require(model.permissions.contains{$0.id==bad.id},"Cancelled removal discarded grant")
        model.remove(permission:bad.id);model.selection=other.id;question?(.alertSecondButtonReturn);question?(.alertSecondButtonReturn)
        try require(store.repositories.first{$0.id==saved.id}?.additionalPermissions?.contains{$0.id==bad.id}==false && store.repositories.first{$0.id==other.id} != nil,"Captured removal affected later selection or ran twice")
        model.selection=saved.id
        var live:RepositoryAccessLease?=try store.acquire(saved.id,requireSecurityScope:true).retainingRelatedScopes(store.acquireAdditionalPermissions(saved.id,requireSecurityScope:true))
        let index=try Data(contentsOf:metadata.appendingPathComponent("index"))
        model.remove();question?(.alertSecondButtonReturn)
        try require(store.repositories.count==1 && workspace.recentRepositories==store.repositories && live?.contains(source)==true && !scopes.active.isEmpty && (try? Data(contentsOf:metadata.appendingPathComponent("index")))==index,"Forget dropped live scopes, deleted files or failed to update Recents")
        live=nil;try require(scopes.active.isEmpty,"Live manager grant did not release")
        model.choose(.addPermission);let pending=reply;controller.close();pending?(.OK)
        try require(model.retired && !model.busy && store.repositories[0].additionalPermissions==nil && scopes.active.isEmpty,"Retired folder picker saved late access")
        workspace.showRepositoryAccess(selected:other.id)
        controller=NSApp.windows.compactMap{$0.delegate as? RepositoryAccessWindowController}.first{$0.model !== model}!
        let fresh=controller.model
        var lateQuestion:((NSApplication.ModalResponse)->Void)?
        fresh.presentQuestion={_,_,completion in lateQuestion=completion}
        fresh.remove();controller.close();lateQuestion?(.alertSecondButtonReturn)
        try require(fresh.retired && store.repositories.count==1,"Retired question forgot repository")
        // Exercise actual native sheet ownership and forced-close settlement.
        workspace.showRepositoryAccess(selected:other.id)
        controller=NSApp.windows.compactMap{$0.delegate as? RepositoryAccessWindowController}.first{$0.model !== model && $0.model !== fresh}!
        controller.model.choose(.addPermission);try await wait{controller.window?.attachedSheet is NSOpenPanel}
        let actual=controller.model;controller.close();try await wait{!actual.busy && actual.retired}
        try require(store.repositories.count==1 && scopes.active.isEmpty,"Actual picker owner-close leaked/saved permission")
        withExtendedLifetime(panel) {}
        print("Repository access manager: native tables, window reuse, independent stale/failed grant checks, Recents order, busy/Quit gates, captured pickers/questions, invalid/duplicate/save-failed renewal, individual grant identity, Cancel, Forget/live scopes and actual picker/late-close settlement passed.")
    }
    @MainActor static func captureAccess(_ window:NSWindow) async throws {
        guard #available(macOS 14.4,*) else { return }
        NSApp.activate(ignoringOtherApps:true)
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/repository-access-captures-2026-10-15")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();window.makeKeyAndOrderFront(nil)
            try await Task.sleep(nanoseconds:200_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else { throw Failure.assertion("Owned access window unavailable for capture") }
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*window.backingScaleFactor);config.height=Int(window.frame.height*window.backingScaleFactor);config.showsCursor=false;config.ignoreShadowsSingleWindow=true
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure.assertion("Access window PNG failed") }
            try bytes.write(to:output.appendingPathComponent("repository-access-"+name+".png"))
        }
    }

}
