import AppKit
import TurtleGitCore

private final class MetadataScopeProvider:RepositoryBookmarkProvider {
    var active:[String:Int]=[:],starts=0,stops=0,creates=0
    var stale=false,invalid=Set<Data>()
    func create(for url:URL) throws->Data { creates += 1;return Data(url.path.utf8) }
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
    }

}
