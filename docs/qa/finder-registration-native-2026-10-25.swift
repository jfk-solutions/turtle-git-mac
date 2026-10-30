// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

final class RegistrationBookmarks:RepositoryBookmarkProvider {
    var created=[String]()
    var relocated=[String:URL]()
    func create(for url:URL)throws->Data {created.append(url.path);return Data(("PRIVATE:"+url.path).utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {let text=String(decoding:data,as:UTF8.self);guard text.hasPrefix("PRIVATE:") else {throw RepositoryAccessFailure.unknownRepository};let path=String(text.dropFirst(8));return .init(url:relocated[path] ?? URL(fileURLWithPath:path),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
/// A real blocking bookmark provider, not a delayed MainActor callback. Its
/// gate proves that native event processing remains available while the worker
/// is resolving authority; release is guaranteed by the fixture's defer.
private final class HeldRegistrationBookmarks:RepositoryBookmarkProvider {
    private let lock=NSLock(),gate=DispatchSemaphore(value:0)
    private var held:String?,entered=false,paths=[String](),mainResolution=false
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ bytes:Data)throws->ResolvedBookmark {
        let path=String(decoding:bytes,as:UTF8.self)
        lock.lock();paths.append(path);mainResolution = mainResolution || Thread.isMainThread
        let pause=held==path;if pause {entered=true};lock.unlock()
        if pause,gate.wait(timeout:.now()+15) != .success {throw RepositoryAccessFailure.securityScopeUnavailable}
        return .init(url:URL(fileURLWithPath:path),stale:false)
    }
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
    func arm(_ url:URL){lock.lock();held=url.path;entered=false;paths=[];mainResolution=false;lock.unlock()}
    func release(){lock.lock();held=nil;lock.unlock();gate.signal()}
    var observation:(entered:Bool,paths:[String],main:Bool){lock.lock();defer{lock.unlock()};return(entered,paths,mainResolution)}
}
private extension NSWindow {
    @objc func registrationOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));registrationOrder(mode,relativeTo:number)}
}
@MainActor private final class RegistrationReceiverLifetime:NSObject,NSApplicationDelegate {
    // After a real miniaturize/deminiaturize round trip, this unbundled receiver
    // received AEQuit while asynchronous cleanup drained (AppKit stack recorded).
    // Only the private receiver stays alive; production delegate Quit decisions
    // are still exercised directly by the dialog fixture and remain unchanged.
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        fputs("Finder receiver: declined external Quit while owned verification drains\n",stderr)
        return .terminateCancel
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
}
@MainActor
@main enum FinderRegistrationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"Finder registration \(line): "+message)}}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Finder registration timeout \(line)")}
    @MainActor final class Context {
        // Match RepositoryAccessStore's canonical namespace once, before deriving
        // linked/Clone paths. The runner's POSIX /private/var spelling is an alias.
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL.resolvingSymlinksInPath(),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let provider=RegistrationBookmarks(),suite="TurtleGit.Registration."+UUID().uuidString,prefs:UserDefaults
        let recent:RepositoryAccessStore,watched:RepositoryAccessStore,manager:FinderWatchManager,workspace:RepositoryModel
        let cache:FinderSnapshotStore
        let parent:NSWindow
        var clones=[CloneWindowController](),panels=0
        var additionalManagers=[FinderWatchManager](),additionalModels=[RepositoryModel](),additionalWindows=[NSWindowController]()
        var commandLog:URL {root.appendingPathComponent("git-commands.tsv")}
        var other:GitRepository!,source:GitRepository!,third:GitRepository!
        var selected:URL?,permissionReply:((NSApplication.ModalResponse)->Void)?
        var permissionDirectory:URL?,permissionTitle="",permissionMessage=""
        var hold:URL {root.appendingPathComponent("hold")};var release:URL {root.appendingPathComponent("release")};var started:URL {root.appendingPathComponent("started")}
        init()throws {
            prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"EnableGravatar")
            recent=try RepositoryAccessStore(storageURL:root.appendingPathComponent("recents.json"),provider:provider)
            watched=try RepositoryAccessStore(storageURL:root.appendingPathComponent("watches.json"),provider:provider)
            let wrapper=root.appendingPathComponent("held-helper")
            cache=FinderSnapshotStore(url:root.appendingPathComponent("private-status.json"))
            manager=FinderWatchManager(permissions:watched,cache:cache,requireScope:true,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:wrapper,libgit2Configuration:.init(enabled:false))},notify:{})
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))},finderWatches:manager,savedAccessStore:recent)
            workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=provider;workspace.fileComparisonPreferences=prefs
            parent=NSWindow(contentRect:.init(x:-24000,y:-24000,width:800,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;parent.alphaValue=0;workspace.workspaceWindow=parent;parent.orderFront(nil)
            workspace.selectedFinderServiceFolderURL={ [weak self] _ in self?.selected }
            workspace.presentFinderServiceFolderPanel={ [weak self] panel,owner,reply in
                self?.panels += 1;self?.permissionReply=reply
                self?.permissionDirectory=panel.directoryURL;self?.permissionTitle=panel.title;self?.permissionMessage=panel.message
                owner?.beginSheet(panel,completionHandler:reply)
            }
        }
        func repo(_ name:String)async throws->GitRepository {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let value=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false));_=try await value.run(["init","--template=","-b","main"])
            for (key,text) in [("user.name","Registration QA"),("user.email","registration@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await value.run(["config",key,text])}
            try Data("baseline\n".utf8).write(to:folder.appendingPathComponent("file"));try await value.stage(["file"]);_=try await value.commit(message:"registration fixture");return value
        }
        func prepare()async throws {
            func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let shell="""
            #!/bin/sh
            inspect() {
              target="$PWD"
              while [ "$#" -gt 0 ]; do
                case "$1" in -C) target="$2"; shift; shift;; -c|--git-dir|--work-tree) shift; shift;; --*) shift;; *) break;; esac
              done
              printf '%s\t%s\n' "$target" "${1-}" >> \(quote(commandLog.path))
              if [ "${1-}" = rev-parse ] && [ -f \(quote(root.appendingPathComponent("hold-root").path)) ] && [ "$target" = "$(cat \(quote(root.appendingPathComponent("hold-root").path)))" ]; then
                exec 9>\(quote(root.appendingPathComponent("owned-resource").path))
                : >\(quote(started.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
              fi
              if [ "${1-}" = status ] && [ -f \(quote(root.appendingPathComponent("fail-status").path)) ]; then
                echo 'controlled first publication failure' >&2
                exit 73
              fi
              if [ "${1-}" = status ] && [ -f \(quote(root.appendingPathComponent("hold-status").path)) ]; then
                exec 9>\(quote(root.appendingPathComponent("owned-resource").path))
                : >\(quote(started.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
              fi
              if [ "${1-}" = rev-parse ] && [ -f \(quote(hold.path)) ]; then
                exec 9>\(quote(root.appendingPathComponent("owned-resource").path))
                : >\(quote(started.path))
                while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
              fi
            }
            inspect "$@"
            exec \(quote(git.path)) "$@"
            """
            let wrapper=root.appendingPathComponent("held-helper");try Data(shell.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            other=try await repo("other");source=try await repo("source café");third=try await repo("third")
            await manager.add(other.root);try await FinderRegistrationVerification.wait {manager.pendingOperations==0 && FinderSnapshot.readLive(from:cache.url)?.roots.contains(other.root.path)==true}
            try FinderRegistrationVerification.require(manager.rows.count==1 && manager.backgroundService==nil,"Private baseline watch missing or service enabled")
        }
        func submit(_ folder:URL)async throws {
            selected=folder;permissionReply=nil
            try FinderRegistrationVerification.require(workspace.handleFinderService(FinderRequest(action:.registerRepository,paths:[folder])),"Accepted folder registration refused")
            if permissionReply==nil && workspace.hasPendingFinderServiceWork {try await FinderRegistrationVerification.wait {permissionReply != nil || !workspace.hasPendingFinderServiceWork}}
        }
        func answer(_ response:NSApplication.ModalResponse) {permissionReply?(response);permissionReply=nil}
        func block()throws {try? FileManager.default.removeItem(at:release);try? FileManager.default.removeItem(at:started);try Data().write(to:hold)}
        func unblock() {try? Data().write(to:release);try? FileManager.default.removeItem(at:hold)}
        func cleanup()async throws {
            fputs("Finder registration cleanup: begin\n",stderr)
            unblock();try? FileManager.default.removeItem(at:root.appendingPathComponent("hold-root"));answer(.cancel);workspace.stopMonitoringForTermination()
            for model in additionalModels {model.stopMonitoringForTermination();await model.shutdownFinderPublication()}
            for window in additionalWindows {window.close()}
            for manager in additionalManagers {await manager.shutdown()}
            for clone in clones {clone.progressController?.model.invalidate();clone.progressController?.close();clone.model.invalidate();clone.close()}
            await manager.shutdown();fputs("Finder registration cleanup: manager drained\n",stderr);parent.close()
            try await FinderRegistrationVerification.wait {!workspace.hasPendingFinderServiceWork && !workspace.busy && manager.pendingOperations==0 && CloneWindowModel.activeOperations==0 && CloneProgressWindowModel.activeOperations==0 && CloneWindowController.activeChildReleases==0}
            prefs.removePersistentDomain(forName:suite)
            fputs("Finder registration cleanup: complete\n",stderr)
        }
    }
    static func registration(_ c:Context)async throws {
        let original=c.watched.repositories[0]
        try await c.submit(c.source.root);try require(c.permissionReply != nil && c.parent.attachedSheet != nil,"First use did not own actual folder sheet")
        try require(c.permissionDirectory.map{Data($0.path.utf8)}==Data(c.source.root.path.utf8),"Add permission picker opened a parent or unrelated folder")
        try require(c.permissionTitle=="Add to TurtleGit" && c.permissionMessage.contains("status badges in Finder") && !c.permissionMessage.contains("Services"),"Add permission picker lost its action-specific explanation")
        c.answer(.cancel)
        try await wait {!c.workspace.hasPendingFinderServiceWork};try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Cancelled Add saved grants")
        try await c.submit(c.source.root);c.answer(.OK);try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error==nil && c.workspace.root==nil,"Add failed or switched unrelated workspace: \(c.workspace.error ?? "")")
        try require(c.watched.repositories.count==2 && c.recent.repositories.count==1 && c.provider.created.contains(c.source.root.path),"Add did not persist exact child watch+recent bookmarks")
        let id=c.watched.repositories.first {$0.lastKnownPath==c.source.root.path}?.id,panels=c.panels
        try await c.submit(c.source.root);if c.permissionReply != nil {c.answer(.OK)};try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==2 && c.watched.repositories.contains{$0.id==id} && c.panels==panels,"Duplicate Add duplicated watch or demanded unnecessary picker")
        try require(c.watched.repositories.contains{$0.id==original.id && $0.bookmark==original.bookmark} && c.manager.backgroundService==nil,"Add changed unrelated watch or enabled service")
        let reopened=try c.recent.acquire(c.recent.repositories[0].id,requireSecurityScope:true);try require(reopened.contains(c.source.root),"Persisted registration grant cannot reopen root")
        try await c.submit(c.source.root.appendingPathComponent("file"));if c.permissionReply != nil {c.answer(.OK)};try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error != nil && c.watched.repositories.count==2,"File candidate silently registered parent")
        let linked=c.root.appendingPathComponent("linked worktree")
        _=try await c.source.run(["worktree","add","-b","linked-fixture",linked.path])
        var metadataChoices=[URL]()
        c.workspace.chooseRepositoryMetadataFolder={requirement,token in try token.check();metadataChoices.append(requirement.folder);return c.source.root}
        try await c.submit(linked);c.answer(.OK);try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.workspace.error==nil && !metadataChoices.isEmpty,"Linked metadata access was not requested/retained: \(c.workspace.error ?? "")")
        let linkedWatch=c.watched.repositories.first {$0.lastKnownPath==linked.path},linkedRecent=c.recent.repositories.first {$0.lastKnownPath==linked.path}
        try require(linkedWatch?.additionalPermissions?.contains {$0.path==c.source.root.path} == true && linkedRecent?.additionalPermissions?.contains {$0.path==c.source.root.path} == true,"Linked repository metadata grants were not persisted in both independent stores; requested=\(linked.path); source=\(c.source.root.path); choices=\(metadataChoices.map(\.path)); watches=\(c.watched.repositories.map {($0.lastKnownPath,($0.additionalPermissions ?? []).map(\.path))}); recents=\(c.recent.repositories.map {($0.lastKnownPath,($0.additionalPermissions ?? []).map(\.path))})")
        try require(c.watched.repositories.count==3 && c.manager.backgroundService==nil,"Linked registration affected unrelated watches/service")
        try await deferredStartup(c)
    }
    static func deferredStartup(_ c:Context)async throws {
        var a=try await c.repo("deferred/selected")
        let b=try await c.repo("deferred/unrelated"),target=try await c.repo("deferred/registered")
        let archive=c.root.appendingPathComponent("deferred/watches.json"),recents=c.root.appendingPathComponent("deferred/recents.json")
        let watched=try RepositoryAccessStore(storageURL:archive,provider:c.provider),recent=try RepositoryAccessStore(storageURL:recents,provider:c.provider)
        _=try watched.remember(a.root);_=try watched.remember(b.root);_=try recent.remember(a.root)
        let saved=watched.repositories,cache=FinderSnapshotStore(url:c.root.appendingPathComponent("deferred/status.json")),wrapper=c.root.appendingPathComponent("held-helper")
        let factory:(URL)throws->GitRepository={GitRepository(root:$0,executable:wrapper,libgit2Configuration:.init(enabled:false))}
        let manager=FinderWatchManager(permissions:watched,cache:cache,requireScope:true,scopeProvider:c.provider,repositoryFactory:factory,notify:{})
        c.additionalManagers.append(manager)
        let action=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:factory,finderWatches:manager,savedAccessStore:recent)
        c.additionalModels.append(action);action.requiresRepositoryScope=true;action.repositoryBookmarkProvider=c.provider;action.fileComparisonPreferences=c.prefs
        try Data().write(to:c.commandLog)
        action.configureActionRouting()
        func commands()->[(String,String)] {
            ((try? String(contentsOf:c.commandLog,encoding:.utf8)) ?? "").split(separator:"\n").compactMap {line in
                let fields=line.split(separator:"\t",maxSplits:1,omittingEmptySubsequences:false);return fields.count==2 ? (String(fields[0]),String(fields[1])):nil
            }
        }
        func clearCommands()throws {try Data().write(to:c.commandLog)}
        try require(action.finderWatches === manager && manager.startup == .deferred && manager.pendingOperations==0 && commands().isEmpty,"Action configuration restored/crawled saved repositories")
        var commit:CommitWindowController?
        action.commitWindowFactory={repository,access in
            let controller=CommitWindowController(repository:repository,access:access,defaults:c.prefs)
            controller.window?.alphaValue=0;controller.window?.isReleasedWhenClosed=false
            commit=controller;c.additionalWindows.append(controller);return controller
        }
        try require(action.handleFinderService(.init(action:.commit,paths:[a.root])),"Private deferred Commit launch was refused")
        try await wait{commit != nil && !action.hasPendingFinderServiceWork && !action.busy && CommitWindowModel.activeReloads==0 && commit?.model.busy==false}
        try require(action.error==nil && manager.startup == .deferred && manager.pendingOperations==0 && !commands().contains{$0.0==b.root.path},"Opening selected Commit scanned an unrelated saved root")
        commit?.close();try await wait{CommitWindowModel.activeReloads==0}
        try clearCommands()
        let unknown=c.root.appendingPathComponent("deferred/not-authorized")
        manager.refresh(repository:unknown)
        try require(commands().isEmpty && watched.repositories.count==saved.count,"Targeted refresh invented a grant or read unknown root")
        try Data("target changed\n".utf8).write(to:a.root.appendingPathComponent("file"))
        manager.refresh(repository:a.root)
        try await wait{manager.pendingOperations==0 && FinderSnapshot.readLive(from:cache.url)?.states[a.root.path+"/file"] == .modified}
        try require(commands().contains{$0.0==a.root.path && $0.1=="status"} && !commands().contains{$0.0==b.root.path},"Targeted mutation refresh did not isolate selected root")
        let originalA=a.root,moved=c.root.appendingPathComponent("deferred/moved selected")
        guard let movedRecord=watched.repositories.first(where:{$0.lastKnownPath==originalA.path}),let unrelated=watched.repositories.first(where:{$0.lastKnownPath==b.root.path}) else {throw Failure(description:"Missing private saved roots")}
        let movedID=movedRecord.id
        try FileManager.default.moveItem(at:originalA,to:moved)
        c.provider.relocated[originalA.path]=moved
        a=GitRepository(root:moved,executable:c.git,libgit2Configuration:.init(enabled:false))
        try clearCommands();manager.refresh(repository:moved)
        try await wait{manager.pendingOperations==0 && FinderSnapshot.readLive(from:cache.url)?.states[moved.path+"/file"] == .modified}
        try require(watched.repositories.contains{$0.id==movedID && $0.lastKnownPath==moved.path} && watched.repositories.contains{$0.id==unrelated.id && $0.bookmark==unrelated.bookmark},"Moved bookmark refresh lost watch identity or changed unrelated authority")
        try require(FinderSnapshot.readLive(from:cache.url)?.roots.contains(originalA.path) != true && !commands().contains{$0.0==b.root.path},"Moved targeted refresh retained stale publication or scanned unrelated root")
        let service=FinderBackgroundService();service.registrationStatus={.enabled};service.updateStatus()
        var transferred=[FinderServiceAuthorization]()
        service.exchange={request in
            switch request {
            case .grants(let bytes):transferred.append(try JSONDecoder().decode(FinderServiceAuthorization.self,from:bytes));return nil
            case .status:return try JSONEncoder().encode(FinderCacheServiceReport(running:true,roots:manager.rows.map{.init(id:$0.id)}))
            case .refresh:return nil
            }
        }
        manager.backgroundService=service
        service.requestSync(manager)
        try require(transferred.isEmpty && !service.busy && !manager.canSynchronizeBackground,"Incomplete local watches sent a partial helper grant set")
        try clearCommands()
        _=try await manager.register(root:target.root,access:RepositoryAccessLease(url:target.root,provider:c.provider),cancellation:OperationCancellation(),awaitInitialPublication:true)
        try await wait{manager.pendingOperations==0 && !service.busy && !transferred.isEmpty}
        let expected=Set(watched.repositories.map(\.id))
        try require(transferred.allSatisfy{Set($0.grants.map(\.id))==expected},"Add replaced helper authority with a partial grant set")
        let transferredPaths=try transferred.last!.grants.map {try SystemRepositoryTransferBookmarks().resolveTransfer($0.bookmark).url.standardizedFileURL.resolvingSymlinksInPath().path}
        try require(Set(transferredPaths)==Set([a.root.path,b.root.path,target.root.path]),"Complete helper transfer lost exact authorized root bookmarks")
        try require(commands().contains{$0.0==b.root.path && $0.1=="rev-parse"} && !commands().contains{$0.0==b.root.path && $0.1=="status"},"Background authorization crawled unrelated status or skipped root discovery")
        try require(FinderSnapshot.readLive(from:cache.url)?.roots.contains(target.root.path)==true && watched.repositories.contains{$0.id==unrelated.id && $0.bookmark==unrelated.bookmark},"Add failed target publication or changed unrelated stored authority")
        manager.restore()
        try await wait{manager.pendingOperations==0 && FinderSnapshot.readLive(from:cache.url)?.roots.contains(b.root.path)==true}
        try require(action.finderWatches === manager && manager.startup == .allSavedRepositories && commands().contains{$0.0==b.root.path && $0.1=="status"},"Workspace promotion did not restore all roots on the same publisher")
        // The explicit workspace/Settings restore is exercised directly here:
        // creating the production workspace would publish real App Group prefs.
        await manager.shutdown();action.stopMonitoringForTermination()
        let disconnected=try await c.repo("deferred/disconnected"),offline=c.root.appendingPathComponent("deferred/offline-volume")
        let unavailableStore=try RepositoryAccessStore(storageURL:c.root.appendingPathComponent("deferred/unavailable-watches.json"),provider:c.provider)
        let afterDisconnected=try await c.repo("deferred/after-disconnected")
        let laterSaved=try unavailableStore.remember(afterDisconnected.root)
        let oldUnavailable=try unavailableStore.remember(disconnected.root)
        try FileManager.default.moveItem(at:disconnected.root,to:offline)
        let unavailableCache=FinderSnapshotStore(url:c.root.appendingPathComponent("deferred/unavailable-status.json"))
        let unavailable=FinderWatchManager(permissions:unavailableStore,cache:unavailableCache,requireScope:true,scopeProvider:c.provider,repositoryFactory:factory,notify:{})
        c.additionalManagers.append(unavailable)
        let unavailableService=FinderBackgroundService();unavailableService.registrationStatus={.enabled};unavailableService.updateStatus();unavailable.backgroundService=unavailableService
        var helperIDs=Set([oldUnavailable.id,laterSaved.id]),unavailableTransfers=0
        unavailableService.exchange={request in
            switch request {
            case .grants(let bytes):
                let authorization=try JSONDecoder().decode(FinderServiceAuthorization.self,from:bytes)
                helperIDs=Set(authorization.grants.map(\.id));unavailableTransfers += 1;return nil
            case .status:return try JSONEncoder().encode(FinderCacheServiceReport(running:true,roots:unavailable.rows.map{.init(id:$0.id)}))
            case .refresh:return nil
            }
        }
        try clearCommands()
        let registered=try await unavailable.register(root:target.root,access:RepositoryAccessLease(url:target.root,provider:c.provider),cancellation:OperationCancellation(),awaitInitialPublication:true)
        try require(unavailableStore.repositories.contains{$0.id==registered && $0.lastKnownPath==target.root.path} && FinderSnapshot.readLive(from:unavailableCache.url)?.states[target.root.path+"/file"] == .normal,"Disconnected unrelated watch prevented valid local registration/publication")
        try require(unavailableTransfers==0 && helperIDs==Set([oldUnavailable.id,laterSaved.id]) && unavailableService.failure != nil && !unavailableService.busy && !unavailable.canSynchronizeBackground,"Unavailable unrelated authority replaced helper grants or hid deferred failure")
        try require(commands().contains{$0.0==afterDisconnected.root.path && $0.1=="rev-parse"} && !commands().contains{$0.0==afterDisconnected.root.path && $0.1=="status"},"Unavailable saved root prevented later valid authority preparation or triggered its status scan")
        try FileManager.default.moveItem(at:offline,to:disconnected.root)
        unavailable.refresh(repository:disconnected.root)
        try await wait{unavailable.pendingOperations==0 && !unavailableService.busy && unavailableTransfers>0 && unavailableService.failure==nil}
        try require(helperIDs==Set(unavailableStore.repositories.map(\.id)) && helperIDs.contains(registered),"Restored unrelated authority did not retry a complete helper grant replacement")
        await unavailable.shutdown()
        let queuedStore=try RepositoryAccessStore(storageURL:c.root.appendingPathComponent("deferred/queued-watches.json"),provider:c.provider)
        _=try queuedStore.remember(b.root)
        let queuedCache=FinderSnapshotStore(url:c.root.appendingPathComponent("deferred/queued-status.json"))
        let queued=FinderWatchManager(permissions:queuedStore,cache:queuedCache,requireScope:true,scopeProvider:c.provider,repositoryFactory:factory,notify:{})
        c.additionalManagers.append(queued)
        let queuedService=FinderBackgroundService();queuedService.registrationStatus={.enabled};queuedService.updateStatus();queued.backgroundService=queuedService
        var queuedTransfers=[FinderServiceAuthorization]()
        queuedService.exchange={request in
            switch request {
            case .grants(let bytes):queuedTransfers.append(try JSONDecoder().decode(FinderServiceAuthorization.self,from:bytes));return nil
            case .status:return try JSONEncoder().encode(FinderCacheServiceReport(running:true,roots:queued.rows.map{.init(id:$0.id)}))
            case .refresh:return nil
            }
        }
        try Data("queued mutation\n".utf8).write(to:b.root.appendingPathComponent("file"))
        try? FileManager.default.removeItem(at:c.release);try? FileManager.default.removeItem(at:c.started)
        let queuedHold=c.root.appendingPathComponent("hold-root");try Data(b.root.path.utf8).write(to:queuedHold)
        defer{c.unblock();try? FileManager.default.removeItem(at:queuedHold)}
        let queuedRegistration=Task {try await queued.register(root:target.root,access:RepositoryAccessLease(url:target.root,provider:c.provider),cancellation:OperationCancellation(),awaitInitialPublication:true)}
        try await wait{FileManager.default.fileExists(atPath:c.started.path) && queued.busy}
        queued.refresh(repository:b.root);queued.refresh(repository:b.root)
        try require(queuedTransfers.isEmpty && FinderSnapshot.readLive(from:queuedCache.url)?.roots.contains(b.root.path) != true,"Busy target refresh replaced authority or published during registration")
        c.unblock();try? FileManager.default.removeItem(at:queuedHold)
        _=try await queuedRegistration.value
        try await wait{queued.pendingOperations==0 && !queuedService.busy && !queuedTransfers.isEmpty && FinderSnapshot.readLive(from:queuedCache.url)?.states[b.root.path+"/file"] == .modified}
        let queuedIDs=Set(queuedStore.repositories.map(\.id))
        try require(queuedTransfers.allSatisfy{Set($0.grants.map(\.id))==queuedIDs} && FinderSnapshot.readLive(from:queuedCache.url)?.roots.contains(target.root.path)==true,"Queued target refresh revoked registration or incomplete helper authority")
        await queued.shutdown()
        let cancelledStore=try RepositoryAccessStore(storageURL:c.root.appendingPathComponent("deferred/cancel-watches.json"),provider:c.provider)
        _=try cancelledStore.remember(b.root)
        let cancelledCache=FinderSnapshotStore(url:c.root.appendingPathComponent("deferred/cancel-status.json"))
        let cancelled=FinderWatchManager(permissions:cancelledStore,cache:cancelledCache,requireScope:true,scopeProvider:c.provider,repositoryFactory:factory,notify:{})
        c.additionalManagers.append(cancelled)
        let cancelledService=FinderBackgroundService();cancelledService.registrationStatus={.enabled};cancelledService.updateStatus();cancelled.backgroundService=cancelledService
        var cancelledGrants=0
        cancelledService.exchange={request in if case .grants=request {cancelledGrants += 1};return nil}
        try? FileManager.default.removeItem(at:c.release);try? FileManager.default.removeItem(at:c.started)
        let holdRoot=c.root.appendingPathComponent("hold-root");try Data(b.root.path.utf8).write(to:holdRoot)
        defer{c.unblock();try? FileManager.default.removeItem(at:holdRoot)}
        let token=OperationCancellation()
        let registration=Task {try await cancelled.register(root:target.root,access:RepositoryAccessLease(url:target.root,provider:c.provider),cancellation:token,awaitInitialPublication:true)}
        try await wait{FileManager.default.fileExists(atPath:c.started.path) && cancelled.pendingOperations>0}
        token.cancel()
        do {_=try await registration.value;throw Failure(description:"Cancelled complete-authority preparation unexpectedly completed")}
        catch is OperationCancellationFailure {} catch is GitCommandCancellationFailure {} catch is CancellationError {}
        c.unblock();try? FileManager.default.removeItem(at:holdRoot)
        await cancelled.shutdown()
        try require(cancelledGrants==0 && cancelled.pendingOperations==0 && !cancelledService.busy,"Cancelled authority preparation transferred partial grants or retained owned work")
        try require(FinderSnapshot.readLive(from:cancelledCache.url)?.roots.contains(target.root.path) != true,"Cancelled authority preparation published target after retirement")
    }
    static func clone(_ c:Context)async throws {
        try c.block();let mutating=Task {await c.manager.add(c.other.root)}
        defer {c.unblock()};try await wait {FileManager.default.fileExists(atPath:c.started.path) && c.manager.busy}
        let grant=RepositoryAccessLease(url:c.root,provider:c.provider),owner=CloneWindowController(directory:c.root,access:grant,preferences:c.prefs,executable:c.git,clipboardText:"");c.clones.append(owner)
        owner.window?.isReleasedWhenClosed=false;owner.showWindow(nil);c.workspace.configureCloneInteractions(owner)
        let destination=c.root.appendingPathComponent("cloned child");owner.model.source=c.source.root.path;owner.model.directory=destination.path
        var extraPickers=0;owner.model.presentOpenPanel={_,_,reply in extraPickers += 1;reply(.cancel)}
        owner.model.clone();try await wait {owner.model.completed != nil && c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==1,"Queued Clone registration wrote during other watch mutation")
        c.parent.close() // Only workspace adoption is revoked; accepted Clone still registers.
        c.unblock();await mutating.value;try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(owner.model.error==nil && owner.model.completionWarning==nil,"Successful Clone registration lost result: \(owner.model.error ?? owner.model.completionWarning ?? "")")
        try require(c.watched.repositories.contains{$0.lastKnownPath==destination.path} && c.recent.repositories.contains{$0.lastKnownPath==destination.path},"Completed Clone lost persistent registration after parent close")
        try require(extraPickers==0 && c.panels==0 && c.manager.backgroundService==nil,"Clone requested second permission or enabled background service")
        let head=try await GitRepository(root:destination,executable:c.git).run(["rev-parse","HEAD"]).stdout,source=try await c.source.run(["rev-parse","HEAD"]).stdout
        try require(head==source && c.provider.created.contains(destination.path),"Clone content/child bookmark differs")
        // A completed transport remains available when registration itself fails.
        c.manager.retire()
        let refused=CloneWindowController(directory:c.root,access:grant,preferences:c.prefs,executable:c.git,clipboardText:"");c.clones.append(refused);refused.window?.isReleasedWhenClosed=false;refused.showWindow(nil)
        c.workspace.configureCloneInteractions(refused)
        let second=c.root.appendingPathComponent("clone registration failure");refused.model.source=c.source.root.path;refused.model.directory=second.path
        refused.model.clone();try await wait {refused.model.completed != nil && refused.model.completionWarning != nil && !c.workspace.hasPendingFinderServiceWork}
        try require(refused.model.error==nil && refused.model.output != nil && FileManager.default.fileExists(atPath:second.appendingPathComponent(".git").path),"Registration failure discarded successful Clone")
        try require(refused.model.completionWarning?.contains("Finder registration") == true && !c.watched.repositories.contains {$0.lastKnownPath==second.path},"Registration failure was silent or saved through retired watch owner")
    }
    static func authority(_ c:Context)async throws {
        let provider=HeldRegistrationBookmarks()
        defer{provider.release()}
        let store=try RepositoryAccessStore(storageURL:c.root.appendingPathComponent("held-authority.json"),provider:provider)
        let source=try store.remember(c.source.root)
        _=try store.remember(c.other.root);let third=try store.remember(c.third.root)
        func model()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,
                repositoryFactory:{GitRepository(root:$0,executable:c.git,libgit2Configuration:.init(enabled:false))},
                snapshotWriter:{_ in true},finderWatches:c.manager,savedAccessStore:store)
            value.requiresRepositoryScope=true;value.repositoryBookmarkProvider=provider;value.fileComparisonPreferences=c.prefs;value.workspaceWindow=c.parent
            c.additionalModels.append(value);return value
        }
        let registration=model()
        provider.arm(c.third.root)
        try require(registration.handleFinderService(.init(action:.registerRepository,paths:[c.third.root])),"Held saved Add was refused")
        try await wait{provider.observation.entered}
        try require(registration.finderActionAuthorityPending && registration.hasPendingFinderServiceWork && !registration.busy && !provider.observation.main,"Saved Add blocked native event processing or lost worker ownership")
        try require(!registration.handleFinderService(.init(action:.registerRepository,paths:[c.source.root])),"Held Add admitted overlapping action")
        provider.release();try await wait{!registration.hasPendingRepositoryWork && !registration.busy && c.manager.pendingOperations==0}
        try require(registration.error==nil && registration.root==nil && c.watched.repositories.contains{$0.lastKnownPath==c.third.root.path},"Saved Add did not register headlessly after worker release")
        try require(provider.observation.paths==[c.third.root.path] && !provider.observation.main,"Saved Add resolved unrelated grants or ran bookmark resolution on main")

        // A forgotten grant cannot return from its worker as fresh authority.
        // Keep the normal first-use permission fallback, then cancel it.
        let stale=model();var chooser:((NSApplication.ModalResponse)->Void)?,commits=0
        stale.presentFinderServiceFolderPanel={_,_,reply in chooser=reply}
        stale.commitWindowFactory={repository,access in commits += 1;let controller=CommitWindowController(repository:repository,access:access,defaults:c.prefs);c.additionalWindows.append(controller);return controller}
        provider.arm(c.source.root)
        try require(stale.handleFinderService(.init(action:.commit,paths:[c.source.root])),"Held Services Commit was refused")
        try await wait{provider.observation.entered};try store.forget(source.id)
        provider.release();try await wait{chooser != nil}
        try require(commits==0 && stale.hasPendingFinderServiceWork && !provider.observation.main,"Forgotten saved grant launched Commit or lost chooser ownership")
        chooser?(.cancel);chooser=nil;try await wait{!stale.hasPendingRepositoryWork && !stale.busy}
        try require(commits==0 && stale.root==nil && !store.repositories.contains{$0.id==source.id},"Cancelled stale-grant fallback revived permission or workspace")
        let restoredSource=try store.remember(c.source.root)

        // Multi-root transport must retain separate genuine primary leases;
        // closing each captured form allows the next repository to proceed.
        let batch=model();var roots=[String](),forms=[NSWindowController]()
        batch.finderServiceWorkflowPresentation={action,controller,repository,access in
            guard action == .fetch else{return}
            roots.append(repository.root.path);forms.append(controller);c.additionalWindows.append(controller)
            if access?.contains(repository.root) != true {batch.error="Wrong transport authority"}
            Task{@MainActor in await Task.yield();controller.close()}
        }
        provider.arm(c.third.root)
        try require(batch.handleFinderService(.init(action:.fetch,paths:[c.source.root,c.third.root])),"Multi-root saved Fetch refused")
        try await wait{provider.observation.entered}
        try require(batch.hasPendingRepositoryWork && batch.finderActionAuthorityPending && roots.isEmpty && !provider.observation.main,"Multi-root authority lost ownership or presented before all scopes resolved")
        provider.release();try await wait{!batch.hasPendingRepositoryWork && !batch.busy}
        try require(batch.error==nil && roots==[c.source.root.path,c.third.root.path] && forms.count==2,"Independent saved roots did not receive ordered Fetch forms: \(roots); \(batch.error ?? "")")
        try require(Set(provider.observation.paths)==Set([c.source.root.path,c.third.root.path]) && !provider.observation.main,"Multi-root Fetch resolved unrelated grants or main-thread bookmarks")

        // Additional metadata scopes must never become a second repository's
        // primary grant merely because a combined lease retains their lifetime.
        try store.forget(third.id);try store.addPermission(restoredSource.id,url:c.third.root)
        let related=model();var relatedChooser:((NSApplication.ModalResponse)->Void)?,relatedForms=0
        related.presentFinderServiceFolderPanel={_,_,reply in relatedChooser=reply}
        related.finderServiceWorkflowPresentation={_,controller,_,_ in relatedForms += 1;c.additionalWindows.append(controller);controller.close()}
        try require(related.handleFinderService(.init(action:.fetch,paths:[c.source.root,c.third.root])),"Related-only authority request refused before owned validation")
        try await wait{relatedChooser != nil}
        try require(relatedForms==0 && related.hasPendingRepositoryWork,"Related metadata scope widened primary authority for a second root")
        relatedChooser?(.cancel);relatedChooser=nil;try await wait{!related.hasPendingRepositoryWork && !related.busy}

        // Quit cancels admission immediately but the real blocking worker still
        // owns its grants and pending barrier until it actually returns.
        let cancelled=model();var latePanels=0
        cancelled.presentFinderServiceFolderPanel={_,_,_ in latePanels += 1}
        provider.arm(c.source.root)
        try require(cancelled.handleFinderService(.init(action:.registerRepository,paths:[c.source.root])),"Cancellable saved Add refused")
        try await wait{provider.observation.entered}
        cancelled.confirmingQuit=true
        try require(cancelled.hasPendingRepositoryWork,"Quit released a real saved-bookmark worker early")
        provider.release();try await wait{!cancelled.hasPendingRepositoryWork}
        try require(latePanels==0 && cancelled.root==nil && cancelled.error==nil && !c.watched.repositories.contains{$0.lastKnownPath==c.source.root.path},"Quit permitted late chooser/registration/error delivery")
        cancelled.confirmingQuit=false
    }
    static func services(_ c:Context)async throws {
        let selected=NSPasteboard.withUniqueName();defer{selected.releaseGlobally()}
        let paths=[c.source.root.appendingPathComponent("file"),c.third.root]
        selected.writeObjects(paths.map {url in let item=NSPasteboardItem();item.setString(url.absoluteString,forType:.fileURL);return item})
        let original=selected.changeCount,expected=try FinderServiceCommand.status.request(paths:paths).paths
        var opens=[[URL]](),legacy=[FinderRequest]()
        let provider=TurtleGitFinderServicesProvider(open:{opens.append($0)},submit:{legacy.append($0)})
        var error:NSString?
        provider.openInTurtleGit(selected,userData:"open",error:&error)
        try require(error==nil && opens.count==1 && opens[0].map{Data($0.path.utf8)}==expected.map{Data($0.path.utf8)} && selected.changeCount==original,"Single public Service did not capture literal selected file/folder URLs")
        let wire=try TurtleGitFinderServicesProvider.openSelectionURL(expected),decoded=try TurtleGitFinderServicesProvider.openSelection(from:wire)
        try require(decoded.map{Data($0.path.utf8)}==expected.map{Data($0.path.utf8)},"Standalone generic Open forwarding changed selected paths")
        error=nil;provider.openInTurtleGit(selected,userData:"log",error:&error)
        try require(error != nil && opens.count==1,"Generic public Service accepted arbitrary command UserData")
        let one=NSPasteboard.withUniqueName();defer{one.releaseGlobally()};one.writeObjects([c.source.root as NSURL])
        error=nil;provider.performFinderAction(one,userData:"log",error:&error)
        try require(error==nil && legacy.count==1 && legacy[0].action == .log,"Unregistered legacy handler compatibility changed")
        provider.retire();error=nil;provider.openInTurtleGit(selected,userData:"open",error:&error)
        try require(error != nil && opens.count==1,"Retired public Service delivered late selection")
        let malformed=NSPasteboard.withUniqueName();defer{malformed.releaseGlobally()};malformed.setString("plain text is not a file URL",forType:.string)
        let fresh=TurtleGitFinderServicesProvider(open:{opens.append($0)},submit:{legacy.append($0)});defer{fresh.retire()}
        error=nil;fresh.openInTurtleGit(malformed,userData:"open",error:&error)
        try require(error != nil && opens.count==1,"Public Service silently admitted text-only pasteboard")
        let actual=TurtleGitFinderServicesProvider(open:{paths in
            guard c.workspace.handleOpenServiceSelection(paths) else{throw Failure(description:"Actual generic Open refused")}
        },submit:{_ in throw Failure(description:"Generic Open entered legacy action route")});defer{actual.retire()}
        let fileBoard=NSPasteboard.withUniqueName();defer{fileBoard.releaseGlobally()};fileBoard.writeObjects([c.source.root.appendingPathComponent("file") as NSURL])
        c.selected=c.source.root;c.permissionReply=nil;error=nil
        actual.openInTurtleGit(fileBoard,userData:"open",error:&error)
        try await wait{c.permissionReply != nil}
        try require(error==nil && c.workspace.root==nil && c.workspace.error==nil && c.parent.attachedSheet is NSOpenPanel,"Ungrantable first-use selection did not enter owned Open Repository chooser")
        c.answer(.cancel);try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy}
        try require(c.workspace.root==nil && c.recent.repositories.isEmpty,"Cancelled generic Open adopted repository or persisted permission")
        error=nil;actual.openInTurtleGit(fileBoard,userData:"open",error:&error);try await wait{c.permissionReply != nil};c.answer(.OK)
        try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.workspace.root?.path==c.source.root.path}
        try require(error==nil && c.workspace.error==nil && c.workspace.workspaceWindow===c.parent,"Explicit generic Open failed to adopt chosen repository in existing workspace")
    }
    static func launch(_ c:Context)async throws {
        // Exercise the actual cold Finder URL -> private action router, not just
        // RepositoryModel's registration method. Permission remains explicit.
        let action=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in true},finderWatches:c.manager,savedAccessStore:c.recent)
        action.requiresRepositoryScope=true;action.repositoryBookmarkProvider=c.provider;action.fileComparisonPreferences=c.prefs
        action.selectedFinderServiceFolderURL={_ in c.selected}
        action.presentFinderServiceFolderPanel={panel,_,reply in c.panels += 1;c.permissionReply=reply;panel.orderFront(nil)}
        let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=["--turtlegit-action-only"];delegate.makeStandaloneWorkspace={action};delegate.configureStandaloneServices={_,_ in}
        var presentations=0,activations=0;delegate.presentWorkspace={presentations += 1};delegate.activateStandaloneApplication={activations += 1}
        defer{delegate.retireFinderServices();action.stopMonitoringForTermination()}
        delegate.startupDidFinishLaunching()
        let baselineWindows=Set(NSApp.windows.map(ObjectIdentifier.init)),baselineWatches=c.watched.repositories.map(\.id)
        c.selected=c.third.root;c.permissionReply=nil
        guard let url=FinderRequest(action:.registerRepository,paths:[c.third.root]).url else{throw Failure(description:"Cold registration URL unavailable")}
        delegate.application(NSApp,open:[url])
        try await wait{c.permissionReply != nil}
        try require(action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0,"Cold registration opened workspace before folder grant")
        c.answer(.cancel)
        try await wait{!action.hasPendingFinderServiceWork && !action.busy}
        try require(action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0 && c.recent.repositories.isEmpty && c.watched.repositories.map(\.id)==baselineWatches && action.error==nil && delegate.actionErrorController==nil,"Cancelled cold registration saved/presented a workspace or surfaced an error")
        delegate.application(NSApp,open:[url]);try await wait{c.permissionReply != nil}
        c.answer(.OK)
        try await wait{!action.hasPendingFinderServiceWork && !action.busy && c.manager.pendingOperations==0}
        try require(delegate.actionRepositoryModel === action && action.root==nil && action.workspaceWindow==nil && presentations==0 && activations==0 && action.error==nil && delegate.actionErrorController==nil,"Cold registration adopted/presented a workspace or failed")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.third.root.path} && baselineWatches.allSatisfy{old in c.watched.repositories.contains{$0.id==old}} && c.manager.rows.contains{$0.path==c.third.root.path},"Cold registration failed exact watch/status publication")
        try require(c.recent.repositories.count==1 && c.recent.repositories[0].lastKnownPath==c.third.root.path && action.recentRepositories.contains{$0.lastKnownPath==c.third.root.path} && c.manager.backgroundService==nil && NSApp.windows.filter{!baselineWindows.contains(ObjectIdentifier($0))}.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Cold registration failed captured recent record, enabled background service or retained permission window")
        delegate.retireFinderServices();action.stopMonitoringForTermination()
        c.workspace.open(c.other.root);try await wait{!c.workspace.busy && c.workspace.root?.path==c.other.root.path}
        try await DialogLaunchVerification.verify(repository:c.source,existing:c.workspace,preferences:c.prefs)
    }
    static func warmRegistration(_ c:Context)async throws {
        c.workspace.open(c.other.root)
        try await wait{!c.workspace.busy && c.workspace.root?.path==c.other.root.path}
        let originalRoot=c.workspace.root,originalWindow=c.workspace.workspaceWindow,originalWatch=c.watched.repositories[0]
        let windowCount=NSApp.windows.filter(\.isVisible).count
        // A decoded restart archive may carry an invalid namespace from an
        // older producer. Its optional restoration must not prevent real Add.
        var archive=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:c.cache.warmURL))
        archive.roots.append(c.source.root.path)
        archive.states[c.source.root.path] = .conflicted
        archive.states[c.source.root.path+"/stale/"] = .conflicted
        archive.repositories[c.source.root.path] = .init()
        let damaged=try JSONEncoder().encode(archive);try damaged.write(to:c.cache.warmURL)
        let restart=c.cache,probeSession=try restart.startSession()
        defer {_ = try? restart.endSession(probeSession)}
        let warning=try restart.begin(root:c.source.root,session:probeSession)
        try require(warning.persistenceFailure != nil && FinderSnapshot.readLive(from:c.cache.url)?.roots.contains(c.source.root.path) != true,"Invalid optional restart state became live authority or lost its nonfatal warning")
        try require((try Data(contentsOf:c.cache.warmURL))==damaged,"Restart admission erased unrelated warm data before fresh publication")
        let unchangedHead=try await c.source.run(["rev-parse","HEAD"]).stdout
        let unchangedIndex=try Data(contentsOf:c.source.root.appendingPathComponent(".git/index"))
        try Data("fresh registration state\n".utf8).write(to:c.source.root.appendingPathComponent("file"))
        try await c.submit(c.source.root)
        if c.permissionReply != nil {c.answer(.OK)}
        try await wait{!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error==nil && c.workspace.root==originalRoot && c.workspace.workspaceWindow===originalWindow,"Explicit Add adopted/switched the live workspace")
        try require(NSApp.windows.filter(\.isVisible).count==windowCount && c.parent.isVisible,"Explicit Add presented a duplicate workspace")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.source.root.path} && c.watched.repositories.contains{$0.id==originalWatch.id && $0.bookmark==originalWatch.bookmark},"Explicit Add did not retain exact new/unrelated watches")
        try require(c.manager.rows.contains{$0.path==c.source.root.path} && c.manager.backgroundService==nil,"Explicit Add did not publish owned watch status or enabled background mode")
        let fresh=try c.cache.readLive(),saved=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:c.cache.warmURL))
        try require(fresh.states[c.source.root.path+"/file"] == .modified && fresh.states[c.source.root.path+"/stale/"]==nil && fresh.states[c.other.root.path+"/file"] == .normal,"Add failed to replace damaged restart state with fresh badges or lost valid sibling")
        try require(saved.states[c.source.root.path+"/file"] == .modified && saved.states[c.source.root.path+"/stale/"]==nil && saved.states[c.other.root.path+"/file"] == .normal,"Fresh warm repair reset valid sibling or retained malformed cache keys")
        try require(c.recent.repositories.contains{$0.lastKnownPath==c.source.root.path},"Nonfatal warm warning prevented Add from completing its Recent entry")
        let finalHead=try await c.source.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==unchangedHead && (try Data(contentsOf:c.source.root.appendingPathComponent(".git/index")))==unchangedIndex,"Warm recovery changed repository HEAD or index")
        // Unlike invalid namespace admission, malformed JSON is detected during
        // optional archive rebuilding after live publication. Its typed recovery
        // notice must not turn a successfully completed Add into an error.
        try Data("{invalid restart archive".utf8).write(to:c.cache.warmURL)
        let thirdHead=try await c.third.run(["rev-parse","HEAD"]).stdout
        let thirdIndex=try Data(contentsOf:c.third.root.appendingPathComponent(".git/index"))
        try await c.submit(c.third.root);if c.permissionReply != nil {c.answer(.OK)}
        try await wait {!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error==nil && c.recent.repositories.contains{$0.lastKnownPath==c.third.root.path},"Successful malformed-JSON rebuild incorrectly failed Add")
        let rebuiltLive=try c.cache.readLive(),rebuiltWarm=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:c.cache.warmURL))
        for value in [rebuiltLive,rebuiltWarm] {
            try require(value.states[c.third.root.path+"/file"] == .normal && value.states[c.source.root.path+"/file"] == .modified && value.states[c.other.root.path+"/file"] == .normal,"JSON recovery lost fresh badges or valid live siblings")
        }
        try require(c.manager.rows.first(where:{$0.path==c.third.root.path})?.status.contains(FinderPublicationFailure.corruptWarmCacheReset.localizedDescription)==true,"Successful cache rebuild notice was not retained by the owned watch row")
        let thirdFinalHead=try await c.third.run(["rev-parse","HEAD"]).stdout
        try require(thirdFinalHead==thirdHead && (try Data(contentsOf:c.third.root.appendingPathComponent(".git/index")))==thirdIndex && c.workspace.root==originalRoot && c.workspace.workspaceWindow===originalWindow && c.manager.backgroundService==nil,"Warm JSON recovery changed repository/scene ownership or background opt-in")
    }
    static func publication(_ c:Context)async throws {
        let nested=try await c.repo(c.source.root.lastPathComponent+"/Nested checkout")
        let ignored=try await c.repo(c.source.root.lastPathComponent+"/Ignored checkout")
        try Data("Ignored checkout/\n".utf8).write(to:c.source.root.appendingPathComponent(".gitignore"))
        let raw=try await c.source.status(readPolicy:.automatic)
        try require(raw.contains{$0.path=="Nested checkout/" && $0.state == .untracked} && raw.contains{$0.path=="Ignored checkout/" && $0.state == .ignored},"Actual Git directory-marker reproduction missing")
        let hold=c.root.appendingPathComponent("hold-status"),fail=c.root.appendingPathComponent("fail-status")
        try Data().write(to:hold);defer {c.unblock();try? FileManager.default.removeItem(at:hold);try? FileManager.default.removeItem(at:fail)}
        try await c.submit(c.source.root);c.answer(.OK)
        try await wait {FileManager.default.fileExists(atPath:c.started.path)}
        try require(c.workspace.busy && c.workspace.hasPendingFinderServiceWork && c.recent.repositories.isEmpty,"Add completed before actual first status read/publication")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.source.root.path},"Accepted watch was not persisted before owned first publication")
        c.unblock();try? FileManager.default.removeItem(at:hold)
        try await wait {!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error==nil && c.recent.repositories.contains{$0.lastKnownPath==c.source.root.path},"Successful first publication lost saved recent: \(c.workspace.error ?? "")")
        let published=FinderSnapshot.readLive(from:c.cache.url)
        try require(published?.roots.contains(c.source.root.path)==true && published?.roots.contains(c.other.root.path)==true,"Successful Add did not publish both actual repository roots")
        try require(published?.states[nested.root.path] == .untracked && published?.states[ignored.root.path] == .ignored && published?.overlayEntries?[nested.root.path] == .untracked && published?.overlayEntries?[ignored.root.path] == .ignored,"Git directory markers were not published as canonical folder badges")
        try require(published?.states[nested.root.path+"/"] == nil && published?.states[ignored.root.path+"/"] == nil,"Raw trailing directory markers escaped into shared Finder cache")
        try Data().write(to:fail)
        try await c.submit(c.third.root);if c.permissionReply != nil {c.answer(.OK)}
        try await wait {!c.workspace.hasPendingFinderServiceWork && !c.workspace.busy && c.manager.pendingOperations==0}
        try require(c.workspace.error?.contains("controlled first publication failure")==true,"First collection failure was silently reported as Add success")
        try require(c.watched.repositories.contains{$0.lastKnownPath==c.third.root.path} && !c.recent.repositories.contains{$0.lastKnownPath==c.third.root.path},"Failed publication lost captured saved watch or falsely completed recent pairing")
        try require(c.workspace.root==nil && c.workspace.workspaceWindow===c.parent && c.manager.backgroundService==nil,"Headless publication adopted workspace or enabled background service")
    }
    static func ownership(_ c:Context)async throws {
        try c.block();let mutating=Task {await c.manager.add(c.other.root)};defer {c.unblock()}
        try await wait {c.manager.busy && FileManager.default.fileExists(atPath:c.started.path)}
        try await c.submit(c.source.root);c.answer(.OK)
        try await wait {c.workspace.hasPendingFinderServiceWork && c.workspace.busy && c.permissionReply==nil}
        c.workspace.confirmingQuit=true;try await wait {!c.workspace.hasPendingFinderServiceWork}
        try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Cancelled queued registration persisted late")
        c.unblock();await mutating.value;c.workspace.confirmingQuit=false
        try c.block();try await c.submit(c.third.root);c.answer(.OK);try await wait {FileManager.default.fileExists(atPath:c.started.path) && c.manager.busy}
        c.workspace.stopMonitoringForTermination();c.unblock();try await wait {!c.workspace.hasPendingFinderServiceWork && !c.manager.busy}
        try require(c.watched.repositories.count==1 && c.recent.repositories.isEmpty,"Retired registration published or saved late")
    }
    static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        let lifetime=RegistrationReceiverLifetime(),originalDelegate=NSApp.delegate
        NSApp.delegate=lifetime
        defer{NSApp.delegate=originalDelegate;withExtendedLifetime(lifetime){}}
        if let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),let replacement=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.registrationOrder(_:relativeTo:))) {method_exchangeImplementations(original,replacement)}
        var context:Context?
        do {let c=try Context();context=c;try await c.prepare();switch CommandLine.arguments[3] {case "publication":try await publication(c);case "registration":try await registration(c);case "clone":try await clone(c);case "ownership":try await ownership(c);case "warm":try await warmRegistration(c);case "authority":try await authority(c);case "services":try await services(c);case "launch":try await launch(c);default:throw Failure(description:"Unknown case")};try await c.cleanup();print("PASS: Finder registration \(CommandLine.arguments[3])")}
        catch {try? await context?.cleanup();fputs("Finder registration failed: \(error)\n",stderr);exit(1)}
    }
}
