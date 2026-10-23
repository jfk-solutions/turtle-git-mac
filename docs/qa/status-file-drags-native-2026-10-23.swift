// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func workingDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func workingDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));workingDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum StatusFileDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"Working drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ condition:()->Bool)async throws{for _ in 0..<3000{window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Working drag timeout \(line)")}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    final class Scope:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data{Data(url.path.utf8)}
        func resolve(_ bytes:Data)throws->ResolvedBookmark{.init(url:URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool{starts += 1;return true}
        func stopAccessing(_ url:URL){stops += 1}
    }
    final class DataReply:@unchecked Sendable {
        private let lock=NSLock();private var stored:Result<Data,Error>?
        var value:Result<Data,Error>?{lock.lock();defer{lock.unlock()};return stored}
        func finish(_ data:Data?,_ error:Error?){lock.lock();defer{lock.unlock()};if let error{stored = .failure(error)}else if let data{stored = .success(data)}else{stored = .failure(Failure(description:"Missing drag data"))}}
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.WorkingDrag."+UUID().uuidString,prefs:UserDefaults,scope=Scope()
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        let literal="literal\tline\n雪.txt"
        var owners:[NSWindowController]=[],head="",index=Data(),before:[String:Data]=[:]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Autocompletion");prefs.set(1,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint")}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Working drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in ["a.txt","z.txt",literal,"missing.txt","deleted.txt"]{try Data((name+" base\n").utf8).write(to:root.appendingPathComponent(name))}
            try Data("ignored-dir/\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
            try await repo.stage(["."]);_=try await repo.commit(message:"private drag base");head=try await repo.rebaseCommit("HEAD").hash
            for name in ["a.txt","z.txt",literal]{try Data((name+" working\n").utf8).write(to:root.appendingPathComponent(name))}
            try FileManager.default.removeItem(at:root.appendingPathComponent("missing.txt"));try FileManager.default.removeItem(at:root.appendingPathComponent("deleted.txt"));_=try await repo.run(["add","--","deleted.txt"])
            try FileManager.default.createDirectory(at:root.appendingPathComponent("module"),withIntermediateDirectories:true)
            _=try await repo.run(["update-index","--add","--cacheinfo","160000",head,"module"])
            try FileManager.default.createDirectory(at:root.appendingPathComponent("ignored-dir"),withIntermediateDirectories:true)
            try Data("ignored\n".utf8).write(to:root.appendingPathComponent("ignored-dir/payload"))
            for name in ["loose-a.txt","loose-z.txt","untracked\t\n雪.txt"]{try Data((name+" bytes\n").utf8).write(to:root.appendingPathComponent(name))}
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            for name in ["a.txt","z.txt",literal,"loose-a.txt","loose-z.txt","untracked\t\n雪.txt"]{before[name]=try Data(contentsOf:root.appendingPathComponent(name))}
        }
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.showWindow(nil);owner.window?.alphaValue=0;owner.window?.orderFront(nil);return owner}
        func lease()->RepositoryAccessLease{RepositoryAccessLease(url:root,provider:scope)}
        func preserved()async throws {let current=try await repo.rebaseCommit("HEAD").hash;try require(current==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Drag changed HEAD/index");for(name,bytes)in before{try require((try Data(contentsOf:root.appendingPathComponent(name)))==bytes,"Drag changed working file "+name)}}
        func clean()async {for owner in owners {if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[];for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};FileListDrag.discardAll();prefs.removePersistentDomain(forName:suite)}
    }
    static func drained()->Bool{FileListDrag.activeLoads==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && StatusWindowModel.activeOperations==0 && AddWindowModel.activeOperations==0}
    static func check(_ drag:WorkingFileListDrag,expected:[String],eligible:[String],origin:String,_ c:Context)async throws {
        try require(drag.paths==expected,"Drag lost native display order or included checked-only rows: \(drag.paths) vs \(expected)")
        try require(Data(drag.text.utf8)==Data((expected.map{$0+"\r\n"}.joined()).utf8),"Unicode path text representation changed literal bytes/order")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try require(drag.write(to:board),"Captured native drag could not write private pasteboard")
        try require(board.string(forType:.string).map{Data($0.utf8)}==Data(drag.text.utf8),"Private pasteboard did not retain complete selected path text")
        let urls=(board.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        try require(urls.map{String($0.path.dropFirst(c.root.path.count+1))}==eligible,"File URL payload omitted/reordered eligible rows or exported missing/deleted/directory/gitlink: \(urls)")
        try require(FileListDrag.isOwnWorkingDrop(pasteboard:board,origin:origin) && !FileListDrag.isOwnWorkingDrop(pasteboard:board,origin:origin+".other"),"Own-drag marker not confined to originating list")
        try require(FileListDrag.isOwnWorkingDrop(providers:drag.providers,origin:origin),"Own providers lost source marker")
        for path in eligible {let url=c.root.appendingPathComponent(path);try require(urls.contains(url),"Working drag substituted a temporary/index URL")}
    }
    static func probe(_ owner:NSWindowController)async throws->CommitFileInteraction.Probe {
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.contains{$0.nativeTable != nil && $0.captureWorkingDrag != nil}}
        return try unwrap(views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.nativeTable != nil && $0.captureWorkingDrag != nil},"Missing installed outbound table adapter")
    }
    static func select(_ paths:[String],in probe:CommitFileInteraction.Probe)throws->[String] {
        let wanted=GitPathSet(paths),indexes=IndexSet(probe.rows.indices.filter{probe.rows[$0].entry.map{wanted.contains($0.path)} == true})
        try require(indexes.count==paths.count,"Actual native list omitted required drag rows: \(paths)")
        let table=try unwrap(probe.nativeTable,"Detached native list")
        table.selectRowIndexes(indexes,byExtendingSelection:false)
        return indexes.compactMap{probe.rows[$0].entry?.path}
    }
    static func sheetFence(_ owner:NSWindowController,capture:()->WorkingFileListDrag?)async throws {
        let window=try unwrap(owner.window,"Missing drag owner"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        defer{if sheet.sheetParent != nil{window.endSheet(sheet,returnCode:.abort)};sheet.close()}
        window.beginSheet(sheet,completionHandler:{_ in})
        try await wait{window.attachedSheet === sheet}
        try require(capture()==nil,"Source list began an outbound drag through its attached sheet")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
    }
    @MainActor final class ClosedSource {
        weak var owner:NSWindowController?
        weak var model:AnyObject?
        weak var window:NSWindow?
        weak var content:NSView?
        weak var adapter:AnyObject?
        init(owner:NSWindowController,model:AnyObject,adapter:AnyObject){self.owner=owner;self.model=model;self.adapter=adapter;window=owner.window;content=owner.window?.contentView}
    }
    struct AcceptedDrag {
        let drag:WorkingFileListDrag,source:ClosedSource,entries:[StatusEntry]
        let refusesNewDrags:()->Bool
    }
    static func deliveredAfterClose(_ accepted:AcceptedDrag,_ c:Context)async throws {
        if ProcessInfo.processInfo.environment["TURTLEGIT_DRAG_TRACE"] == "1" {
            func pointer(_ object:AnyObject?)->String? {
                object.map { "0x"+String(UInt(bitPattern:Unmanaged.passUnretained($0).toOpaque()),radix:16) }
            }
            let source=accepted.source
            let witness:[String:Any]=[
                "controller":pointer(source.owner).map { $0 as Any } ?? NSNull(),
                "model":pointer(source.model).map { $0 as Any } ?? NSNull(),
                "window":pointer(source.window).map { $0 as Any } ?? NSNull(),
                "sourceVisible":source.window?.isVisible == true,
                "sourceSheetAttached":source.window?.attachedSheet != nil,
                "drained":drained()
            ]
            let bytes=try JSONSerialization.data(withJSONObject:witness,options:[.sortedKeys])
            try bytes.write(to:c.base.appendingPathComponent("release-witness.json"),options:.atomic)
        }
        try await wait{drained()}
        try require(accepted.source.window?.isVisible != true && accepted.source.window?.attachedSheet==nil,"Source window remained open or retained an attached sheet")
        try require(!c.owners.contains{$0 === accepted.source.owner} && accepted.refusesNewDrags(),"Closed source remained owned or accepted a new drag")
        // Cocoa may retain closed windows/models in event caches. Deallocation
        // is an optional retain-graph diagnostic, not the source-close contract.
        if ProcessInfo.processInfo.environment["TURTLEGIT_DRAG_REQUIRE_DEALLOCATION"] == "1" {
            do {try await wait{drained() && accepted.source.owner==nil && accepted.source.model==nil}}
            catch {
                let source=accepted.source
                print("Release witness owner=\(source.owner != nil) model=\(source.model != nil) window=\(source.window != nil) content=\(source.content != nil) adapter=\(source.adapter != nil) hostingController=\(source.window?.contentViewController != nil) visible=\(source.window?.isVisible == true) sheet=\(source.window?.attachedSheet != nil) appListed=\(NSApp.windows.contains{$0 === source.window}) drained=\(drained()) scope=\(c.scope.starts)/\(c.scope.stops)")
                print("Release counters files=\(FileListDrag.activeLoads) commitReload=\(CommitWindowModel.activeReloads) commitMetadata=\(CommitWindowModel.activeMetadataOperations) commitPreferences=\(CommitWindowModel.activePreferenceOperations) commitFiles=\(CommitWindowModel.activeFileOperations) status=\(StatusWindowModel.activeOperations) add=\(AddWindowModel.activeOperations)")
                if let model=source.model as? CommitWindowModel {print("Closed Commit model focusAvailable=\(model.messageFocusAvailable) fileWork=\(model.fileWorkPending) busy=\(model.busy)")}
                fflush(stdout);throw error
            }
        }
        try await afterClose(accepted.drag,c)
        try await independentPermission(accepted,c)
    }
    static func independentPermission(_ accepted:AcceptedDrag,_ c:Context)async throws {
        let scope=Scope()
        var callerLease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        weak var authority=callerLease
        let directories=GitPathSet(accepted.entries.filter {entry in
            (try? FileManager.default.attributesOfItem(atPath:c.root.appendingPathComponent(entry.path).path)[.type]) as? FileAttributeType == .typeDirectory
        }.map(\.path))
        var captured:WorkingFileListDrag?=FileListDrag.workingSelection(repository:c.repo,access:callerLease,entries:accepted.entries,directories:directories,backend:.init(enabled:false),origin:UUID().uuidString)
        try require(captured != nil,"Independent permission helper refused actual selected entries")
        try require(captured?.paths==accepted.drag.paths,"Independent permission receipt changed actual native selected order")
        let providers=captured!.providers
        callerLease=nil;captured=nil
        try require(authority != nil && scope.starts==1 && scope.stops==0,"Provider failed to retain authority after caller lease and helper receipt release")
        let provider=try unwrap(providers.first{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)},"Independent permission receipt omitted real file URL")
        let reply=DataReply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){reply.finish($0,$1)}
        try await wait{reply.value != nil}
        let data=try reply.value!.get(),url=try unwrap(URL(string:String(decoding:data,as:UTF8.self)),"Independent provider returned invalid file URL")
        try require(accepted.drag.paths.contains(String(url.path.dropFirst(c.root.path.count+1))) && authority != nil && scope.stops==0,"Independent provider lost captured file/permission after source close")
        let bytes=try Data(contentsOf:url)
        try require(bytes==c.before[String(url.path.dropFirst(c.root.path.count+1))],"Independent authorized provider returned different working bytes")
    }
    static func commit(_ c:Context)async throws {
        let accepted=try await commitSource(c);try await deliveredAfterClose(accepted,c)
    }
    static func status(_ c:Context)async throws {
        let accepted=try await statusSource(c);try await deliveredAfterClose(accepted,c)
    }
    static func add(_ c:Context)async throws {
        let accepted=try await addSource(c);try await deliveredAfterClose(accepted,c)
    }
    static func afterClose(_ drag:WorkingFileListDrag,_ c:Context)async throws {
        let provider=try unwrap(drag.providers.first{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)},"No file URL provider survived source close")
        let result=DataReply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){result.finish($0,$1)}
        try await wait{result.value != nil};let bytes=try result.value!.get()
        let text=String(decoding:bytes,as:UTF8.self),url=try unwrap(URL(string:text),"Captured provider did not return literal file URL")
        try require(drag.fileURLs.contains(url) && (try Data(contentsOf:url))==c.before[String(url.path.dropFirst(c.root.path.count+1))],"Source close rebound captured file URL/bytes")
        try require(c.scope.starts>0 && c.scope.stops==0,"Captured drag failed to retain its originating permission")
    }
    static func commitSource(_ c:Context)async throws->AcceptedDrag {
        let owner=autoreleasepool {c.own(CommitWindowController(repository:c.repo,access:c.lease(),defaults:c.prefs))},model=owner.model
        model.confirmCancel={$0(true)};model.reload()
        try await wait(owner.window){!model.busy && model.fileListAvailable && model.entries.contains{ $0.path=="module" }}
        model.setFileSortOrder([CommitFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner)
        let chosen=["a.txt","z.txt",c.literal,"missing.txt","deleted.txt","module"]
        try await wait(owner.window){Set(adapter.rows.compactMap{ $0.entry?.path }).isSuperset(of:Set(chosen)) && adapter.rows.compactMap{$0.entry?.path}.first==model.sortedFiles(model.visibleEntries,statistics:model.statistics).first?.path}
        model.checked=GitPathSet(["loose-a.txt"])
        let expected=try select(chosen,in:adapter);try await wait{model.selection==GitPathSet(chosen)}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(adapter.workingDragSelection(),"Commit installed adapter refused selected rows")
        try require(expected.first=="z.txt" && expected.last=="a.txt","Commit fixture did not realize descending native row order")
        let eligible=expected.filter{["a.txt","z.txt",c.literal].contains($0)}
        try await check(drag,expected:expected,eligible:eligible,origin:model.workingDragOrigin,c)
        try require(model.checked==GitPathSet(["loose-a.txt"]) && !model.receiveFileDrop(drag.providers),"Commit drag changed checked files or accepted its own source")
        let textOnly=try select(["missing.txt","deleted.txt","module"],in:adapter);try await wait{model.selection==GitPathSet(textOnly)}
        let excluded=try unwrap(adapter.workingDragSelection(),"Missing/deleted/gitlink selection lost text-only drag")
        try await check(excluded,expected:textOnly,eligible:[],origin:model.workingDragOrigin,c)
        _ = try select(chosen,in:adapter);try await wait{model.selection==GitPathSet(chosen)}
        try await sheetFence(owner){adapter.workingDragSelection()}
        model.busy=true;try require(adapter.workingDragSelection()==nil,"Commit busy list exported new drag");model.busy=false
        model.confirmingQuit=true;try require(adapter.workingDragSelection()==nil,"Commit Quit fence exported new drag");model.confirmingQuit=false
        // This prohibited headless receiver has no ordinary AppKit event-loop
        // autorelease boundary. Drain Cocoa's transient creation/close retains
        // explicitly; the source still receives its normal production close.
        return try autoreleasepool {
            owner.close();try require(adapter.workingDragSelection()==nil,"Retired Commit adapter exported new drag")
            let source=ClosedSource(owner:owner,model:model,adapter:adapter);c.owners.removeAll{$0 === owner}
            let entries=drag.paths.compactMap{path in model.entries.first{ $0.path==path }}
            try require(entries.count==drag.paths.count,"Captured actual selected entries disappeared before close")
            return AcceptedDrag(drag:drag,source:source,entries:entries,refusesNewDrags:{[weak model] in model?.captureWorkingDrag(drag.paths)==nil})
        }
    }
    static func statusSource(_ c:Context)async throws->AcceptedDrag {
        let owner=autoreleasepool {c.own(StatusWindowController(repository:c.repo,access:c.lease(),defaults:c.prefs))},model=owner.model
        model.reload();try await wait(owner.window){!model.busy && model.files.contains{$0.id=="module"}}
        model.setSortOrder([StatusFileSort(column:.path,order:.reverse)])
        let adapter=try await probe(owner),chosen=["a.txt","z.txt",c.literal,"missing.txt","deleted.txt","module"]
        try await wait(owner.window){Set(adapter.rows.compactMap{$0.entry?.path}).isSuperset(of:Set(chosen)) && adapter.rows.compactMap{$0.entry?.path}.first==model.sortedRows.first?.path}
        let expected=try select(chosen,in:adapter);try await wait{model.selection==GitPathSet(chosen)}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let drag=try unwrap(adapter.workingDragSelection(),"Working Tree installed adapter refused selected rows")
        try require(expected.first=="z.txt" && expected.last=="a.txt","Working Tree fixture did not realize descending row order")
        try await check(drag,expected:expected,eligible:expected.filter{["a.txt","z.txt",c.literal].contains($0)},origin:model.workingDragOrigin,c)
        var accepted=0;model.onTransferDrop={_ in accepted += 1;return true}
        try require(!model.receiveFileDrop(drag.providers) && accepted==0,"Working Tree accepted its own file drag")
        let external=NSItemProvider(contentsOf:c.root.appendingPathComponent("loose-a.txt"))!
        try require(model.receiveFileDrop([external]) && accepted==1,"Working Tree incorrectly rejected another owner/external file")
        model.busy=true;try require(adapter.workingDragSelection()==nil,"Busy Working Tree exported new drag");model.busy=false
        model.confirmingQuit=true;try require(adapter.workingDragSelection()==nil,"Working Tree Quit fence exported new drag");model.confirmingQuit=false
        // This prohibited headless receiver has no ordinary AppKit event-loop
        // autorelease boundary. Drain Cocoa's transient creation/close retains
        // explicitly; the source still receives its normal production close.
        return try autoreleasepool {
            owner.close();try require(adapter.workingDragSelection()==nil,"Retired Working Tree exported new drag")
            let source=ClosedSource(owner:owner,model:model,adapter:adapter);c.owners.removeAll{$0 === owner}
            let entries=drag.paths.compactMap{path in model.files.first{ $0.id==path }?.entry}
            try require(entries.count==drag.paths.count,"Captured actual selected entries disappeared before close")
            return AcceptedDrag(drag:drag,source:source,entries:entries,refusesNewDrags:{[weak model] in model?.captureWorkingDrag(drag.paths)==nil})
        }
    }
    static func addSource(_ c:Context)async throws->AcceptedDrag {
        let owner=autoreleasepool {c.own(AddWindowController(repository:c.repo,access:c.lease(),defaults:c.prefs))},model=owner.model
        model.includeIgnored=true;model.reload()
        try await wait(owner.window){!model.busy && model.entries.contains{$0.path=="loose-z.txt"}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSTableView}.first,"Missing actual Add table")
        let coordinator=try unwrap(table.dataSource as? AddFileTable.Coordinator,"Missing actual Add table data source")
        table.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)];coordinator.tableView(table,sortDescriptorsDidChange:[])
        let chosen=["loose-a.txt","loose-z.txt","untracked\t\n雪.txt"]
        let indexes=IndexSet(coordinator.rows.indices.filter{chosen.contains(coordinator.rows[$0].path)})
        try require(indexes.count==chosen.count,"Actual Add candidate list omitted literal selected rows")
        table.selectRowIndexes(indexes,byExtendingSelection:false);try await wait{model.highlighted==GitPathSet(chosen)}
        model.checked=GitPathSet(model.entries.filter{!chosen.contains($0.path)}.prefix(1).map(\.path));let checked=model.checked
        let expected=indexes.map{coordinator.rows[$0].path}
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        // A real file disappears after the accepted Add read. It remains in
        // selected path text, but cannot offer working-file contents.
        let disappearing=c.root.appendingPathComponent("loose-z.txt");try FileManager.default.removeItem(at:disappearing)
        defer{try? c.before["loose-z.txt"]?.write(to:disappearing)}
        let drag=try unwrap(coordinator.captureDrag(rows:indexes),"Actual Add delegate refused selected rows")
        try await check(drag,expected:expected,eligible:expected.filter{$0 != "loose-z.txt"},origin:model.workingDragOrigin,c)
        try require(model.checked==checked && !checked.isEmpty && checked.intersection(GitPathSet(chosen)).isEmpty,"Add drag changed/used checked operation membership")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};try require(coordinator.tableView(table,writeRowsWith:indexes,to:board) && coordinator.workingDrag != nil,"Add native writeRows callback did not retain/publish selection")
        try require(!coordinator.validateDrop(board),"Add delegate accepted own-source drop")
        let row=indexes.first!,checkbox=table.rect(ofColumn:0),point=NSPoint(x:checkbox.midX,y:table.rect(ofRow:row).midY)
        try require(!coordinator.tableView(table,canDragRowsWith:indexes,at:point),"Dragging checkbox initiated file export")
        try await sheetFence(owner){coordinator.captureDrag(rows:indexes)}
        model.busy=true;try require(coordinator.captureDrag(rows:indexes)==nil,"Busy Add exported new drag");model.busy=false
        model.confirmingQuit=true;try require(coordinator.captureDrag(rows:indexes)==nil,"Add Quit fence exported new drag");model.confirmingQuit=false
        // This prohibited headless receiver has no ordinary AppKit event-loop
        // autorelease boundary. Drain Cocoa's transient creation/close retains
        // explicitly; the source still receives its normal production close.
        return try autoreleasepool {
            owner.close();try require(coordinator.captureDrag(rows:indexes)==nil,"Retired Add delegate exported new drag")
            let source=ClosedSource(owner:owner,model:model,adapter:coordinator);c.owners.removeAll{$0 === owner}
            let entries=drag.paths.compactMap{path in model.entries.first{ $0.path==path }?.status}
            try require(entries.count==drag.paths.count,"Captured actual selected entries disappeared before close")
            return AcceptedDrag(drag:drag,source:source,entries:entries,refusesNewDrags:{[weak model] in model?.captureWorkingDrag(drag.paths)==nil})
        }
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.workingDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.workingDragOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "commit":try await commit(c);case "status":try await status(c);case "add":try await add(c);default:throw Failure(description:"Unknown drag case")};try await c.preserved();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned drag windows/work did not drain");print("PASS: status file drags "+kind);fflush(stdout)}catch{await c.clean();fputs("Status file drags failed: \(error)\n",stderr);exit(1)}
    }
}
