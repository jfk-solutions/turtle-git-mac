import AppKit
import TurtleGitCore

private final class HandoffBookmarks: RepositoryBookmarkProvider {
    var active: [String:Int] = [:]
    func create(for url:URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data:Data) throws -> ResolvedBookmark { .init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false) }
    func startAccessing(_ url:URL) -> Bool { active[url.path,default:0] += 1;return true }
    func stopAccessing(_ url:URL) { active[url.path,default:0] -= 1;if active[url.path]==0 {active.removeValue(forKey:url.path)} }
}

@main struct RepositoryHandoffsVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Repository handoff did not settle at \(line)")
    }
    @MainActor private static func workspace(container:URL,git:URL,prefs:UserDefaults,scopes:HandoffBookmarks? = nil) -> (RepositoryModel,NSWindow) {
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks-"+UUID().uuidString+".json")))
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
    @MainActor static func completedOperations(container:URL,source:URL,git:URL,prefs:UserDefaults) async throws {
        for bare in [false,true] {
            let (model,host)=workspace(container:container,git:git,prefs:prefs)
            defer {model.stopMonitoringForTermination();host.close()}
            model.open(source);try await wait {!model.busy && model.root != nil}
            let owner=try clone(model);defer {owner.close()}
            owner.model.onProgress=nil
            let destination=container.appendingPathComponent(bare ? "real-clone-bare":"real-clone")
            owner.model.configureLaunch(source:source.path,exactPath:true);owner.model.directory=destination.path;owner.model.bare=bare;owner.model.recursive=false
            var release:CheckedContinuation<Void,Never>?
            defer {release?.resume()}
            model.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
            try await wait {release != nil}
            owner.model.clone();try await wait {owner.model.completed != nil && !owner.model.activeOperation}
            try require(model.busy && same(model.root,source) && model.hasPendingRepositoryHandoff,"Clone replaced an active workspace operation")
            let delegate=TurtleGitApplicationDelegate();delegate.repositoryModel=model
            try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Pending handoff lost Quit ownership")
            owner.close()
            try require(owner.model.pathCompletionPermissions.isEmpty && model.hasPendingRepositoryHandoff,"Closing Clone retained browsing grants or discarded the captured handoff")
            release?.resume();release=nil
            try await wait {!model.busy && !model.hasPendingRepositoryHandoff}
            try require(same(model.root,destination),"Real Clone handoff root=\(model.root?.path ?? "nil"), expected=\(destination.path), error=\(model.error ?? "none")")
            try require(model.bare==bare && model.branch=="main" && model.section==(bare ? .log:.status) && model.error==nil,"Real Clone completion lost root/bare mode or metadata")
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
            try require(model.busy && same(model.root,source) && model.hasPendingRepositoryHandoff,"Init replaced an active workspace operation")
            initializer.model.acknowledgeSuccess()
            release?.resume();release=nil
            try await wait {!model.busy && same(model.root,target)}
            try require(model.bare==bare && model.error==nil && model.section==(bare ? .log:.status),"Real Init completion lost bare mode/section")
            model.closeRepository()
        }
        print("Real Clone/Init normal and bare: completed while a captured operation owned busy, adopted afterward with authoritative metadata")
    }
    @MainActor static func competingOwners(container:URL,source:URL,completed:URL,linked:URL,git:URL,prefs:UserDefaults) async throws {
        let scopes=HandoffBookmarks(),(model,host)=workspace(container:container,git:git,prefs:prefs,scopes:scopes)
        defer {model.stopMonitoringForTermination();host.close()}
        model.open(source);try await wait {!model.busy && model.root != nil}
        let owner=try clone(model);defer {owner.close()}
        func result(_ root:URL,_ output:String="Completed") {
            owner.model.onCloned(GitRepository(root:root,executable:git),RepositoryAccessLease(url:root,provider:scopes),nil,false,output)
        }
        var release:CheckedContinuation<Void,Never>?
        defer {release?.resume()}
        model.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
        try await wait {release != nil}
        result(completed,"Earlier completion");result(source,"Latest completion")
        try require(model.hasPendingRepositoryHandoff,"Multiple results duplicated pending ownership")
        release?.resume();release=nil
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff && model.output=="Latest completion"}
        try require(same(model.root,source),"Earlier result replaced the latest completion")
        // An accepted explicit Open/Close wins even before the scheduled handoff starts.
        result(completed);model.open(source)
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff}
        try require(same(model.root,source),"Scheduled completion overrode explicit Open")
        result(completed);model.closeRepository()
        try await wait {!model.hasPendingRepositoryHandoff}
        try require(!scopes.active.isEmpty,"Closing workspace discarded the still-open Clone dialog permission")
        try require(model.root==nil,"Scheduled completion reopened a closed repository")
        model.open(source);try await wait {!model.busy && model.root != nil}
        let index=try Data(contentsOf:source.appendingPathComponent(".git/index"))
        let invalid=container.appendingPathComponent("invalid-result")
        try FileManager.default.createDirectory(at:invalid,withIntermediateDirectories:true)
        result(invalid)
        try await wait {!model.busy && !model.hasPendingRepositoryHandoff && model.error != nil}
        try require(same(model.root,source) && (try? Data(contentsOf:source.appendingPathComponent(".git/index")))==index,"Failed completion failed to roll back workspace/index")
        model.error=nil;result(completed,"Retry completed")
        try await wait {!model.busy && same(model.root,completed)}
        try require(model.error==nil && model.output=="Retry completed","Completion could not recover after failure")
        // Existing compound permissions are reused instead of prompting a second time.
        model.chooseRepositoryMetadataFolder={_,_ in throw Failure(description:"Retained metadata grant was ignored")}
        var compound:RepositoryAccessLease?=RepositoryAccessLease(url:linked,provider:scopes).retainingRelatedScopes([RepositoryAccessLease(url:source.appendingPathComponent(".git"),provider:scopes)])
        owner.model.onCloned(GitRepository(root:linked,executable:git),compound!,nil,false,"Compound result")
        try await wait {!model.busy && same(model.root,linked)}
        try require(model.error==nil,"Compound metadata adoption failed");compound=nil
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
        try require(same(model.root,source) && model.error==nil,"Owner-close metadata reply adopted a late result")
        result(completed)
        try require(!model.hasPendingRepositoryHandoff && same(model.root,source),"Closed initiating owner accepted a new result")
        // A pending result is cancelled immediately when the initiating window closes.
        let (pending,pendingHost)=workspace(container:container,git:git,prefs:prefs)
        defer {pending.stopMonitoringForTermination();pendingHost.close()}
        pending.open(source);try await wait {!pending.busy && pending.root != nil}
        let pendingClone=try clone(pending);defer {pendingClone.close()}
        pending.perform {repository in await withCheckedContinuation {release=$0};return try await repository.run(["rev-parse","HEAD"]).text}
        try await wait {release != nil}
        pendingClone.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed),nil,false,"Closed result")
        pendingHost.close();try await wait {!pending.hasPendingRepositoryHandoff}
        release?.resume();release=nil;try await wait {!pending.busy}
        try require(same(pending.root,source),"Closed owner adopted a queued result")
        // Retirement drops pending work and rejects later completion callbacks.
        let (retired,retiredHost)=workspace(container:container,git:git,prefs:prefs)
        defer {retired.stopMonitoringForTermination();retiredHost.close()}
        let retiredClone=try clone(retired);defer {retiredClone.close()}
        retired.confirmingQuit=true
        retiredClone.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed),nil,false,"Pending quit")
        try require(retired.hasPendingRepositoryHandoff,"Suspended result lost ownership")
        retired.stopMonitoringForTermination();retired.confirmingQuit=false
        retiredClone.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed),nil,false,"Late result")
        try require(!retired.hasPendingRepositoryHandoff && retired.root==nil && !retired.busy,"Retired workspace accepted a queued/late result")
        owner.close();model.closeRepository();try await wait {scopes.active.isEmpty}
        print("Competing owners: latest completion, explicit Open/Close, rollback/retry, compound metadata permission, pending/in-flight window close and retirement passed")
    }
    @MainActor static func transportBatch(container:URL,source:URL,completed:URL,linked:URL,git:URL,prefs:UserDefaults) async throws {
        let scopes=HandoffBookmarks(),(model,host)=workspace(container:container,git:git,prefs:prefs,scopes:scopes)
        defer {model.stopMonitoringForTermination();host.close()}
        let owner=try clone(model);defer {owner.close()}
        var grants=0,reply:CheckedContinuation<URL?,Error>?,token:OperationCancellation?
        defer {reply?.resume(returning:nil)}
        model.commandLineRepositoryPermission={paths in grants += 1;return RepositoryAccessLease(url:paths[0],provider:scopes)}
        model.chooseRepositoryMetadataFolder={_,cancellation in token=cancellation;return try await withCheckedThrowingContinuation {reply=$0}}
        model.handleCommandLine(arguments:["--command=fetch","--path",linked.path,"--path",source.path],currentDirectory:source.path)
        try await wait {reply != nil}
        owner.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed,provider:scopes),nil,false,"Clone superseded batch")
        try require(token?.isCancelled==true,"Completed repository did not cancel batch preparation")
        reply?.resume(returning:source.appendingPathComponent(".git"));reply=nil
        try await wait {!model.busy && RepositoryModel.activeCommandFileOperations==0 && same(model.root,completed)}
        try require(grants==1 && !NSApp.windows.contains {$0.isVisible && $0.delegate is FetchWindowController} && model.error==nil,"Superseded batch opened transport forms or requested another root")
        model.closeRepository();try await wait {scopes.active.isEmpty}
        print("Multi-root batch: captured Clone result cancels held metadata adoption, prevents the next root/form and releases both owners")
    }
    @MainActor static func main() async throws {
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
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=true;workspace.repositoryBookmarkProvider=scopes;workspace.fileComparisonPreferences=prefs;workspace.creationClipboardText={nil};workspace.notifyFinder={}
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;workspace.workspaceWindow=host
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        workspace.activate(.clone)
        let clone=NSApp.windows.compactMap {$0.delegate as? CloneWindowController}.first!
        var reply:CheckedContinuation<URL?,Error>?
        workspace.chooseRepositoryMetadataFolder={_,_ in try await withCheckedThrowingContinuation {reply=$0}}
        defer {reply?.resume(returning:nil)}
        workspace.open(linked);try await wait {reply != nil}
        clone.model.onCloned(GitRepository(root:completed,executable:git),RepositoryAccessLease(url:completed,provider:scopes),nil,false,"Clone completed")
        reply?.resume(returning:source.appendingPathComponent(".git"));reply=nil
        try await wait {!workspace.busy && workspace.root?.resolvingSymlinksInPath().path==completed.resolvingSymlinksInPath().path}
        try require(workspace.branch=="main" && workspace.entries.isEmpty,"Completed Clone handoff did not refresh its own repository")
        clone.close();workspace.closeRepository()
        try await wait {scopes.active.isEmpty}
        print("Held Open + Clone completion: original busy stall repaired; fake grants released")
        try await completedOperations(container:container,source:source,git:git,prefs:prefs)
        try await competingOwners(container:container,source:source,completed:completed,linked:linked,git:git,prefs:prefs)
        try await transportBatch(container:container,source:source,completed:completed,linked:linked,git:git,prefs:prefs)
        try require(!workspace.hasPendingRepositoryHandoff && RepositoryModel.activeCommandFileOperations==0,"Handoff or command owners leaked")
        print("PASS: repository handoff family: held Open/Clone race; real Clone and Init normal/bare results during held operations; latest completion; explicit Open/Close; queued and in-flight owner closure; termination/late callbacks; rollback/retry; compound scopes; transport batch cancellation; private state and owned cleanup")
    }
}
