// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Carbon
import Darwin
import TurtleGitCore

/// Runs inside the existing private workspace receiver. Raw Apple events enter
/// NSAppleEventManager, while lifecycle ordering is explicitly driven here; this
/// boundary is not claimed to be a physical Finder/Launch Services cold launch.
extension WorkspaceLaunchVerification {
    static func dispatchFinderURL(_ url:URL)throws {
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kInternetEventClass),eventID:AEEventID(kAEGetURL),targetDescriptor:NSAppleEventDescriptor(processIdentifier:ProcessInfo.processInfo.processIdentifier),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string:url.absoluteString),forKeyword:AEKeyword(keyDirectObject))
        let reply=NSAppleEventDescriptor.null()
        guard let raw=event.aeDesc,let answer=reply.aeDesc else{throw Failure(description:"Private raw GetURL descriptor unavailable")}
        var context:UInt8=0
        withUnsafeMutablePointer(to:&context){_ = NSAppleEventManager.shared().dispatchRawAppleEvent(raw,withRawReply:UnsafeMutablePointer(mutating:answer),handlerRefCon:UnsafeMutableRawPointer($0))}
    }
    static func configureCommitPreferences(_ preferences:UserDefaults) {
        preferences.set(true,forKey:"HintStagingMode");preferences.set(1,forKey:"CommitMergeHint");preferences.set(7,forKey:"NothingToCommitShowUnversioned");preferences.set(false,forKey:"Autocompletion")
    }
    static func privateCommitRepository(_ c:Context)async throws->GitRepository {
        let folder=c.folder.appendingPathComponent("selected repository 雪")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repository=GitRepository(root:folder,executable:c.git,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Cold Launch QA"),("user.email","cold@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        try Data("before\n".utf8).write(to:folder.appendingPathComponent("tracked 雪.txt"));try await repository.stage(["tracked 雪.txt"]);_=try await repository.commit(message:"initial")
        try Data("after\n".utf8).write(to:folder.appendingPathComponent("tracked 雪.txt"))
        _=try c.store.remember(folder)
        configureCommitPreferences(c.preferences)
        return repository
    }
    static func currentCommit()->CommitWindowController? {
        NSApp.windows.compactMap{$0.windowController as? CommitWindowController}.first
    }
    static func finderDelivery(_ c:Context,mode:String)async throws {
        let store=FinderActionHandoff(root:c.folder.appendingPathComponent("private-action-handoffs"))
        let original=FinderRequest(action:.log,paths:[c.folder.appendingPathComponent("literal 雪\t[*]")])
        let delivery=try store.publish(original)
        var consumed=0,routed=[FinderRequest](),authorityResume:CheckedContinuation<Void,Never>?,blockedModel:RepositoryModel?,secondDelivery:FinderActionDelivery?
        let secondRequest=FinderRequest(action:.status,paths:original.paths)
        if mode=="finder-authority-gate"{c.delegate.prepareGitConfigurationReads={await withCheckedContinuation{authorityResume=$0}}}
        defer{authorityResume?.resume();authorityResume=nil;blockedModel?.busy=false}
        c.delegate.consumeFinderAction={value in consumed+=1;return try store.consume(value)}
        c.delegate.workspaceOpenHandler={model,url in
            if let value=FinderRequest(url:url) {
                routed.append(value)
                if mode=="finder-authority-gate",routed.count==1 {blockedModel=model;model.busy=true}
            }
        }
        c.delegate.startupArguments=mode=="finder-url-first" ? []:delivery.arguments
        c.delegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        defer{c.delegate.retireInboundURLBridge()}
        if mode=="finder-url-first"{try dispatchFinderURL(delivery.url)}
        try require(routed.isEmpty,"Finder capability bypassed startup readiness")
        c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:true]))
        c.delegate.finishPendingDefaultWorkspaceLaunch()
        if mode=="finder-authority-gate" {
            try await wait("actual queued action authority gate"){authorityResume != nil}
            try dispatchFinderURL(delivery.url)
            secondDelivery=try store.publish(secondRequest)
            try dispatchFinderURL(secondDelivery!.url)
            try require(!c.delegate.gitConfigurationReadsReady && routed.isEmpty,"Cold action bypassed pending Git configuration authority")
            try noWorkspace(c,"Pending foreground authority created a blank workspace")
            authorityResume?.resume();authorityResume=nil
        }
        try await wait("receipt route after startup"){!routed.isEmpty}
        if secondDelivery != nil {
            try require(routed.count==1 && routed[0].url==original.url && blockedModel?.busy==true,"Queued receipt overtook the held first action")
            await Task.yield()
            try require(routed.count==1,"Second distinct Finder command was delivered while first authority preparation remained busy")
            blockedModel?.busy=false
            try await wait("second distinct action after authority drain"){routed.count==2}
            try require(routed[1].url==secondRequest.url,"FIFO lost or reordered the distinct second Finder command")
        }
        let accepted=secondDelivery == nil ? 1:2
        try require(consumed==accepted && routed[0].url==original.url,"Cold receipt lost original literal path/request or consumed twice")
        try dispatchFinderURL(delivery.url);try dispatchFinderURL(delivery.url)
        try require(consumed==accepted && routed.count==accepted,"argv/GetURL repeated one Finder command")
        let again=try store.publish(original)
        try dispatchFinderURL(again.url)
        try await wait("independent repeat click routed"){routed.count==accepted+1}
        try require(consumed==accepted+1 && routed.last?.url==original.url,"Independent repeat Finder click was deduplicated by request contents")
        try noWorkspace(c,"Finder receipt routing materialized default workspace")
        try require((try? store.consume(delivery))==nil && (try? store.consume(again))==nil,"Accepted receipt remained consumable")
        if let secondDelivery {try require((try? store.consume(secondDelivery))==nil,"Queued second capability remained consumable")}
        print("COLD_TIMING "+mode+" once_only=\(accepted+1) workspace=0")
    }

    static func finderMissing(_ c:Context)async throws {
        let store=FinderActionHandoff(root:c.folder.appendingPathComponent("private-action-handoffs"))
        guard let delivery=FinderActionDelivery(receipt:UUID().uuidString.lowercased(),action:.commit) else{throw Failure(description:"Missing receipt fixture invalid")}
        var consumed=0,routed=0
        c.delegate.consumeFinderAction={value in consumed+=1;return try store.consume(value)}
        c.delegate.workspaceOpenHandler={_,_ in routed+=1}
        c.delegate.startupArguments=delivery.arguments
        c.delegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification));defer{c.delegate.retireInboundURLBridge()}
        c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:true]))
        try await wait("missing receipt owned diagnostic"){c.delegate.actionErrorController?.window != nil}
        let errorWindow=c.delegate.actionErrorController?.window
        try require(errorWindow?.alphaValue==0 && routed==0,"Missing cold capability opened action or visible/unowned error")
        try noWorkspace(c,"Missing capability opened default workspace")
        try dispatchFinderURL(delivery.url)
        try require(consumed==1 && c.delegate.actionErrorController?.window === errorWindow,"Duplicate failed delivery repeated consumption/diagnostic")
        c.delegate.actionErrorController?.close()
    }
    final class ForegroundAuthorityProbe:RepositoryBookmarkProvider,@unchecked Sendable {
        private let lock=NSLock()
        private var resolutions:[(String,Bool)]=[]
        private let gate=DispatchSemaphore(value:0)
        private var holdFirst=true,entered=false
        func release(){gate.signal()}
        var waiting:Bool{lock.lock();defer{lock.unlock()};return entered}
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {
            let path=String(decoding:data,as:UTF8.self)
            lock.lock();resolutions.append((path,Thread.isMainThread));let hold=holdFirst;holdFirst=false;if hold{entered=true};lock.unlock()
            if hold{_ = gate.wait(timeout:.now()+5)}
            return .init(url:URL(fileURLWithPath:path),stale:false)
        }
        func startAccessing(_ url:URL)->Bool{true}
        func stopAccessing(_ url:URL){}
        var resolved:[(String,Bool)]{lock.lock();defer{lock.unlock()};return resolutions}
    }
    static func finderCommit(_ c:Context,prioritizedAuthority:Bool=false)async throws {
        let repository=try await privateCommitRepository(c),store=FinderActionHandoff(root:c.folder.appendingPathComponent("private-action-handoffs"))
        var authority:ForegroundAuthorityProbe?,authorityModel:RepositoryModel?
        var routedActions=[RepositoryAction](),queuedFollowup:FinderActionDelivery?
        defer{authority?.release()}
        if prioritizedAuthority {
            let provider=ForegroundAuthorityProbe(),archive=try RepositoryAccessStore(storageURL:c.folder.appendingPathComponent("foreground-access.json"),provider:provider)
            _=try archive.remember(repository.root)
            let unrelated=c.folder.appendingPathComponent("unrelated saved repository")
            try FileManager.default.createDirectory(at:unrelated,withIntermediateDirectories:true)
            _=try archive.remember(unrelated)
            try require(archive.repositories.first?.lastKnownPath==unrelated.path,"Authority fixture did not place unrelated bookmark first")
            let git=c.git,model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:archive)
            model.requiresRepositoryScope=true;model.repositoryBookmarkProvider=provider;model.fileComparisonPreferences=c.preferences;c.models.append(model)
            let configure=c.delegate.configureGeneralApplication
            c.delegate.configureGeneralApplication={delegate in configure?(delegate);delegate.makeStandaloneWorkspace={model}}
            let route=c.delegate.workspaceOpenHandler
            c.delegate.workspaceOpenHandler={model,url in if let request=FinderRequest(url:url){routedActions.append(request.action)};route(model,url)}
            authority=provider;authorityModel=model
        }
        let beforeHead=try await repository.run(["rev-parse","HEAD"]).stdout,index=repository.root.appendingPathComponent(".git/index"),beforeIndex=try Data(contentsOf:index)
        let delivery=try store.publish(FinderRequest(action:.commit,paths:[repository.root]))
        var consumed=0;c.delegate.consumeFinderAction={value in consumed+=1;return try store.consume(value)}
        c.delegate.startupArguments=delivery.arguments
        let began=ProcessInfo.processInfo.systemUptime
        c.delegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification));defer{c.delegate.retireInboundURLBridge()}
        c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:true]))
        if let authority,let authorityModel {
            try await wait("real foreground bookmark resolver held"){authority.waiting && authorityModel.finderActionAuthorityPending}
            try require(!authorityModel.busy && routedActions==[.commit],"Actual authority pending was not distinct from ordinary Git busy")
            queuedFollowup=try store.publish(FinderRequest(action:.about,paths:[repository.root]))
            try dispatchFinderURL(queuedFollowup!.url);try dispatchFinderURL(delivery.url)
            await Task.yield()
            try require(routedActions==[.commit],"Second actual receipt bypassed held foreground authority preparation")
            authority.release()
        }
        try await wait("cold receipt actual Commit window"){currentCommit()?.window?.isVisible==true}
        let shown=ProcessInfo.processInfo.systemUptime
        guard let child=currentCommit() else{throw Failure(description:"Cold receipt lost actual Commit owner")}
        try await wait("cold receipt Commit changes ready"){child.model.error != nil || !child.model.busy && CommitWindowModel.activeReloads==0 && child.model.fileListAvailable && child.model.visibleEntries.contains{GitReferenceName.equal($0.path,"tracked 雪.txt")}}
        let loaded=ProcessInfo.processInfo.systemUptime
        try require(child.model.error==nil && child.model.visibleEntries.contains{GitReferenceName.equal($0.path,"tracked 雪.txt")},"Cold receipt failed actual selected repository change read")
        if let authority {
            let records=authority.resolved
            try require(!records.isEmpty && records.allSatisfy{$0.0==repository.root.path && !$0.1},"Foreground Commit resolved an unrelated saved bookmark or resolved selected authority on MainActor")
        }
        try await wait("foreground authority preparation drained"){RepositoryModel.activeFinderAuthorityPreparations==0 && c.models.allSatisfy{!$0.hasPendingRepositoryWork}}
        if queuedFollowup != nil {try await wait("real queued About dispatch after authority release"){routedActions==[.commit,.about]}}
        let owner=child.window
        try dispatchFinderURL(delivery.url)
        try require(consumed==(queuedFollowup == nil ? 1:2) && currentCommit()?.window === owner,"Second cold-delivery channel recreated Commit")
        try noWorkspace(c,"Cold Commit receipt opened blank workspace")
        child.close()
        try await wait("cold Commit child drain"){CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && child.window?.isVisible != true}
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==beforeHead && (try Data(contentsOf:index))==beforeIndex,"Opening cold Commit changed HEAD or index bytes")
        print(String(format:"COLD_TIMING finder-commit window_seconds=%.6f changes_seconds=%.6f",shown-began,loaded-began))
    }
    final class StartupPublisherProbe:@unchecked Sendable {
        private let lock=NSLock()
        private var entered=false,onMain=false,presented=false,presentedBeforeWork=false
        func markPresented(){lock.lock();presented=true;lock.unlock()}
        func markWorker(){lock.lock();entered=true;onMain=Thread.isMainThread;presentedBeforeWork=presented;lock.unlock()}
        var state:(entered:Bool,onMain:Bool,presentedBeforeWork:Bool){lock.lock();defer{lock.unlock()};return(entered,onMain,presentedBeforeWork)}
    }
    final class StartupAuthorityProbe:RepositoryBookmarkProvider,@unchecked Sendable {
        private let lock=NSLock()
        private var resolutions=0,starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark{lock.lock();resolutions+=1;lock.unlock();return .init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{lock.lock();starts+=1;lock.unlock();return true}
        func stopAccessing(_ url:URL){lock.lock();stops+=1;lock.unlock()}
        var state:(resolutions:Int,starts:Int,stops:Int){lock.lock();defer{lock.unlock()};return(resolutions,starts,stops)}
    }
    static func startupConfigurationGate(_ c:Context)async throws {
        let repository=try await privateCommitRepository(c),provider=StartupAuthorityProbe(),publisher=StartupPublisherProbe()
        let permissions=try RepositoryAccessStore(storageURL:c.folder.appendingPathComponent("gated-watches.json"),provider:provider)
        _=try permissions.remember(repository.root)
        let cache=FinderSnapshotStore(url:c.folder.appendingPathComponent("gated-status.json")),git=c.git
        let manager=FinderWatchManager(permissions:permissions,cache:cache,requireScope:true,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},notify:{})
        var resume:CheckedContinuation<Void,Never>?
        let model=RepositoryModel(startMonitoring:true,initializePreferences:true,snapshotStore:cache,finderWatches:manager,savedAccessStore:c.store,comparisonMarks:WorkingComparisonMarkStore(storageURL:c.folder.appendingPathComponent("gated-comparison-mark.json")),cachePersistenceDefaults:c.preferences,publishCachePersistence:{value in publisher.markWorker();try cache.setPersistence(value)},prepareGitConfigurationReads:{await withCheckedContinuation{resume=$0}})
        c.models.append(model);model.startWorkspaceServices()
        do {
            try await wait("owned Git configuration preparation held"){resume != nil && model.workspaceServicesPending}
            try require(publisher.state.entered && !publisher.state.onMain && provider.state.resolutions==0 && provider.state.starts==0 && manager.pendingOperations==0,"Watcher authority overtook Git configuration preparation, or prior cache bootstrap used MainActor")
            var pulse=false;Task{@MainActor in pulse=true};try await wait("MainActor responsive during authority gate"){pulse}
            resume?.resume();resume=nil
            await model.settleWorkspaceServices()
            try await wait("watch authority acquired only after configuration preparation"){manager.pendingOperations==0 && provider.state.resolutions>0 && provider.state.starts>0}
            try require(!publisher.state.onMain,"Prepared bootstrap publisher ran on MainActor")
            model.stopMonitoringForTermination();await manager.shutdown()
            try require(provider.state.starts==provider.state.stops,"Deferred watcher authority was not released")
        }catch{resume?.resume();resume=nil;await model.settleWorkspaceServices();model.stopMonitoringForTermination();await manager.shutdown();throw error}
    }
    static func startupLock(_ c:Context)async throws {
        let probe=StartupPublisherProbe(),cache=c.cache
        let lockURL=URL(fileURLWithPath:cache.url.path+".lock")
        let descriptor=Darwin.open(lockURL.path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,mode_t(0o600))
        guard descriptor>=0,flock(descriptor,LOCK_EX|LOCK_NB)==0 else{throw Failure(description:"Could not acquire exact private cache lock")}
        var locked=true
        func release(){if locked{_ = flock(descriptor,LOCK_UN);_ = Darwin.close(descriptor);locked=false}}
        defer{release()}
        let began=ProcessInfo.processInfo.systemUptime,git=c.git
        let model=RepositoryModel(startMonitoring:true,initializePreferences:true,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},snapshotStore:cache,finderWatches:c.watchManager,savedAccessStore:c.store,comparisonMarks:WorkingComparisonMarkStore(storageURL:c.folder.appendingPathComponent("startup-comparison-mark.json")),cachePersistenceDefaults:c.preferences,publishCachePersistence:{value in probe.markWorker();try cache.setPersistence(value)})
        c.models.append(model)
        let constructed=ProcessInfo.processInfo.systemUptime
        try require(!probe.state.entered && !model.workspaceServicesPending,"Constructor performed presentation-owned Finder startup")
        c.scene.makeModel={model}
        c.scene.makeController={value,appearance,delegate in
            let owner=WorkspaceWindowController(model:value,appearance:appearance,applicationDelegate:delegate)
            owner.presentWindow={window in c.presentations+=1;window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.makeKeyAndOrderFront(nil);probe.markPresented()}
            c.controllers.append(owner);return owner
        }
        c.delegate.startupArguments=[]
        c.delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification,userInfo:[NSApplication.launchIsDefaultUserInfoKey:true]))
        do {
            try await wait("workspace visible while private cache writer held"){c.scene.storedController?.window?.isVisible==true && probe.state.entered}
            let shown=ProcessInfo.processInfo.systemUptime
            try require(model.workspaceServicesPending && !probe.state.onMain && probe.state.presentedBeforeWork,"Cache-lock worker blocked MainActor or preceded window presentation")
            var heartbeat=false;Task{@MainActor in heartbeat=true}
            try await wait("MainActor heartbeat during real held flock"){heartbeat}
            let old=NSApp.windows.count
            c.delegate.application(NSApp,open:[FinderRequest(action:.about,paths:[c.folder]).url!])
            try await wait("foreground About while workspace cache locked"){NSApp.windows.count>old && NSApp.windows.contains{$0.windowController is TurtleGitAboutController}}
            try require(model.workspaceServicesPending,"Background cache unexpectedly finished while its actual lock remained held")
            release();await model.settleWorkspaceServices()
            try require(!model.workspaceServicesPending,"Released startup worker did not drain")
            print(String(format:"COLD_TIMING private-cache-lock constructor_seconds=%.6f window_seconds=%.6f",constructed-began,shown-began))
        }catch{release();await model.settleWorkspaceServices();throw error}
    }
}
