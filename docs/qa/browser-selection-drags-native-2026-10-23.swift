// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func browserDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func browserDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));browserDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum BrowserSelectionDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Browser drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Browser drag timeout \(line)")}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    final class Reply:@unchecked Sendable {
        private let lock=NSLock();private var result:Result<Void,Error>?
        var value:Result<Void,Error>?{lock.lock();defer{lock.unlock()};return result}
        func finish(_ error:Error?){lock.lock();defer{lock.unlock()};result=error.map{.failure($0)} ?? .success(())}
    }
    final class DataReply:@unchecked Sendable {
        private let lock=NSLock();private var result:Result<Data,Error>?
        var value:Result<Data,Error>?{lock.lock();defer{lock.unlock()};return result}
        func finish(_ data:Data?,_ error:Error?){lock.lock();defer{lock.unlock()};result=error.map{.failure($0)} ?? data.map{.success($0)} ?? .failure(Failure(description:"Missing text representation"))}
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
        let suite="TurtleGit.BrowserSelectionDrag."+UUID().uuidString,prefs:UserDefaults
        let literal="literal\tline\n雪.bin"
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        var head="",index=Data(),owners:[RepositoryBrowserWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar")}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root.appendingPathComponent("folder/deep"),withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Browser drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in ["a.txt","folder/a.txt","folder/deep/b.txt",literal]{try Data((name+" historical\n").utf8).write(to:root.appendingPathComponent(name))}
            try await repo.stage(["."]);_=try await repo.commit(message:"private leaves");head=try await repo.rebaseCommit("HEAD").hash
            _=try await repo.run(["update-index","--add","--cacheinfo","160000",head,"module"])
            _=try await repo.commit(message:"private gitlink");head=try await repo.rebaseCommit("HEAD").hash
            _=try await repo.run(["tag","-a","drag-tag","-m","annotated historical drag"])
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try Data("dirty working\n".utf8).write(to:root.appendingPathComponent("a.txt"))
        }
        func open()async throws->RepositoryBrowserWindowController {
            let owner=RepositoryBrowserWindowController(repository:repo,access:RepositoryAccessLease(url:root),revision:"drag-tag",preferences:prefs)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            try await wait{!owner.model.busy && owner.model.snapshot != nil && owner.contentsTable != nil && !owner.model.transferInventoryBusy}
            return owner
        }
        func preserved()async throws {
            let hash=try await repo.rebaseCommit("HEAD").hash,data=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try require(hash==head && data==index,"Drag mutated HEAD/index")
            try require(try Data(contentsOf:root.appendingPathComponent("a.txt"))==Data("dirty working\n".utf8),"Drag mutated working bytes")
        }
        func clean()async {
            for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[]
            for _ in 0..<3000{if RepositoryBrowserExportFiles.activeLoads==0 && RepositoryBrowserWindowModel.activeOperations==0{break};try? await Task.sleep(nanoseconds:10_000_000)}
            RepositoryBrowserExportFiles.discardAll();prefs.removePersistentDomain(forName:suite)
        }
    }
    static func contents(_ owner:RepositoryBrowserWindowController)throws->RepositoryBrowserContentsTable.Coordinator {
        try unwrap(owner.contentsTable?.dataSource as? RepositoryBrowserContentsTable.Coordinator,"Missing actual Browser contents datasource")
    }
    static func select(_ names:[String],_ owner:RepositoryBrowserWindowController)async throws->(RepositoryBrowserContentsTable.Coordinator,IndexSet,[RepositoryBrowserEntry]) {
        let model=owner.model;model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.name,order:.reverse)]
        let coordinator=try contents(owner);coordinator.update()
        let entries=model.entries,indexes=IndexSet(entries.indices.filter{names.contains(entries[$0].path)})
        try require(indexes.count==names.count,"Missing displayed Browser rows")
        let table=try unwrap(owner.contentsTable,"Detached Browser contents")
        table.deselectAll(nil);table.selectRowIndexes(indexes,byExtendingSelection:false)
        try await wait{model.selection==Set(indexes.map{entries[$0].id})}
        return(coordinator,indexes,indexes.map{entries[$0]})
    }
    static func down(_ table:NSTableView,row:Int)throws->NSEvent {
        let window=try unwrap(table.window,"Detached native gesture source"),rect=table.rect(ofRow:row)
        let point=table.convert(NSPoint(x:rect.minX+60,y:rect.midY),to:nil)
        return try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),"Missing source mouse event")
    }
    static func assertText(_ drag:RepositoryBrowserSelectionDrag,_ expected:[String])throws {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let text=expected.map{$0+"\r\n"}.joined()
        try require(drag.paths.map{Data($0.utf8)}==expected.map{Data($0.utf8)},"Recursive text order/path identity changed")
        try require(drag.text==text && drag.write(to:board) && board.string(forType:.string)==text,"Native aggregate text omitted literal paths")
    }
    static func promise(_ promise:RepositoryBrowserFilePromise,to destination:URL)async throws {
        let provider=promise.provider(),reply=Reply()
        let queued=RepositoryBrowserExportFiles.activeLoads
        promise.filePromiseProvider(provider,writePromiseTo:destination){reply.finish($0)}
        try require(RepositoryBrowserExportFiles.activeLoads==queued+1,"Queued promise escaped Quit ownership")
        try await wait{reply.value != nil};try reply.value!.get()
    }
    static func list(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        let(coordinator,indexes,entries)=try await select(["folder","module",c.literal],owner)
        let receipt=try unwrap(coordinator.captureDrag(rows:indexes),"Actual contents gesture refused")
        let expected=entries.flatMap{$0.kind == .directory ? ["folder/a.txt","folder/deep/b.txt"]:[$0.path]}
        try assertText(receipt,expected)
        try require(receipt.revision==c.head && receipt.names.count==2 && !receipt.names.contains("module"),"Peeled revision/gitlink descriptor capture failed")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let native=try unwrap(owner.contentsTable as? RepositoryBrowserNativeTable,"No native source")
        try require(native.captureDragGesture(try down(native,row:indexes.first!)),"Native source press refused")
        try require(coordinator.tableView(native,writeRowsWith:indexes,to:board),"Actual native writeRows rejected selection")
        try require(board.string(forType:.string)==receipt.text,"Installed datasource lost aggregate text")
        owner.close()
        let destination=c.base.appendingPathComponent("list-delivery");try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        for item in receipt.promises{try await promise(item,to:destination.appendingPathComponent(item.name))}
        try require(try Data(contentsOf:destination.appendingPathComponent("folder/deep/b.txt"))==Data("folder/deep/b.txt historical\n".utf8),"Folder contents changed after close")
        try require(try Data(contentsOf:destination.appendingPathComponent(c.literal))==Data((c.literal+" historical\n").utf8),"Literal historical contents changed")
        try require(!model.active && coordinator.captureDrag(rows:indexes)==nil,"Retired contents accepted new source")
        let second=try await c.open();let(source,rows,_)=try await select(["module"],second)
        let textOnly=try unwrap(source.captureDrag(rows:rows),"Gitlink text-only drag refused")
        try assertText(textOnly,["module"]);try require(textOnly.names.isEmpty && textOnly.promises.isEmpty && textOnly.providers.isEmpty,"Gitlink invented file contents")
    }
    static func tree(_ c:Context)async throws {
        let owner=try await c.open()
        let tree=try unwrap(views(owner.window?.contentView).compactMap{$0 as? RepositoryBrowserFolderOutline}.first,"Missing actual folder tree")
        let coordinator=try unwrap(tree.dataSource as? RepositoryBrowserFolderTree.Coordinator,"Missing folder datasource")
        let root=try unwrap(coordinator.captureDrag(""),"Root transfer refused")
        try assertText(root,["a.txt","folder/a.txt","folder/deep/b.txt",c.literal,"module"])
        try require(Set(root.names)==Set(["a.txt","folder",c.literal]),"Root drag inserted repository-name wrapper")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        try require(tree.captureDragGesture(try down(tree,row:0)),"Native tree press refused")
        try require(coordinator.outlineView(tree,writeItems:[coordinator.node("")],to:board),"Actual tree root writeItems refused")
        try require(board.pasteboardItems?.count==root.writers.count,"Root datasource flattened multiple file promises")
        let nested=try unwrap(coordinator.captureDrag("folder"),"Nested tree transfer refused")
        try assertText(nested,["folder/a.txt","folder/deep/b.txt"]);try require(nested.names==["folder"],"Nested folder lost leaf export name")
        owner.model.loadDirectory("folder",select:true)
        try await wait{owner.model.snapshot?.directory=="folder"}
        let(list,rows,_)=try await select(["folder/deep"],owner)
        let selected=try unwrap(list.captureDrag(rows:rows),"Nested contents refused")
        try assertText(selected,["folder/deep/b.txt"]);try require(selected.names==["deep"],"Contents folder exported full parent hierarchy")
        owner.close()
        let destination=c.base.appendingPathComponent("root-delivery");try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        for item in root.promises{try await promise(item,to:destination.appendingPathComponent(item.name))}
        try require(try Data(contentsOf:destination.appendingPathComponent("a.txt"))==Data("a.txt historical\n".utf8),"Root promise used working bytes")
        try require(!FileManager.default.fileExists(atPath:destination.appendingPathComponent(c.root.lastPathComponent).path),"Root exported repository wrapper")
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        let(coordinator,rows,entries)=try await select(["a.txt"],owner)
        let accepted=try unwrap(coordinator.captureDrag(rows:rows),"Initial receipt refused")
        model.busy=true;try require(coordinator.captureDrag(rows:rows)==nil,"Busy owner accepted drag");model.busy=false
        model.confirmingQuit=true;try require(coordinator.captureDrag(rows:rows)==nil,"Quit owner accepted drag");model.confirmingQuit=false
        model.choosingRevision=true;try require(coordinator.captureDrag(rows:rows)==nil,"Revision picker accepted drag");model.choosingRevision=false
        let window=try unwrap(owner.window,"Missing owner"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:160,height:60),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;window.beginSheet(sheet,completionHandler:{_ in})
        try await wait{window.attachedSheet===sheet};try require(coordinator.captureDrag(rows:rows)==nil,"Sheet owner accepted drag");window.endSheet(sheet,returnCode:.abort);sheet.close()
        let native=try unwrap(owner.contentsTable as? RepositoryBrowserNativeTable,"Missing gesture source")
        // SwiftUI restores the disabled native subtree on its next update, and
        // AppKit clears the two sides of a sheet relationship independently.
        // A new press must wait for that real interactive projection.
        do {
            try await wait {
                native.layoutSubtreeIfNeeded()
                let rect=native.rect(ofRow:rows.first!),point=NSPoint(x:rect.minX+60,y:rect.midY)
                return window.attachedSheet==nil && sheet.sheetParent==nil && native.window===window && native.isEnabled && coordinator.available && model.transferContext(tree:false) != nil && native.row(at:point)==rows.first! && native.column(at:point)>=0
            }
        } catch {
            fputs("Browser press readiness: parentSheet=\(window.attachedSheet != nil) childParent=\(sheet.sheetParent != nil) attached=\(native.window===window) enabled=\(native.isEnabled) available=\(coordinator.available) context=\(model.transferContext(tree:false) != nil) rows=\(native.numberOfRows) selected=\(native.selectedRowIndexes) frame=\(native.frame) bounds=\(native.bounds)\n",stderr)
            throw error
        }
        try require(native.captureDragGesture(try down(native,row:rows.first!)),"Press receipt refused")
        let nonce=model.transferContext(tree:false)
        model.selection=[];model.selection=Set(entries.map(\.id))
        try require(model.transferContext(tree:false)==nonce && native.acceptsDragGesture,"Highlight change invalidated normal native drag")
        model.sortOrder=[KeyPathComparator(\RepositoryBrowserEntry.name)]
        try require(!native.acceptsDragGesture,"Changed display sorting retained stale native press")
        let old=model.generation;model.refresh();try require(coordinator.captureDrag(rows:rows)==nil,"Reload accepted stale displayed rows")
        try await wait{!model.busy && !model.transferInventoryBusy};try require(model.generation != old && accepted.revision==c.head,"Reload retargeted accepted transfer")
        owner.close();try require(coordinator.captureDrag(rows:rows)==nil,"Closed owner accepted drag")
        let textReply=DataReply()
        _=accepted.textProvider.loadDataRepresentation(forTypeIdentifier:accepted.textProvider.registeredTypeIdentifiers[0]){textReply.finish($0,$1)}
        try await wait{textReply.value != nil}
        let textBytes=try textReply.value!.get();try require(textBytes==Data(accepted.text.utf8),"Deferred aggregate text changed after close")
        let scope=Scope();var lease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        var receipt:RepositoryBrowserSelectionDrag?=RepositoryBrowserSelectionDrag(repository:c.repo,access:lease,snapshot:try unwrap(model.snapshot,"Missing snapshot"),selected:entries,inventory:nil,backend:.init(enabled:false));lease=nil
        try require(scope.starts==1 && scope.stops==0,"Receipt dropped captured grant")
        var promised:RepositoryBrowserFilePromise?=try unwrap(receipt?.promises.first,"No retained promise")
        receipt=nil;try require(scope.stops==0,"Pending promise lost grant")
        try await promised!.write(to:c.base.appendingPathComponent("accepted.txt"));promised=nil
        try await wait{scope.stops==1}
        try require(try Data(contentsOf:c.base.appendingPathComponent("accepted.txt"))==Data("a.txt historical\n".utf8),"Accepted transfer changed after retirement")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hooks=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.browserDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.browserDragOrder(_:relativeTo:))))]
        for(a,b)in hooks{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in hooks.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();switch CommandLine.arguments[3]{case "list":try await list(c);case "tree":try await tree(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown Browser drag case")};try await c.preserved();await c.clean();try require(RepositoryBrowserExportFiles.activeLoads==0 && RepositoryBrowserWindowModel.activeOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Browser windows/readers did not drain");print("PASS: browser selection drags "+CommandLine.arguments[3]);fflush(stdout)}catch{await c.clean();fputs("Browser selection drags failed: \(error)\n",stderr);exit(1)}
    }
}
