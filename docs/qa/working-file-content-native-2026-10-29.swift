// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietSelectedContentOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-22000,y:-22000));quietSelectedContentOrder(mode,relativeTo:number)
    }
    @objc func quietSelectedContentSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-22000,y:-22000));quietSelectedContentSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main struct WorkingFileContentVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func samePath(_ lhs:URL?,_ rhs:URL)->Bool {guard let lhs else{return false};return lhs.resolvingSymlinksInPath().standardizedFileURL.path.utf8.elementsEqual(rhs.resolvingSymlinksInPath().standardizedFileURL.path.utf8)}
    static func wait(_ message:String,line:Int = #line,_ predicate:()->Bool)async throws {
        for _ in 0..<2000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): "+message)
    }
    @MainActor final class Context {
        let root:URL,repository:GitRepository,preferences:UserDefaults,suite:String
        let path="selected 雪\t[*].txt",original=Data("selected parent bytes\r\n".utf8),headBytes=Data("selected current HEAD bytes\n".utf8)
        var workspace:RepositoryModel?,comparisons:[FileComparisonWindowController]=[],owners:[NSWindowController]=[]
        var submodules:[SubmoduleDiffWindowController]=[]
        init(root:URL,git:URL)throws {
            self.root=root;repository=GitRepository(root:root.appendingPathComponent("repository",isDirectory:true),executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.SelectedContent."+UUID().uuidString;preferences=try unwrap(UserDefaults(suiteName:suite),"No private preferences")
            for key in ["UseLibgit2","EnableGravatar","TurtleGit.Commit.GitGuiInterface"]{preferences.set(false,forKey:key)}
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","ShowAppContextMenuIcons"]{preferences.set(true,forKey:key)}
        }
        func setup()async throws {
            try FileManager.default.createDirectory(at:repository.root,withIntermediateDirectories:true);_=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Selected Content QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            try original.write(to:repository.root.appendingPathComponent(path));try await repository.stage([path]);_=try await repository.commit(message:"parent selected content")
            let executable=repository.executable
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:executable,libgit2Configuration:.init(enabled:false))},snapshotStore:FinderSnapshotStore(url:root.appendingPathComponent("private-finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("private-marks.json")),cachePersistenceDefaults:preferences)
            workspace=model;model.fileComparisonPreferences=preferences
            model.fileComparisonWindowPresentation={ [weak self] controller in self?.comparisons.append(controller);controller.showWindow(nil)}
            model.open(repository.root)
            try await wait("Private selected-content workspace did not open"){samePath(model.root,self.repository.root) && !model.busy && !model.hasPendingRepositoryWork}
        }
        func clean()async {
            comparisons.forEach{$0.close()};owners.forEach{$0.close()};submodules.forEach{$0.close()};workspace?.stopMonitoringForTermination()
            for _ in 0..<2000{if drained(self){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite)
        }
        func preserved(head:Data,index:Data,working:Data,phase:String)async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,phase+": Native comparison changed HEAD")
            let actual=try Data(contentsOf:repository.root.appendingPathComponent(".git/index"))
            if actual != index {
                try index.write(to:root.appendingPathComponent(phase+"-index-before.bin"));try actual.write(to:root.appendingPathComponent(phase+"-index-after.bin"))
            }
            try require(actual==index,phase+": Native comparison changed actual index bytes (before \(index.count), after \(actual.count)); private before/after evidence retained")
            try require(try Data(contentsOf:repository.root.appendingPathComponent(path))==working,phase+": Native comparison changed selected working bytes")
        }
    }
    static func drained(_ c:Context)->Bool {
        FileListComparisonSession.activeOperations==0 && StatusWindowModel.activeOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileDrops==0 && PatchWindowModel.activeOperations==0 && c.workspace?.busy != true && c.comparisons.allSatisfy{!$0.model.busy && !$0.model.hasPendingEditorChoice} && c.submodules.allSatisfy{!$0.hasPendingWork}
    }
    static func ready(_ owner:CommitWindowController)async throws {
        let model=owner.model
        try await wait("Commit selected-content read did not settle: "+(model.error ?? "none")){!model.busy && model.changelistsLoaded && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.loadingAuthorDate && model.commitIdentityPrepared && !model.savingPreferences && !model.fileWorkPending && !model.stagingHintVisible && !model.mergeHintVisible}
        try require(model.error==nil,"Commit selected-content error: "+(model.error ?? "none"))
    }
    static func verify(_ c:Context)async throws {
        let workspace=try unwrap(c.workspace,"No private workspace"),head=try await c.repository.run(["rev-parse","HEAD"]).stdout
        var index=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        let source=NSWindow(contentRect:.init(x:-22000,y:-22000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        source.isReleasedWhenClosed=false;source.appearance=NSAppearance(named:.darkAqua);source.orderFront(nil);c.owners.append(NSWindowController(window:source))
        workspace.showWorkingFiles(repository:c.repository,access:nil,paths:[c.path],owner:source,preferences:c.preferences)
        try await wait("Root omitted explicitly selected unchanged file"){!workspace.busy && c.comparisons.count==1 && c.comparisons[0].model.document != nil}
        let clean=c.comparisons[0]
        try require(clean.model.document?.base.bytes==c.original && clean.model.document?.destination.bytes==c.original,"Root unchanged selection did not display both actual file sides")
        try require(clean.model.comparisonDefaults === c.preferences && clean.window?.appearance?.name==source.appearance?.name,"Unchanged comparison lost owner preferences/appearance")
        clean.close();try await c.preserved(head:head,index:index,working:c.original,phase:"root-unchanged")
        // The file is a real MM status row although its working contents equal
        // HEAD. This is a user-visible explicit Compare, not a fabricated row.
        try Data("different staged bytes\n".utf8).write(to:c.repository.root.appendingPathComponent(c.path));try await c.repository.stage([c.path]);try c.original.write(to:c.repository.root.appendingPathComponent(c.path))
        index=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        workspace.activate(.status,paths:[c.path])
        try await wait("Root-created Working Tree did not load"){NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.contains{samePath($0.model.repository.root,c.repository.root) && !$0.model.busy && $0.model.hasStatusSnapshot}}
        let status=try unwrap(NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.first{samePath($0.model.repository.root,c.repository.root)},"No root-owned Working Tree");c.owners.append(status)
        // Status initialization has its own refresh contract. Fence the tested
        // display comparison after that lifecycle, while also retaining the
        // intentionally different staged blob and the unchanged working file.
        try require(try await c.repository.run(["show",":"+c.path]).stdout==Data("different staged bytes\n".utf8),"Status initialization changed the intended staged blob")
        index=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        status.model.diff([c.path])
        try await wait("Working Tree dropped a selected row whose effective HEAD→working contents are unchanged"){!workspace.busy && c.comparisons.count==2 && c.comparisons[1].model.document != nil}
        try require(c.comparisons[1].model.document?.base.bytes==c.original && c.comparisons[1].model.document?.destination.bytes==c.original,"Working Tree displayed index bytes instead of effective HEAD/working bytes")
        c.comparisons[1].close();status.close();try await c.preserved(head:head,index:index,working:c.original,phase:"status-effective-equal")
        // Set up a new HEAD, then use the actual Commit owner and shared menu
        // capture. No Commit/Stage operation is invoked by the UI under test.
        try c.headBytes.write(to:c.repository.root.appendingPathComponent(c.path));try await c.repository.stage([c.path]);_=try await c.repository.commit(message:"head selected content")
        let currentHead=try await c.repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        workspace.activate(.commit,paths:[c.path])
        try await wait("Root did not create actual Commit owner"){NSApp.windows.contains{$0.delegate is CommitWindowController}}
        let commit=try unwrap(NSApp.windows.compactMap{$0.delegate as? CommitWindowController}.first,"No actual Commit owner");c.owners.append(commit)
        try await ready(commit)
        let model=commit.model
        model.setFormOption(.amend,value:true,receipt:model.formReceipt);try await ready(commit)
        model.setFormOption(.amendComparison,value:false,receipt:model.formReceipt);try await ready(commit)
        try require(model.amendToParent && model.entries.contains{$0.path==c.path},"Commit amend-to-parent selected row was not available")
        let menu=model.fileMenu([c.path]);model.withFileMenu(menu){model.compare(paths:[c.path])}
        try await wait("Commit selected amend row did not reach real comparison"){!workspace.busy && c.comparisons.count==3 && c.comparisons[2].model.document != nil}
        let amended=c.comparisons[2]
        try require(amended.model.snapshot.from == .revision(String(decoding:head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)) && amended.model.document?.base.bytes==c.original && amended.model.document?.destination.bytes==c.headBytes,"Commit amend selected comparison used HEAD/working default instead of pinned parent/current bytes")
        try require(amended.model.comparisonDefaults === c.preferences,"Commit amend comparison lost originating preferences")
        amended.close();model.message="";commit.close();try await c.preserved(head:currentHead,index:index,working:c.headBytes,phase:"commit-amend-parent")
        try await submodules(c,source:source)
    }
    static func submodules(_ c:Context,source:NSWindow)async throws {
        let root=c.root.appendingPathComponent("submodule-parent",isDirectory:true),childRoot=root.appendingPathComponent("module",isDirectory:true),fm=FileManager.default
        try fm.createDirectory(at:childRoot,withIntermediateDirectories:true)
        let parent=GitRepository(root:root,executable:c.repository.executable,libgit2Configuration:.init(enabled:false)),child=GitRepository(root:childRoot,executable:c.repository.executable,libgit2Configuration:.init(enabled:false))
        for repository in [parent,child] {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Submodule Content QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        }
        try Data("parent baseline\n".utf8).write(to:root.appendingPathComponent("parent.txt"));try await parent.stage(["parent.txt"]);_=try await parent.commit(message:"parent baseline")
        try Data("child index revision\n".utf8).write(to:childRoot.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"index child")
        let indexOID=try await child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await parent.run(["update-index","--add","--cacheinfo","160000,"+indexOID+",module"])
        try Data("child later HEAD\n".utf8).write(to:childRoot.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"later child")
        let childOID=try await child.run(["rev-parse","HEAD"]).stdout
        let dirty=Data("child dirty working\n".utf8);try dirty.write(to:childRoot.appendingPathComponent("child.txt"))
        let head=try await parent.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),childIndex=try Data(contentsOf:childRoot.appendingPathComponent(".git/index"))
        let workspace=try unwrap(c.workspace,"No submodule route owner");var raw:[CommitFile]=[]
        workspace.readWorkingFileComparison={repository,paths,amend,token in let snapshot=try await repository.workingFileComparison(paths:paths,amendToParent:amend,cancellation:token);raw.append(contentsOf:snapshot.files);return snapshot}
        workspace.submoduleDiffPresentation={controller in c.submodules.append(controller);controller.showWindow(nil)}
        workspace.showWorkingFiles(repository:parent,access:nil,paths:["module"],owner:source,preferences:c.preferences)
        try await wait("Root Added-submodule comparison did not load"){!workspace.busy && c.submodules.count==1 && !c.submodules[0].model.busy && c.submodules[0].model.details != nil}
        let addition=try unwrap(c.submodules[0].model.details,"No actual Added submodule details")
        try require(raw.count==1 && raw[0].action.hasPrefix("A") && raw[0].isSubmodule,"Root did not retain Added null-side gitlink flags")
        try require(addition.from.revision==nil && addition.to.revision==indexOID && !addition.toWorkingTree && addition.dirty && addition.change == .newSubmodule,"Root Added DiffNull displayed child HEAD instead of index gitlink")
        try require(try await parent.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Added submodule presentation changed parent storage")
        try require(try await child.run(["rev-parse","HEAD"]).stdout==childOID && Data(contentsOf:childRoot.appendingPathComponent(".git/index"))==childIndex && Data(contentsOf:childRoot.appendingPathComponent("child.txt"))==dirty,"Added submodule presentation changed child storage")
        c.submodules[0].close()
        _=try await parent.commit(message:"record index gitlink")
        _=try await parent.run(["rm","--cached","--","module"]);try fm.moveItem(at:childRoot,to:root.appendingPathComponent("detached-child",isDirectory:true))
        let deletedHead=try await parent.run(["rev-parse","HEAD"]).stdout,deletedIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        raw=[];workspace.showWorkingFiles(repository:parent,access:nil,paths:["module"],owner:source,preferences:c.preferences)
        try await wait("Root Deleted-submodule comparison did not load"){!workspace.busy && c.submodules.count==2 && !c.submodules[1].model.busy && c.submodules[1].model.details != nil}
        let deletion=try unwrap(c.submodules[1].model.details,"No actual Deleted submodule details")
        try require(raw.count==1 && raw[0].action.hasPrefix("D") && raw[0].isSubmodule && deletion.from.revision==indexOID && deletion.to.revision==nil && !deletion.toWorkingTree && deletion.change == .deleteSubmodule,"Root Deleted DiffNull did not retain historical→empty/uninitialized flags")
        try require(try await parent.run(["rev-parse","HEAD"]).stdout==deletedHead && Data(contentsOf:root.appendingPathComponent(".git/index"))==deletedIndex,"Deleted submodule presentation changed parent storage")
        c.submodules[1].close()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietSelectedContentOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietSelectedContentSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let c=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do{try await c.setup();try await verify(c);await c.clean()}catch{await c.clean();throw error}
        let owners=c.owners+c.comparisons.map{$0 as NSWindowController}+c.submodules.map{$0 as NSWindowController}
        try require(drained(c) && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Selected-file native owners/workers survived cleanup")
        print("PASS: Working-file content selection Root/Working Tree unchanged and actual Commit amend bytes, storage preservation and drain")
    }
}
