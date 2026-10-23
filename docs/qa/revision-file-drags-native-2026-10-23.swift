// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func revisionDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func revisionDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));revisionDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum RevisionFileDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Revision drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Revision drag timeout \(line)")}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    final class Reply:@unchecked Sendable {
        private let lock=NSLock();private var result:Result<Data,Error>?
        var value:Result<Data,Error>?{lock.lock();defer{lock.unlock()};return result}
        func finish(_ bytes:Data?,_ error:Error?){lock.lock();defer{lock.unlock()};result=error.map{.failure($0)} ?? bytes.map{.success($0)} ?? .failure(Failure(description:"Missing delivered bytes"))}
    }
    final class Scope:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{starts += 1;return true}
        func stopAccessing(_ url:URL){stops += 1}
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.RevisionDrag."+UUID().uuidString,prefs:UserDefaults
        let literal="literal\tline\n雪.bin",names=["one/same.txt","two/same.txt"]
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        var first="",head="",index=Data(),historical:[String:Data]=[:],working:[String:Data]=[:],owners:[RevisionComparisonWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func prepare()async throws {
            for name in ["one","two"]{try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:true)}
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Revision drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in names+[literal,"deleted.txt","missing.txt"]{try Data((name+" base\n").utf8).write(to:root.appendingPathComponent(name))}
            try await repo.stage(["."]);_=try await repo.commit(message:"private base");first=try await repo.rebaseCommit("HEAD").hash
            for name in names+[literal]{let bytes=Data((name+" historical\n").utf8);historical[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try FileManager.default.removeItem(at:root.appendingPathComponent("deleted.txt"));_=try await repo.run(["add","-A","--"])
            _=try await repo.run(["update-index","--add","--cacheinfo","160000",first,"module"]);_=try await repo.commit(message:"private changes");head=try await repo.rebaseCommit("HEAD").hash
            for name in names+[literal]{let bytes=Data((name+" unsaved working\n").utf8);working[name]=bytes;try bytes.write(to:root.appendingPathComponent(name))}
            try FileManager.default.removeItem(at:root.appendingPathComponent("missing.txt"));try FileManager.default.createDirectory(at:root.appendingPathComponent("module"),withIntermediateDirectories:true)
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        }
        func open(working:Bool=false)async throws->RevisionComparisonWindowController {
            let owner=RevisionComparisonWindowController(repository:repo,access:RepositoryAccessLease(url:root),from:.revision(working ? head:first),to:working ? .workingTree:.revision(head),preferences:prefs,savesGeometry:false)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            try await wait{!owner.model.busy && owner.model.snapshot != nil && owner.model.fileDragGeneration != nil}
            return owner
        }
        func preserved()async throws {
            let hash=try await repo.rebaseCommit("HEAD").hash,data=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(hash==head && data==index,"Drag mutated HEAD/index")
            for(name,bytes)in working{let data=try Data(contentsOf:root.appendingPathComponent(name));try require(data==bytes,"Drag mutated working bytes")}
            try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent("missing.txt").path),"Drag recreated missing input")
        }
        func clean()async{for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[];for _ in 0..<3000{if FileListDrag.activeLoads==0 && RevisionComparisonWindowModel.activeFileOperations==0{break};try? await Task.sleep(nanoseconds:10_000_000)};FileListDrag.discardAll();prefs.removePersistentDomain(forName:suite)}
    }
    static func probe(_ owner:RevisionComparisonWindowController)async throws->FileListDragInteraction.Probe {
        try await wait{views(owner.window?.contentView).compactMap{$0 as? FileListDragInteraction.Probe}.contains{$0.nativeTable != nil}}
        return try unwrap(views(owner.window?.contentView).compactMap{$0 as? FileListDragInteraction.Probe}.first{$0.nativeTable != nil},"Missing installed Changed Files adapter")
    }
    static func select(_ names:[String],_ owner:RevisionComparisonWindowController,_ adapter:FileListDragInteraction.Probe)async throws->[CommitFile] {
        let wanted=GitPathSet(names),model=owner.model
        model.sortOrder=[KeyPathComparator(\CommitFile.sortPath,order:.reverse)]
        try await wait{adapter.nativeTable?.numberOfRows==model.visibleFiles.count && adapter.rows.map(\.id)==model.visibleFiles.map(\.path)}
        let rows=model.visibleFiles,indexes=IndexSet(rows.indices.filter{wanted.contains(rows[$0].path)})
        try require(indexes.count==names.count,"Changed Files projection omitted fixture rows")
        // SwiftUI can publish an empty ID set for direct replacement of a
        // multiselection with its subset. Use the existing production helper's
        // explicit native deselect/select transitions, as keyboard actions do.
        CommitFileInteraction.replaceSelection(in:try unwrap(adapter.nativeTable,"Detached file table"),with:indexes)
        try await wait{model.selection==wanted}
        return indexes.map{rows[$0]}
    }
    static func text(_ drag:FileListSelectionDrag,_ files:[CommitFile])throws {
        let expected=files.map{$0.path+"\r\n"}.joined(),board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try require(drag.paths==files.map(\.path) && Data(drag.text.utf8)==Data(expected.utf8),"Transfer lost displayed row ordering/literal paths")
        try require(drag.write(to:board) && board.string(forType:.string).map{Data($0.utf8)}==Data(expected.utf8),"Native writers omitted aggregate path text")
    }
    static func promise(_ writer:NSFilePromiseProvider,_ output:URL)async throws {
        let delegate=try unwrap(writer.delegate as? FileListFilePromise,"Missing existing promise delegate"),reply=Reply(),before=FileListDrag.activeLoads
        delegate.filePromiseProvider(writer,writePromiseTo:output){reply.finish($0==nil ? Data():nil,$0)}
        try require(FileListDrag.activeLoads==before+1,"Promise callback was not counted before actor dispatch")
        try await wait{reply.value != nil};_=try reply.value!.get()
    }
    static func historical(_ c:Context)async throws {
        let owner=try await c.open(),adapter=try await probe(owner),files=try await select(c.names+[c.literal,"deleted.txt","module"],owner,adapter)
        let drag=try unwrap(adapter.captureSelection(),"Historical actual native selection refused")
        try text(drag,files);try require(drag.revision == .revision(c.head),"Drag captured from/base/editor text instead of snapshot destination")
        let eligible=files.filter{!$0.isSubmodule && $0.action.first != "D"},promises=drag.writers.compactMap{$0 as? NSFilePromiseProvider}
        try require(promises.count==3 && promises.count==eligible.count && drag.providers.count==3 && drag.operationMask == .copy,"Historical drag omitted occurrences or exposed working move")
        let excluded=try await select(["deleted.txt","module"],owner,adapter),textOnly=try unwrap(adapter.captureSelection(),"Excluded rows lost text-only drag")
        try text(textOnly,excluded);try require(textOnly.providers.isEmpty && textOnly.writers.compactMap{$0 as? NSFilePromiseProvider}.isEmpty,"Excluded rows promised contents")
        owner.close();try require(adapter.captureSelection()==nil,"Closed Changed Files exported a new drag")
        for(index,provider)in promises.enumerated(){let name=(provider.delegate as! FileListFilePromise).name,output=c.base.appendingPathComponent("receiver-\(index)/"+name);try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true);try await promise(provider,output);let bytes=try Data(contentsOf:output);try require(bytes==c.historical[eligible[index].path],"Historical occurrence retargeted to working/base bytes")}
    }
    static func working(_ c:Context)async throws {
        let owner=try await c.open(working:true),adapter=try await probe(owner),files=try await select(c.names+[c.literal,"missing.txt"],owner,adapter)
        let drag=try unwrap(adapter.captureSelection(),"Working actual native selection refused")
        try text(drag,files);try require(drag.revision == .workingTree && drag.fileURLs.count==3 && drag.providers.count==3 && drag.operationMask == [.copy,.move],"Working transfer did not publish real URLs/copy-move")
        let missing=try await select(["missing.txt"],owner,adapter),textOnly=try unwrap(adapter.captureSelection(),"Missing working row lost text")
        try text(textOnly,missing);try require(textOnly.providers.isEmpty && textOnly.operationMask == .copy,"Missing working row offered contents")
        owner.close();let eligible=files.filter{$0.path != "missing.txt"}
        for(index,provider)in drag.providers.enumerated(){let reply=Reply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){reply.finish($0,$1)};try await wait{reply.value != nil};let data=try reply.value!.get(),url=try unwrap(URL(string:String(decoding:data,as:UTF8.self)),"Invalid working URL");try require(url==c.root.appendingPathComponent(eligible[index].path),"Working delivery used a temporary URL");let bytes=try Data(contentsOf:url);try require(bytes==c.working[eligible[index].path],"Working URL lost original bytes")}
    }
    static func sourceownership(_ c:Context)async throws {
        let owner=try await c.open(),adapter=try await probe(owner),files=try await select(c.names,owner,adapter),model=owner.model
        let accepted=try unwrap(adapter.captureSelection(),"Initial owned drag refused")
        // A real synthetic destination endpoint offers all names as text and
        // never guesses working-tree or historical contents for that endpoint.
        let emptyFiles=model.visibleFiles
        let empty=try unwrap(FileListSelectionDrag(repository:c.repo,access:model.access,files:emptyFiles,revision:.emptyTree,backend:.init(enabled:false)),"Synthetic empty endpoint lost path-text transfer")
        try text(empty,emptyFiles)
        try require(empty.revision == .emptyTree && empty.fileURLs.isEmpty && empty.providers.isEmpty && empty.writers.count==1 && empty.operationMask == .copy,"Synthetic endpoint offered alternate contents")
        let emptyReply=Reply();empty.textProvider.loadDataRepresentation(forTypeIdentifier:NSPasteboard.PasteboardType.string.rawValue){emptyReply.finish($0,$1)}
        try await wait{emptyReply.value != nil};let emptyBytes=try emptyReply.value!.get()
        try require(emptyBytes==Data(emptyFiles.map{$0.path+"\r\n"}.joined().utf8),"Empty endpoint provider omitted selected path text")
        for path in ["../escape",".git/config","/absolute"] {
            let invalid=CommitFile(path:path,oldPath:nil,action:"D",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)
            try require(FileListSelectionDrag(repository:c.repo,access:model.access,files:[invalid],revision:.emptyTree,backend:.init(enabled:false))==nil,"Text-only endpoint bypassed shared path validation")
        }
        try require(model.captureFileDrag([c.literal])==nil,"Unhighlighted row acquired a drag")
        // AppKit changes highlighted and marked rows after mouseDown. Those
        // updates must not retire the already-started gesture's source context.
        let highlightGeneration=model.fileDragGeneration,menuEpoch=model.fileMenuEpoch
        let tableForHighlight=try unwrap(adapter.nativeTable,"Missing native highlight table"),rows=model.visibleFiles
        let literalRow=try unwrap(rows.firstIndex{$0.path==c.literal},"Missing literal highlight row")
        CommitFileInteraction.replaceSelection(in:tableForHighlight,with:IndexSet(integer:literalRow))
        try await wait{model.selection==GitPathSet([c.literal])}
        model.focusedFile=c.literal
        try require(model.fileDragGeneration==highlightGeneration && model.fileMenuEpoch != menuEpoch,"Native highlight/mark retired drag source or preserved stale popup")
        _=try await select(c.names,owner,adapter)
        model.busy=true;try require(adapter.captureSelection()==nil && model.fileDragGeneration==nil,"Busy owner allowed drag");model.busy=false
        model.confirmingQuit=true;try require(adapter.captureSelection()==nil,"Quit owner allowed drag");model.confirmingQuit=false
        model.canStartFileDrag={false};try require(adapter.captureSelection()==nil,"Embedded owner callback was ignored");model.canStartFileDrag={true}
        let window=try unwrap(owner.window,"Missing owner"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:160,height:60),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;window.beginSheet(sheet,completionHandler:{_ in})
        try await wait{window.attachedSheet===sheet};try require(adapter.captureSelection()==nil,"Owned sheet did not block drag");window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
        let table=try unwrap(adapter.nativeTable,"Missing actual source table"),selectedRow=try unwrap(table.selectedRowIndexes.first,"Missing highlighted source row")
        let rect=table.rect(ofRow:selectedRow),point=table.convert(NSPoint(x:rect.minX+80,y:rect.midY),to:nil)
        let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let moved=NSEvent.mouseEvent(with:.leftMouseDragged,location:NSPoint(x:point.x+12,y:point.y+12),modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:1)!
        _=adapter.observe(moved);try require(adapter.activeDrag==nil,"Orphan native drag acquired a source receipt")
        _=adapter.observe(down)
        let oldGeneration=model.fileDragGeneration,snapshot=try unwrap(model.snapshot,"Missing accepted source")
        model.installEmbeddedSnapshot(.init(root:snapshot.root,from:snapshot.from,to:.revision(c.first),fromDetails:snapshot.fromDetails,toDetails:nil,files:snapshot.files,options:snapshot.options),bare:false)
        try require(model.fileDragGeneration != oldGeneration && accepted.revision == .revision(c.head),"Replaced snapshot retained source gesture identity or retargeted receipt")
        try require(adapter.observe(moved) === moved && adapter.activeDrag==nil,"Native drag crossed a replaced source snapshot")
        owner.close();try require(adapter.captureSelection()==nil,"Retired source allowed new gesture")
        // A dedicated caller grant verifies receipt retention independently of
        // legitimate Cocoa caching of the unrelated window/model.
        let scope=Scope();var lease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        var receipt:FileListSelectionDrag?=FileListSelectionDrag(repository:c.repo,access:lease,files:files,revision:.revision(c.head),backend:.init(enabled:false));lease=nil
        try require(scope.starts==1 && scope.stops==0,"Accepted transfer dropped caller grant")
        var writer:NSFilePromiseProvider?=try unwrap(receipt?.writers.compactMap{$0 as? NSFilePromiseProvider}.first,"Missing retained grant promise")
        let output=c.base.appendingPathComponent("grant/"+(writer!.delegate as! FileListFilePromise).name)
        try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true);try await promise(writer!,output)
        let bytes=try Data(contentsOf:output);try require(bytes==c.historical[files[0].path],"Retained receipt changed materialization source")
        receipt=nil;try require(scope.stops==0,"Live deferred promise lost retained scope")
        withExtendedLifetime(writer){};writer=nil;try await wait{scope.stops==1}
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hooks=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.revisionDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.revisionDragOrder(_:relativeTo:))))]
        for(a,b)in hooks{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in hooks.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();switch CommandLine.arguments[3]{case "historical":try await historical(c);case "working":try await working(c);case "sourceownership":try await sourceownership(c);default:throw Failure(description:"Unknown Changed Files drag case")};try await c.preserved();await c.clean();try require(FileListDrag.activeLoads==0 && RevisionComparisonWindowModel.activeFileOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Changed Files windows/readers did not drain");print("PASS: revision file drags "+CommandLine.arguments[3]);fflush(stdout)}catch{await c.clean();fputs("Revision file drags failed: \(error)\n",stderr);exit(1)}
    }
}
