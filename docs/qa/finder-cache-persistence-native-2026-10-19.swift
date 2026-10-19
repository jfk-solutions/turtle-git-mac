// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum FinderCachePersistenceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static var windows:[NSWindow]=[]
    static var models:[RepositoryModel]=[]
    static var managers:[FinderWatchManager]=[]
    static var runtimes:[FinderCacheServiceRuntime]=[]
    static var workers:[Process]=[]
    static var sessions:[(FinderSnapshotStore,FinderPublicationSession)]=[]
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Cache persistence did not settle at \(line)")
    }
    static func cleanup()async {
        windows.forEach {$0.orderOut(nil);$0.close()};windows=[]
        for worker in workers {if worker.isRunning {worker.terminate()};worker.waitUntilExit();print("Cache persistence worker reaped: \(worker.processIdentifier)")};workers=[]
        for model in models {model.stopMonitoringForTermination();await model.shutdownFinderPublication();model.closeRepository()};models=[]
        for runtime in runtimes {await runtime.shutdown()};runtimes=[]
        for manager in managers {await manager.shutdown()};managers=[]
        for (store,session) in sessions {_ = try? store.endSession(session)};sessions=[]
    }
    static func session(_ store:FinderSnapshotStore)throws->FinderPublicationSession {
        let value=try store.startSession();sessions.append((store,value));return value
    }
    static func snapshot(_ root:URL,_ state:FileState)->FinderSnapshot {
        FinderSnapshot(roots:[root.path],states:[root.path:state,root.appendingPathComponent("file").path:state],repositories:[root.path:.init()])
    }
    static func state(_ store:FinderSnapshotStore,_ root:URL)->FileState? {
        FinderSnapshot.readLive(from:store.url)?.states[root.appendingPathComponent("file").path]
    }
    static func repository(_ folder:URL,_ git:URL)async throws->GitRepository {
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Cache lifecycle QA"),("user.email","cache@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("baseline\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"cache baseline")
        return repo
    }
    static func settings(_ folder:URL,_ git:URL)async throws {
        let root=folder.appendingPathComponent("repository"),repo=try await repository(root,git)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let store=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"))
        let suite="TurtleGit.CachePersistence.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set("keep",forKey:"UnrelatedPrivatePreference")
        try require(FinderCachePersistencePreferences.from(defaults:prefs).cacheSave,"CacheSave source default is not true")
        let live=try session(store);_ = try store.publish(store.begin(root:root,session:live),snapshots:[snapshot(root,.normal)])
        var reject=true,attempts=0
        let publisher:(FinderCachePersistencePreferences)throws->Void = { value in
            attempts += 1;if reject {throw Failure(description:"Controlled private publication failure")};try store.setPersistence(value)
        }
        let original=AdvancedSettingsModel(defaults:prefs,publishFinderMenu:{_ in},publishCachePersistence:publisher,publishCacheTray:{_ in})
        let coordinator=AdvancedSettingsTable.Coordinator(model:original),scroll=coordinator.makeScrollView()
        let window=NSWindow(contentRect:.init(x:-12000,y:-12000,width:720,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.alphaValue=0;window.contentView=scroll;windows.append(window)
        guard let table=coordinator.table,let row=AdvancedSettingDefinition.all.firstIndex(where:{$0.name=="CacheSave"}) else {throw Failure(description:"Missing native CacheSave row")}
        var rect=NSRect.zero
        let tip=coordinator.tableView(table,toolTipFor:NSCell(),rect:&rect,tableColumn:table.tableColumns.first,row:row,mouseLocation:.zero)
        try require(!tip.contains("no effect"),"Native CacheSave still claims no runtime consumer")
        try require(original.edit("CacheSave",text:"false"),"Source boolean edit refused");original.apply()
        try require(!FinderCachePersistencePreferences.from(defaults:prefs).cacheSave && original.error != nil && original.modified && original.cachePersistencePublicationPending,"Failed policy publication lost saved choice or retry")
        original.cancel();try require(original.cachePersistencePublicationPending && attempts==1,"Cancel published or forgot committed recovery")
        let reopened=AdvancedSettingsModel(defaults:prefs,publishFinderMenu:{_ in},publishCachePersistence:publisher,publishCacheTray:{_ in})
        try require(reopened.modified && reopened.cachePersistencePublicationPending,"Reopening lost pending policy retry")
        reject=false;reopened.apply()
        try require(!reopened.modified && reopened.error==nil && attempts==2 && !(try store.persistence()).cacheSave,"Apply without editing did not retry saved policy")
        try require(state(store,root) == .normal,"Disabling persistence removed current live badges")
        try require(reopened.edit("CacheSave",text:"true"),"Edit refused");reopened.cancel()
        try require(!FinderCachePersistencePreferences.from(defaults:prefs).cacheSave && attempts==2,"Cancel committed a draft")
        try require(reopened.edit("CacheSave",text:""),"Default deletion refused");reopened.apply()
        try require(FinderCachePersistencePreferences.from(defaults:prefs).cacheSave && (try store.persistence()).cacheSave,"Blank did not restore default-on policy")
        _ = try store.endSession(live);try require(state(store,root)==nil,"Closed session remained authoritative")
        let warmed=try session(store);_ = try store.begin(root:root,session:warmed)
        try require(state(store,root) == .normal,"Enabled cache did not warm an authorized root")
        _ = try store.endSession(warmed)
        try require(reopened.edit("CacheSave",text:"false"),"Disable refused");reopened.apply()
        let cold=try session(store);_ = try store.begin(root:root,session:cold)
        try require(state(store,root)==nil,"Disabled policy resurrected old warm status");_ = try store.endSession(cold)
        let model=RepositoryModel(startMonitoring:true,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:publisher)
        models.append(model);model.open(root)
        try await wait {!model.busy && state(store,root) == .normal}
        model.closeRepository();try require(state(store,root) == .normal,"Closing workspace removed a live process's cached badges")
        model.open(root);try await wait {!model.busy && model.root != nil}
        try Data("cache lifecycle edit\n".utf8).write(to:root.appendingPathComponent("file"))
        try await wait {state(store,root) == .modified}
        model.stopMonitoringForTermination();await model.shutdownFinderPublication()
        try require(!model.hasPendingFinderPublication && state(store,root)==nil,"Foreground quit retained live status after drain")
        let restarted=try session(store);_ = try store.begin(root:root,session:restarted)
        try require(state(store,root)==nil,"Foreground restart with CacheSave=false restored status");_ = try store.endSession(restarted)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(afterHead==head && afterIndex==index && (try Data(contentsOf:root.appendingPathComponent("file")))==Data("cache lifecycle edit\n".utf8),"Settings or cache lifecycle changed repository bytes")
        try require(prefs.string(forKey:"UnrelatedPrivatePreference")=="keep","Policy reset unrelated preferences")
        window.close()
        print("PASS: CacheSave native row, saved/durable retry, reopened Apply, Cancel/default reset, current live badges, authorized warm/cold claims and foreground close/quit with unchanged Git state")
    }
    static func worker(_ folder:URL)async throws {
        let input=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:folder.appendingPathComponent("input.json")))
        let store=FinderSnapshotStore(url:URL(fileURLWithPath:input["store"]!)),root=FileTransferPaths.fileURL(input["root"]!),lease=try store.startSession()
        defer {_ = try? store.endSession(lease)}
        let result=try store.publish(store.begin(root:root,session:lease),snapshots:[snapshot(root,.modified)])
        try require(result.published,"Separate process failed to publish")
        try Data().write(to:folder.appendingPathComponent("ready"))
        try await wait {FileManager.default.fileExists(atPath:folder.appendingPathComponent("stop").path)}
        withExtendedLifetime(lease) {}
    }
    static func lifecycle(_ folder:URL,_ git:URL)async throws {
        let root=folder.appendingPathComponent("repository"),repo=try await repository(root,git)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let store=FinderSnapshotStore(url:folder.appendingPathComponent("shared/status.json"));try store.setPersistence(.init(cacheSave:false))
        let parent=try session(store);_ = try store.publish(store.begin(root:root,session:parent),snapshots:[snapshot(root,.normal)])
        let childFolder=folder.appendingPathComponent("owned-worker");try FileManager.default.createDirectory(at:childFolder,withIntermediateDirectories:true)
        try JSONEncoder().encode(["store":store.url.path,"root":root.path]).write(to:childFolder.appendingPathComponent("input.json"))
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=[childFolder.path,git.path,"worker"];try child.run();workers.append(child)
        try await wait {FileManager.default.fileExists(atPath:childFolder.appendingPathComponent("ready").path)}
        try require(state(store,root) == .modified,"Newer separate-process status did not win")
        let revision=FinderSnapshot.readLive(from:store.url)?.liveRevision
        try require(kill(child.processIdentifier,SIGKILL)==0,"Could not stop owned crash-test worker")
        try await wait {!child.isRunning};child.waitUntilExit()
        try require(state(store,root) == .normal && FinderSnapshot.readLive(from:store.url)?.liveRevision != revision,"Exited publisher was not fenced or older live publisher was lost")
        _ = try store.endSession(parent);try require(state(store,root)==nil,"Last publisher exit left authoritative status")
        let old=try session(store),pending=try store.begin(root:root,session:old);_ = try store.endSession(old)
        let fresh=try session(store);_ = try store.publish(store.begin(root:root,session:fresh),snapshots:[snapshot(root,.normal)])
        var refused=false;do {refused = !(try store.publish(pending,snapshots:[snapshot(root,.conflicted)]).published)} catch {refused=true}
        try require(refused && state(store,root) == .normal,"Old process session ticket overwrote a restart");_ = try store.endSession(fresh)
        let permissions=try FinderServicePermissionStore(url:folder.appendingPathComponent("private/grants.json")),access=RepositoryAccessLease(url:root)
        let request=try FinderServiceAuthorization.capture([(UUID(),root,access)])
        _ = try permissions.install(request,requireSecurityScope:false)
        let grants=try Data(contentsOf:permissions.url)
        let runtime=FinderCacheServiceRuntime(permissions:permissions,cache:store,repository:{GitRepository(root:$0,executable:git)})
        runtimes.append(runtime);try runtime.start(requireSecurityScope:false)
        try await wait {runtime.report.roots.first?.lastPublication != nil && state(store,root) == .normal}
        await runtime.shutdown();try require(state(store,root)==nil,"Stopped helper retained live lease")
        try runtime.start(requireSecurityScope:false)
        try Data("service lifecycle edit\n".utf8).write(to:root.appendingPathComponent("file"))
        try await wait {state(store,root) == .modified && runtime.report.cacheSave==false}
        try store.setPersistence(.init(cacheSave:true));runtime.refresh()
        try await wait {runtime.report.cacheSave==true && runtime.report.cacheFailure==nil}
        await runtime.shutdown()
        let warm=URL(fileURLWithPath:store.url.path+".warm")
        try require(FileManager.default.fileExists(atPath:warm.path),"Enabled helper did not retain completed warm state")
        try FileManager.default.removeItem(at:warm);try FileManager.default.createDirectory(at:warm,withIntermediateDirectories:false)
        try runtime.start(requireSecurityScope:false)
        try await wait {runtime.report.roots.first?.lastPublication != nil && runtime.report.cacheFailure != nil && state(store,root) == .modified}
        let manager=FinderWatchManager(permissions:try RepositoryAccessStore(storageURL:folder.appendingPathComponent("private/app-grants.json")),cache:nil,requireScope:false,notify:{})
        managers.append(manager)
        let frontend=FinderBackgroundService();frontend.registrationStatus={.enabled};frontend.updateStatus();manager.backgroundService=frontend
        frontend.exchange={ operation in
            switch operation {
            case .status:return try JSONEncoder().encode(runtime.report)
            case .refresh:runtime.refresh();return nil
            case .grants:throw Failure(description:"Status retry attempted to replace permissions")
            }
        }
        frontend.checkStatus(manager);try await wait {!frontend.busy}
        try require(frontend.report?.cacheFailure == runtime.report.cacheFailure && frontend.message.hasPrefix("Background cache needs attention: ") && frontend.message.contains(runtime.report.cacheFailure ?? "missing diagnostic"),"Native background status hid durable failure")
        try FileManager.default.removeItem(at:warm)
        frontend.checkStatus(manager,retry:true);try await wait {!frontend.busy && runtime.report.cacheFailure==nil}
        frontend.checkStatus(manager);try await wait {!frontend.busy}
        try require(frontend.report?.cacheFailure==nil && state(store,root) == .modified,"Retry did not recover live/warm state")
        await runtime.shutdown();await manager.shutdown()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(afterHead==head && afterIndex==index && (try Data(contentsOf:permissions.url))==grants,"Cache restart/retry changed Git state or saved grants")
        try require(state(store,root)==nil,"Helper shutdown left status authoritative")
        print("PASS: CacheSave separate-process crash fencing, live writer fallback, stale ticket refusal, helper stop/restart, disabled cold scan, warm failure with live badges, native diagnostics/retry and retained grants/Git bytes")
    }
}
