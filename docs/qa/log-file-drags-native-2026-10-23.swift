// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func logDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func logDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));logDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum LogFileDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"Log drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ condition:()->Bool)async throws{for _ in 0..<3000{if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Log drag timeout \(line)")}
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
        let suite="TurtleGit.LogDrag."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        let literal="literal\tline\n雪.bin",names=["one/same.txt","two/same.txt"]
        var first="",head="",index=Data(),historical:[String:Data]=[:],working:[String:Data]=[:],owners:[LogWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache");prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")}
        func prepare()async throws {
            for name in ["one","two"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Log drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in names+[literal,"deleted.txt"]{try Data((name+" base\n").utf8).write(to:root.appendingPathComponent(name))}
            try await repo.stage(["."]);_=try await repo.commit(message:"drag base");first=try await repo.rebaseCommit("HEAD").hash
            for name in names+[literal]{let bytes=Data((name+" historical\n").utf8);historical[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try FileManager.default.removeItem(at:root.appendingPathComponent("deleted.txt"))
            _=try await repo.run(["add","-A","--"]);_=try await repo.run(["update-index","--add","--cacheinfo","160000",first,"module"])
            _=try await repo.commit(message:"drag changed files");head=try await repo.rebaseCommit("HEAD").hash
            for name in names+[literal]{let bytes=Data((name+" unsaved working\n").utf8);working[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try FileManager.default.createDirectory(at:root.appendingPathComponent("module"),withIntermediateDirectories:true)
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        }
        func log(range:Bool=false)async throws->LogWindowController {
            let owner=LogWindowController(repository:repo,access:RepositoryAccessLease(url:root),labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owners.append(owner)
            if range {owner.model.revisionRange = .init(from:first,to:head)}
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);owner.model.reload()
            try await wait{!owner.model.busy && owner.model.entries.contains{$0.hash==self.head}}
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
    static func drained()->Bool{FileListDrag.activeLoads==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeWorkingCommandReads==0}
    static func probe(_ owner:LogWindowController)async throws->LogFileDragInteraction.Probe {
        try await wait{views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.contains{$0.nativeTable != nil}}
        return try unwrap(views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.first{$0.nativeTable != nil},"Missing installed Log native drag adapter")
    }
    static func select(_ paths:[String],owner:LogWindowController,probe:LogFileDragInteraction.Probe)async throws->[CommitFile] {
        let wanted=GitPathSet(paths),model=owner.model
        try await wait{probe.rows.map(\.rawID)==model.fileTableRows.map(\.rawID)}
        let rows=model.fileTableRows,indexes=IndexSet(rows.indices.filter{rows[$0].file.map{wanted.contains($0.path)} == true})
        try require(indexes.count==paths.count,"Actual changed-file list omitted selected rows")
        let table=try unwrap(probe.nativeTable,"Detached Log file table")
        let gestureContext=probe.generation?()
        table.selectRowIndexes(indexes,byExtendingSelection:false)
        let files=indexes.compactMap{rows[$0].file},ids=GitPathSet(files.map(\.id))
        try await wait{model.selectedFiles==ids}
        model.focusedChangedFile=files.first?.id
        try require(gestureContext != nil && probe.generation?()==gestureContext,"Native highlight/marked-row selection invalidated its own drag gesture")
        return files
    }
    static func checkText(_ drag:LogFileListDrag,files:[CommitFile])throws {
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
    static func fence(_ owner:LogWindowController,_ adapter:LogFileDragInteraction.Probe)async throws {
        let model=owner.model
        model.busy=true;try require(adapter.captureSelection()==nil,"Busy Log exported a new drag");model.busy=false
        model.confirmingQuit=true;try require(adapter.captureSelection()==nil,"Quit Log exported a new drag");model.confirmingQuit=false
        let window=try unwrap(owner.window,"Missing Log window"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        defer{if sheet.sheetParent != nil{window.endSheet(sheet,returnCode:.abort)};sheet.close()}
        window.beginSheet(sheet,completionHandler:{_ in});try await wait{window.attachedSheet === sheet}
        try require(adapter.captureSelection()==nil,"Log exported through attached sheet")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
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
    static func historical(_ c:Context,range:Bool)async throws {
        let owner=try await c.log(range:range),model=owner.model
        model.select([c.head]);try await wait{model.files.contains{$0.path=="deleted.txt"} && model.files.contains{$0.path=="module"}}
        model.setChangedFileSort([LogChangedFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner)
        try await wait{adapter.nativeTable?.numberOfRows==model.fileTableRows.count}
        let files=try await select(c.names+[c.literal,"deleted.txt","module"],owner:owner,probe:adapter)
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(adapter.captureSelection(),"Installed Log adapter refused historical multi-selection")
        try checkText(drag,files:files);try require(drag.operationMask == .copy,"Historical promises offered destructive move")
        if case .revision(let hash)=drag.revision{try require(hash==c.head,"History/range drag used wrong selected child revision")}else{throw Failure(description:"Historical drag offered working tree")}
        let promises=drag.writers.compactMap{$0 as? NSFilePromiseProvider},eligible=files.filter{!$0.isSubmodule && $0.action.first != "D"}
        try require(promises.count==eligible.count && promises.count==3 && drag.providers.count==3 && drag.fileURLs.isEmpty,"Historical selection failed to publish every eligible occurrence")
        let textFiles=try await select(["deleted.txt","module"],owner:owner,probe:adapter)
        let textOnly=try unwrap(adapter.captureSelection(),"Excluded rows lost text-only drag")
        try checkText(textOnly,files:textFiles);try require(textOnly.writers.compactMap{$0 as? NSFilePromiseProvider}.isEmpty && textOnly.providers.isEmpty && textOnly.operationMask == .copy,"Text-only selection promised excluded contents or move")
        _=try await select(c.names+[c.literal,"deleted.txt","module"],owner:owner,probe:adapter)
        try await fence(owner,adapter)
        // Selection changes and owner retirement cannot retarget already-accepted promises.
        model.select([c.first,c.head])
        try require(model.captureFileDrag(files.map(\.id))==nil,"A combined multi-revision selection invented one source hash")
        model.select([c.first]);owner.close();try require(adapter.captureSelection()==nil,"Retired Log exported new source selection")
        let textReply=Reply();drag.textProvider.loadDataRepresentation(forTypeIdentifier:NSPasteboard.PasteboardType.string.rawValue){textReply.finish($0,$1)}
        try await wait{textReply.value != nil};try require(try textReply.value!.get()==Data(drag.text.utf8),"Aggregate text provider lost captured selection after close")
        for(index,provider)in promises.enumerated(){let leaf=(eligible[index].path as NSString).lastPathComponent;try require((provider.delegate as? FileListFilePromise)?.name==leaf,"Promise lost its captured source basename");let output=c.base.appendingPathComponent("receiver-\(index)/"+leaf);try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true);try await promised(provider,to:output);try require((try Data(contentsOf:output))==c.historical[eligible[index].path],"Promise used old/current bytes or reordered occurrences")}
        try await grantIndependent(c)
    }
    static func working(_ c:Context)async throws {
        let owner=try await c.log(),model=owner.model
        try await wait{model.workingTreeSnapshot != nil};model.select([""])
        try await wait{model.selectedWorkingTree && model.files.contains{$0.path==c.names[0]}}
        model.setChangedFileSort([LogChangedFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner),files=try await select(c.names+[c.literal],owner:owner,probe:adapter)
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(adapter.captureSelection(),"Installed Log adapter refused working selection")
        try checkText(drag,files:files);try require(drag.operationMask == [.copy,.move],"Real working URLs lost native copy/move choices")
        if case .workingTree=drag.revision{}else{throw Failure(description:"Working drag promised a historical revision")}
        try require(drag.fileURLs.map{String($0.path.dropFirst(c.root.path.count+1))}==files.map(\.path) && drag.writers.compactMap{$0 as? NSFilePromiseProvider}.isEmpty,"Working drag substituted temporary/index files")
        try await fence(owner,adapter);owner.close();try require(adapter.captureSelection()==nil,"Closed working Log exported another drag")
        for(index,provider)in drag.providers.enumerated(){let reply=Reply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){reply.finish($0,$1)};try await wait{reply.value != nil};let data=try reply.value!.get(),url=try unwrap(URL(string:String(decoding:data,as:UTF8.self)),"Invalid captured working URL");try require(url==drag.fileURLs[index] && (try Data(contentsOf:url))==c.working[files[index].path],"Closed Log working drag lost original URL/content")}
        try await grantIndependent(c)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.logDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.logDragOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {try await c.prepare();switch CommandLine.arguments[3]{case "historical":try await historical(c,range:false);case "range":try await historical(c,range:true);case "working":try await working(c);default:throw Failure(description:"Unknown Log drag case")};try await c.preserved();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Log drag windows/work did not drain");print("PASS: log file drags "+CommandLine.arguments[3]);fflush(stdout)}catch{await c.clean();fputs("Log file drags failed: \(error)\n",stderr);exit(1)}
    }
}
