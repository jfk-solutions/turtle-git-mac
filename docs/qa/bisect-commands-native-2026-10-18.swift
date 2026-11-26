import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifyBisectCommands() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Bisect command QA"),("user.email","bisect@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt");var hashes=[String]()
        for index in 0..<8 {try Data("\(index)\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"step \(index)");hashes.append(try await repo.rebaseCommit("HEAD").hash)}
        let suite="TurtleGit.BisectCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"DownloadAnimation");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("private-marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={};workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
        defer {workspace.stopMonitoringForTermination();NativeOwnedWindowCleanup.close(NSApp.windows)}
        func owners()->[BisectWindowController] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? BisectWindowController}}
        func invoke(_ flags:[String]) {workspace.handleCommandLine(arguments:["--command=bisect"]+flags,currentDirectory:root.path)}
        invoke([]);try await wait {!workspace.busy && owners().first?.model.busy==false}
        let owner=try requireOne(owners()),model=owner.model
        @MainActor func admissionDiagnostic()->String {
            var fields:[String]=[]
            fields.append("workspaceBusy=\(workspace.busy),busy=\(model.busy),pending=\(model.hasPendingWork),picker=\(model.hasPicker)")
            fields.append("confirmQuit=\(model.confirmingQuit),confirmCancel=\(model.confirmingCancellation),retired=\(model.retired),presentation=\(model.presentationAvailable())")
            fields.append("active=\(String(describing:model.state?.active)),head=\(String(describing:model.state?.head)),exit=\(String(describing:model.lastExitCode)),reset=\(model.canPerform(.reset))")
            fields.append("sheet=\(owner.window?.attachedSheet != nil),error=\(String(reflecting:model.error))")
            return fields.joined(separator:"; ")
        }
        @MainActor func acknowledgeError() async throws {
            model.error=nil
            do {try await wait {owner.window?.attachedSheet==nil && !model.busy && !model.hasPendingWork}}
            catch{throw Failure(description:"Bisect error acknowledgement did not detach: "+admissionDiagnostic()+"; "+String(describing:error))}
        }
        try require(model.error=="Operation unknown or not allowed." && model.state?.active==false && !model.hasStartReview,"Unknown inactive command created a Start review or lost actual state")
        try await acknowledgeError()
        invoke(["--start","--good",hashes[0],"--bad",hashes[7]])
        try await wait {!workspace.busy && !model.busy && model.error==nil}
        try require(owners().count==1 && model.good==hashes[0] && model.bad==hashes[7] && model.canStart && !model.progressPresentation.animateActivity,"Start presets/private preferences or recovered initial review lost")
        model.good=hashes[1]
        invoke(["/start","/good:"+hashes[0],"/bad:"+hashes[6]])
        try await wait {!workspace.busy && !model.busy}
        try require(model.good==hashes[1] && model.bad==hashes[7],"Repeated Start replaced the edited native review")
        var state=try await repo.bisectState();try require(!state.active && state.head==hashes[7],"Start command mutated before acceptance")
        try Data("uncommitted 🐢\n".utf8).write(to:file);model.confirmStash={false};model.start()
        try await wait {!model.busy}
        state=try await repo.bisectState()
        try require(!state.active && model.canStart && Data(contentsOf:file)==Data("uncommitted 🐢\n".utf8),"Declined Stash changed files or started a session")
        try Data("7\n".utf8).write(to:file);model.start()
        try await wait {!model.busy && model.state?.active==true && !workspace.busy}
        try require(model.lastExitCode==0 && model.postOperations==BisectOperation.allCases,"Accepted Start failed to create native continuation state")
        invoke(["--good","--ref",hashes[2]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect good "+hashes[2])==true}
        try require(model.lastExitCode==0,"Good command failed")
        invoke(["--bad","--ref",hashes[6]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect bad "+hashes[6])==true}
        invoke(["--skip","--ref",hashes[3]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect skip "+hashes[3])==true}
        try require(model.lastExitCode==0,"Skip command failed")
        let beforeBusy=try await repo.bisectState();model.hasPicker=true
        invoke(["--reset"]);try await wait {!workspace.busy}
        state=try await repo.bisectState()
        try require(state.head==beforeBusy.head && state.log==beforeBusy.log && workspace.error?.contains("current bisect operation")==true,"Pending picker allowed a competing reset")
        model.hasPicker=false;invoke(["--reset","--ref",hashes[0]])
        try await wait {!workspace.busy && !model.busy && model.state?.active==false}
        state=try await repo.bisectState();try require(state.head==hashes[7] && !state.active,"Reset used ignored ref or lost original branch")
        invoke(["--good"]);try await wait {!workspace.busy && !model.busy && model.error != nil}
        state=try await repo.bisectState();try require(!state.active && state.head==hashes[7],"Inactive classification mutated repository")
        try await acknowledgeError()
        _ = try await repo.run(["bisect","start","--term-old=old","--term-new=new",hashes[7],hashes[0]])
        let customBefore=try await repo.bisectState()
        invoke(["--start"]);try await wait {!workspace.busy && !model.busy && model.error != nil}
        state=try await repo.bisectState()
        let unchanged="active=\(state.active),logEqual=\(state.log==customBefore.log),headEqual=\(state.head==customBefore.head); "+admissionDiagnostic()
        try require(state.active,"Rejected active Start ended the custom-term session: "+unchanged)
        try require(state.log==customBefore.log && state.head==customBefore.head,"Rejected active Start changed exact log/HEAD: "+unchanged)
        try require(model.state?.active==true,"Rejected active Start lost recoverable active model: "+unchanged)
        // Reset is a recovery action, but the native error sheet still owns
        // command admission until its acknowledgement has actually detached.
        try await acknowledgeError()
        try require(model.canPerform(.reset),"Acknowledged active Start refusal did not restore Reset: "+admissionDiagnostic())
        invoke(["--start","--good="+hashes[0],"--bad="+hashes[7],"--skip","--reset","--ref",hashes[2]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect old "+hashes[2])==true}
        try require(model.state?.goodTerm=="old" && model.state?.badTerm=="new" && model.lastExitCode==0,"Active Start+Good precedence or custom terms were lost")
        invoke(["--bad","--skip","--reset","--ref",hashes[6]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect new "+hashes[6])==true}
        invoke(["--skip","--reset","--ref",hashes[3]])
        try await wait {!workspace.busy && !model.busy && model.state?.log.contains("git bisect skip "+hashes[3])==true}
        invoke(["--reset"]);try await wait {!workspace.busy && !model.busy && model.state?.active==false}
        state=try await repo.bisectState();try require(state.head==hashes[7],"Custom-term Reset failed")
        invoke(["--start"]);try await wait {!workspace.busy && !model.busy && model.canPickRevision}
        try require(model.good.isEmpty && model.bad=="main" && !model.canStart,"Fresh Start after Reset reused stale revision defaults")
        // Start must refuse an independent pending merge without modifying it.
        _ = try await repo.run(["checkout","-b","merge-side",hashes[0]])
        try Data("side\n".utf8).write(to:root.appendingPathComponent("side.txt"));try await repo.stage(["side.txt"]);_ = try await repo.commit(message:"side")
        _ = try await repo.run(["checkout","main"]);_ = try await repo.run(["merge","--no-ff","--no-commit","merge-side"])
        let mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        invoke(["--start","--good",hashes[0],"--bad",hashes[7]])
        try await wait {!workspace.busy && !model.busy && model.error != nil}
        try require(try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))==mergeHead && model.state?.active==false,"Refused Start changed pending merge")
        _ = try await repo.run(["merge","--abort"])
        try await acknowledgeError()
        owner.close();try require(model.retired,"Closed Bisect owner remained live")
        model.load(command:.init(start:true,good:hashes[0],bad:hashes[7]))
        model.start();model.perform(.reset)
        try await wait {BisectWindowModel.activeOperations==0}
        state=try await repo.bisectState()
        try require(!state.active && state.head==hashes[7] && Data(contentsOf:file)==Data("7\n".utf8),"Retired native owner accepted late work")
        print("PASS: bisect command family: fresh-state routing and source flag precedence; initial unknown-state recovery; preserved Start presets/draft and private progress preferences; dirty Stash Abort and accepted Start; real Good/Bad/Skip/Reset including custom terms and ignored Reset ref; picker/merge/inactive/active/retired fences; original branch and bytes restored; owned windows closed")
    }
}
