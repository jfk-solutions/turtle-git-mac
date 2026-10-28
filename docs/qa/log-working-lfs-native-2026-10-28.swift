// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Combine
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitLogLFSBeginSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        // AppKit can present/reposition a sheet without the public order route.
        // Set alpha before presentation, independent of its eventual geometry.
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitLogLFSBeginSheet(sheet,completionHandler:completionHandler)
    }
    @objc func turtleGitLogLFSOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitLogLFSOrder(place,relativeTo:number)
    }
}

/// Real selected-path Git dispatch through a private executable LFS stub. No
/// public server, user preferences, general pasteboard or visible window is used.
@main struct LogWorkingLFSVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:5_000_000)}
        throw Failure(description:"Log LFS did not settle at line \(line)")
    }
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func exact(_ values:[String])->[Data] {values.map{Data($0.utf8)}}
    @MainActor static func drained()->Bool {
        LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 &&
        LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeWorkingLFSReads==0 &&
        LFSLocksWindowModel.activeOperations==0 && LogWindowModel.activeNoteReads==0
    }
    @MainActor final class ReadHold {
        var token:OperationCancellation?
        var paths:[String]=[]
        var reply:CheckedContinuation<[WorkingTreeFile],Never>?
        func release(_ rows:[WorkingTreeFile]) {let current=reply;reply=nil;current?.resume(returning:rows)}
    }
    @MainActor final class Context {
        let root:URL,git:URL,actual:GitRepository,repository:GitRepository
        let preferences:UserDefaults,suite:String,clipboard:NSPasteboard
        var owners:[LogWindowController]=[],progress:[LFSFileOperationController]=[],holds:[ReadHold]=[]
        var workspaces:[RepositoryModel]=[],noteReleases:[()->Void]=[]
        var initialHead=Data(),initialIndex=Data(),initialConfig=Data(),initialContents:[String:Data]=[:]
        let modified=["asset a.bin","雪\t🦎.bin"]
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;actual=GitRepository(root:root,executable:git,diffDetection:.init(percentage:50))
            repository=GitRepository(root:root,executable:root.appendingPathComponent("lfs-test-git"),diffDetection:.init(percentage:50))
            suite="TurtleGit.LogWorkingLFS."+UUID().uuidString;preferences=try unwrap(UserDefaults(suiteName:suite),"Missing private preferences")
            clipboard=NSPasteboard.withUniqueName()
            for key in ["EnableLogCache","EnableGravatar","UseLibgit2","ShowGitexeTimings"] {preferences.set(false,forKey:key)}
            preferences.set(true,forKey:"LogIncludeWorkingTreeChanges");preferences.set(true,forKey:"ShowAppContextMenuIcons")
            preferences.set(0,forKey:"AutoCloseGitProgress")
            // This global Status preference must never expand Log's source mask
            // or cause an unrelated locks --json server query.
            preferences.set(true,forKey:"WorkingTree.LFSOwnerVisible")
        }
        func setup()async throws {
            _=try await actual.run(["init","-b","main"])
            for(key,value)in [("user.name","Log LFS QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await actual.run(["config",key,value])}
            // Identical base blobs plus an unmerged index can make Git's real
            // `status --renames` suppress the separate deleted gone.bin row:
            // --no-renames and `diff HEAD` still report it. Give each source a
            // distinct payload so this LFS fixture actually contains all states.
            func original(_ path:String)->Data {Data(String(repeating:"original \(path) payload\n",count:32).utf8)}
            for path in modified+["gone.bin","was-file.bin","conflict.bin"] {try original(path).write(to:root.appendingPathComponent(path))}
            try Data("ignored.bin\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
            try await actual.stage(["."]);_=try await actual.commit(message:"private Log LFS source states")
            for path in modified {try Data("modified\n".utf8).write(to:root.appendingPathComponent(path))}
            try FileManager.default.removeItem(at:root.appendingPathComponent("gone.bin"))
            try FileManager.default.removeItem(at:root.appendingPathComponent("was-file.bin"))
            try FileManager.default.createDirectory(at:root.appendingPathComponent("was-file.bin"),withIntermediateDirectories:true)
            try Data("untracked child\n".utf8).write(to:root.appendingPathComponent("was-file.bin/child"))
            for path in ["added.bin","untracked.bin","ignored.bin"] {try Data("new\n".utf8).write(to:root.appendingPathComponent(path))}
            try await actual.stage(["added.bin"])
            var hashes:[String]=[]
            for bytes in [original("conflict.bin"),Data("mine\n".utf8),Data("theirs\n".utf8)] {hashes.append(try await actual.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.newlines))}
            let unmerged="0 \(String(repeating:"0",count:40))\tconflict.bin\0"+hashes.enumerated().map{"100644 \($0.element) \($0.offset+1)\tconflict.bin\0"}.joined()
            _=try await actual.run(["update-index","-z","--index-info"],input:Data(unmerged.utf8))
            let rawStatus=try await actual.run(["status","--porcelain=v1","-z","--untracked-files=all","--find-renames=50%"]).stdout
            let setupEntries=StatusEntry.parse(rawStatus)
            for(path,state)in [("gone.bin",FileState.deleted),("added.bin",.added),("conflict.bin",.conflicted),("untracked.bin",.untracked)] {
                try require(setupEntries.contains{GitReferenceName.equal($0.path,path) && $0.state==state},"Real Git setup omitted \(path)/\(state): \(String(decoding:rawStatus,as:UTF8.self).debugDescription)")
            }
            try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:["engine":git.path]).write(to:root.appendingPathComponent(".git/lfs-fixture.json"))
            let stub = #"""
            #!/usr/bin/python3
            import os,sys,json,time,pathlib,signal
            args=sys.argv[1:];i=args.index('-C');root=pathlib.Path(args[i+1]);cmd=args[i+2:]
            config=json.loads((root/'.git/lfs-fixture.json').read_text())
            if not cmd or cmd[0]!='lfs':os.execv(config['engine'],[config['engine']]+args)
            log=root/'.git/lfs-calls.jsonl'
            with log.open('a') as out:out.write(json.dumps(cmd,ensure_ascii=True)+'\n')
            if cmd==['lfs','locks','--json']:print('unexpected lock-list query',file=sys.stderr);sys.exit(91)
            if len(cmd)<4 or cmd[1]not in ('lock','unlock')or cmd[-2]!='--':print('invalid literal argv',file=sys.stderr);sys.exit(92)
            control=root/'.git/lfs-control.json';mode=json.loads(control.read_text())if control.exists()else{}
            path=cmd[-1]
            if mode.get('holdPath')==path:
                active=root/'.git/lfs-active.json'
                active.write_text(json.dumps({'pid':os.getpid(),'path':path,'argv':sys.argv}))
                def terminate(*_):raise SystemExit(143)
                signal.signal(signal.SIGTERM,terminate)
                try:
                    with (root/'.git/lfs-held-open').open('ab') as owned:
                        deadline=time.monotonic()+20
                        while not(root/'.git/lfs-release').exists()and time.monotonic()<deadline:time.sleep(.01)
                        if not(root/'.git/lfs-release').exists():print('private hold timeout',file=sys.stderr);sys.exit(93)
                finally:active.unlink(missing_ok=True)
            if mode.get('failPath')==path and '--force'not in cmd:print('owned by another user',file=sys.stderr);sys.exit(1)
            print(('Locked 'if cmd[1]=='lock'else'Unlocked ')+path)
            """#
            let executable=root.appendingPathComponent("lfs-test-git")
            try Data(stub.utf8).write(to:executable);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
        }
        func control(_ value:[String:String])throws {
            try? FileManager.default.removeItem(at:root.appendingPathComponent(".git/lfs-release"))
            try JSONSerialization.data(withJSONObject:value).write(to:root.appendingPathComponent(".git/lfs-control.json"),options:.atomic)
        }
        func calls()throws->[[String]] {
            let path=root.appendingPathComponent(".git/lfs-calls.jsonl")
            guard FileManager.default.fileExists(atPath:path.path)else{return []}
            return try String(contentsOf:path,encoding:.utf8).split(separator:"\n").map{try JSONDecoder().decode([String].self,from:Data($0.utf8))}
        }
        func open()async throws->LogWindowController {
            let owner=LogWindowController(repository:repository,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owners.append(owner);owner.model.clipboard=clipboard
            owner.makeLFSOperation={ [unowned self] repo,access,defaults in
                let child=LFSFileOperationController(repository:repo,access:access,defaults:defaults)
                child.window?.alphaValue=0;child.window?.setFrameOrigin(.init(x:-24000,y:-24000))
                progress.append(child);return child
            }
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            owner.model.reload();try await wait{!owner.model.busy && owner.model.entries.contains{$0.hash.isEmpty}}
            owner.model.select([""]);try await working(owner)
            return owner
        }
        func working(_ owner:LogWindowController)async throws {
            try await wait{!owner.model.busy && owner.model.selectedWorkingTree && modified.allSatisfy{path in owner.model.files.contains{GitReferenceName.equal($0.path,path)}}}
        }
        func finishReview(_ child:LFSFileOperationController,owner:LogWindowController)async throws {
            var sawReload=false
            // Drop the initial busy=true result-review publication. A later
            // true transition is the actual deferred automatic reload, after
            // finishProgress first releases the review's busy state.
            let subscription=owner.model.$busy.dropFirst().sink{if $0 {sawReload=true}}
            defer {subscription.cancel()}
            child.model.finishProgress()
            // Observe that reload and its actual read drain, not an arbitrary
            // delay or explicit reload that would hide the completion route.
            try await wait{sawReload && owner.lfsOperation==nil && !owner.model.busy && LogWindowModel.activeHistoryLoads==0}
            try await working(owner)
        }
        func files(_ paths:[String],_ owner:LogWindowController)throws->[CommitFile] {
            let wanted=GitPathSet(paths),rows=owner.model.fileTableRows.compactMap(\.file).filter{wanted.contains($0.path)}
            if rows.count != wanted.count {
                let visible=owner.model.fileTableRows.compactMap(\.file).map{["path":$0.path,"oldPath":$0.oldPath ?? "","action":$0.action,"id":$0.id]}
                let diagnostic=String(data:try JSONSerialization.data(withJSONObject:visible,options:.sortedKeys),encoding:.utf8) ?? "unavailable"
                throw Failure(description:"Missing requested actual changed-file rows: \(paths); selected=\(owner.model.selected), modelFiles=\(owner.model.files.count), visible=\(diagnostic)")
            }
            return rows
        }
        func ids(_ paths:[String],_ owner:LogWindowController)throws->GitPathSet {GitPathSet(try files(paths,owner).map(\.id))}
        func actionDiagnostic(_ ids:GitPathSet,locked:Bool,_ owner:LogWindowController)->String {
            let m=owner.model
            let value:[String:Any]=["ids":Array(ids),"selected":Array(m.selectedFiles),"revisions":Array(m.selected),
                "canStart":m.canWorkingLFS(ids,locked:locked),"actions":m.workingLFSActions(ids).map{String(describing:$0)},
                "busy":m.busy,"error":m.error ?? "","invalidated":m.isInvalidated,"working":m.selectedWorkingTree,
                "sheet":owner.window?.attachedSheet.map{String(describing:type(of:$0))} ?? "none",
                "preflight":m.workingLFSReadPending,"child":owner.lfsOperation != nil,"historyReads":LogWindowModel.activeHistoryLoads]
            return (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)).flatMap{String(data:$0,encoding:.utf8)} ?? "unavailable"
        }
        func ready(_ ids:GitPathSet,locked:Bool,_ owner:LogWindowController)async throws {
            do {try await wait{!owner.model.busy && !owner.model.workingLFSReadPending && owner.lfsOperation==nil && LogWindowModel.activeHistoryLoads==0 && owner.window?.attachedSheet==nil && owner.model.error==nil}}
            catch {throw Failure(description:"Log LFS action readiness failed: \(actionDiagnostic(ids,locked:locked,owner))")}
            try require(owner.model.canWorkingLFS(ids,locked:locked),"Log LFS valid dispatch refused: \(actionDiagnostic(ids,locked:locked,owner))")
        }
        func dispatch(_ ids:GitPathSet,locked:Bool,_ owner:LogWindowController)async throws {
            try await ready(ids,locked:locked,owner)
            owner.model.setWorkingLFSLocked(ids,locked:locked)
            try require(owner.model.workingLFSReadPending,"Log LFS dispatch did not accept preflight: \(actionDiagnostic(ids,locked:locked,owner))")
        }
        func acknowledgeError(_ owner:LogWindowController)async throws {
            // Keep the expected error until SwiftUI actually presents its sheet;
            // clearing the binding early races later presentation/dismissal.
            try await wait{owner.window?.attachedSheet != nil}
            let sheet=try unwrap(owner.window?.attachedSheet,"Missing expected error sheet")
            try await wait{views(sheet.contentView).compactMap{$0 as? NSButton}.contains{$0.title=="OK"}}
            let okay=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title=="OK"},"Missing native error acknowledgement")
            let intersectsScreen=NSScreen.screens.contains{$0.frame.intersects(sheet.frame)}
            let diagnostic:[String:Any]=["alpha":sheet.alphaValue,"isVisible":sheet.isVisible,"frame":NSStringFromRect(sheet.frame),
                "intersectsScreen":intersectsScreen,"screens":NSScreen.screens.map{NSStringFromRect($0.frame)},
                "parentAlpha":owner.window?.alphaValue ?? -1,"parentFrame":owner.window.map{NSStringFromRect($0.frame)} ?? "none"]
            let serialized=(try? JSONSerialization.data(withJSONObject:diagnostic,options:.sortedKeys)).flatMap{String(data:$0,encoding:.utf8)} ?? "unavailable"
            print("Log LFS owned error sheet presentation: "+serialized);fflush(stdout)
            // Cocoa positions sheets relative to the owner after our order
            // hook. Invisible OR outside every screen meets fixture policy.
            try require(sheet.alphaValue==0 || !sheet.isVisible || !intersectsScreen,"Owned error sheet could appear on the user desktop: \(serialized)")
            okay.performClick(nil)
            try await wait{owner.model.error==nil && owner.window?.attachedSheet==nil}
        }
        func select(_ paths:[String],_ owner:LogWindowController)async throws->GitPathSet {
            do {try await wait{!owner.model.busy && !owner.model.workingLFSReadPending && owner.lfsOperation==nil && LogWindowModel.activeHistoryLoads==0 && owner.window?.attachedSheet==nil && owner.model.error==nil}}
            catch {throw Failure(description:"Log LFS native selection not ready for \(paths): \(actionDiagnostic(GitPathSet(),locked:true,owner))")}
            let ids=try ids(paths,owner)
            try await wait{views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.contains{$0.nativeTable?.window === owner.window}}
            let probe=try unwrap(views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.first{$0.nativeTable?.window === owner.window},"Missing attached native Log file adapter")
            let table=try unwrap(probe.nativeTable,"Missing actual changed-file table")
            try await wait{probe.rows.map(\.rawID)==owner.model.fileTableRows.map(\.rawID) && table.numberOfRows==probe.rows.count}
            let rows=owner.model.fileTableRows,wanted=GitPathSet(paths)
            let indexes=IndexSet(rows.indices.filter{rows[$0].file.map{wanted.contains($0.path)} == true})
            try require(indexes.count==paths.count,"Native selection omitted requested path indexes")
            func diagnostic()->String {
                let value:[String:Any]=["requestedPaths":paths,"requestedIDs":Array(ids),"requestedIndexes":Array(indexes),
                    "probeIDs":probe.rows.map(\.rawID),"nativeIndexes":Array(table.selectedRowIndexes),
                    "nativeRowCount":table.numberOfRows,"modelIDs":Array(owner.model.selectedFiles),
                    "nativeModelIDs":Array(owner.model.nativeFileSelection),"revisions":Array(owner.model.selected),
                    "busy":owner.model.busy,"error":owner.model.error ?? "","hasSheet":owner.window?.attachedSheet != nil,"attached":table.window === owner.window]
                return (try? JSONSerialization.data(withJSONObject:value,options:.sortedKeys)).flatMap{String(data:$0,encoding:.utf8)} ?? "unavailable"
            }
            let before=diagnostic();print("Log LFS native select before: "+before);fflush(stdout)
            // The earlier working-row highlight can survive native table reuse
            // while its model selection is reset by history/refresh. AppKit does
            // not notify an unchanged selectRowIndexes call. Make an actual
            // deselect/reselect gesture, as a user click followed by selection.
            owner.window?.makeFirstResponder(table);table.deselectAll(nil)
            table.selectRowIndexes(indexes,byExtendingSelection:false)
            do {try await wait{owner.model.selectedFiles==ids}}
            catch {throw Failure(description:"Log LFS native selection failed; before=\(before); after=\(diagnostic())")}
            owner.model.focusedChangedFile=rows[indexes.first!].file?.id
            return ids
        }
        func hold(_ model:LogWindowModel,rows:[WorkingTreeFile])->ReadHold {
            let value=ReadHold();holds.append(value)
            model.readWorkingLFSSelection={paths,token in value.paths=paths;value.token=token;return await withCheckedContinuation{value.reply=$0}}
            return value
        }
        func retiredLogCache()async throws {
            let store=try RepositoryAccessStore(storageURL:root.appendingPathComponent(".git/qa-access.json"))
            let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git] in GitRepository(root:$0,executable:git,askpass:nil)},snapshotWriter:{_ in false},savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent(".git/qa-marks.json")),cachePersistenceDefaults:preferences,publishCachePersistence:{_ in})
            workspaces.append(workspace);workspace.fileComparisonPreferences=preferences;workspace.notifyFinder={}
            var made:[LogWindowController]=[],presented:[LogWindowController]=[]
            workspace.logWindowFactory={ [unowned self] repo,access in
                let owner=LogWindowController(repository:repo,access:access,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
                made.append(owner);owners.append(owner);return owner
            }
            workspace.logWindowPresentation={owner in presented.append(owner);owner.showWindow(nil)}
            func show(){workspace.showLog(repository:actual,access:nil,paths:[],preferences:preferences)}
            show();let first=try unwrap(made.first,"Root did not create initial Log")
            first.model.reload()
            try await wait{!first.model.busy && first.model.entries.contains{!$0.hash.isEmpty}}
            let revision=try unwrap(first.model.entries.first{!$0.hash.isEmpty},"Missing revision for deferred Note")
            first.model.select([revision.hash]);try await wait{!first.model.busy && first.model.canEditNotes}
            var continuation:CheckedContinuation<Void,Never>?,token:OperationCancellation?
            func release(){let pending=continuation;continuation=nil;pending?.resume()}
            noteReleases.append{release()}
            first.model.prepareNoteIdentity={_ in true}
            first.model.readNote={_,owned in
                token=owned
                await withCheckedContinuation{continuation=$0}
                throw CancellationError()
            }
            first.model.editNotes();try await wait{continuation != nil && first.model.loadingNote}
            try require(!first.model.busy && first.window?.attachedSheet==nil,"Note fixture unexpectedly blocked ordinary window Close")
            first.window?.performClose(nil)
            try require(first.model.isInvalidated && first.model.noteWorkPending && token?.isCancelled==true,"Normal Close did not retire while retaining Note worker")
            show()
            try require(made.count==2 && presented.last === made[1] && made[1] !== first && !made[1].model.isInvalidated,"Root reused invalidated cached Log while old Note read drained")
            let fresh=made[1]
            show();try require(made.count==2 && presented.last === fresh,"Root failed to reuse live replacement while retired owner drained")
            release();try await wait{LogWindowModel.activeNoteReads==0 && !first.model.noteWorkPending}
            show();try require(made.count==2 && presented.last === fresh && !fresh.model.isInvalidated,"Retired Note completion evicted or hid replacement Log")
            fresh.close();workspace.stopMonitoringForTermination()
            try await wait{LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeNoteReads==0}
        }
        func checkpoint()async throws {
            initialHead=try await actual.run(["rev-parse","HEAD"]).stdout
            initialIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"));initialConfig=try Data(contentsOf:root.appendingPathComponent(".git/config"))
            for path in modified+["added.bin","conflict.bin","untracked.bin","ignored.bin","was-file.bin/child"] {initialContents[path]=try Data(contentsOf:root.appendingPathComponent(path))}
        }
        func preserved()async throws {
            try require(try await actual.run(["rev-parse","HEAD"]).stdout==initialHead,"LFS workflow changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==initialIndex,"LFS workflow changed the raw conflicted index")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/config"))==initialConfig,"LFS workflow changed Git configuration")
            for(path,data)in initialContents {try require(try Data(contentsOf:root.appendingPathComponent(path))==data,"LFS workflow rewrote a selected/unselected working file")}
            try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("gone.bin").path),"LFS recreated a deleted file")
            try require(!(try calls()).contains{$0==["lfs","locks","--json"]},"Log fetched server ownership despite source column mask")
        }
        func clean()async {
            noteReleases.forEach{$0()};noteReleases=[];workspaces.forEach{$0.stopMonitoringForTermination()}
            for owner in owners {if let window=owner.window,let sheet=window.attachedSheet,owner.lfsOperation==nil {window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()}
            progress.forEach{$0.close()};holds.forEach{$0.release([])}
            try? Data().write(to:root.appendingPathComponent(".git/lfs-release"))
            for _ in 0..<3000 {if drained() && owners.allSatisfy({$0.lfsOperation==nil}) {break};try? await Task.sleep(nanoseconds:5_000_000)}
            preferences.removePersistentDomain(forName:suite);clipboard.releaseGlobally()
        }
    }
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitLogLFSOrder(_:relativeTo:)))!
        let beginOriginal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!
        let beginHidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitLogLFSBeginSheet(_:completionHandler:)))!
        method_exchangeImplementations(original,hidden)
        method_exchangeImplementations(beginOriginal,beginHidden)
        defer {method_exchangeImplementations(beginOriginal,beginHidden);method_exchangeImplementations(original,hidden)}
        let context=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {try await context.setup();ProgressActionLog.install(store:ActionLogStore(storageURL:context.root.appendingPathComponent(".git/qa-action-log.txt")),preferences:context.preferences);try await verify(context);await context.clean()}
        catch {await context.clean();throw error}
        try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Log/LFS resources did not drain")
        print("PASS: Log working-tree LFS selected-path commands, source eligibility/five-column mask/icons, captured menu and preflight staleness, real stub argv, review/Force retry/cancel/retired ownership, refresh, retired Note cache replacement and drain; private preferences/clipboard/repository, HEAD/index/workfiles retained.")
    }
    @MainActor static func verify(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        try await c.checkpoint()
        let tracked=try await c.select(c.modified,owner),deleted=try c.ids(["gone.bin"],owner),added=try c.ids(["added.bin"],owner)
        for ids in [tracked,deleted,added] {try require(model.workingLFSActions(ids)==[.lock,.unlock] && model.canWorkingLFS(ids,locked:true) && model.canWorkingLFS(ids,locked:false),"Tracked working files lost hidden-owner LFS commands")}
        for paths in [["untracked.bin"],["conflict.bin"],["was-file.bin"],[c.modified[0],"untracked.bin"],[c.modified[0],"conflict.bin"]] {
            try require(model.workingLFSActions(try c.ids(paths,owner)).isEmpty,"Ineligible/conflicted/directory selection exposed LFS: \(paths)")
        }
        try require(model.workingLFSActions(GitPathSet()).isEmpty && model.workingLFSActions(["not-a-row"]).isEmpty,"Empty/foreign selection exposed LFS")
        let columnProbe=try unwrap(views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first,"Missing native column adapter")
        try require(!columnProbe.columnMenu().items.contains{$0.title==StatusListColumn.lfsOwner.rawValue},"Log invented an LFS-owner column")
        model.setChangedFileColumn(.lfsOwner,visible:true)
        try require(!model.changedFileColumns.visible.contains(.lfsOwner),"Log accepted a column outside the source allowed mask")
        try require(MenuIcon.lock.contextImage(defaults:c.preferences) != nil && MenuIcon.unlock.contextImage(defaults:c.preferences) != nil,"Original LFS command images missing")
        c.preferences.set(false,forKey:"ShowAppContextMenuIcons")
        try require(MenuIcon.lock.contextImage(defaults:c.preferences)==nil && MenuIcon.unlock.contextImage(defaults:c.preferences)==nil,"LFS images ignored supplied icon preference")
        c.preferences.set(true,forKey:"ShowAppContextMenuIcons")
        let history=try unwrap(model.entries.first{!$0.hash.isEmpty},"Missing real history control")
        model.select([history.hash]);try require(model.workingLFSActions(tracked).isEmpty,"Historical files exposed working-tree LFS commands")
        model.select(["",history.hash]);try require(model.workingLFSActions(tracked).isEmpty,"Mixed revision/working-tree selection exposed LFS")
        model.select([""]);try await c.working(owner)
        let freshTracked=try await c.select(c.modified,owner)
        let stale=model.fileMenuSnapshot(freshTracked)
        model.setChangedFileSort([.init(column:.path,order:.reverse)])
        let before=try c.calls().count
        model.withFileMenu(stale){model.setWorkingLFSLocked(freshTracked,locked:true)}
        try require(!model.workingLFSReadPending && (try c.calls()).count==before,"Stale sorted menu dispatched LFS")
        // Actual Log selection enters the shared native sheet and real Git stub.
        let ids=try await c.select(c.modified,owner),paths=try c.files(c.modified,owner).map(\.path)
        var refreshes=0,pulls=0,logs:[String]=[]
        model.onRevisionChanged={_ in refreshes+=1};owner.onPullAfterLFSLock={pulls+=1};owner.onLFSProgressLog={logs.append($0)}
        try await c.ready(ids,locked:true,owner)
        let snapshot=model.fileMenuSnapshot(ids)
        model.withFileMenu(snapshot){model.setWorkingLFSLocked(ids,locked:true)}
        model.withFileMenu(snapshot){model.setWorkingLFSLocked(ids,locked:true)}
        try await wait{owner.lfsOperation != nil}
        let progress=try unwrap(owner.lfsOperation,"Missing owned LFS child")
        try await wait{!progress.model.busy && progress.model.results.count==paths.count && !model.workingLFSReadPending}
        try require(model.busy && owner.window?.attachedSheet===progress.window && !progress.model.refreshLocksAfterOperation,"Log did not retain busy/sheet ownership through result review")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Actual application Quit ignored accepted LFS result review")
        try require(exact(progress.model.results.map(\.path))==exact(paths) && progress.model.results.allSatisfy(\.success),"Progress changed captured path order or lost literal Unicode/tab path")
        try require(try c.calls().dropFirst(before).map{Array($0)}==paths.map{["lfs","lock","--",$0]},"Real git-lfs lock argv did not preserve selected literal paths exactly once")
        progress.model.onProgressLog?(paths[0])
        try require(logs==[paths[0]],"Progress Show Log lost its dedicated captured-path callback")
        try require(pulls==1 && refreshes==0,"Lock followup/refresh fired at the wrong lifecycle phase")
        try await c.finishReview(progress,owner:owner)
        try require(refreshes==1,"Lock review did not deliver its peer refresh")
        // Unlock reports a real per-file failure; Force must retain that target.
        let single=try await c.select([c.modified[1]],owner);try c.control(["failPath":c.modified[1]])
        try await c.dispatch(single,locked:false,owner);try await wait{owner.lfsOperation != nil}
        let failed=try unwrap(owner.lfsOperation,"Missing Unlock child");try await wait{!failed.model.busy && failed.model.canForceRetry}
        try require(model.busy && failed.model.results.count==1 && !failed.model.results[0].success,"Failed unlock lost review or Force action")
        await failed.model.unlock(forceRetry:true)
        try require(!failed.model.canForceRetry && failed.model.results.allSatisfy(\.success),"Force retry did not replace failed result")
        try require(Array(try c.calls().suffix(2))==[["lfs","unlock","--",c.modified[1]],["lfs","unlock","--force","--",c.modified[1]]],"Force retry changed original literal path/command")
        try await c.finishReview(failed,owner:owner);try c.control([:])
        // A held fresh read owns cancellation/Quit until its continuation drains.
        let rows=try await c.actual.workingTreeStatus(refreshIndex:false),hold=c.hold(model,rows:rows)
        let heldIDs=try await c.select([c.modified[0]],owner);let count=try c.calls().count
        try require(model.canWorkingLFS(heldIDs,locked:true),"Fixture requested held preflight before actual Log readiness; busy=\(model.busy), historyReads=\(LogWindowModel.activeHistoryLoads)")
        try await c.dispatch(heldIDs,locked:true,owner);try await wait{hold.reply != nil}
        try require(model.busy && model.workingLFSReadPending && LogWindowModel.activeWorkingLFSReads==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Preflight failed Close/Quit lifetime ownership")
        try require(model.cancelWorkingLFSRead() && hold.token?.isCancelled==true,"Preflight Cancel did not cancel its captured token")
        try require(model.workingLFSReadPending && LogWindowModel.activeWorkingLFSReads==1,"Cancel released preflight before actual worker drain")
        hold.release(rows);try await wait{!model.workingLFSReadPending && !model.busy}
        try require(try c.calls().count==count,"Cancelled fresh read contacted Git LFS")
        // Native selection replacement during a read cannot retarget the batch.
        let staleHold=c.hold(model,rows:rows)
        try await c.dispatch(heldIDs,locked:true,owner);try await wait{staleHold.reply != nil}
        model.selectedFiles=try c.ids([c.modified[1]],owner);staleHold.release(rows)
        try await wait{!model.workingLFSReadPending && !model.busy}
        try require(try c.calls().count==count,"Stale selected-file epoch contacted Git LFS")
        // A fresh index result with a selected path missing must refuse all work.
        model.readWorkingLFSSelection={_,_ in rows.filter{!GitReferenceName.equal($0.id,c.modified[0])}}
        let vanished=try await c.select([c.modified[0]],owner);try await c.dispatch(vanished,locked:true,owner)
        try await wait{!model.workingLFSReadPending && !model.busy}
        try require(model.error != nil && (try c.calls()).count==count,"Fresh index eligibility did not atomically refuse missing selection")
        model.readWorkingLFSSelection=nil;try await c.acknowledgeError(owner)
        // User Cancel retains completed server results and manual review until
        // the real subprocess drains; it cannot open a Pull followup.
        let cancelIDs=try await c.select(c.modified,owner),cancelPaths=try c.files(c.modified,owner).map(\.path)
        try c.control(["holdPath":cancelPaths.last!]);let beforeCancelPulls=pulls
        try await c.dispatch(cancelIDs,locked:true,owner)
        try await wait{FileManager.default.fileExists(atPath:c.root.appendingPathComponent(".git/lfs-active.json").path)}
        let cancelled=try unwrap(owner.lfsOperation,"Missing cancellable LFS child")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Actual application Quit ignored active LFS child")
        cancelled.model.cancel();try await wait{!cancelled.model.busy && LFSLocksWindowModel.activeOperations==0}
        try require(model.busy && cancelled.model.actionLogCancelled && cancelled.model.results.contains(where:{$0.success}) && pulls==beforeCancelPulls,"Cancel discarded completed server effects, released review or opened Pull")
        try await c.finishReview(cancelled,owner:owner)
        // Retiring the actual native owner cancels an accepted held Git child;
        // its close callback and peer refresh wait until the worker truly drains.
        let targetIDs=try await c.select(c.modified,owner),targetPaths=try c.files(c.modified,owner).map(\.path)
        try c.control(["holdPath":targetPaths.last!]);let beforeRetireRefreshes=refreshes
        try await c.dispatch(targetIDs,locked:true,owner)
        try await wait{FileManager.default.fileExists(atPath:c.root.appendingPathComponent(".git/lfs-active.json").path)}
        let held=try unwrap(owner.lfsOperation,"Missing actual held Git progress");var closed=0;owner.onClosed={closed+=1}
        owner.close();try require(closed==0 && LFSLocksWindowModel.activeOperations==1,"Forced parent close published before accepted Git drained")
        try await wait{closed==1 && owner.lfsOperation==nil && !held.model.busy && drained()}
        try require(refreshes==beforeRetireRefreshes+1 && pulls==1,"Retired child lost peer refresh or opened a late Pull followup")
        try require(!FileManager.default.fileExists(atPath:c.root.appendingPathComponent(".git/lfs-active.json").path),"Cancelled stub helper survived its owner")
        try await c.retiredLogCache()
        try await c.preserved()
    }
}
