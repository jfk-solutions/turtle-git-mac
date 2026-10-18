import AppKit
import TurtleGitCore

private final class FileCommandBookmarks: RepositoryBookmarkProvider {
    func create(for url:URL) throws -> Data {Data(url.path.utf8)}
    func resolve(_ data:Data) throws -> ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}

extension PrimaryCommandsVerification {
    @MainActor static func verifyFiles() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),path="-file 雪[*].txt",file=FileTransferPaths.fileURL(root.path+"/"+path)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","File launch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let original=Data("alpha\nsame\nold\n".utf8),working=Data("working\nsame\nnew\n".utf8)
        try original.write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD")
        try Data("beta\nsame\nnew\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"file change")
        let fileTip=try await repo.rebaseCommit("HEAD")
        try Data("unrelated\n".utf8).write(to:root.appendingPathComponent("other"));try await repo.stage(["other"]);_ = try await repo.commit(message:"unrelated tip")
        try working.write(to:file)
        let addFolder=root.appendingPathComponent("add folder"),addName="add folder/new 雪[*].txt"
        try FileManager.default.createDirectory(at:addFolder,withIntermediateDirectories:true);try Data("new bytes\n".utf8).write(to:FileTransferPaths.fileURL(root.path+"/"+addName))
        let suite="TurtleGit.FileCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let bookmarks=FileCommandBookmarks()
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        model.requiresRepositoryScope=false;model.repositoryBookmarkProvider=bookmarks;model.fileComparisonPreferences=prefs;model.notifyFinder={}
        model.blameRecentDocuments=try BlameRecentDocuments(url:container.appendingPathComponent("blame-recent.json"),provider:bookmarks)
        model.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root,provider:bookmarks)}
        let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;model.workspaceWindow=host
        defer {model.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ args:[String]) {model.handleCommandLine(arguments:args,currentDirectory:root.path)}
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),refs=try await repo.run(["show-ref"]).stdout
        // Each Blame command has its own viewer; a second command cannot move the first selection.
        invoke(["--command=blame","--path",file.path,"--endrev",base.hash,"--line=2"])
        try await wait {!model.busy && windows(BlameWindowController.self).first?.model.busy == false}
        let blame=try requireOne(windows(BlameWindowController.self))
        try require(blame.model.snapshot?.revision==base.hash && blame.model.selection==2 && blame.model.sourceNavigation?.line==2,"Blame lost historical revision, source selection or navigation")
        let list=container.appendingPathComponent("blame-paths.txt");try Data((file.path+"\n").utf8).write(to:list)
        model.commandLinePathListPermission={_,_ in RepositoryAccessLease(url:container,provider:bookmarks)}
        invoke(["--command=blame","--pathfile",list.path,"--deletepathfile","--endrev",base.hash,"--line=9999"])
        try await wait {!model.busy && windows(BlameWindowController.self).count==2 && windows(BlameWindowController.self).allSatisfy {!$0.model.busy}}
        let second=windows(BlameWindowController.self).first {$0 !== blame}!
        try require(blame.model.selection==2 && second.model.selection==3 && !FileManager.default.fileExists(atPath:list.path),"Second Blame retargeted its first window or failed to clamp line")
        blame.close();second.close()
        // Repository adoption releases its own busy owner before activating a
        // comparison, then must not clear the comparison's newly acquired owner.
        let extra=root.appendingPathComponent("extra.txt");try Data("extra\n".utf8).write(to:extra)
        let many=[file,root.appendingPathComponent("other"),FileTransferPaths.fileURL(root.path+"/"+addName),extra]
        prefs.set(3,forKey:"NumDiffWarning")
        var comparisonReply:CheckedContinuation<Bool,Never>?,comparisonCount=0
        defer {comparisonReply?.resume(returning:false)}
        model.fileComparisonQuestion={count in comparisonCount=count;return await withCheckedContinuation {comparisonReply=$0}}
        invoke(["--command=diff"]+many.flatMap {["--path",$0.path]})
        try await wait {comparisonReply != nil}
        try require(comparisonCount==4 && model.busy && FileListComparisonSession.activeOperations==1,"Repository adoption stole comparison busy ownership")
        comparisonReply?.resume(returning:false);comparisonReply=nil;model.fileComparisonQuestion=nil
        try await wait {!model.busy && FileListComparisonSession.activeOperations==0}
        prefs.removeObject(forKey:"NumDiffWarning")
        invoke(["--command=prevdiff","--path",file.path])
        try await wait {!model.busy && windows(FileComparisonWindowController.self).first?.model.document != nil && windows(FileComparisonWindowController.self).first?.model.filtering == false}
        let comparison=try requireOne(windows(FileComparisonWindowController.self))
        try require(comparison.model.document?.base.bytes==original && comparison.model.document?.destination.bytes==working,"Previous Diff used HEAD~1 instead of second file history entry or lost working bytes")
        comparison.close()
        invoke(["--command=prevdiff","--path",file.path,"--unified","--alternative"])
        try await wait {!model.busy}
        try require(!windows(PatchWindowController.self).isEmpty,"Previous unified viewer missing: \(model.error ?? "no error")")
        let patch=try requireOne(windows(PatchWindowController.self)),patchText=String(decoding:patch.model.exportDocument.bytes,as:UTF8.self)
        try require(patchText.contains("-alpha") && patchText.contains("+working"),"Previous unified Diff used the wrong base");patch.close()
        invoke(["--command=prevdiff","--path",root.path,"--unified"])
        try await wait {!model.busy && windows(RevisionComparisonWindowController.self).first?.model.busy == false}
        let directory=try requireOne(windows(RevisionComparisonWindowController.self))
        try require(directory.model.from==fileTip.hash && directory.model.to==ComparisonRevision.workingTree.label,"Directory Previous Diff did not use HEAD~1-to-working list precedence");directory.close()
        // Rename remains a review form and keeps an existing edit intact.
        invoke(["--command=rename","--path",file.path])
        try await wait {!model.busy && !windows(RenameWindowController.self).isEmpty}
        let rename=try requireOne(windows(RenameWindowController.self));rename.model.name="edited name.txt"
        invoke(["--command=rename","--path",file.path]);try await wait {!model.busy}
        try require(windows(RenameWindowController.self).count==1 && rename.model.name=="edited name.txt","Repeated Rename discarded the edit");rename.close()
        // A folder Add opens the checked selection; another launch preserves that draft.
        invoke(["--command=add","--path",addFolder.path])
        try await wait {!model.busy && !model.hasPendingRepositoryWork && windows(AddWindowController.self).first?.model.busy == false}
        let add=try requireOne(windows(AddWindowController.self))
        try require(add.model.entries.map(\.path)==[addName],"Add lost selected directory scope");add.model.checked=[]
        invoke(["--command=add","--path",root.path]);try await wait {!model.busy && !model.hasPendingRepositoryWork}
        try require(windows(AddWindowController.self).count==1 && add.model.checked.isEmpty && add.model.scopePaths==["add folder"] && model.error?.contains("already open")==true,"Command-line Add replaced the checked draft")
        add.close();model.error=nil
        let reviewRefs=try await repo.run(["show-ref"]).stdout
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working && reviewRefs==refs,"Opening review/read-only commands changed repository content")
        // Source file-only Add runs the real operation immediately after authorization.
        invoke(["--command=add","--path",FileTransferPaths.fileURL(root.path+"/"+addName).path])
        try await wait {!model.busy && !model.hasPendingRepositoryWork && windows(AddProgressWindowController.self).first?.model.busy == false}
        let progress=try requireOne(windows(AddProgressWindowController.self))
        try require(progress.model.success && progress.model.paths==[addName],"File-only Add did not run source-style progress")
        try require(try await repo.run(["ls-files","--error-unmatch","--",addName]).exitCode==0,"File-only Add did not stage its literal name");progress.close()
        _ = try await repo.run(["reset","--",addName]);try await wait {!model.busy}
        try FileManager.default.removeItem(at:file)
        invoke(["--command=add","--path",file.path])
        try await wait {!model.busy && !model.hasPendingRepositoryWork && windows(AddProgressWindowController.self).first?.model.busy == false}
        let deletion=try requireOne(windows(AddProgressWindowController.self))
        try require(deletion.model.success,"File-only Add did not stage a missing tracked file");deletion.close()
        try require(try await repo.run(["ls-files","-z","--",path]).stdout.isEmpty,"Add failed to stage the selected deletion")
        _ = try await repo.run(["reset","--hard","HEAD"]);try working.write(to:file);try await wait {!model.busy}
        // Actual Rename mutates only on acceptance, through the existing Git plan.
        invoke(["--command=rename","--path",file.path]);try await wait {!model.busy && !windows(RenameWindowController.self).isEmpty}
        let acceptedRename=try requireOne(windows(RenameWindowController.self));acceptedRename.model.name="renamed 雪[*].txt";acceptedRename.model.rename()
        try await wait {RenameWindowModel.activeOperations==0 && windows(RenameWindowController.self).isEmpty && !model.busy}
        let renamed=root.appendingPathComponent("renamed 雪[*].txt")
        try require(!FileManager.default.fileExists(atPath:file.path) && (try? Data(contentsOf:renamed))==working,"Accepted Rename lost working bytes or original path")
        _ = try await repo.run(["reset","--hard","HEAD"]);try await wait {!model.busy}
        // Remove and keep-local both require the normal source confirmation.
        var question:((NSApplication.ModalResponse)->Void)?,questionAlert:NSAlert?
        model.removeWindowFactory={repository,access,request in
            let controller=RemoveWindowController(repository:repository,access:access,request:request,preferences:prefs)
            controller.presentQuestion={_,alert,reply in questionAlert=alert;question=reply;return true};return controller
        }
        invoke(["--command=remove","--path",file.path,"--keep"])
        try await wait {question != nil}
        let removal=try requireOne(windows(RemoveWindowController.self))
        try require(removal.model.request.keepLocal && questionAlert?.buttons.last?.keyEquivalent=="\r","Remove keep preset or Abort default was lost")
        try require(try await repo.run(["ls-files","--error-unmatch","--",path]).exitCode==0 && FileManager.default.fileExists(atPath:file.path),"Remove mutated before confirmation")
        question?(.alertSecondButtonReturn);question=nil;questionAlert=nil
        try await wait {RemoveWindowModel.activeOperations==0 && windows(RemoveWindowController.self).isEmpty}
        invoke(["--command=remove","--path",file.path,"--keep"]);try await wait {question != nil}
        question?(.alertFirstButtonReturn);question=nil;questionAlert=nil
        try await wait {RemoveWindowModel.activeOperations==0 && windows(RemoveWindowController.self).first?.model.busy == false && !model.busy}
        try require(FileManager.default.fileExists(atPath:file.path),"Keep-local Remove deleted local content")
        try require(try await repo.run(["ls-files","-z","--",path]).stdout.isEmpty,"Keep-local Remove left path in index")
        windows(RemoveWindowController.self).forEach {$0.close()};_ = try await repo.run(["reset","--hard","HEAD"]);try await wait {!model.busy}
        invoke(["--command=remove","--path",file.path]);try await wait {question != nil}
        question?(.alertFirstButtonReturn);question=nil;questionAlert=nil
        try await wait {RemoveWindowModel.activeOperations==0 && windows(RemoveWindowController.self).first?.model.busy == false && !model.busy}
        try require(!FileManager.default.fileExists(atPath:file.path),"Accepted Remove retained file");windows(RemoveWindowController.self).forEach {$0.close()}
        _ = try await repo.run(["reset","--hard","HEAD"]);try await wait {!model.busy}
        try await verifyAddPreparationOwners(container:container,root:root,git:git,prefs:prefs)
        try require(try await repo.run(["show-ref"]).stdout==refs,"File actions changed references")
        print("PASS: source file command family: historical/line Blame independent viewers; file/directory Previous Diff and unified bytes; Rename review/edit/accept; scoped Add draft and automatic file progress; Remove Abort/keep/delete; cancelled/retired Add preparation; captured repository output; private preferences and owned cleanup")
    }
    @MainActor static func verifyAddPreparationOwners(container:URL,root:URL,git:URL,prefs:UserDefaults) async throws {
        let name="add folder/new 雪[*].txt",file=FileTransferPaths.fileURL(root.path+"/"+name),repo=GitRepository(root:root,executable:git)
        for retire in [false,true] {
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent(UUID().uuidString+".json")))
            model.fileComparisonPreferences=prefs;model.notifyFinder={};model.requiresRepositoryScope=false
            model.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
            let host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;model.workspaceWindow=host
            defer {model.stopMonitoringForTermination();host.close()}
            var release:CheckedContinuation<Void,Never>?,token:OperationCancellation?
            defer {release?.resume()}
            model.addSelectionPreflight={repository,paths,cancellation in token=cancellation;await withCheckedContinuation {release=$0};return try await repository.addSelectionIsFiles(paths,cancellation:cancellation)}
            model.handleCommandLine(arguments:["--command=add","--path",file.path],currentDirectory:root.path)
            try await wait {release != nil}
            let delegate=TurtleGitApplicationDelegate();delegate.repositoryModel=model
            try require(model.hasPendingRepositoryWork && delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Add preparation lost Quit ownership")
            if retire {model.stopMonitoringForTermination()} else {host.close()}
            try require(token?.isCancelled==true,"Closed/retired owner did not cancel Add preparation")
            release?.resume();release=nil;try await wait {!model.hasPendingRepositoryWork}
            try require(model.error==nil && !NSApp.windows.contains {$0.isVisible && $0.delegate is AddProgressWindowController},"Late Add preparation opened mutation progress")
            try require(try await repo.run(["ls-files","-z","--",name]).stdout.isEmpty,"Cancelled Add preparation staged a file")
        }
        let other=container.appendingPathComponent("other-repository")
        try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
        _ = try await GitRepository(root:other,executable:git).run(["init","-b","main"])
        let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("captured-marks.json")))
        model.fileComparisonPreferences=prefs;model.requiresRepositoryScope=false;model.notifyFinder={};model.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
        defer {model.stopMonitoringForTermination()}
        var release:CheckedContinuation<Void,Never>?
        defer {release?.resume()}
        model.addSelectionPreflight={repository,paths,token in await withCheckedContinuation {release=$0};return try await repository.addSelectionIsFiles(paths,cancellation:token)}
        model.handleCommandLine(arguments:["--command=add","--path",file.path],currentDirectory:root.path)
        try await wait {release != nil}
        model.open(other);try await wait {!model.busy && model.root?.path==other.path}
        let output=model.output
        release?.resume();release=nil
        try await wait {!model.hasPendingRepositoryWork && NSApp.windows.compactMap {$0.delegate as? AddProgressWindowController}.contains {!$0.model.busy && $0.model.success}}
        let progress=NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? AddProgressWindowController}.first!
        try require(progress.model.repository.root.path==root.path && model.root?.path==other.path && model.output==output,"Delayed Add retargeted its repository or overwrote another workspace's output")
        progress.close();_ = try await repo.run(["reset","--",name])
    }
}
