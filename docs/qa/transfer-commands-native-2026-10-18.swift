import AppKit
import TurtleGitCore

private final class TransferCommandGrant: RepositoryBookmarkProvider {
    let granted: Bool
    init(_ granted: Bool) { self.granted=granted }
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {granted}
    func stopAccessing(_ url:URL) {}
}
extension PrimaryCommandsVerification {
    @MainActor static func verifyTransferCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let root=container.appendingPathComponent("repository"),external=container.appendingPathComponent("external"),destination=root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:git)
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Transfer QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        for name in ["first","rename","guarded"] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repository.stage(["first","rename","guarded"]);_ = try await repository.commit(message:"base")
        let head=try await repository.rebaseCommit("HEAD"),suite="TurtleGit.TransferCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        try Data("index bytes\n".utf8).write(to:root.appendingPathComponent("first"));try await repository.stage(["first"])
        try Data("working bytes\n".utf8).write(to:root.appendingPathComponent("first"))
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
        workspace.fileCopySourceProvider=TransferCommandGrant(false)
        var moves:[FileMoveWindowController]=[],copies:[FileCopyWindowController]=[]
        workspace.movePresentation={controller in
            moves.append(controller)
            controller.model.chooseName={source,folder,_,token in try? await repository.prepareFileMove(source:source,to:folder,name:"renamed",cancellation:token)}
        }
        var authorizations=0,hold=false,reply:CheckedContinuation<[RepositoryAccessLease]?,Never>?
        workspace.copyPresentation={controller in
            copies.append(controller);controller.model.requireSourceScopes=true
            controller.model.collision={_ in .keep};controller.model.repositoryChoice={_ in .deleteMetadata}
            controller.model.authorizeSources={sources in
                authorizations += 1
                if hold {return await withCheckedContinuation {reply=$0}}
                return sources.map {RepositoryAccessLease(url:$0,provider:TransferCommandGrant(true))}
            }
        }
        defer {moves.forEach {$0.close()};copies.forEach {$0.close()};workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        @MainActor func invoke(_ args:[String]) {workspace.handleCommandLine(arguments:args,currentDirectory:root.path)}
        invoke(["--command=dropmove","--path",root.appendingPathComponent("first").path,"--droptarget",destination.path])
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork && moves.first?.model.progress==true && moves.first?.model.busy==false}
        let moved=moves[0],adopted=try workspace.gitConfigurationContext()
        try require(workspace.root?.path==root.path && moved.model.moved==1 && moved.model.preferences === prefs && moved.model.repository === adopted.repository && moved.model.access === adopted.access,"Drop Move did not adopt destination, start or retain preferences")
        let staged=try await repository.run(["show",":dest/first"]).stdout
        try require(staged==Data("index bytes\n".utf8) && String(contentsOf:destination.appendingPathComponent("first"))=="working bytes\n" && !FileManager.default.fileExists(atPath:root.appendingPathComponent("first").path),"Automatic Move lost separate staged/working bytes")
        moved.close()
        invoke(["/command:dropmove","--path",root.appendingPathComponent("rename").path,"--droptarget",destination.path,"--rename"])
        try await wait {!workspace.busy && moves.count==2 && moves[1].model.progress && !moves[1].model.busy}
        try require(moves[1].model.renameFirst && moves[1].model.moved==1 && FileManager.default.fileExists(atPath:destination.appendingPathComponent("renamed").path),"Move/Rename did not use the captured name plan")
        moves[1].close()
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        for (source,target) in [(external.appendingPathComponent("foreign"),destination),(root.appendingPathComponent("guarded"),root.appendingPathComponent(".git")),(root.appendingPathComponent("guarded"),root.appendingPathComponent("guarded"))] {
            workspace.error=nil
            invoke(["--command=dropmove","--path",source.path,"--droptarget",target.path])
            try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
            try require(workspace.error != nil && moves.count==2 && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Invalid/cross-worktree move reached native execution")
        }
        let keep=external.appendingPathComponent("keep"),nested=external.appendingPathComponent("nested")
        try Data("external source\n".utf8).write(to:keep);try Data("retained target\n".utf8).write(to:destination.appendingPathComponent("keep"))
        try FileManager.default.createDirectory(at:nested.appendingPathComponent(".git"),withIntermediateDirectories:true)
        try Data("original metadata".utf8).write(to:nested.appendingPathComponent(".git/config"))
        try Data("nested body\n".utf8).write(to:nested.appendingPathComponent("body"))
        let paths=container.appendingPathComponent("copy-paths")
        try Data((keep.path+"\0"+nested.path+"\0"+external.appendingPathComponent(".git/config").path+"\0"+destination.path+"\0").utf8).write(to:paths)
        workspace.commandLinePathListPermission={file,_ in RepositoryAccessLease(url:file.deletingLastPathComponent())}
        invoke(["--command=dropcopyadd","--droptarget",destination.path,"--pathfile",paths.path,"--pathfile0","--deletepathfile"])
        try await wait {!workspace.busy && copies.first?.model.progress==true && copies.first?.model.busy==false && FileCopyWindowModel.activeOperations==0}
        let copied=copies[0],kept=try await repository.run(["show",":dest/keep"]).stdout,nestedBytes=try await repository.run(["show",":dest/nested/body"]).stdout
        try require(!copied.model.failed && copied.model.kept==1 && copied.model.copied==1 && copied.model.preferences === prefs && !copied.model.paste && authorizations==1,"Copy/Add command lost batch policy, permissions or preferences")
        try require(kept==Data("retained target\n".utf8) && nestedBytes==Data("nested body\n".utf8) && (try String(contentsOf:keep))=="external source\n" && FileManager.default.fileExists(atPath:nested.appendingPathComponent(".git/config").path) && !FileManager.default.fileExists(atPath:destination.appendingPathComponent("nested/.git").path),"Copy Keep or copied-metadata choice changed original source or staged incorrect bytes")
        try require(!FileManager.default.fileExists(atPath:paths.path) && copied.model.sources.count==2,"Path-file deletion/admin/destination-self filtering failed")
        copied.close()
        // A held source grant owns the operation until it actually returns.
        let late=external.appendingPathComponent("late");try Data("late body".utf8).write(to:late)
        hold=true;workspace.error=nil
        invoke(["--command=dropcopyadd","--path",late.path,"--droptarget",destination.path])
        try await wait {copies.count==2 && reply != nil}
        let closing=copies[1];closing.close()
        try require(FileCopyWindowModel.activeOperations>0,"Forced close released a pending source grant before actual return")
        reply?.resume(returning:[RepositoryAccessLease(url:late,provider:TransferCommandGrant(true))]);reply=nil
        try await wait {FileCopyWindowModel.activeOperations==0 && !workspace.hasPendingRepositoryWork}
        try require(!FileManager.default.fileExists(atPath:destination.appendingPathComponent("late").path),"Late grant copied after retirement")
        // A receiving window closed before destination preflight cannot hand off.
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;workspace.workspaceWindow=owner
        invoke(["--command=dropmove","--path",root.appendingPathComponent("guarded").path,"--droptarget",destination.path]);owner.close()
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
        try require(moves.count==2 && FileManager.default.fileExists(atPath:root.appendingPathComponent("guarded").path),"Closed receiving owner started a transfer")
        workspace.workspaceWindow=nil
        let finalHead=try await repository.rebaseCommit("HEAD")
        try require(finalHead.hash==head.hash && FileMoveWindowModel.activeOperations==0 && FileCopyWindowModel.activeOperations==0,"Transfer command committed or leaked operation owners")
        print("PASS: Transfer command family: destination adoption and automatic Move/Copy/Add; Move/Rename name plan; distinct index/working bytes; invalid/cross-worktree/admin targets refused; authorized external copy, source batch policy, Keep and nested metadata Delete; path-file deletion and admin/self filtering; owning preferences; late source grant and receiving-owner close fences; HEAD unchanged; owned windows closed. Physical Finder menus and real scoped picker issuance not exercised.")
    }
}
