// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func syncDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func syncDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));syncDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum SyncFileDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"Sync drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ condition:()->Bool)async throws{for _ in 0..<3000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Sync drag timeout \(line)")}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    final class Scope:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{starts += 1;return true}
        func stopAccessing(_ url:URL){stops += 1}
    }
    final class Reply:@unchecked Sendable {
        private let lock=NSLock();private var stored:Result<Data,Error>?
        var value:Result<Data,Error>?{lock.lock();defer{lock.unlock()};return stored}
        func finish(_ bytes:Data?,_ error:Error?){lock.lock();defer{lock.unlock()};stored=error.map{.failure($0)} ?? bytes.map{.success($0)} ?? .failure(Failure(description:"Missing delivered bytes"))}
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.SyncDrag."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        let literal="literal\tline\n雪.bin",names=["one/same.txt","two/same.txt"]
        var first="",head="",index=Data(),historical:[String:Data]=[:],working:[String:Data]=[:],owners:[SynchronizationWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache");prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")}
        func prepare()async throws {
            for name in ["one","two"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Sync drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in names+[literal,"deleted.txt"]{try Data((name+" base\n").utf8).write(to:root.appendingPathComponent(name))}
            try await repo.stage(["."]);_=try await repo.commit(message:"drag base");first=try await repo.rebaseCommit("HEAD").hash
            let remote=base.appendingPathComponent("origin.git")
            _=try await repo.run(["clone","--bare","--template=","--",root.path,remote.path]);_=try await repo.run(["remote","add","origin",remote.path]);_=try await repo.run(["fetch","origin"])
            _=try await repo.run(["branch","--set-upstream-to=origin/main","main"])
            for name in names+[literal]{let bytes=Data((name+" historical\n").utf8);historical[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try Data("new historical file\n".utf8).write(to:root.appendingPathComponent("new.txt"))
            try FileManager.default.removeItem(at:root.appendingPathComponent("deleted.txt"))
            _=try await repo.run(["add","-A","--"]);_=try await repo.run(["update-index","--add","--cacheinfo","160000",first,"module"])
            _=try await repo.commit(message:"drag changed files");head=try await repo.rebaseCommit("HEAD").hash
            for name in names+[literal]{let bytes=Data((name+" unsaved working\n").utf8);working[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try FileManager.default.createDirectory(at:root.appendingPathComponent("module"),withIntermediateDirectories:true)
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        }
        func sync()async throws->SynchronizationWindowController {
            let owner=SynchronizationWindowController(repository:repo,access:RepositoryAccessLease(url:root),preferences:prefs)
            owners.append(owner);owner.model.sshSettings.enabled=false
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            try await wait{!owner.model.busy && owner.model.outgoing != nil && !owner.model.hasPendingInlineWork}
            return owner
        }
        func preserved()async throws {
            let current=try await repo.rebaseCommit("HEAD").hash
            try require(current==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Drag changed HEAD/index")
            for(name,bytes)in working{try require((try Data(contentsOf:root.appendingPathComponent(name)))==bytes,"Drag changed working contents")}
        }
        func clean()async {
            for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[]
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            FileListDrag.discardAll();prefs.removePersistentDomain(forName:suite)
        }
    }
    static func drained()->Bool{FileListDrag.activeLoads==0 && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && RevisionComparisonWindowModel.activeFileOperations==0 && StatusWindowModel.activeOperations==0}
    static func checkText(_ drag:FileListSelectionDrag,files:[CommitFile])throws {
        try require(drag.paths==files.map(\.path),"Drag used a model/default order instead of native displayed selection")
        let expected=files.map{$0.path+"\r\n"}.joined()
        try require(Data(drag.text.utf8)==Data(expected.utf8),"Drag path text lost Unicode spelling/order")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try require(board.writeObjects(drag.writers) && board.string(forType:.string).map{Data($0.utf8)}==Data(expected.utf8),"Multiple writers lost aggregate selected-path text")
    }
    static func promised(_ provider:NSFilePromiseProvider,to url:URL)async throws {
        let delegate=try unwrap(provider.delegate as? FileListFilePromise,"Missing real file promise delegate")
        try require(delegate.filePromiseProvider(provider,fileNameForType:provider.fileType)==delegate.name,"Native promise naming callback changed its captured leaf")
        let reply=Reply(),before=FileListDrag.activeLoads
        delegate.filePromiseProvider(provider,writePromiseTo:url){error in reply.finish(error==nil ? Data():nil,error)}
        try require(FileListDrag.activeLoads==before+1,"Queued promise work was not retained before main-actor dispatch")
        try await wait{reply.value != nil};_=try reply.value!.get()
    }
    static func grantIndependent(_ c:Context)async throws {
        // This lease belongs only to the helper receipt; Cocoa may legitimately
        // cache the unrelated source controller, so its deallocation is no oracle.
        let scope=Scope();var lease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        let entry=try await c.repo.rebaseCommit(c.head),files=try await c.repo.files(in:entry)
        let selected=try unwrap(files.first{$0.path==c.names[0]},"Missing grant fixture blob")
        let plan=try FileListDragPlan(root:c.root,revision:.revision(c.head),files:[selected],backend:.init(enabled:false))
        var promise:NSFilePromiseProvider?=try FileListFilePromise(repository:c.repo,access:lease,plan:plan,itemAt:0).provider();lease=nil
        try require(scope.starts==1 && scope.stops==0,"Helper receipt failed to retain a caller-released grant")
        let output=c.base.appendingPathComponent("independent/same.txt");try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
        try await promised(promise!,to:output)
        try require((try Data(contentsOf:output))==c.historical[c.names[0]],"Independent promise rebound to working bytes")
        promise=nil;try await wait{scope.stops==1}
    }
    static func nativeFiles(_ owner:SynchronizationWindowController,incoming:Bool)async throws->SynchronizationFiles.Coordinator {
        let model=owner.model;model.tab=incoming ? 5:1
        let state=model.displayedFileList,id=NSUserInterfaceItemIdentifier("TurtleGit.Sync.Files."+(incoming ? "In":"Out"))
        try await wait{views(owner.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.contains{table in table.identifier==id && (table.dataSource as? SynchronizationFiles.Coordinator)?.state === state}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.first{$0.identifier==id && ($0.dataSource as? SynchronizationFiles.Coordinator)?.state === state},"Missing current native Sync table")
        let coordinator=try unwrap(table.dataSource as? SynchronizationFiles.Coordinator,"Missing Sync datasource")
        state.sort(by:.path,ascending:false);coordinator.refresh()
        try await wait{state.available && table.numberOfRows==state.rows.count}
        return coordinator
    }
    static func select(_ paths:[String],_ coordinator:SynchronizationFiles.Coordinator)async throws->[CommitFile] {
        let state=coordinator.state,table=try unwrap(coordinator.table,"Detached Sync native list"),wanted=GitPathSet(paths)
        let rows=state.rows,indexes=IndexSet(rows.indices.filter{wanted.contains(rows[$0].path)})
        try require(indexes.count==paths.count,"Actual Sync list omitted required selected paths")
        table.selectRowIndexes(indexes,byExtendingSelection:false)
        try await wait{state.selection==wanted};coordinator.refresh()
        return indexes.map{rows[$0]}
    }
    static func capture(_ coordinator:SynchronizationFiles.Coordinator)->FileListSelectionDrag? {
        guard let table=coordinator.table else{return nil}
        return coordinator.captureDrag(rows:table.selectedRowIndexes)
    }
    static func fences(_ owner:SynchronizationWindowController,_ capture:()->Bool)async throws {
        let model=owner.model
        // Accept a real owned read. Its synchronous busy transition precedes
        // the queued Task, so this assertion needs no timing gate or setter.
        // An impossible object makes the read fail without presenting a child
        // or replacing the deliberately captured file-list snapshots.
        model.compareHistoryChangeSets(first:String(repeating:"0",count:40),second:"HEAD")
        try require(model.busy,"Busy fence did not start its actual owned read")
        try require(!capture(),"Busy Sync exported drag")
        try await wait{!model.busy && !model.hasPendingInlineWork}
        model.confirmingQuit=true;try require(!capture(),"Quit Sync exported drag");model.confirmingQuit=false
        let window=try unwrap(owner.window,"Missing Sync window"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        defer{if sheet.sheetParent != nil{window.endSheet(sheet,returnCode:.abort)};sheet.close()}
        window.beginSheet(sheet,completionHandler:{_ in});try await wait{window.attachedSheet === sheet}
        try require(!capture(),"Attached Sync sheet allowed drag")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
    }
    static func deliver(_ drag:FileListSelectionDrag,files:[CommitFile],expected:[String:Data],_ c:Context)async throws {
        let eligible=files.filter{!$0.isSubmodule && $0.action.first != "D"},promises=drag.writers.compactMap{$0 as? NSFilePromiseProvider}
        try require(promises.count==eligible.count && drag.providers.count==eligible.count,"Sync aggregate omitted or added file occurrences")
        let textReply=Reply();drag.textProvider.loadDataRepresentation(forTypeIdentifier:NSPasteboard.PasteboardType.string.rawValue){textReply.finish($0,$1)}
        try await wait{textReply.value != nil};try require(try textReply.value!.get()==Data(drag.text.utf8),"Sync text provider rebound after close")
        for(index,provider)in promises.enumerated(){let leaf=(eligible[index].path as NSString).lastPathComponent;try require((provider.delegate as? FileListFilePromise)?.name==leaf,"Sync promise lost source leaf");let output=c.base.appendingPathComponent("receiver-\(index)/"+leaf);try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true);try await promised(provider,to:output);try require((try Data(contentsOf:output))==expected[eligible[index].path],"Sync promise used selected child/current bytes instead of captured base")}
    }
    static func endpoints(_ c:Context,incoming:Bool)async throws {
        let owner=try await c.sync(),model=owner.model
        let source=incoming ? c.head:c.first,destination=incoming ? c.first:c.head
        let snapshot=try await c.repo.revisionComparison(from:.revision(source),to:.revision(destination))
        let child=incoming ? model.incomingComparison:model.comparison
        child.installEmbeddedSnapshot(snapshot,bare:false)
        let coordinator=try await nativeFiles(owner,incoming:incoming),state=coordinator.state
        let excluded=incoming ? "new.txt":"deleted.txt"
        let files=try await select(c.names+[c.literal,excluded,"module"],coordinator)
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(capture(coordinator),"Native Sync refused aggregate selection");try checkText(drag,files:files)
        if case .revision(let hash)=drag.revision{try require(hash==source,"Sync materialization chose newer child instead of old/base endpoint")}else{throw Failure(description:"Sync historical source became working tree")}
        try require(drag.operationMask == .copy && drag.fileURLs.isEmpty,"Historical Sync transfer allowed move or working URLs")
        let textFiles=try await select([excluded,"module"],coordinator),text=try unwrap(capture(coordinator),"Sync excluded-only rows lost text transfer")
        try checkText(text,files:textFiles);try require(text.providers.isEmpty && text.writers.compactMap{$0 as? NSFilePromiseProvider}.isEmpty,"Sync excluded rows promised contents")
        _=try await select(c.names+[c.literal,excluded,"module"],coordinator)
        let oldEpoch=state.menuEpoch;state.sort(by:.path,ascending:true)
        try require(state.captureFileDrag(files.map(\.path),epoch:oldEpoch)==nil,"Old sorted Sync selection receipt revived")
        state.sort(by:.path,ascending:false);coordinator.refresh()
        try await fences(owner){capture(coordinator) != nil}
        model.tab=2;try require(capture(coordinator)==nil,"Hidden Sync tab exported stale source")
        owner.close();try require(capture(coordinator)==nil,"Retired Sync datasource exported new source")
        let expected=Dictionary(uniqueKeysWithValues:(c.names+[c.literal]).map{($0,incoming ? c.historical[$0]!:Data(($0+" base\n").utf8))})
        try await deliver(drag,files:files,expected:expected,c)
    }
    static func conflicts(_ c:Context)async throws {
        let owner=try await c.sync(),model=owner.model
        _=try await c.repo.run(["restore","--source=HEAD","--worktree","--","."])
        _=try await c.repo.run(["checkout","-b","conflict-side",c.first])
        for path in c.names+[c.literal]{try Data((path+" conflicting side\n").utf8).write(to:c.root.appendingPathComponent(path))}
        try await c.repo.stage(c.names+[c.literal]);_=try await c.repo.commit(message:"private conflict side")
        _=try await c.repo.run(["checkout","main"]);let merged=try await c.repo.run(["merge","--no-edit","conflict-side"],successfulExitCodes:0...1)
        try require(merged.exitCode==1,"Private conflict fixture did not stop real merge")
        try await wait{!model.busy && !model.hasPendingInlineWork}
        model.tab=6;let actions=model.conflictFileActions;model.refreshConflictFiles()
        try await wait{!actions.busy && actions.files.count>=3}
        let adapter:CommitFileInteraction.Probe=try await {
            try await wait{views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.contains{$0.captureWorkingDrag != nil && $0.nativeTable != nil}}
            return try unwrap(views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.captureWorkingDrag != nil && $0.nativeTable != nil},"Missing actual Sync conflict drag adapter")
        }()
        actions.setSortOrder([StatusFileSort(column:.path,order:.reverse)])
        try await wait{adapter.rows.compactMap{$0.entry?.path}==actions.sortedRows.map(\.path)}
        let table=try unwrap(adapter.nativeTable,"Detached conflict table"),paths=GitPathSet(c.names+[c.literal])
        let indexes=IndexSet(adapter.rows.indices.filter{adapter.rows[$0].entry.map{paths.contains($0.path)} == true})
        try require(indexes.count==3,"Native conflict list omitted real conflicted rows");table.selectRowIndexes(indexes,byExtendingSelection:false)
        try await wait{actions.selection==paths}
        let ordered=indexes.compactMap{adapter.rows[$0].entry?.path},drag=try unwrap(adapter.workingDragSelection(),"Conflict highlighted rows refused working drag")
        try require(drag.paths==ordered && drag.fileURLs.map{String($0.path.dropFirst(c.root.path.count+1))}==ordered,"Conflict drag changed displayed order or real URLs")
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"));for path in c.names+[c.literal]{c.working[path]=try Data(contentsOf:c.root.appendingPathComponent(path))}
        try await fences(owner){adapter.workingDragSelection() != nil}
        model.tab=2;try require(adapter.workingDragSelection()==nil,"Hidden conflict tab exported drag")
        owner.close();try require(adapter.workingDragSelection()==nil,"Closed conflict owner exported drag")
        for(index,provider)in drag.providers.enumerated(){let reply=Reply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){reply.finish($0,$1)};try await wait{reply.value != nil};let data=try reply.value!.get(),url=try unwrap(URL(string:String(decoding:data,as:UTF8.self)),"Conflict URL invalid");try require(url==drag.fileURLs[index] && (try Data(contentsOf:url))==c.working[ordered[index]],"Conflict drag rebound after close")}
    }
    static func ownership(_ c:Context)async throws {
        // The exact private grant belongs only to this helper receipt. Source
        // controller caches do not decide whether its permission survives.
        let owner=try await c.sync(),snapshot=try await c.repo.revisionComparison(from:.revision(c.first),to:.revision(c.head))
        owner.model.comparison.installEmbeddedSnapshot(snapshot,bare:false)
        let coordinator=try await nativeFiles(owner,incoming:false),files=try await select(c.names+[c.literal],coordinator)
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(capture(coordinator),"Ownership capture failed");owner.close()
        let expected=Dictionary(uniqueKeysWithValues:files.map{($0.path,Data(($0.path+" base\n").utf8))})
        try await deliver(drag,files:files,expected:expected,c)
        try await grantIndependent(c)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.syncDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.syncDragOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {try await c.prepare();switch CommandLine.arguments[3]{case "incoming":try await endpoints(c,incoming:true);case "outgoing":try await endpoints(c,incoming:false);case "conflicts":try await conflicts(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown Sync drag case")};try await c.preserved();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Sync windows/work did not drain");print("PASS: sync file drags "+CommandLine.arguments[3]);fflush(stdout)}catch{await c.clean();fputs("Sync file drags failed: \(error)\n",stderr);exit(1)}
    }
}
