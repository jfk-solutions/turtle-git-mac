import AppKit
import Darwin
import TurtleGitCore

@main struct CommitRefreshVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure(description:message)}}
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Commit refresh timeout at \(line)")
    }
    @MainActor static func main()async {
        do {try await verify()}catch {fputs("Commit refresh failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let repo=GitRepository(root:root,executable:git),manager=FileManager.default
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Commit Refresh QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        func write(_ path:String,_ text:String)throws {try Data(text.utf8).write(to:root.appendingPathComponent(path))}
        try manager.createDirectory(at:root.appendingPathComponent("tracked"),withIntermediateDirectories:true)
        try manager.createDirectory(at:root.appendingPathComponent("build"),withIntermediateDirectories:true)
        try write(".gitignore","/build/\n")
        for index in 0..<512 {try write("tracked/file-\(index)","unchanged \(index)\n")}
        for path in ["changed","staged","rename","assume","skip","unchanged-flag"] {try write(path,"base \(path)\n")}
        _ = try await repo.run(["add","--all"]);_ = try await repo.commit(message:"private refresh baseline")
        for index in 0..<1024 {try write("build/output-\(index)","ignored output \(index)\n")}
        try write("changed","working changed\n");try write("staged","staged changed\n")
        try write("assume","staged assume\n");try write("skip","staged skip\n")
        try await repo.stage(["staged","assume","skip"])
        _ = try await repo.run(["update-index","--assume-unchanged","assume","unchanged-flag"])
        _ = try await repo.run(["update-index","--skip-worktree","skip"])
        _ = try await repo.run(["mv","rename","renamed"])
        try write("untracked","new file\n")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout
        let suite="TurtleGit.CommitRefresh."+UUID().uuidString
        guard let prefs=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")}
        prefs.set(true,forKey:"RememberFileListPosition");prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"HintStagingMode");prefs.set(false,forKey:"EnableGravatar")
        var owners:[CommitWindowController]=[]
        defer {owners.forEach{$0.close()};prefs.removePersistentDomain(forName:suite)}
        func make()->CommitWindowController {
            let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-20000,y:-20000));owner.window?.orderFront(nil)
            owner.model.reload();return owner
        }
        func ready(_ model:CommitWindowModel)async throws {
            try await wait {!model.busy && !model.savingPreferences && model.changelistsLoaded && !model.stagingHintVisible && model.guiPatch?.busy != true}
        }
        let owner=make(),model=owner.model;try await ready(model)
        let expected:Set<String>=["changed","staged","renamed","assume","skip","untracked"]
        func assertSnapshot(_ model:CommitWindowModel)throws {
            let paths=Set(model.entries.map(\.path))
            try require(paths==expected,"Refresh change rows differ: \(paths.sorted())")
            try require(!model.entries.contains{$0.state == .ignored || $0.path.hasPrefix("build/") || $0.path.hasPrefix("tracked/")},"Commit enumerated unchanged or ignored rows")
            try require(Set(model.fileMetadata.keys)==expected,"Metadata was not scoped to change rows")
            try require(Set(model.indexFlagFiles.map{$0.entry.path})==expected,"Index flags expanded to unchanged tracked files")
            try require(model.indexFlagFiles.allSatisfy{$0.modificationDate==nil},"Flags-only read performed unrelated date metadata collection")
            try require(model.indexFlagFiles.first{$0.entry.path=="assume"}?.assumeUnchanged==true && model.indexFlagFiles.first{$0.entry.path=="skip"}?.skipWorktree==true,"Scoped refresh lost actual index flags")
            try require(model.indexFlagFiles.first{$0.entry.path=="untracked"}?.assumeUnchanged==false && model.indexFlagFiles.first{$0.entry.path=="untracked"}?.skipWorktree==false,"Untracked row acquired tracked flags")
            try require(model.fileListReadError==nil && !model.fileListReadCancelled,"Accepted refresh retained failure state")
        }
        try assertSnapshot(model)
        model.message="private draft";model.selection=["changed"]
        var reads=0
        model.queryCommitStatus={parent,token in reads += 1;return try await repo.commitDialogStatus(amendToParent:parent,cancellation:token,refreshIndex:false)}
        let menu=NSMenu(title:"Private refresh commands")
        owner.commandMenu?.applicationMenu={menu};owner.commandMenu?.keyWindow={owner.window};owner.commandMenu?.install()
        func f5()throws {
            guard let window=owner.window,let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.function],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:96) else{throw Failure(description:"F5 event unavailable")}
            try require(window.performKeyEquivalent(with:event),"Actual native F5 declined refresh")
        }
        try f5();try await ready(model);try assertSnapshot(model)
        try require(reads==1 && model.selection.contains("changed") && model.message=="private draft","Classic F5 lost selection/draft or duplicated status read")
        model.setCommitInterface(true);try await ready(model);try assertSnapshot(model)
        model.selectGuiFiles(["staged"],staged:true);try await ready(model)
        let guiSelection=model.selection,beforeGUI=reads
        try f5();try await ready(model);try assertSnapshot(model)
        try require(reads==beforeGUI+1 && model.selection==guiSelection && model.message=="private draft","Git Gui F5 lost selection/draft or duplicated status read")
        model.setCommitInterface(false);try await ready(model);try assertSnapshot(model)
        // Hold only the existing injectable status boundary after a real Git
        // read; cancellation must prevent the otherwise valid result publishing.
        var entered=false,releaseRead:(()->Void)?
        defer {releaseRead?()}
        let baseline=model.entries
        model.queryCommitStatus={parent,token in
            let result=try await repo.commitDialogStatus(amendToParent:parent,cancellation:token,refreshIndex:false)
            entered=true
            await withCheckedContinuation { continuation in releaseRead={continuation.resume()} }
            return result
        }
        model.reload();try await wait {entered}
        var cancelled=false
        model.cancel(closeWindow:false){cancelled=$0}
        try require(!cancelled && CommitWindowModel.activeReloads>0,"Cancellation released ownership before held read drained")
        releaseRead?();releaseRead=nil
        try await wait {cancelled && CommitWindowModel.activeReloads==0 && !model.busy}
        try require(model.entries==baseline && model.message=="private draft","Cancelled refresh published or changed draft")
        // Retirement must drain the same real read without touching a successor.
        let retired=make();try await ready(retired.model)
        var retiringEntered=false,releaseRetiredRead:(()->Void)?
        defer {releaseRetiredRead?()}
        retired.model.queryCommitStatus={parent,token in
            let result=try await repo.commitDialogStatus(amendToParent:parent,cancellation:token,refreshIndex:false)
            retiringEntered=true
            await withCheckedContinuation { continuation in releaseRetiredRead={continuation.resume()} }
            return result
        }
        let retiredRows=retired.model.entries
        retired.model.reload();try await wait {retiringEntered};retired.close()
        let replacement=make();try await ready(replacement.model)
        releaseRetiredRead?();releaseRetiredRead=nil
        try await wait {CommitWindowModel.activeReloads==0}
        try require(!retired.model.messageFocusAvailable && retired.model.entries==retiredRows,"Retired refresh published after owner closure")
        try assertSnapshot(replacement.model)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout
        let bytes=try Data(contentsOf:root.appendingPathComponent("changed"))
        try require(head==afterHead && index==afterIndex && bytes==Data("working changed\n".utf8),"Refresh mutated HEAD/index/worktree")
        owners.forEach{$0.close()}
        try await wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activePreferenceOperations==0}
        print("PASS: Commit refresh scoped rows/metadata/index flags, unchanged and ignored exclusion, Classic/Git Gui F5 and selections, cancellation/retirement atomicity, exact Git witnesses; owned windows closed")
    }
}
