import AppKit
import Darwin
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyConflictCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),path="-conflict 雪\n[*].dat"
        func png(_ red:UInt8)->Data {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
            for y in 0..<2 {for x in 0..<2 {let offset=y*bitmap.bytesPerRow+x*4;bitmap.bitmapData![offset]=red;bitmap.bitmapData![offset+1]=0;bitmap.bitmapData![offset+2]=0;bitmap.bitmapData![offset+3]=255}}
            return bitmap.representation(using:.png,properties:[:])!
        }
        @MainActor func fixture(_ name:String,image:Bool=false,deleted:Bool=false) async throws->GitRepository {
            let folder=container.appendingPathComponent(name),filePath=image ? path+".png":path
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repository=GitRepository(root:folder,executable:git);_ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Conflict command QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
            let file=folder.appendingPathComponent(filePath),data=image ? [png(40),png(100),png(200)]:[Data("base\n".utf8),Data("mine\n".utf8),Data("theirs\n".utf8)]
            try data[0].write(to:file);try await repository.stage([filePath]);_ = try await repository.commit(message:"base")
            _ = try await repository.run(["switch","-c","side"]);try data[2].write(to:file);try await repository.stage([filePath]);_ = try await repository.commit(message:"theirs")
            _ = try await repository.run(["switch","main"])
            if deleted {_ = try await repository.run(["rm","--",filePath])} else {try data[1].write(to:file);try await repository.stage([filePath])}
            _ = try await repository.commit(message:"mine")
            do {_ = try await repository.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflict")} catch is GitFailure {}
            return repository
        }
        let text=try await fixture("text"),image=try await fixture("image",image:true),deleted=try await fixture("delete",deleted:true)
        let hash=try await text.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let module="module",records=(1...3).map {"160000 \(hash) \($0)\t\(module)\0"}.joined()
        _ = try await text.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        var baselines:[(GitRepository,Data,Data)]=[]
        for repository in [text,image,deleted] {baselines.append((repository,try await repository.run(["rev-parse","HEAD"]).stdout,try Data(contentsOf:repository.root.appendingPathComponent(".git/index"))))}
        let suite="TurtleGit.ConflictCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,foreignSuite=suite+".foreign",foreign=UserDefaults(suiteName:foreignSuite)!
        defer {prefs.removePersistentDomain(forName:suite);foreign.removePersistentDomain(forName:foreignSuite)}
        prefs.set(true,forKey:"ConflictDontGuessBranchNames");foreign.set(false,forKey:"ConflictDontGuessBranchNames")
        var tools=MergeToolPreferences();tools.blockWhileMerging=true;try tools.save(to:prefs)
        var other=MergeToolPreferences();other.blockWhileMerging=false;try other.save(to:foreign)
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:400,height:220),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.workspaceWindow=owner;workspace.fileComparisonPreferences=prefs
        workspace.commandLineRepositoryPermission={_ in workspace.fileComparisonPreferences=foreign;return RepositoryAccessLease(url:container)}
        var windows:[NSWindowController]=[],external:[(Bool,NSWindow?,Bool)]=[]
        workspace.conflictWindowPresentation={controller in if !windows.contains(where:{$0 === controller}) {windows.append(controller)};controller.window?.alphaValue=0;controller.showWindow(nil)}
        workspace.openExternalConflict={_,_,_,alternate,window,_,_,_,settings in external.append((alternate,window,settings.blockWhileMerging));return false}
        workspace.readConflictEditorEntry={repository,path,token in let entry=try await repository.conflictEditorEntry(path:path,cancellation:token);workspace.fileComparisonPreferences=foreign;return entry}
        defer {workspace.cancelConflictEditorPreparations();windows.forEach {$0.window?.close()};owner.close();workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        @MainActor func invoke(_ repository:GitRepository,_ file:String,alternate:Bool=false) {
            workspace.fileComparisonPreferences=prefs;workspace.error=nil
            let args=["--command=conflicteditor","--path",repository.root.appendingPathComponent(file).path]+(alternate ? ["--alternative"]:[])
            ComparisonToolInvocation.$alternate.withValue(!alternate) {workspace.handleCommandLine(arguments:args,currentDirectory:container.path)}
        }
        invoke(text,path)
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && windows.contains(where:{$0 is TextConflictWindowController})}
        let editor=windows.compactMap {$0 as? TextConflictWindowController}.first!
        try await wait {editor.model.document != nil && !editor.model.busy}
        try require(workspace.root?.path==text.root.path && editor.model.comparisonDefaults === prefs && external.last?.0==false && external.last?.1 === owner && external.last?.2==true,"Conflict command lost adoption, explicit normal tool, owner or original preferences")
        editor.model.result="Uncommitted editor draft\n"
        invoke(text,path,alternate:true)
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && FileListComparisonSession.activeOperations==0}
        try require(windows.filter {$0 is TextConflictWindowController}.count==1 && editor.model.result=="Uncommitted editor draft\n" && external.last?.0==true,"Repeated alternate entry replaced the native draft or ignored its flag")
        editor.window?.close()
        invoke(image,path+".png")
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && windows.contains(where:{$0 is ImageConflictWindowController})}
        let picture=windows.compactMap {$0 as? ImageConflictWindowController}.first!
        let expected=try await image.imageConflictDocument(path:path+".png",identityOptions:.init(defaults:prefs))
        try require(picture.model.document.conflictTitles?.mine.title==expected?.conflictTitles?.mine.title && picture.model.document.contents[.mine]==png(100),"Image route retargeted identities or stage bytes")
        picture.model.reload();try await wait {!picture.model.busy}
        try require(picture.model.document.conflictTitles?.mine.title==expected?.conflictTitles?.mine.title,"Image reload lost its owning preferences")
        picture.window?.close()
        invoke(deleted,path)
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && windows.contains(where:{$0 is DeleteConflictWindowController})}
        let removal=windows.compactMap {$0 as? DeleteConflictWindowController}.first!
        try require(removal.model.operation.preferences === prefs,"Delete/Modify lost command preferences");removal.window?.close()
        invoke(text,module)
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && windows.contains(where:{$0 is SubmoduleConflictWindowController})}
        let child=windows.compactMap {$0 as? SubmoduleConflictWindowController}.first!
        try require(child.model.operation.preferences === prefs && child.model.path==module,"Submodule route lost original selection/preferences");child.window?.close()
        try await wait {ConflictReviewOperation.activeOperations==0 && FileListComparisonSession.activeOperations==0}
        for (repository,head,index) in baselines {try require(try await repository.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:repository.root.appendingPathComponent(".git/index"))==index,"Editor entry changed HEAD/index")}
        let bare=container.appendingPathComponent("bare.git");_ = try await text.run(["init","--bare",bare.path])
        let beforeInvalid=windows.count,previousRoot=workspace.root?.path
        for selected in [bare,text.root] {
            workspace.error=nil;workspace.handleCommandLine(arguments:["--command=conflicteditor","--path",selected.path],currentDirectory:container.path)
            try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
            try require(workspace.error != nil && windows.count==beforeInvalid && workspace.root?.path==previousRoot,"Bare/root-only conflict selection opened an editor or changed context")
        }
        // Exact preparations can coexist; cancelling one spelling cannot retire its peer.
        let nfd="e\u{301}.txt",nfc="é.txt",blob=try await text.run(["hash-object","-w","--stdin"],input:Data("base\n".utf8)).text.trimmingCharacters(in:.newlines)
        let peerRecords=[nfd,nfc].flatMap {path in (1...3).map {"100644 \(blob) \($0)\t\(path)\0"}}.joined()
        _ = try await text.run(["update-index","-z","--index-info"],input:Data(peerRecords.utf8))
        var holds=GitPathMap<CheckedContinuation<ConflictEntry,Never>>(),tokens=GitPathMap<OperationCancellation>(),routed:[String]=[]
        workspace.conflictEditorPresentation={_,_,path,_ in routed.append(path)}
        workspace.readConflictEditorEntry={repository,path,token in let entry=try await repository.conflictEditorEntry(path:path,cancellation:token);tokens[path]=token;return await withCheckedContinuation {holds[path]=$0}}
        workspace.showConflictEditor(repository:text,access:nil,path:nfd,owner:owner,preferences:prefs)
        workspace.showConflictEditor(repository:text,access:nil,path:nfc,owner:owner,preferences:prefs)
        try await wait {holds.count==2}
        try require(workspace.conflictEditorPreparationCount==2,"Canonical preparations were merged")
        workspace.cancelConflictEditorPreparation(repository:text,path:nfd)
        try require(tokens[nfd]?.isCancelled==true && tokens[nfc]?.isCancelled==false,"Cancellation crossed exact path identity")
        let first=try await text.conflictEditorEntry(path:nfd);holds.removeValue(forKey:nfd)?.resume(returning:first)
        try await wait {workspace.conflictEditorPreparationCount==1}
        let second=try await text.conflictEditorEntry(path:nfc);holds.removeValue(forKey:nfc)?.resume(returning:second)
        try await wait {workspace.conflictEditorPreparationCount==0 && FileListComparisonSession.activeOperations==0}
        try require(routed.count==1 && GitReferenceName.equal(routed[0],nfc),"Retired/canonical peer routed to another editor")
        workspace.readConflictEditorEntry=nil;workspace.conflictEditorPresentation=nil
        // Delete windows and their close callbacks use the same exact keys.
        var deletionRecords:[String]=[]
        let zero=String(repeating:"0",count:40)
        for path in [nfd,nfc] {
            deletionRecords.append("0 \(zero)\t\(path)\0")
            for stage in [1,3] {deletionRecords.append("100644 \(blob) \(stage)\t\(path)\0")}
        }
        let deletions=deletionRecords.joined()
        _ = try await text.run(["update-index","-z","--index-info"],input:Data(deletions.utf8))
        let before=windows.count
        for path in [nfd,nfc] {workspace.showConflictEditor(repository:text,access:nil,path:path,owner:owner,preferences:prefs)}
        try await wait {windows.count==before+2 && workspace.conflictEditorPreparationCount==0}
        let peers=Array(windows.suffix(2)).compactMap {$0 as? DeleteConflictWindowController}
        try require(peers.count==2 && peers[0] !== peers[1],"Canonical Delete windows shared an owner")
        let firstPeer=peers.first(where:{GitReferenceName.equal($0.model.path,nfd)})!,secondPeer=peers.first(where:{GitReferenceName.equal($0.model.path,nfc)})!
        firstPeer.window?.close();workspace.showConflictEditor(repository:text,access:nil,path:nfc,owner:owner,preferences:prefs)
        try await wait {workspace.conflictEditorPreparationCount==0}
        try require(windows.count==before+2 && secondPeer.model.operation.active,"Peer close removed the other native editor")
        secondPeer.window?.close();try await wait {ConflictReviewOperation.activeOperations==0}
        // A closed initiating window suppresses a noncooperative shared read.
        var release:CheckedContinuation<ConflictEntry,Never>?
        workspace.readConflictEditorEntry={repository,path,token in let entry=try await repository.conflictEditorEntry(path:path,cancellation:token);return await withCheckedContinuation {release=$0}}
        let count=windows.count
        invoke(text,path);try await wait {release != nil}
        owner.close();try require(workspace.hasPendingRepositoryWork && FileListComparisonSession.activeOperations>0,"Owner close lost pending editor lifetime")
        release?.resume(returning:try await text.conflictEditorEntry(path:path));release=nil
        try await wait {!workspace.busy && workspace.conflictEditorPreparationCount==0 && FileListComparisonSession.activeOperations==0}
        try require(windows.count==count && workspace.error==nil,"Late read routed after command owner close")
        workspace.readConflictEditorEntry=nil;workspace.workspaceWindow=nil
        // Real metadata Git work is cancelled/reaped before an editor handoff.
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let helper=container.appendingPathComponent("conflict-gated-git"),marker=container.appendingPathComponent("metadata-pid")
        let script="""
        #!/bin/sh
        for task_arg in "$@";do
          if [ "$task_arg" = rev-parse ];then
            printf '%s\\n' "$$" > \(quote(marker.path))
            while :;do /bin/sleep 0.05;done
          fi
        done
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let preparing=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:helper)},snapshotWriter:{_ in true})
        preparing.requiresRepositoryScope=false;preparing.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container)}
        let parent=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;preparing.workspaceWindow=parent
        defer {parent.close();preparing.stopMonitoringForTermination()}
        preparing.handleCommandLine(arguments:["--command=conflicteditor","--path",text.root.appendingPathComponent(path).path],currentDirectory:container.path)
        try await wait {((try? String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) == false)}
        let pid=try requireOne([Int32(try String(contentsOf:marker).trimmingCharacters(in:.whitespacesAndNewlines))].compactMap {$0})
        try require(preparing.hasPendingRepositoryWork && preparing.busy,"Metadata preparation lost pending ownership")
        parent.close();try await wait {!preparing.busy && !preparing.hasPendingRepositoryWork}
        try require(preparing.root==nil && preparing.error==nil && kill(pid,0) == -1 && errno==ESRCH,"Closed metadata owner adopted a repository or retained its Git process")
        print("Owned conflict metadata Git process reaped: \(pid)")
        print("PASS: Conflict command family: source flags and captured root/owner/preferences; native text/image/delete/submodule routing; repeated draft preservation; identity snapshot/reload; exact concurrent preparations, isolated cancel and native Delete peer close; late command-owner closure; unchanged opening HEAD/index; owned windows closed. No external app launched; scope adapters injected, physical Finder/signed acceptance not exercised.")
    }
}
