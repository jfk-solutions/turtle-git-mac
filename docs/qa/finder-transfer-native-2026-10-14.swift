import AppKit
import TurtleGitCore
@main struct FinderTransferVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func wait(_ condition:()->Bool)async throws{for _ in 0..<2500{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Finder transfer timeout")}
    final class Granted:RepositoryBookmarkProvider {
        let granted:Bool;init(_ granted:Bool=true){self.granted=granted}
        func create(for url:URL)throws->Data{Data()};func resolve(_ data:Data)throws->ResolvedBookmark{throw Failure(description:"Unused bookmark resolution")}
        func startAccessing(_ url:URL)->Bool{granted};func stopAccessing(_ url:URL){}
    }
    @MainActor static func main()async{do{try await verify()}catch{fputs("Finder transfer failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Finder Transfer"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let folder=root.appendingPathComponent("target 雪",isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let tracked=root.appendingPathComponent("file 雪\n.txt");try Data("tracked".utf8).write(to:tracked);try await repo.stage([tracked.lastPathComponent]);_ = try await repo.commit(message:"baseline")
        let outside=root.deletingLastPathComponent().appendingPathComponent("FinderSource-"+UUID().uuidString);try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:outside)}
        let source=outside.appendingPathComponent("external 雪\n.txt");try Data("external".utf8).write(to:source)
        let before=try await repo.run(["ls-files","--stage","-z"]).stdout
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false});defer{workspace.closeRepository()}
        workspace.open(root);try await wait{!workspace.busy && workspace.root != nil};try require(workspace.error==nil,"Initial workspace adoption failed")
        var routed:[FinderRequest]=[]
        workspace.finderTransferPresentation={request,repository,lease in
            routed.append(request)
            precondition(repository.root.path==workspace.root?.path && lease.contains(folder))
        }
        for (action,sources) in [(RepositoryAction.pasteCopy,[source]),(.pasteMove,[tracked])]{let request=FinderRequest(action:action,paths:[folder],sources:sources);workspace.handle(request.url!);try await wait{!workspace.busy && routed.last?.action==action};try require(routed.last?.paths.map(\.path)==[folder.path] && routed.last?.sources.map(\.path)==sources.map(\.path),"Captured transfer route changed folder or sources")}
        let after=try await repo.run(["ls-files","--stage","-z"]).stdout;try require(before==after,"Request delivery mutated index")
        let suite="TurtleGit.FinderTransfer."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite)};prefs.set(false,forKey:"ConfirmKillProcess")
        ProgressActionLog.install(store:ActionLogStore(storageURL:outside.appendingPathComponent("actions.log")),preferences:prefs)
        let controller=FileCopyWindowController(repository:repo,access:nil,sources:[source],folder:folder,paste:true,sourceProvider:Granted(false),preferences:prefs);defer{controller.close()};controller.model.requireSourceScopes=true
        var asked:[URL]=[];controller.model.authorizeSources={urls in asked=urls;return urls.map{RepositoryAccessLease(url:$0,provider:Granted())}}
        controller.model.run();try await wait{!controller.model.busy};let added=try await repo.run(["show",":target 雪/"+source.lastPathComponent]).text
        try require(asked.map(\.path)==[source.path] && !controller.model.failed && controller.model.copied==1 && added=="external","Authorized copy mismatch: asked=\(asked.map(\.path)) sources=\(controller.model.sources.map(\.path)) copied=\(controller.model.copied) failed=\(controller.model.failed) cancelled=\(controller.model.cancelled) added=\(added.debugDescription) output=\(controller.model.output)");controller.close()
        // Held authorization keeps Quit blocked after retirement; late grant cannot copy.
        let lateSource=outside.appendingPathComponent("late.txt");try Data("late".utf8).write(to:lateSource)
        let late=FileCopyWindowController(repository:repo,access:nil,sources:[lateSource],folder:folder,paste:true,sourceProvider:Granted(false),preferences:prefs);late.model.requireSourceScopes=true
        var release:(([RepositoryAccessLease]?)->Void)?;late.model.authorizeSources={_ in await withCheckedContinuation{c in release={c.resume(returning:$0)}}};late.model.run();try await wait{release != nil}
        late.close();try require(FileCopyWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retirement lost authorization lifetime")
        release?([RepositoryAccessLease(url:lateSource,provider:Granted())]);try await wait{FileCopyWindowModel.activeOperations==0};try require(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("late.txt").path),"Late grant copied after retirement")
        let moving=FileMoveWindowController(repository:repo,access:nil,paths:[],preferences:prefs);defer{moving.close()};moving.model.loadClipboard([tracked],destination:folder);try await wait{!moving.model.busy};try require(moving.model.folder.path==folder.path && moving.model.paths==[tracked.lastPathComponent],"Paste Move defaulted to root instead of Finder destination");moving.close()
        print("Finder transfers: real request decode/adoption to injected native route retains destination/sources without mutation; source authorization adapter enables actual copied/staged bytes; retired held authorization remains counted for Quit and rejects late grant; Move retains captured folder; owned controllers closed. Physical Finder and signed grants unproven.")
    }
}
