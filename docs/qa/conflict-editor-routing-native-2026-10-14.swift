import AppKit
import TurtleGitCore

@main struct ConflictEditorRoutingVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Conflict editor routing timeout at line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Conflict editor routing failed: \(error)\n",stderr);exit(1) } }
    static func png(_ red: UInt8) -> Data {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<2 { for x in 0..<2 { let offset=y*bitmap.bytesPerRow+x*4;bitmap.bitmapData![offset]=red;bitmap.bitmapData![offset+1]=0;bitmap.bitmapData![offset+2]=0;bitmap.bitmapData![offset+3]=255 } }
        return bitmap.representation(using:.png,properties:[:])!
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),path="-conflict 雪\n[*].dat"
        func fixture(_ name:String,image:Bool=false,deleted:Bool=false) async throws -> GitRepository {
            let folder=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Routing QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            let file=folder.appendingPathComponent(path),bytes=image ? [png(40),png(100),png(200)]:[Data("base\n".utf8),Data("mine\n".utf8),Data("theirs\n".utf8)]
            try bytes[0].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
            _ = try await repo.run(["switch","-c","side"]);try bytes[2].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"theirs")
            _ = try await repo.run(["switch","main"])
            if deleted { _ = try await repo.run(["rm","--",path]) } else { try bytes[1].write(to:file);try await repo.stage([path]) }
            _ = try await repo.commit(message:"mine")
            do { _ = try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflict") } catch is GitFailure {}
            return repo
        }
        @MainActor func owner() -> NSWindow { let window=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.orderFront(nil);return window }
        let text=try await fixture("text"),image=try await fixture("image",image:true),deleted=try await fixture("delete",deleted:true)
        let module="module",hash=try await text.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let records=(1...3).map { "160000 \(hash) \($0)\t\(module)\0" }.joined();_ = try await text.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        let suite="TurtleGit.EditorRouting."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.fileComparisonPreferences=prefs
        let window=owner();defer { window.close();workspace.cancelConflictEditorPreparations() }
        var routes:[(RepositoryModel.ConflictEditorRoute,String,String)]=[],imageBytes:Data?,externalOwners:[NSWindow?]=[]
        workspace.openExternalConflict={_,_,_,_,captured,_,_,_ in externalOwners.append(captured);return false}
        workspace.conflictEditorPresentation={route,repo,path,document in routes.append((route,repo.root.path,path));if route == .image { imageBytes=document?.contents[.mine] };precondition(window.attachedSheet == nil)}
        let baselines=try await [text,image,deleted].asyncBaseline()
        for (repo,selected,expected) in [(text,path,RepositoryModel.ConflictEditorRoute.text),(image,path,.image),(deleted,path,.deleteModify),(text,module,.submodule)] {
            workspace.showConflictEditor(repository:repo,access:nil,path:selected,owner:window)
            try await wait { workspace.conflictEditorPreparationCount == 0 && FileListComparisonSession.activeOperations == 0 }
            try require(workspace.error == nil && routes.last?.0 == expected && routes.last?.1 == repo.root.path && routes.last?.2 == selected,"Routing changed kind/root/literal path")
        }
        try require(imageBytes == png(100) && externalOwners.count == 2 && externalOwners.allSatisfy({$0 === window}),"Image stages/external owner capture changed")
        for (repo,head,index,file) in baselines { try require(try await repo.run(["rev-parse","HEAD"]).stdout == head && Data(contentsOf:repo.root.appendingPathComponent(".git/index")) == index && Data(contentsOf:repo.root.appendingPathComponent(path)) == file,"Routing changed repository state") }
        // Owner closure during a noncooperative entry read retains Quit lifetime,
        // suppresses all routing and settles only after that same reader returns.
        var release:(()->Void)?,reads=0
        workspace.readConflictEditorEntry={repo,path,token in reads += 1;let entry=try await repo.conflictEditorEntry(path:path,cancellation:token);await withCheckedContinuation { continuation in release={continuation.resume()} };return entry}
        let closing=owner(),beforeRoutes=routes.count
        workspace.showConflictEditor(repository:text,access:nil,path:path,owner:closing);workspace.showConflictEditor(repository:text,access:nil,path:path,owner:closing)
        try await wait { release != nil };try require(reads == 1 && workspace.conflictEditorPreparationCount == 1,"Duplicate preparation was not coalesced")
        closing.close();try require(FileListComparisonSession.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owner close dropped live read lifetime")
        release?();try await wait { workspace.conflictEditorPreparationCount == 0 && FileListComparisonSession.activeOperations == 0 }
        try require(routes.count == beforeRoutes && workspace.error == nil,"Retired entry read opened editor/error")
        workspace.readConflictEditorEntry=nil
        // Real stage-blob read cancellation must kill/reap its Git group before
        // image inspection can publish or text fallback can open.
        let helper=text.root.appendingPathComponent("gated-git"),marker=text.root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = cat-file ] && [ "$5" = blob ];then
          : > "$3/ready"
          while :; do /bin/sleep 0.05; done
        fi
        exec "$TG_ROUTING_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_ROUTING_GIT",git.path,1);defer { unsetenv("TG_ROUTING_GIT") }
        let wrapped=GitRepository(root:text.root,executable:helper),live=owner();defer { live.close() }
        workspace.showConflictEditor(repository:wrapped,access:nil,path:path,owner:live);try await wait { FileManager.default.fileExists(atPath:marker.path) }
        workspace.cancelConflictEditorPreparation(repository:wrapped,path:path);try await wait { workspace.conflictEditorPreparationCount == 0 && FileListComparisonSession.activeOperations == 0 }
        try require(routes.count == beforeRoutes && workspace.error == nil,"Cancelled blob read fell through to editor/error")
        // An external launch callback returning after owner close keeps its
        // already-launched tool inputs, but cannot mark resolved or fall back.
        var settings=MergeToolPreferences();settings.program.enabled=true;settings.program.applicationPath="/Applications/Preview.app";settings.blockWhileMerging=false
        var launched=false,prepared=false,arguments:[String]=[],sdkReply:((NSRunningApplication)->Void)?
        let sdkOwner=owner(),token=OperationCancellation(),entry=try await text.conflictEditorEntry(path:path)
        let opening=Task { try await MergeToolApplication.open(repository:text,access:nil,path:path,alternate:false,owner:sdkOwner,cancellation:token,onPrepared:{prepared=true},preferences:settings,expectedEntry:entry,launch:{_,configuration in
            launched=true;arguments=configuration.arguments
            return await withCheckedContinuation { continuation in sdkReply={continuation.resume(returning:$0)} }
        }) }
        try await wait { sdkReply != nil };try require(prepared && launched && arguments.count == 4 && MergeToolApplication.activeRequests > 0,"External launch omitted prepared arguments/ownership")
        let folder=URL(fileURLWithPath:arguments[0]).deletingLastPathComponent()
        try require(try Data(contentsOf:URL(fileURLWithPath:arguments[0])) == Data("base\n".utf8) && Data(contentsOf:URL(fileURLWithPath:arguments[1])) == Data("theirs\n".utf8) && Data(contentsOf:URL(fileURLWithPath:arguments[2])) == Data("mine\n".utf8) && arguments[3] == text.root.appendingPathComponent(path).path,"External source files/working result mismatch")
        sdkOwner.close();sdkReply?(.current);let result=try await opening.value
        try require(result && token.isCancelled && MergeToolApplication.activeRequests == 0 && FileManager.default.fileExists(atPath:folder.path),"Late SDK completion dropped live inputs or retained work")
        MergeToolApplication.discardAll();try require(!FileManager.default.fileExists(atPath:folder.path),"Explicit retained preview cleanup failed")
        // Cooperative tokens also settle a tool wait without a Task cancellation.
        let waitToken=OperationCancellation(),session=ExternalMergeSession(owner:nil,cancellation:waitToken);var stopped=0,finish:(()->Void)?
        let waiting=Task { await session.wait { reply in finish=reply;return { stopped += 1 } } }
        try await wait { finish != nil };waitToken.cancel();let waited=await waiting.value;finish?()
        try require(!waited && session.retired && stopped == 1,"Token cancellation did not settle once-only tool observation")
        print("Conflict editor routing: all four real kinds, exact image stage/owner/path capture, unchanged baselines, duplicate/retired reads, actual blob process cancellation, external SDK late-reply input retention and token-only tool wait cleanup passed. No external app launched or killed; owned windows closed.")
    }
}

private extension Array where Element == GitRepository {
    func asyncBaseline() async throws -> [(GitRepository,Data,Data,Data)] {
        var result:[(GitRepository,Data,Data,Data)]=[]
        for repo in self { result.append((repo,try await repo.run(["rev-parse","HEAD"]).stdout,try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),try Data(contentsOf:repo.root.appendingPathComponent("-conflict 雪\n[*].dat")))) };return result
    }
}
