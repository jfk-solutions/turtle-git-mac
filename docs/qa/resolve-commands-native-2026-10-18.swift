import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyResolveCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let folder=container.appendingPathComponent("repository"),paths=["-first 雪\n[*].txt","second.txt"]
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Resolve command QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        func write(_ value:String) throws {for path in paths {try Data(value.utf8).write(to:folder.appendingPathComponent(path))}}
        try write("base\n");try await repo.stage(paths);_=try await repo.commit(message:"base")
        _=try await repo.run(["switch","-c","side"]);try write("theirs\n");try await repo.stage(paths);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["switch","main"]);try write("mine\n");try await repo.stage(paths);_=try await repo.commit(message:"mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflicts")} catch is GitFailure {}
        let index=try Data(contentsOf:folder.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let stages=try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite="TurtleGit.ResolveCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,foreignSuite=suite+".foreign",foreign=UserDefaults(suiteName:foreignSuite)!
        defer {prefs.removePersistentDomain(forName:suite);foreign.removePersistentDomain(forName:foreignSuite)}
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let owner=NSWindow(contentRect:.init(x:0,y:0,width:300,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.workspaceWindow=owner;workspace.fileComparisonPreferences=prefs
        workspace.commandLineRepositoryPermission={_ in workspace.fileComparisonPreferences=foreign;return RepositoryAccessLease(url:container)}
        var windows:[ResolveWindowController]=[]
        workspace.resolveWindowPresentation={controller in
            if !windows.contains(where:{$0 === controller}) {windows.append(controller)}
            controller.window?.alphaValue=0;controller.showWindow(nil)
        }
        defer {windows.forEach {$0.close()};owner.close();workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        @MainActor func invoke(_ flags:[String],selected:[String]=[]) async throws {
            try await wait {!workspace.busy && RepositoryModel.activeCommandFileOperations==0}
            workspace.error=nil;workspace.fileComparisonPreferences=prefs
            let urls=selected.isEmpty ? [folder.path]:selected
            workspace.handleCommandLine(arguments:["--command=resolve"]+flags+urls.flatMap {["--path",$0]},currentDirectory:container.path)
        }
        try await invoke([])
        try await wait {!workspace.busy && windows.count==1 && !windows[0].model.busy && windows[0].model.entries.count==2}
        let normal=windows[0]
        try require(normal.model.preferences === prefs && normal.model.commandOptions == ResolveCommandOptions(),"Review lost options or original preferences")
        normal.model.checked=[paths[0]]
        try await invoke([])
        try await wait {!workspace.busy}
        try require(windows.count==1 && normal.model.checked == [paths[0]],"Repeated review erased checked targets")
        try require(try await repo.run(["ls-files","--stage","-z"]).stdout==stages,"Review entry mutated the index")
        normal.model.resolveChecked()
        try await wait {!normal.model.busy && normal.model.success && normal.model.showingProgress}
        try require(normal.model.resolvedCount==1 && normal.model.entries.count==1,"Ordinary checked progress did not resolve one file")
        normal.model.closeProgress();try await wait {normal.retired}
        try await invoke(["--silent"])
        try await wait {!workspace.busy && windows.count==2 && !windows[1].model.busy && windows[1].model.entries.count==1}
        let silent=windows[1];silent.model.checked=[paths[1]];silent.model.resolveChecked()
        try await wait {!silent.model.busy && silent.retired}
        try require(silent.model.success && !silent.model.showingProgress && silent.model.silentAttempt,"Reviewed Silent displayed progress or failed to close")
        // Restore only private fixture index stages before the next independent mode.
        try index.write(to:folder.appendingPathComponent(".git/index"))
        try await invoke(["--noquestion"])
        try await wait {!workspace.busy && windows.count==3 && !windows[2].model.busy && windows[2].model.success}
        let skipped=windows[2]
        try require(skipped.model.showingProgress && skipped.model.resolvedCount==0 && skipped.model.output.contains("Skipped: ."),"Noquestion-only did not retain source Skip semantics")
        try require(try await repo.run(["ls-files","--stage","-z"]).stdout==stages,"Noquestion-only staged an argv path without source action metadata")
        skipped.model.closeProgress();try await wait {skipped.retired}
        try Data("ignored.bin\n".utf8).write(to:folder.appendingPathComponent(".gitignore"))
        try Data("forced ignored content\n".utf8).write(to:folder.appendingPathComponent("ignored.bin"))
        for side in ["LOCAL","REMOTE","BASE","BACKUP"] {try Data(side.utf8).write(to:folder.appendingPathComponent(paths[0]+"."+side+".txt"))}
        let list=container.appendingPathComponent("paths")
        try Data((folder.appendingPathComponent(paths[0]).path+"\0"+folder.appendingPathComponent("ignored.bin").path+"\0").utf8).write(to:list)
        workspace.commandLinePathListPermission={_,_ in RepositoryAccessLease(url:container)}
        try await wait {!workspace.busy}
        workspace.handleCommandLine(arguments:["--command=resolve","--silent","--noquestion","--pathfile",list.path,"--pathfile0","--deletepathfile"],currentDirectory:container.path)
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations==0}
        let remaining=try await repo.conflicts(),ignored=try await repo.run(["show",":ignored.bin"]).text
        try require(windows.count==3 && remaining.count==1 && GitReferenceName.equal(remaining[0].path,paths[1]) && ignored=="forced ignored content\n","Direct Silent changed scope or opened a review/progress window")
        try require(!FileManager.default.fileExists(atPath:list.path),"Resolve path-file deletion was lost")
        for side in ["LOCAL","REMOTE","BASE"] {try require(!FileManager.default.fileExists(atPath:folder.appendingPathComponent(paths[0]+"."+side+".txt").path),"Source merge side file was retained")}
        try require(FileManager.default.fileExists(atPath:folder.appendingPathComponent(paths[0]+".BACKUP.txt").path),"Unrelated backup was removed")
        // A reviewed Silent error stays visible for acknowledgment and exposes
        // neither progress nor a success/Commit path.
        try await invoke(["--silent"])
        try await wait {!workspace.busy && windows.count==4 && !windows[3].model.busy && windows[3].model.entries.count==1}
        let failing=windows[3]
        failing.model.executeResolution={_,_,_,_,_ in throw ResolveFailure.stale}
        failing.model.checked=[paths[1]];failing.model.resolveChecked()
        try await wait {!failing.model.busy && failing.model.error != nil}
        try require(!failing.model.showingProgress && !failing.model.success && !failing.retired,"Silent review failure disappeared or exposed success")
        failing.model.error=nil;failing.close()
        let previousRoot=workspace.root
        let outside=container.appendingPathComponent("outside.txt");try Data("outside".utf8).write(to:outside)
        try await invoke(["--silent","--noquestion"],selected:[folder.appendingPathComponent(paths[1]).path,outside.path])
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork}
        try require(workspace.error != nil && workspace.root==previousRoot && windows.count==4,"Mixed-root Resolve silently dropped an input or changed workspace")
        // Duplicate pending direct entry retains the same operation. Closing
        // the initiating owner fences an uncooperative late completion.
        var release:CheckedContinuation<Void,Never>?,token:OperationCancellation?,calls=0
        workspace.executeSilentResolve={_,captured,current in
            calls += 1;token=current
            try require(captured == [paths[1]],"Direct command lost literal original path")
            await withCheckedContinuation {release=$0}
            return "late silent result"
        }
        try await invoke(["--silent","--noquestion"],selected:[folder.appendingPathComponent(paths[1]).path])
        try await wait {release != nil && workspace.hasPendingRepositoryWork}
        try await invoke(["--silent","--noquestion"],selected:[folder.appendingPathComponent(paths[1]).path])
        try await wait {!workspace.busy}
        try require(calls==1,"Repeated pending silent command started a second mutation")
        owner.close()
        try require(token?.isCancelled==true && workspace.hasPendingRepositoryWork && FileListComparisonSession.activeOperations>0,"Silent owner closure dropped cancellation/lifetime")
        release?.resume();release=nil
        try await wait {!workspace.busy && !workspace.hasPendingRepositoryWork && FileListComparisonSession.activeOperations==0 && ResolveWindowModel.activeOperations==0}
        try require(workspace.error==nil && !workspace.output.contains("late silent result") && windows.count==4,"Late Silent completion published error/output/window")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head,"Resolve committed unexpectedly")
        print("PASS: Resolve command family: four source flag modes, captured preferences/adoption, retained checked draft, real checked/silent staging, source noquestion Skip behavior, literal authorized path file, ignored targets and exact side-file cleanup, silent failure, mixed-root refusal, duplicate coalescing and closed-owner late completion; no commit/external app, private windows closed")
    }
}
