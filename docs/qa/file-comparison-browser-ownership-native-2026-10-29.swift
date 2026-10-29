// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietComparisonBrowserOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-22000,y:-22000));quietComparisonBrowserOrder(mode,relativeTo:number)
    }
    @objc func quietComparisonBrowserSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-22000,y:-22000));quietComparisonBrowserSheet(sheet,completionHandler:completionHandler)
    }
}
@MainActor @main struct FileComparisonBrowserOwnershipVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ message:String,line:Int = #line,_ predicate:()->Bool)async throws {
        for _ in 0..<2000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): "+message)
    }
    static func samePath(_ actual:URL?,_ expected:URL)->Bool {
        guard let actual else{return false}
        return actual.resolvingSymlinksInPath().standardizedFileURL.path.utf8.elementsEqual(expected.resolvingSymlinksInPath().standardizedFileURL.path.utf8)
    }
    static func workspaceReady(_ workspace:RepositoryModel,expected:URL,message:String)async throws {
        do {try await wait(message){samePath(workspace.root,expected) && !workspace.busy && !workspace.hasPendingRepositoryWork}}
        catch {
            let detail:[String:Any] = ["actualPath":workspace.root?.path ?? "nil","actualURL":workspace.root?.absoluteString ?? "nil",
                "expectedPath":expected.path,"expectedURL":expected.absoluteString,"busy":workspace.busy,
                "pending":workspace.hasPendingRepositoryWork,"error":workspace.error ?? "none",
                "entries":workspace.entries.map{["path":$0.path,"state":$0.state.rawValue]}]
            throw Failure(description:message+": "+String(decoding:try JSONSerialization.data(withJSONObject:detail,options:.sortedKeys),as:UTF8.self))
        }
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor final class Gate {
        var entered=false,token:OperationCancellation?
        private var continuation:CheckedContinuation<Void,Never>?
        func hold(_ token:OperationCancellation)async {self.token=token;entered=true;await withCheckedContinuation{continuation=$0}}
        func release(){let current=continuation;continuation=nil;current?.resume()}
    }
    @MainActor final class Context {
        let root:URL,git:URL,repository:GitRepository,preferences:UserDefaults,suite:String
        let path="same 雪\t[*].txt",bytes=Data("historical source\n".utf8),working=Data("working source\n".utf8)
        var revision="",head=Data(),index=Data(),browsers:[RepositoryBrowserWindowController]=[],gates:[Gate]=[]
        var comparisons:[FileComparisonWindowController]=[],statuses:[StatusWindowController]=[],workspaces:[RepositoryModel]=[]
        var siblings:[NSWindowController]=[]
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;repository=GitRepository(root:root.appendingPathComponent("repository"),executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ComparisonBrowserOwnership."+UUID().uuidString;preferences=try unwrap(UserDefaults(suiteName:suite),"No private preferences")
            preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"EnableGravatar");preferences.set(true,forKey:"ShowAppContextMenuIcons")
        }
        func setup()async throws {
            try FileManager.default.createDirectory(at:repository.root,withIntermediateDirectories:true)
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Ownership QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            try bytes.write(to:repository.root.appendingPathComponent(path));try FileManager.default.createDirectory(at:repository.root.appendingPathComponent("folder"),withIntermediateDirectories:true)
            try Data("folder file\n".utf8).write(to:repository.root.appendingPathComponent("folder/child.txt"))
            try await repository.stage(["."]);_=try await repository.commit(message:"Ownership fixture")
            head=try await repository.run(["rev-parse","HEAD"]).stdout;revision=String(decoding:head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
            index=try Data(contentsOf:repository.root.appendingPathComponent(".git/index"));try working.write(to:repository.root.appendingPathComponent(path))
        }
        func browser()async throws->RepositoryBrowserWindowController {
            let owner=RepositoryBrowserWindowController(repository:repository,access:nil,revision:revision,preferences:preferences);browsers.append(owner);owner.showWindow(nil)
            try await wait("Browser initial snapshot did not drain"){!owner.model.busy && owner.model.snapshot != nil && !owner.model.hasPendingWork}
            return owner
        }
        func gate()->Gate {let gate=Gate();gates.append(gate);return gate}
        func clean()async {
            gates.forEach{$0.release()};browsers.forEach{$0.close()};statuses.forEach{$0.close()};comparisons.forEach{$0.close()};siblings.forEach{$0.close()};workspaces.forEach{$0.stopMonitoringForTermination()}
            for _ in 0..<2000 {if FileComparisonBrowserOwnershipVerification.drained(self){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite);HistoricalPreviewFiles.discardAll()
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Inspection changed HEAD")
            try require(try Data(contentsOf:repository.root.appendingPathComponent(".git/index"))==index,"Inspection changed actual index")
            try require(try Data(contentsOf:repository.root.appendingPathComponent(path))==working,"Inspection changed working bytes")
        }
    }
    static func drained(_ c:Context)->Bool {
        guard RepositoryBrowserWindowModel.activeOperations==0,RepositoryBrowserFileOperation.activeRequests==0,
            ExternalDocumentApplication.activeRequests==0,StatusWindowModel.activeOperations==0,
            FileListComparisonSession.activeOperations==0,AddWindowModel.activeOperations==0,
            RevertWindowModel.activeOperations==0,ResolveWindowModel.activeOperations==0,
            RebaseWindowModel.activePreparationReads==0 else{return false}
        return c.siblings.compactMap{$0 as? RebaseWindowController}.allSatisfy{!$0.transportBatchWorkPending}
            && c.workspaces.allSatisfy{!$0.busy}
            && c.comparisons.allSatisfy{!$0.model.busy && !$0.model.hasPendingEditorChoice}
    }
    static func working(_ c:Context)async throws {
        let fm=FileManager.default,otherRoot=c.root.appendingPathComponent("other-repository")
        try fm.createDirectory(at:otherRoot,withIntermediateDirectories:true)
        let other=GitRepository(root:otherRoot,executable:c.git,libgit2Configuration:.init(enabled:false))
        _=try await other.run(["init","-b","main"])
        for(key,value)in [("user.name","Other QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await other.run(["config",key,value])}
        try Data("other base\n".utf8).write(to:otherRoot.appendingPathComponent(c.path));try await other.stage([c.path]);_=try await other.commit(message:"Other source")
        let base=try await other.run(["rev-parse","HEAD:"+c.path]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let mine=try await other.run(["hash-object","-w","--stdin"],input:Data("other mine\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let theirs=try await other.run(["hash-object","-w","--stdin"],input:Data("other theirs\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let packet="0 "+String(repeating:"0",count:40)+"\t"+c.path+"\0"+"100644 \(base) 1\t\(c.path)\0"+"100644 \(mine) 2\t\(c.path)\0"+"100644 \(theirs) 3\t\(c.path)\0"
        _=try await other.run(["update-index","-z","--index-info"],input:Data(packet.utf8))
        let conflict=Data("<<<<<<< mine\nother mine\n=======\nother theirs\n>>>>>>> theirs\n".utf8)
        try conflict.write(to:otherRoot.appendingPathComponent(c.path))
        let beforeIndex=try Data(contentsOf:otherRoot.appendingPathComponent(".git/index"))
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git,libgit2Configuration:.init(enabled:false))},snapshotStore:FinderSnapshotStore(url:c.root.appendingPathComponent("private-finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("private-marks.json")),cachePersistenceDefaults:c.preferences)
        c.workspaces.append(workspace);workspace.open(otherRoot)
        try await workspaceReady(workspace,expected:otherRoot,message:"Actual private workspace did not open conflicted repository")
        try require(workspace.entries.contains{$0.path==c.path && $0.state == .conflicted},"Other workspace fixture is not actually conflicted")
        let replacementSuite=c.suite+".replacement",replacement=try unwrap(UserDefaults(suiteName:replacementSuite),"No replacement preferences")
        defer{replacement.removePersistentDomain(forName:replacementSuite)}
        workspace.fileComparisonPreferences=replacement
        let source=NSWindow(contentRect:.init(x:-22000,y:-22000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        source.isReleasedWhenClosed=false;source.appearance=NSAppearance(named:.darkAqua);source.orderFront(nil);defer{source.close()}
        workspace.fileComparisonWindowPresentation={controller in c.comparisons.append(controller);controller.showWindow(nil)}
        var received:[(URL,[String],Bool)]=[]
        workspace.readWorkingFileComparison={repository,paths,amend,token in
            received.append((repository.root,paths,repository.libgit2Configuration?.enabled ?? true))
            return try await repository.workingFileComparison(paths:paths,amendToParent:amend,cancellation:token)
        }
        workspace.showWorkingFiles(repository:c.repository,access:nil,paths:[c.path],owner:source,preferences:c.preferences)
        try await wait("Other-workspace conflict incorrectly diverted ordinary requesting-repository comparison"){!workspace.busy && c.comparisons.count==1 && c.comparisons[0].model.document != nil}
        let first=c.comparisons[0]
        try require(first.model.document?.base.bytes==c.bytes && first.model.document?.destination.bytes==c.working && samePath(first.model.snapshot.root,c.repository.root),"Working comparison used workspace root/rows instead of requesting repository")
        try require(first.model.comparisonDefaults === c.preferences && first.window?.appearance?.name==source.appearance?.name && first.window?.alphaValue==0,"Working comparison lost captured preferences/owner appearance")
        try require(received.count==1 && samePath(received[0].0,c.repository.root) && GitPathSet(received[0].1)==GitPathSet([c.path]) && !received[0].2,"Working comparison did not capture requesting backend/path identity")
        first.close()
        workspace.fileComparisonPreferences=c.preferences;workspace.activate(.status)
        try await wait("Root did not create actual Working Tree controller"){NSApp.windows.contains{samePath(($0.delegate as? StatusWindowController)?.model.repository.root,otherRoot)}}
        let status=try unwrap(NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.first{samePath($0.model.repository.root,otherRoot)},"No root-owned Working Tree controller")
        c.statuses.append(status)
        try await wait("Actual conflicted Working Tree did not load"){!status.model.busy && status.model.hasStatusSnapshot}
        // Move the real workspace after creating B's Status window. Every
        // action below uses the unchanged production Root-installed callback.
        workspace.open(c.repository.root)
        try await workspaceReady(workspace,expected:c.repository.root,message:"Actual workspace did not switch away from retained Working Tree")
        replacement.set(true,forKey:"UseLibgit2");workspace.fileComparisonPreferences=replacement
        var conflictReads:[URL]=[],conflictPresentations:[URL]=[]
        workspace.readConflictEditorEntry={repository,path,token in
            conflictReads.append(repository.root)
            return try await repository.conflictEditorEntry(path:path,cancellation:token)
        }
        workspace.conflictEditorPresentation={_,repository,path,_ in if path==c.path {conflictPresentations.append(repository.root)} }
        status.model.diff([c.path])
        try await wait("Explicit Compare on a conflicted file did not create a two-way comparison"){!workspace.busy && c.comparisons.count==2 && c.comparisons[1].model.document != nil}
        try require(samePath(received.last?.0,otherRoot) && received.last?.2==false && conflictReads.isEmpty && c.comparisons[1].model.comparisonDefaults === c.preferences && c.comparisons[1].model.document?.base.bytes==Data("other base\n".utf8) && c.comparisons[1].model.document?.destination.bytes==conflict,"Explicit conflicted Compare changed to workspace root/preferences/backend/merge intent")
        status.model.primaryFileAction([c.path]);try await wait("Root-installed primary conflict callback did not retain requesting repository"){conflictPresentations.count==1 && samePath(conflictPresentations.first,otherRoot) && workspace.conflictEditorPreparationCount==0}
        try require(conflictReads.count==1 && samePath(conflictReads.first,otherRoot) && samePath(workspace.root,c.repository.root),"Primary conflict action switched workspace or used its unrelated repository")
        let readCount=received.count
        status.model.confirmingQuit=true;status.model.diff([c.path]);status.model.primaryFileAction([c.path]);try require(received.count==readCount && conflictReads.count==1,"Quit-owned Working Tree admitted file comparison/action")
        status.model.confirmingQuit=false;c.comparisons[1].close()
        // Invalidate a read-only requesting owner while materialization ignores
        // cancellation. No stale viewer or diagnostic may survive actual drain.
        let held=c.gate();var failures:[String]=[]
        status.model.selection=GitPathSet([c.path])
        let current=status.model.captureComparisonOwner(paths:[c.path])
        try require(current(),"Actual Working Tree comparison owner was not admitted")
        workspace.readWorkingFileComparison={_,_,_,token in await held.hold(token);throw Failure(description:"late comparison failure")}
        workspace.showWorkingFiles(repository:other,access:nil,paths:[c.path],owner:status.window,preferences:c.preferences,ownerIsCurrent:current,onFailure:{failures.append($0)})
        try await wait("Owned comparison materialization did not enter"){held.entered}
        status.model.selection=[]
        try await wait("Requesting owner invalidation did not cancel comparison read"){held.token?.isCancelled==true}
        try require(workspace.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Invalidated comparison released before real worker drain")
        held.release();try await wait("Invalidated comparison did not drain"){!workspace.busy}
        try require(c.comparisons.count==2 && failures.isEmpty && workspace.error==nil,"Stale comparison read presented/diagnosed against retired request")
        // The ordinary file family retains explicit heterogeneous selections:
        // modified, deleted, untracked and gitlink rows are not reclassified by
        // an unrelated workspace. Observe the real root presentation boundary.
        let capabilitiesRoot=c.root.appendingPathComponent("capabilities");try fm.createDirectory(at:capabilitiesRoot,withIntermediateDirectories:true)
        let capabilities=GitRepository(root:capabilitiesRoot,executable:c.git,libgit2Configuration:.init(enabled:false))
        _=try await capabilities.run(["init","-b","main"])
        for(key,value)in [("user.name","Capabilities QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await capabilities.run(["config",key,value])}
        for path in ["tracked.txt","removed.txt"]{try Data((path+" base\n").utf8).write(to:capabilitiesRoot.appendingPathComponent(path))}
        try await capabilities.stage(["."]);_=try await capabilities.run(["update-index","--add","--cacheinfo","160000,"+c.revision+",module"])
        _=try await capabilities.commit(message:"Capabilities baseline")
        try Data("tracked working\n".utf8).write(to:capabilitiesRoot.appendingPathComponent("tracked.txt"));try fm.removeItem(at:capabilitiesRoot.appendingPathComponent("removed.txt"))
        try Data("untracked working\n".utf8).write(to:capabilitiesRoot.appendingPathComponent("-new 雪.txt"))
        var presented:[CommitFile]=[],presentedSnapshot:RevisionComparisonSnapshot?
        workspace.readWorkingFileComparison=nil
        workspace.fileComparisonPresentation={snapshot,file in presentedSnapshot=snapshot;presented.append(file)}
        let paths=["tracked.txt","removed.txt","-new 雪.txt","module"]
        workspace.showWorkingFiles(repository:capabilities,access:nil,paths:paths,owner:source,preferences:c.preferences)
        try await wait("Heterogeneous working selection did not reach presentation"){!workspace.busy && presented.count==paths.count}
        try require(GitPathSet(presented.map(\.path))==GitPathSet(paths) && presented.first{$0.path=="removed.txt"}?.action=="D" && presented.first{$0.path=="-new 雪.txt"}?.action=="A" && presented.first{$0.path=="module"}?.isSubmodule==true,"Working comparison narrowed deletion/untracked/gitlink source capabilities")
        try require(samePath(presentedSnapshot?.root,capabilitiesRoot),"Heterogeneous selection lost requesting repository")
        workspace.open(capabilitiesRoot)
        try await workspaceReady(workspace,expected:capabilitiesRoot,message:"Actual capability workspace did not open")
        workspace.fileComparisonPreferences=c.preferences;workspace.activate(.status)
        try await wait("Root did not create multi-selection Working Tree"){NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.contains{samePath($0.model.repository.root,capabilitiesRoot) && $0.model.hasStatusSnapshot && !$0.model.busy}}
        let multiple=try unwrap(NSApp.windows.compactMap{$0.delegate as? StatusWindowController}.first{samePath($0.model.repository.root,capabilitiesRoot)},"No actual multi-selection Working Tree")
        c.statuses.append(multiple);multiple.model.selection=GitPathSet(paths)
        c.preferences.set(0,forKey:"NumDiffWarning")
        let warningOwner=multiple.model.captureComparisonOwner(paths:paths)
        var warningReads=0
        workspace.readWorkingFileComparison={repository,paths,amend,token in warningReads += 1;return try await repository.workingFileComparison(paths:paths,amendToParent:amend,cancellation:token)}
        presented=[];multiple.model.diff(paths)
        try await wait("Actual multi-file warning did not attach"){multiple.window?.attachedSheet != nil}
        let question=try unwrap(multiple.window?.attachedSheet,"No actual comparison warning")
        try require(warningOwner() && workspace.busy && FileListComparisonSession.activeOperations==1 && question.alphaValue==0,"Own comparison warning invalidated its source or became visible")
        multiple.window?.endSheet(question,returnCode:.alertSecondButtonReturn);question.orderOut(nil)
        try await wait("Declined multi-file warning did not detach/drain"){!workspace.busy && multiple.window?.attachedSheet==nil && FileListComparisonSession.activeOperations==0}
        try require(warningReads==0 && presented.isEmpty && multiple.model.error==nil,"Declined warning materialized files or diagnosed its own sheet")
        c.preferences.removeObject(forKey:"NumDiffWarning");workspace.readWorkingFileComparison=nil
        let unbornRoot=c.root.appendingPathComponent("unborn");try fm.createDirectory(at:unbornRoot,withIntermediateDirectories:true)
        let unborn=GitRepository(root:unbornRoot,executable:c.git,libgit2Configuration:.init(enabled:false));_=try await unborn.run(["init","-b","main"])
        try Data("unborn working\n".utf8).write(to:unbornRoot.appendingPathComponent("new.txt"));presented=[];presentedSnapshot=nil
        workspace.showWorkingFiles(repository:unborn,access:nil,paths:["new.txt"],owner:source,preferences:c.preferences)
        try await wait("Unborn explicit file did not reach presentation"){!workspace.busy && presented.count==1}
        try require(presentedSnapshot?.from == .emptyTree && presented[0].action=="A","Unborn working comparison lost empty-base source behavior")
        workspace.fileComparisonPresentation=nil
        workspace.showWorkingFilePair(repository:c.repository,access:nil,paths:[c.path,"folder/child.txt"],owner:source,preferences:c.preferences)
        try await wait("Owned Compare Two working files did not load"){!workspace.busy && c.comparisons.count==3 && c.comparisons[2].model.document != nil}
        try require(c.comparisons[2].model.document?.base.bytes==c.working && c.comparisons[2].model.document?.destination.bytes==Data("folder file\n".utf8) && c.comparisons[2].model.comparisonDefaults === c.preferences,"Compare Two lost requesting files/order/preferences")
        c.comparisons[2].close()
        try await siblings(c,repository:other)
        try require(try Data(contentsOf:otherRoot.appendingPathComponent(".git/index"))==beforeIndex,"Comparison intent routes changed conflict stages")
        try await c.preserved()
    }
    static func siblings(_ c:Context,repository:GitRepository)async throws {
        let ordinary="plain new.txt";try Data("new ordinary\n".utf8).write(to:repository.root.appendingPathComponent(ordinary))
        let add=AddWindowController(repository:repository,access:nil,defaults:c.preferences);c.siblings.append(add);add.showWindow(nil)
        add.model.setScope([c.path,ordinary]);add.model.reload()
        try await wait("Actual Add scope did not load"){!add.model.busy && add.model.entries.count==2}
        let conflict=try unwrap(add.model.entries.first{$0.path==c.path},"Direct Add scope omitted conflict"),normal=try unwrap(add.model.entries.first{$0.path==ordinary},"Direct Add scope omitted ordinary file")
        var edits:[String]=[],previews:[String]=[]
        add.model.onEditConflict={edits.append($0)};add.model.onPreview={previews.append($0)}
        add.model.primaryFileAction(conflict);add.model.primaryFileAction(normal)
        try require(edits==[c.path] && previews==[ordinary],"Actual Add primary handler did not distinguish conflict edit from ordinary Preview")
        try Data("new ordinary changed metadata and bytes\n".utf8).write(to:repository.root.appendingPathComponent(ordinary));add.model.reload()
        try await wait("Add changed-row reload did not drain"){!add.model.busy}
        add.model.primaryFileAction(normal);try require(previews==[ordinary],"Stale Add native row dispatched against changed metadata")
        add.close();add.model.primaryFileAction(conflict);try require(edits==[c.path],"Retired Add primary handler dispatched")
        let revert=RevertWindowController(repository:repository,access:nil,preferences:c.preferences);c.siblings.append(revert);revert.showWindow(nil);revert.model.setScope([c.path])
        try await wait("Actual Revert conflict scope did not load"){!revert.model.busy && revert.model.entries.contains{$0.path==c.path}}
        var revertEdits=0,revertCompares=0
        revert.model.onAction={action,_ in if action == .editConflict {revertEdits += 1}}
        revert.model.onCompare={_ in revertCompares += 1}
        revert.model.diff([c.path]);revert.model.primaryFileAction([c.path])
        try require(revertCompares==1 && revertEdits==1,"Actual Revert explicit Compare/primary conflict intents diverged")
        revert.close();revert.model.primaryFileAction([c.path]);try require(revertEdits==1,"Retired Revert primary handler dispatched")
        let resolve=ResolveWindowController(repository:repository,access:nil,paths:[c.path],preferences:c.preferences);c.siblings.append(resolve);resolve.showWindow(nil)
        try await wait("Actual Resolve scope did not load"){!resolve.model.busy && resolve.model.entries.contains{$0.path==c.path}}
        var captures:[()->Bool]=[],during:[Bool]=[]
        resolve.model.onFileLog={path in let captured=resolve.model.captureComparisonOwner(paths:[path]);captures.append(captured);during.append(resolve.model.busy && captured())}
        resolve.model.fileCommand(.log,menu:resolve.model.fileMenu([c.path]))
        try await wait("Resolve own-request callback did not drain"){!resolve.model.busy && captures.count==1}
        try require(during==[true] && captures[0](),"Resolve comparison owner did not span its initiating real busy→idle request")
        resolve.model.fileCommand(.log,menu:resolve.model.fileMenu([c.path]));try require(!captures[0](),"Resolve old owner accepted a later operation")
        try await wait("Resolve second own-request callback did not drain"){!resolve.model.busy && captures.count==2}
        resolve.model.selection=resolve.model.selection.isEmpty ? GitPathSet([c.path]):GitPathSet();try require(!captures[1](),"Resolve comparison owner survived selection replacement")
        resolve.close()
        try await rebaseOwner(c)
    }
    static func rebaseOwner(_ c:Context)async throws {
        let root=c.root.appendingPathComponent("replay-owner");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:c.git,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","-b","main"])
        for(key,value)in [("user.name","Replay Owner QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        let path="conflict.txt",clean="applied.txt",file=root.appendingPathComponent(path)
        try Data("base\n".utf8).write(to:file);try await repository.stage([path]);_=try await repository.commit(message:"base")
        let base=try await repository.rebaseCommit("HEAD");_=try await repository.run(["switch","-c","upstream"])
        try Data("upstream\n".utf8).write(to:file);try await repository.stage([path]);_=try await repository.commit(message:"upstream")
        _=try await repository.run(["switch","-c","topic",base.hash]);try Data("topic\n".utf8).write(to:file);try Data("clean applied\n".utf8).write(to:root.appendingPathComponent(clean));try await repository.stage([path,clean]);_=try await repository.commit(message:"topic")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _=try await repository.startRebase(try await repository.rebasePlan(options),editorExecutable:editor)
        let owner=RebaseWindowController(repository:repository,access:nil,preferences:c.preferences);c.siblings.append(owner);owner.showWindow(nil);owner.model.load()
        try await wait("Actual Replay conflict/recovery rows did not load"){!owner.model.busy && owner.model.fileRecovery && owner.model.conflictRows.contains{$0.path==clean}}
        var captures:[()->Bool]=[],during:[Bool]=[]
        owner.model.onConflictWorkingComparison={paths,_ in let capture=owner.model.captureComparisonOwner(paths:paths);captures.append(capture);during.append(owner.model.busy && capture())}
        owner.model.compareConflictWorkingFiles(owner.model.conflictFileMenu([clean]))
        try await wait("Replay own-request comparison callback did not drain"){!owner.model.busy && captures.count==1}
        try require(during==[true] && captures[0](),"Replay owner did not span its initiating actual busy→idle callback")
        owner.model.compareConflictWorkingFiles(owner.model.conflictFileMenu([clean]));try require(!captures[0](),"Replay old owner accepted a later request")
        try await wait("Replay second comparison callback did not drain"){!owner.model.busy && captures.count==2}
        try require(!captures[0](),"Replay old owner revived after the later request drained")
        owner.model.selectedConflicts=owner.model.selectedConflicts==GitPathSet([clean]) ? GitPathSet():GitPathSet([clean]);try require(!captures[1](),"Replay owner survived changed file selection")
        owner.close()
    }
    static func browser(_ c:Context)async throws {
        // Hold actual materialization admission, retaining the real pinned
        // source content. The injection delays IO only, never invents bytes.
        let owner=try await c.browser(),m=owner.model
        let entry=try unwrap(m.entries.first{$0.path==c.path},"Missing literal historical file")
        let content=try await c.repository.repositoryBrowserFile(try unwrap(m.snapshot,"No Browser snapshot"),entry:entry)
        let capturedEditor=AlternativeEditorPreferences(custom:true,applicationPath:c.root.appendingPathComponent("CapturedEditor.app").path)
        capturedEditor.save(to:c.preferences)
        var backendEnabled=false
        m.captureMaterializationBackend={.init(enabled:backendEnabled,mask:0)}
        let gate=c.gate();var reads=0,panels=0,reply:((NSApplication.ModalResponse)->Void)?
        var deliveredContext:RepositoryBrowserWindowModel.FileReadContext?
        m.readFile={snapshot,row,token in
            reads += 1
            try require(snapshot.objectID==c.revision && row.path==c.path,"Materialization lost pinned tree/literal entry")
            await gate.hold(token);return content
        }
        owner.presentSavePanel={_,_,answer in panels += 1;reply=answer;deliveredContext=m.presentedFileContext}
        owner.saveDestination={_ in c.root.appendingPathComponent("should-not-save.txt")}
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait("Actual Browser contents table did not attach"){owner.contentsTable != nil}
        let table=try unwrap(owner.contentsTable,"No actual Browser table"),coordinator=try unwrap(owner.contentsTable?.dataSource as? RepositoryBrowserContentsTable.Coordinator,"No actual contents data source")
        let row=try unwrap(m.entries.firstIndex{$0.path==c.path},"No native historical file row")
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try await wait("Native Browser selection did not update"){m.selection==Set([entry.id])}
        let menu=NSMenu();coordinator.menuNeedsUpdate(menu)
        let save=try unwrap(menu.items.first{$0.title=="Save revision to…"},"Actual Browser file menu omitted Save")
        try require(save.isEnabled && save.image != nil,"Actual Browser Save command unavailable/missing icon")
        try require(NSApp.sendAction(try unwrap(save.action,"No native Save selector"),to:save.target,from:save),"Native Browser Save dispatch failed")
        try await wait("Owned file read did not enter"){gate.entered}
        try require(m.busy && m.hasPendingWork && !m.canUseMenu && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Materialization did not own menu/Quit admission")
        let generation=m.generation;m.refresh();m.loadDirectory("folder",select:true);m.open(entry,action:.openWith)
        try require(reads==1 && m.generation==generation && panels==0,"Competing Browser action bypassed read ownership")
        backendEnabled=true;AlternativeEditorPreferences(custom:false).save(to:c.preferences)
        gate.release();try await wait("Read did not hand off to owned Save panel"){panels==1 && m.handlingFile}
        try require(deliveredContext.map{!$0.backend.enabled && $0.editorSettings==capturedEditor && $0.entry==entry && $0.action == .save}==true,"Read→panel lost captured backend/editor/entry/action")
        try require(RepositoryBrowserFileOperation.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Read→panel lost continuous Quit ownership")
        m.cancelFileRead();reply?(.OK)
        try await wait("Cancelled panel did not release"){!m.handlingFile && !m.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent("should-not-save.txt").path) && m.error==nil,"Cancelled Save wrote bytes or diagnosed stale reply")
        backendEnabled=false
        let cancelled=c.gate();m.readFile={_,_,token in await cancelled.hold(token);return content}
        m.open(entry,action:.save);try await wait("Explicitly cancelled read did not enter"){cancelled.entered}
        m.cancelFileRead()
        try require(cancelled.token?.isCancelled==true && m.busy && m.hasPendingWork,"Cancel released the actual read before worker drain")
        cancelled.release();try await wait("Cancelled read did not drain"){!m.hasPendingWork && !m.busy}
        try require(panels==1 && m.error==nil,"Cancelled materialization presented or diagnosed stale content")
        // A directly changed requested revision invalidates an outstanding
        // source before presentation, even if its worker ignores cancellation.
        let changed=c.gate();m.readFile={_,_,token in await changed.hold(token);return content}
        m.open(entry,action:.save);try await wait("Changed-context read did not enter"){changed.entered}
        m.revision="HEAD~1";changed.release()
        try await wait("Changed-context read did not drain"){!m.hasPendingWork && !m.busy}
        try require(panels==1 && m.error==nil,"Late source materialization presented/diagnosed against changed revision")
        m.revision=c.revision
        // Closing a live owner cancels the same token, keeps Quit blocked until
        // the actual held worker exits, and suppresses its late error.
        let closing=try await c.browser(),closeEntry=try unwrap(closing.model.entries.first{$0.path==c.path},"No closing read row"),held=c.gate()
        var closedPanels=0
        closing.presentSavePanel={_,_,_ in closedPanels += 1}
        closing.model.readFile={_,_,token in await held.hold(token);throw Failure(description:"late retired read failure")}
        closing.model.open(closeEntry,action:.save);try await wait("Closing read did not enter"){held.entered}
        closing.close()
        try require(held.token?.isCancelled==true && closing.hasPendingWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed read lost cancellation/drain/Quit ownership")
        held.release();try await wait("Retired materialization did not drain"){!closing.hasPendingWork}
        try require(closedPanels==0 && closing.model.error==nil && !closing.model.active,"Retired materialization published a panel/error")
        // Open With cancellation must not allocate/launch any preview helper.
        m.readFile=nil
        var apps=0,appReply:((NSApplication.ModalResponse)->Void)?,launches=0
        owner.presentApplicationPanel={_,_,answer in apps += 1;appReply=answer}
        owner.launchDocument={_,_,_ in launches += 1}
        m.open(entry,action:.openWith);try await wait("Open With did not present owned picker"){apps==1}
        m.confirmingQuit=true;appReply?(.OK)
        try await wait("Cancelled Open With did not drain"){!m.hasPendingWork && !m.handlingFile && RepositoryBrowserFileOperation.activeRequests==0}
        try require(launches==0 && ExternalDocumentApplication.activeRequests==0,"Cancelled application picker launched a helper")
        m.confirmingQuit=false
        let application=c.root.appendingPathComponent("PrivateReceiver.app");try FileManager.default.createDirectory(at:application,withIntermediateDirectories:true)
        owner.defaultApplication={_ in application}
        owner.launchDocument={app,documents,configuration in
            // The production opener reconstructs this application URL from
            // its path. Directory-hint/trailing-slash URL representation is
            // irrelevant; preserve exact standardized filesystem path bytes.
            try require(app.standardizedFileURL.path.utf8.elementsEqual(application.standardizedFileURL.path.utf8) && documents.count==1 && configuration.arguments.isEmpty,"Native primary open changed captured application request")
            try require(try Data(contentsOf:documents[0])==c.bytes,"Native primary open changed historical bytes")
            launches += 1
        }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        let current=try unwrap(owner.contentsTable,"No current primary-action table")
        current.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try require(NSApp.sendAction(try unwrap(current.doubleAction,"No native Browser primary action"),to:current.target,from:current),"Actual Browser primary action refused dispatch")
        do {try await wait("Native primary file open did not settle"){launches==1 && !m.handlingFile && !m.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}}
        catch {
            let activeCoordinator=current.dataSource as? RepositoryBrowserContentsTable.Coordinator
            let diagnostic:[String:Any] = ["launches":launches,"busy":m.busy,"handlingFile":m.handlingFile,
                "hasPendingWork":m.hasPendingWork,"fileRequests":RepositoryBrowserFileOperation.activeRequests,
                "documentRequests":ExternalDocumentApplication.activeRequests,"error":m.error ?? "none",
                "modelSelection":Array(m.selection),"nativeSelection":Array(current.selectedRowIndexes),
                "requestedRow":row,"nativeRows":current.numberOfRows,"modelRows":m.entries.map(\.path),
                "coordinatorAvailable":activeCoordinator?.available ?? false,"canUseMenu":m.canUseMenu,
                "revision":m.revision,"snapshotObject":m.snapshot?.objectID ?? "none","snapshotTree":m.snapshot?.treeID ?? "none",
                "isCurrentTable":owner.contentsTable === current,"tableOwnerMatches":current.window === owner.window,
                "actualTarget":current.target.map{String(describing:type(of:$0))} ?? "none",
                "sheet":owner.window?.attachedSheet != nil,"confirmingQuit":m.confirmingQuit,
                "presentationContextActive":m.presentedFileContext != nil]
            let text=String(decoding:try JSONSerialization.data(withJSONObject:diagnostic,options:.sortedKeys),as:UTF8.self)
            throw Failure(description:"Native primary action state: "+text+"; "+String(describing:error))
        }
        // Actual native sheet teardown uses the same delivery cancellation hook,
        // including Quit while the panel is waiting for a human response.
        for action in [RepositoryBrowserWindowModel.FileAction.save,.openWith] {
            let native=try await c.browser(),row=try unwrap(native.model.entries.first{$0.path==c.path},"Native panel row missing")
            native.model.open(row,action:action)
            try await wait("Production Browser chooser did not attach"){native.window?.attachedSheet != nil}
            let sheet=try unwrap(native.window?.attachedSheet,"No native Browser chooser")
            try require(sheet.alphaValue==0,"Owned Browser chooser became visible")
            if action == .save {native.model.cancelFileRead()} else {native.model.confirmingQuit=true}
            try await wait("Cancelled native Browser chooser failed to detach/drain"){native.window?.attachedSheet==nil && !native.model.handlingFile && !native.model.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
            try require(native.model.error==nil,"Cancelled native Browser chooser published a diagnostic")
            native.model.confirmingQuit=false;native.close()
        }
        let writing=try await c.browser(),writingEntry=try unwrap(writing.model.entries.first{$0.path==c.path},"Held write row missing"),writer=c.gate()
        var writeReply:((NSApplication.ModalResponse)->Void)?
        writing.presentSavePanel={_,_,answer in writeReply=answer};writing.saveDestination={_ in c.root.appendingPathComponent("held-write-output.txt")}
        writing.writeDocument={bytes,_,token in try require(bytes==c.bytes,"Held writer received wrong historical bytes");await writer.hold(token);throw Failure(description:"late canceled writer")}
        writing.model.open(writingEntry,action:.save);try await wait("Held writer Save panel did not arrive"){writeReply != nil};writeReply?(.OK)
        try await wait("Accepted writer did not enter"){writer.entered}
        writing.model.confirmingQuit=true
        try require(writer.token?.isCancelled==true && RepositoryBrowserFileOperation.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit canceled writer without retaining actual work")
        writer.release();try await wait("Canceled actual writer did not drain"){!writing.hasPendingWork && RepositoryBrowserFileOperation.activeRequests==0}
        try require(writing.model.error==nil && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("held-write-output.txt").path),"Canceled writer published a stale result/diagnostic")
        writing.model.confirmingQuit=false;writing.close()
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietComparisonBrowserOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietComparisonBrowserSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let c=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {try await c.setup();try await browser(c);try await working(c);await c.clean()}catch{await c.clean();throw error}
        let owners=c.browsers.map{$0 as NSWindowController}+c.comparisons.map{$0 as NSWindowController}+c.statuses.map{$0 as NSWindowController}+c.siblings
        try require(drained(c) && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Browser/comparison windows/workers survived cleanup")
        print("PASS: File comparison/browser ownership, captured intent, native source/context delivery, cancellation and drain")
    }
}
