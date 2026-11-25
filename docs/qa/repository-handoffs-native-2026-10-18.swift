import AppKit
import ObjectiveC
import TurtleGitCore

private final class HandoffBookmarks: RepositoryBookmarkProvider {
    var active: [String:Int] = [:]
    func create(for url:URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data:Data) throws -> ResolvedBookmark { .init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false) }
    func startAccessing(_ url:URL) -> Bool { active[url.path,default:0] += 1;return true }
    func stopAccessing(_ url:URL) { active[url.path,default:0] -= 1;if active[url.path]==0 {active.removeValue(forKey:url.path)} }
}

private extension NSWindow {
    @objc func handoffQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));handoffQAOrder(mode,relativeTo:number)
    }
}

@main struct RepositoryHandoffsVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Repository handoff did not settle at \(line)")
    }
    @MainActor private static func workspace(container:URL,git:URL,prefs:UserDefaults,scopes:HandoffBookmarks? = nil) throws -> (RepositoryModel,NSWindow) {
        let privateFolder=container.appendingPathComponent("registration-"+UUID().uuidString)
        let provider=scopes ?? HandoffBookmarks()
        let store=try RepositoryAccessStore(storageURL:privateFolder.appendingPathComponent("access.json"),provider:provider)
        let cache=FinderSnapshotStore(url:privateFolder.appendingPathComponent("status.json"))
        let watches=FinderWatchManager(permissions:store,cache:cache,requireScope:scopes != nil,scopeProvider:provider,repositoryFactory:{GitRepository(root:$0,executable:git)},registeredRootsURL:privateFolder.appendingPathComponent("roots.json"),notify:{})
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},snapshotStore:cache,finderWatches:watches,savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks-"+UUID().uuidString+".json")),cachePersistenceDefaults:prefs)
        model.requiresRepositoryScope=scopes != nil
        if let scopes {model.repositoryBookmarkProvider=scopes}
        model.fileComparisonPreferences=prefs;model.creationClipboardText={nil};model.transportClipboardText={nil};model.notifyFinder={}
        model.cloneWindowFactory={CloneWindowController(directory:$0,access:$1,preferences:prefs,executable:git)}
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;model.workspaceWindow=host
        return (model,host)
    }
    @MainActor static func clone(_ model:RepositoryModel) throws -> CloneWindowController {
        let before=Set(NSApp.windows.map(ObjectIdentifier.init));model.activate(.clone)
        guard let owner=NSApp.windows.filter({!before.contains(ObjectIdentifier($0))}).compactMap({$0.delegate as? CloneWindowController}).first else {throw Failure(description:"Missing Clone form")}
        return owner
    }
    static func same(_ first:URL?,_ second:URL)->Bool {first?.resolvingSymlinksInPath().path==second.resolvingSymlinksInPath().path}
    @MainActor static func diagnostic(_ model:RepositoryModel,expected:URL?=nil)->String {
        ["expectedRoot="+(expected?.path ?? "nil"),"actualRoot="+(model.root?.path ?? "nil"),
         "busy=\(model.busy)","quit=\(model.confirmingQuit)","handoff=\(model.hasPendingRepositoryHandoff)",
         "registration=\(model.hasPendingFinderServiceWork)","repositoryWork=\(model.hasPendingRepositoryWork)",
         "watchOperations=\(String(describing:model.finderWatches?.pendingOperations))", "savedPaths=\(model.recentRepositories.map(\.lastKnownPath))",
         "error=\(String(reflecting:model.error))", "output=\(String(reflecting:String(model.output.prefix(4096))))"].joined(separator:",")
    }
    @MainActor static func check(_ value:Bool,_ message:String,model:RepositoryModel,expected:URL?=nil)throws {
        if !value {print("Repository handoff diagnostic: "+message+"; "+diagnostic(model,expected:expected))}
        try require(value,message)
    }
    @MainActor static func register(_ owner:CloneWindowController,model:RepositoryModel,root:URL,git:URL,access:RepositoryAccessLease) async throws {
        var saved=0;model.onFinderRegistrationSaved={saved += 1}
        owner.model.onVerifiedClone(GitRepository(root:root,executable:git),access,nil,false,"Verified private result")
        try await wait {!model.hasPendingFinderServiceWork && model.finderWatches?.pendingOperations==0}
        try check(saved==1 && model.recentRepositories.contains{same(URL(fileURLWithPath:$0.lastKnownPath),root)},"Verified Clone did not complete its real private registration/publication (saved=\(saved))",model:model,expected:root)
        model.onFinderRegistrationSaved={}
    }
    @MainActor static func completedOperations(container:URL,source:URL,git:URL,prefs:UserDefaults) async throws {
        for bare in [false,true] {
            let (model,host)=try Self.workspace(container:container,git:git,prefs:prefs)
            defer {model.stopMonitoringForTermination();model.finderWatches?.retire();host.close()}
            model.open(source);try await wait {!model.busy && model.root != nil}
            let owner=try clone(model);defer {owner.close()}
            owner.model.onProgress=nil
            let destination=container.appendingPathComponent(bare ? "real-clone-bare":"real-clone")
            owner.model.configureLaunch(source:source.path,exactPath:true);owner.model.directory=destination.path;owner.model.bare=bare;owner.model.recursive=false
            var release:CheckedContinuation<Void,Never>?
            defer {release?.resume()}
            model.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
            try await wait {release != nil}
            func cloneHandoffDiagnostic()->String {
                "bare=\(bare),expectedHeldRoot=\(source.path),actualRoot=\(model.root?.path ?? "nil"),workspaceBusy=\(model.busy),pendingHandoff=\(model.hasPendingRepositoryHandoff),registrationWork=\(model.hasPendingFinderServiceWork),watchOperations=\(String(describing:model.finderWatches?.pendingOperations)),savedPaths=\(model.recentRepositories.map(\.lastKnownPath)),workspaceError=\(String(reflecting:model.error)),cloneCompleted=\(String(describing:owner.model.completed)),cloneActive=\(owner.model.activeOperation),cloneError=\(String(reflecting:owner.model.error)),cloneWarning=\(String(reflecting:owner.model.completionWarning))"
            }
            owner.model.clone();try await wait {owner.model.completed != nil && !owner.model.activeOperation}
            let stillHeld=model.busy && same(model.root,source)
            if !stillHeld {print("Clone handoff ownership diagnostic: "+cloneHandoffDiagnostic())}
            try require(stillHeld,"Clone replaced an active workspace operation before registration")
            // Exit-zero Clone delivery precedes asynchronous Finder registration.
            // Keep the original workspace operation held until that real gate
            // publishes its queued handoff, rather than assuming synchronous UI.
            var ownershipLost=false
            do {
                try await wait {
                    if !model.busy || !same(model.root,source) {ownershipLost=true;return true}
                    return model.hasPendingRepositoryHandoff && !model.hasPendingFinderServiceWork && model.finderWatches?.pendingOperations==0
                }
            }catch {print("Clone registration/handoff diagnostic: "+cloneHandoffDiagnostic());throw error}
            let queued = !ownershipLost && model.busy && same(model.root,source) && model.hasPendingRepositoryHandoff
            if !queued {print("Clone queued handoff diagnostic: "+cloneHandoffDiagnostic())}
            try require(queued,"Clone replaced an active workspace operation")
            let delegate=TurtleGitApplicationDelegate();delegate.repositoryModel=model
            try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Pending handoff lost Quit ownership")
            owner.close()
            try require(owner.model.pathCompletionPermissions.isEmpty && model.hasPendingRepositoryHandoff,"Closing Clone retained browsing grants or discarded the captured handoff")
            release?.resume();release=nil
            try await wait {!model.busy && !model.hasPendingRepositoryHandoff}
            try require(same(model.root,destination),"Real Clone handoff root=\(model.root?.path ?? "nil"), expected=\(destination.path), error=\(model.error ?? "none")")
            try check(model.bare==bare && model.branch=="main" && model.section==(bare ? .log:.status) && model.error==nil,"Real Clone completion lost root/bare mode or metadata",model:model,expected:destination)
            owner.close();model.closeRepository()
            // Actual Init uses the same captured completion boundary, including bare mode.
            model.open(source);try await wait {!model.busy && model.root != nil}
            let target=container.appendingPathComponent(bare ? "real-init-bare":"real-init")
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            model.handle(FinderRequest(action:.initialize,paths:[target]).url!)
            let initializer=NSApp.windows.compactMap {$0.delegate as? CreateRepositoryWindowController}.first {$0.model.folder==target}!
            defer {initializer.close()};initializer.model.executable=git;initializer.model.bare=bare;initializer.model.showSuccess={}
            model.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
            try await wait {release != nil}
            initializer.model.initialize();try await wait {initializer.model.completed && !initializer.model.busy}
            try check(model.busy && same(model.root,source) && model.hasPendingRepositoryHandoff,"Init replaced an active workspace operation",model:model,expected:source)
            initializer.model.acknowledgeSuccess()
            release?.resume();release=nil
            try await wait {!model.busy && same(model.root,target)}
            try check(model.bare==bare && model.error==nil && model.section==(bare ? .log:.status),"Real Init completion lost bare mode/section",model:model,expected:target)
            model.closeRepository();owner.close();initializer.close();model.finderWatches?.retire()
            try await wait {!model.hasPendingFinderServiceWork && model.finderWatches?.pendingOperations==0 && !model.hasPendingRepositoryHandoff}
        }
        print("Real Clone/Init normal and bare: completed while a captured operation owned busy, adopted afterward with authoritative metadata")
    }
    @MainActor static func competingOwners(container:URL,source:URL,completed:URL,linked:URL,git:URL,prefs:UserDefaults) async throws {
        let scopes=HandoffBookmarks(),(model,host)=try Self.workspace(container:container,git:git,prefs:prefs,scopes:scopes)
        defer {model.stopMonitoringForTermination();model.finderWatches?.retire();host.close()}
        model.open(source);try await wait {!model.busy && model.root != nil}
        let owner=try clone(model);defer {owner.close()}
        try await register(owner,model:model,root:completed,git:git,access:RepositoryAccessLease(url:completed,provider:scopes))
        func result(_ root:URL,_ output:String="Completed") {
            owner.model.onCloned(GitRepository(root:root,executable:git),RepositoryAccessLease(url:root,provider:scopes),nil,false,output)
        }
        var release:CheckedContinuation<Void,Never>?
        defer {release?.resume()}
        model.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
        try await wait {release != nil}
        result(completed,"Earlier completion");result(source,"Latest completion")
        try check(model.hasPendingRepositoryHandoff,"Multiple results duplicated pending ownership",model:model,expected:source)
        release?.resume();release=nil
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff && model.output=="Latest completion"}
        try check(same(model.root,source),"Earlier result replaced the latest completion",model:model,expected:source)
        // An accepted explicit Open/Close wins even before the scheduled handoff starts.
        result(completed);model.open(source)
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff}
        try check(same(model.root,source),"Scheduled completion overrode explicit Open",model:model,expected:source)
        result(completed);model.closeRepository()
        try await wait {!model.hasPendingRepositoryHandoff}
        try check(!scopes.active.isEmpty && owner.model.pathCompletionPermissions.contains{$0.contains(source)} && (scopes.active[source.path] ?? 0)>0,"Closing workspace discarded the still-open Clone dialog permission",model:model)
        try check(model.root==nil,"Scheduled completion reopened a closed repository",model:model)
        model.open(source);try await wait {!model.busy && model.root != nil}
        let index=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        let invalid=container.appendingPathComponent("invalid-result")
        try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        result(invalid)
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff && model.error != nil}
        try check(same(model.root,source) && (try? Data(contentsOf:source.appendingPathComponent(".git/index")))==index,"Failed completion failed to roll back workspace/index",model:model,expected:source)
        model.error=nil;result(completed,"Retry completed")
        try await wait {!model.busy && same(model.root,completed)}
        try check(model.error==nil && model.output=="Retry completed","Completion could not recover after failure",model:model,expected:completed)
        // Existing compound permissions are reused instead of prompting a second time.
        model.chooseRepositoryMetadataFolder={_,_ in throw Failure(description:"Retained metadata grant was ignored")}
        var compound:RepositoryAccessLease?=RepositoryAccessLease(url:linked,provider:scopes).retainingRelatedScopes([RepositoryAccessLease(url:source.appendingPathComponent(".git"),provider:scopes)])
        owner.model.onCloned(GitRepository(root:linked,executable:git),compound!,nil,false,"Compound result")
        try await wait {!model.busy && same(model.root,linked)}
        try check(model.error==nil,"Compound metadata adoption failed",model:model,expected:linked);compound=nil
        model.closeRepository()
        // Closing during a handoff's metadata prompt cancels it and ignores a late valid reply.
        model.open(source);try await wait {!model.busy && model.root != nil}
        var reply:CheckedContinuation<URL?,Error>?
        defer {reply?.resume(returning:nil)}
        model.chooseRepositoryMetadataFolder={_,_ in try await withCheckedThrowingContinuation {reply=$0}}
        result(linked);try await wait {reply != nil}
        let replacement=NSWindow(contentRect:host.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false);replacement.isReleasedWhenClosed=false
        defer {replacement.close()};model.workspaceWindow=replacement
        host.close();reply?.resume(returning:source.appendingPathComponent(".git"));reply=nil
        try await wait {!model.busy}
        try check(same(model.root,source) && model.error==nil,"Owner-close metadata reply adopted a late result",model:model,expected:source)
        result(completed)
        try check(!model.hasPendingRepositoryHandoff && same(model.root,source),"Closed initiating owner accepted a new result",model:model,expected:source)
        // A pending result is cancelled immediately when the initiating window closes.
        let (pending,pendingHost)=try Self.workspace(container:container,git:git,prefs:prefs)
        defer {pending.stopMonitoringForTermination();pending.finderWatches?.retire();pendingHost.close()}
        pending.open(source);try await wait {!pending.busy && pending.root != nil}
        let pendingClone=try clone(pending);defer {pendingClone.close()}
        try await register(pendingClone,model:pending,root:completed,git:git,access:RepositoryAccessLease(url:completed))
        pending.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
        try await wait {release != nil}
        var pendingAccess:RepositoryAccessLease?=RepositoryAccessLease(url:completed)
        weak var retainedPendingAccess=pendingAccess
        pendingClone.model.onCloned(GitRepository(root:completed,executable:git),pendingAccess!,nil,false,"Closed result")
        pendingAccess=nil
        try check(pending.hasPendingRepositoryHandoff && retainedPendingAccess != nil && pending.busy && same(pending.root,source),"Accepted queued result lost its captured grant or replaced the held owner",model:pending,expected:source)
        pendingHost.close();try await wait {!pending.hasPendingRepositoryHandoff}
        release?.resume();release=nil;try await wait {!pending.busy && !pending.hasPendingFinderServiceWork && retainedPendingAccess==nil}
        try check(same(pending.root,source),"Closed owner adopted a queued result",model:pending,expected:source)
        // Retirement drops pending work and rejects later completion callbacks.
        let (retired,retiredHost)=try Self.workspace(container:container,git:git,prefs:prefs)
        defer {retired.stopMonitoringForTermination();retired.finderWatches?.retire();retiredHost.close()}
        let retiredClone=try clone(retired);defer {retiredClone.close()}
        try await register(retiredClone,model:retired,root:completed,git:git,access:RepositoryAccessLease(url:completed))
        // Queue while the owner still admits results, then enter Quit before
        // the scheduled adoption can run. A result first delivered during Quit
        // is a different, deliberately refused action, never a queued intent.
        var quitAccess:RepositoryAccessLease?=RepositoryAccessLease(url:completed)
        weak var retainedQuitAccess=quitAccess
        retiredClone.model.onCloned(GitRepository(root:completed,executable:git),quitAccess!,nil,false,"Pending quit")
        quitAccess=nil
        try check(retired.hasPendingRepositoryHandoff && retired.root==nil && retainedQuitAccess != nil,"Accepted result did not retain queued ownership before Quit",model:retired)
        retired.confirmingQuit=true
        retiredClone.model.onCloned(GitRepository(root:source,executable:git),RepositoryAccessLease(url:source),nil,false,"Refused during quit")
        try check(retired.hasPendingRepositoryHandoff && retired.root==nil && !retired.busy && retainedQuitAccess != nil,"Suspended result lost ownership or Quit admitted a new result",model:retired)
        retired.stopMonitoringForTermination();retired.confirmingQuit=false
        retiredClone.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed),nil,false,"Late result")
        try check(!retired.hasPendingRepositoryHandoff && retired.root==nil && !retired.busy,"Retired workspace accepted a queued/late result",model:retired)
        pending.stopMonitoringForTermination();pending.finderWatches?.retire()
        retired.finderWatches?.retire()
        try await wait {retainedQuitAccess==nil && !pending.hasPendingFinderServiceWork && !retired.hasPendingFinderServiceWork && pending.finderWatches?.pendingOperations==0 && retired.finderWatches?.pendingOperations==0}
        owner.close();model.closeRepository();model.finderWatches?.retire();try await wait {scopes.active.isEmpty && !model.hasPendingFinderServiceWork && model.finderWatches?.pendingOperations==0}
        print("Competing owners: latest completion, explicit Open/Close, rollback/retry, compound metadata permission, pending/in-flight window close and retirement passed")
    }
    @MainActor static func transportBatch(container:URL,source:URL,completed:URL,linked:URL,git:URL,prefs:UserDefaults) async throws {
        let scopes=HandoffBookmarks(),(model,host)=try Self.workspace(container:container,git:git,prefs:prefs,scopes:scopes)
        defer {model.stopMonitoringForTermination();model.finderWatches?.retire();host.close()}
        let owner=try clone(model);defer {owner.close()}
        try await register(owner,model:model,root:completed,git:git,access:RepositoryAccessLease(url:completed,provider:scopes))
        var grants=0,reply:CheckedContinuation<URL?,Error>?,token:OperationCancellation?
        defer {reply?.resume(returning:nil)}
        model.commandLineRepositoryPermission={paths in grants += 1;return RepositoryAccessLease(url:paths[0],provider:scopes)}
        model.chooseRepositoryMetadataFolder={_,cancellation in token=cancellation;return try await withCheckedThrowingContinuation {reply=$0}}
        model.handleCommandLine(arguments:["--command=fetch","--path",linked.path,"--path",source.path],currentDirectory:source.path)
        try await wait {reply != nil}
        owner.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed,provider:scopes),nil,false,"Clone superseded batch")
        try check(token?.isCancelled==true,"Completed repository did not cancel batch preparation",model:model)
        reply?.resume(returning:source.appendingPathComponent(".git"));reply=nil
        try await wait {!model.busy && RepositoryModel.activeCommandFileOperations==0 && same(model.root,completed)}
        try check(grants==1 && !NSApp.windows.contains {$0.isVisible && $0.delegate is FetchWindowController} && model.error==nil,"Superseded batch opened transport forms or requested another root",model:model,expected:completed)
        model.closeRepository();model.finderWatches?.retire();try await wait {scopes.active.isEmpty && !model.hasPendingFinderServiceWork && model.finderWatches?.pendingOperations==0}
        print("Multi-root batch: captured Clone result cancels held metadata adoption, prevents the next root/form and releases both owners")
    }
    @MainActor static func main() async throws {
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.handoffQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden)
        defer {method_exchangeImplementations(original,hidden)}
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let source=container.appendingPathComponent("source"),linked=container.appendingPathComponent("linked"),completed=container.appendingPathComponent("completed")
        for root in [source,completed] {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Handoff QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        }
        let repository=GitRepository(root:source,executable:git)
        _ = try await repository.run(["worktree","add","-b","linked",linked.path])
        let suite="TurtleGit.Handoffs."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let scopes=HandoffBookmarks()
        let (workspace,host)=try Self.workspace(container:container,git:git,prefs:prefs,scopes:scopes)
        defer {workspace.stopMonitoringForTermination();workspace.finderWatches?.retire();host.close();NativeOwnedWindowCleanup.close(NSApp.windows)}
        workspace.activate(.clone)
        let clone=NSApp.windows.compactMap {$0.delegate as? CloneWindowController}.first!
        var reply:CheckedContinuation<URL?,Error>?
        workspace.chooseRepositoryMetadataFolder={_,_ in try await withCheckedThrowingContinuation {reply=$0}}
        defer {reply?.resume(returning:nil)}
        workspace.open(linked);try await wait {reply != nil}
        let cloned=GitRepository(root:completed,executable:git)
        var grant:RepositoryAccessLease?=RepositoryAccessLease(url:completed,provider:scopes)
        clone.model.onCloned(cloned,grant!,nil,false,"Clone completed")
        try require(!workspace.hasPendingRepositoryHandoff,"Active Clone result bypassed verified registration")
        clone.model.onVerifiedClone(cloned,grant!,nil,false,"Clone completed")
        reply?.resume(returning:source.appendingPathComponent(".git"));reply=nil
        try await wait {!workspace.busy && workspace.root?.resolvingSymlinksInPath().path==completed.resolvingSymlinksInPath().path}
        try check(workspace.branch=="main" && workspace.entries.isEmpty,"Completed Clone handoff did not refresh its own repository",model:workspace,expected:completed)
        try check(workspace.recentRepositories.contains{same(URL(fileURLWithPath:$0.lastKnownPath),completed)},"Clone adoption preceded its private registration receipt",model:workspace,expected:completed)
        clone.close();workspace.closeRepository();workspace.finderWatches?.retire();grant=nil
        try await wait {scopes.active.isEmpty && !workspace.hasPendingFinderServiceWork && workspace.finderWatches?.pendingOperations==0}
        print("Held Open + Clone completion: original busy stall repaired; fake grants released")
        try await completedOperations(container:container,source:source,git:git,prefs:prefs)
        try await competingOwners(container:container,source:source,completed:completed,linked:linked,git:git,prefs:prefs)
        try await transportBatch(container:container,source:source,completed:completed,linked:linked,git:git,prefs:prefs)
        try check(!workspace.hasPendingRepositoryHandoff && RepositoryModel.activeCommandFileOperations==0,"Handoff or command owners leaked",model:workspace)
        print("PASS: repository handoff family: held Open/Clone race; real Clone and Init normal/bare results during held operations; latest completion; explicit Open/Close; queued and in-flight owner closure; termination/late callbacks; rollback/retry; compound scopes; transport batch cancellation; private state and owned cleanup")
    }
}
