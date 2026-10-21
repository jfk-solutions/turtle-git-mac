// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func fileListDragHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;fileListDragHiddenOrder(place,relativeTo:number)
    }
}

@MainActor @main enum FileListDragVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    struct Loaded {let bytes:Data,url:URL,mode:Int}
    final class LoadResult:@unchecked Sendable {
        private let lock=NSLock();private var stored:Result<Loaded,Error>?
        var value:Result<Loaded,Error>? {lock.lock();defer{lock.unlock()};return stored}
        func finish(_ url:URL?,_ error:Error?) {
            let result:Result<Loaded,Error>
            do {
                if let error{throw error};guard let url else{throw Failure(message:"Provider returned no URL")}
                let mode=(try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                result = .success(Loaded(bytes:try Data(contentsOf:url),url:url,mode:mode))
            }catch{result = .failure(error)}
            lock.lock();stored=result;lock.unlock()
        }
    }
    final class Scope:RepositoryBookmarkProvider {
        var starts=0,stops=0
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {starts += 1;return true}
        func stopAccessing(_ url:URL){stops += 1}
    }
    @MainActor final class Context {
        let base:URL,root:URL,git:URL,helper:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        let path="nested/source 雪.txt",literal="literal\tline\nname.bin"
        var first="",head="",index=Data(),owners:[NSWindowController]=[]
        init(base:URL,git:URL,helper:URL) {
            self.base=base;root=base.appendingPathComponent("repository");self.git=git;self.helper=helper
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.FileListDrag."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"EnableLogCache")
            prefs.set(false,forKey:"UseLibgit2");prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")
        }
        func prepare()async throws {
            let fm=FileManager.default
            for directory in ["nested","one","two"] {try fm.createDirectory(at:root.appendingPathComponent(directory),withIntermediateDirectories:true)}
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("filter.qa.clean","cat"),("filter.qa.smudge","cat"),("filter.qa.required","true")] {_ = try await repo.run(["config",key,value])}
            try Data("*.txt filter=qa\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
            for (name,bytes) in [(path,Data("source base\n".utf8)),("one/same.txt",Data("one\n".utf8)),("two/same.txt",Data("two\n".utf8)),("gone.txt",Data("gone\n".utf8)),("run.sh",Data("#!/bin/sh\nexit 0\n".utf8)),(literal,Data([0,255,13,10,8]))] {try bytes.write(to:root.appendingPathComponent(name))}
            try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:root.appendingPathComponent("run.sh").path)
            try fm.createSymbolicLink(atPath:root.appendingPathComponent("link").path,withDestinationPath:path)
            _ = try await repo.run(["add","-A","--"]);_ = try await repo.commit(message:"drag base")
            first=try await repo.rebaseCommit("HEAD").hash
            let remote=base.appendingPathComponent("origin.git")
            _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path]);_ = try await repo.run(["remote","add","origin",remote.path]);_ = try await repo.run(["fetch","origin"])
            _ = try await repo.run(["branch","--set-upstream-to=origin/main","main"])
            for (name,bytes) in [(path,Data("source target\n".utf8)),("one/same.txt",Data("one target\n".utf8)),("two/same.txt",Data("two target\n".utf8)),("new.txt",Data("new\n".utf8)),("run.sh",Data("#!/bin/sh\nexit 1\n".utf8)),(literal,Data([0,254,13,10,9]))] {try bytes.write(to:root.appendingPathComponent(name))}
            try fm.removeItem(at:root.appendingPathComponent("gone.txt"));_ = try await repo.run(["add","-A","--"])
            _ = try await repo.run(["update-index","--add","--cacheinfo","160000",first,"module"])
            _ = try await repo.commit(message:"drag target");head=try await repo.rebaseCommit("HEAD").hash
            index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            try Data("source dirty working\n".utf8).write(to:root.appendingPathComponent(path))
        }
        func own<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);return owner}
        func comparison()async throws->RevisionComparisonWindowController {
            let owner=own(RevisionComparisonWindowController(repository:repo,access:RepositoryAccessLease(url:root),from:.revision(first),to:.revision(head),preferences:prefs,savesGeometry:false))
            owner.model.load();try await wait{!owner.model.busy && owner.model.snapshot != nil};return owner
        }
        func clean() {for owner in owners{owner.close()};owners=[];prefs.removePersistentDomain(forName:suite)}
        func preserved()async throws {
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Drag changed index")
            try require(try await repo.rebaseCommit("HEAD").hash==head,"Drag changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(path))==Data("source dirty working\n".utf8),"Drag changed working bytes")
        }
        func plan(_ names:[String],revision:ComparisonRevision?=nil,backend:GitLibGit2Configuration?=nil)async throws->FileListDragPlan {
            let entry=try await repo.rebaseCommit(head)
            let files=try await repo.files(in:entry,backend:.init(enabled:false))
            let chosen=try names.map{name in try unwrap(files.first{Data($0.path.utf8)==Data(name.utf8)},"Missing fixture row: "+name)}
            return try FileListDragPlan(root:root,revision:revision ?? .revision(head),files:chosen,backend:backend ?? .init(enabled:false))
        }
    }
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(message:message)}}
    static func phase(_ name:String){fputs("File drag phase: "+name+"\n",stderr)}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(message:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(message:"File drag timeout at \(line)")}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func drained()->Bool {FileListDrag.activeLoads==0 && RepositoryBrowserExportFiles.activeLoads==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeFileOpenReads==0 && RevisionComparisonWindowModel.activeFileOperations==0 && SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0}
    static func load(_ provider:NSItemProvider)async throws->Loaded {
        let result=LoadResult(),type=try unwrap(provider.registeredTypeIdentifiers.first{$0 != UTType.fileURL.identifier},"Missing content representation")
        _ = provider.loadFileRepresentation(forTypeIdentifier:type){url,error in result.finish(url,error)}
        try await wait{result.value != nil};return try result.value!.get()
    }
    static func promised(_ provider:NSFilePromiseProvider,to url:URL)async throws {
        let delegate=try unwrap(provider.delegate as? FileListFilePromise,"Missing actual file-list promise delegate")
        try require(delegate.filePromiseProvider(provider,fileNameForType:provider.fileType)==delegate.name,"Promise filename mismatch")
        let result=LoadResult()
        let queued=FileListDrag.activeLoads
        delegate.filePromiseProvider(provider,writePromiseTo:url){error in result.finish(error == nil ? url:nil,error)}
        try require(FileListDrag.activeLoads==queued+1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Queued native promise escaped Quit ownership before actor dispatch")
        try await wait{result.value != nil};_ = try result.value!.get()
    }
    static func lists(_ c:Context)async throws {
        phase("Changed Files")
        let compare=try await c.comparison(),model=compare.model
        let receipt=try unwrap(model.captureFileMenu([c.path]),"Comparison receipt"),provider=try unwrap(model.fileDragProvider(receipt),"Comparison provider")
        model.filter="new";try require(model.fileDragProvider(receipt)==nil,"Stale comparison receipt accepted")
        try require(try await load(provider).bytes==Data("source target\n".utf8),"Comparison did not deliver captured target")
        model.filter="";model.busy=true;try require(model.fileDragProvider(model.captureFileMenu([c.path]))==nil,"Busy comparison accepted drag");model.busy=false
        model.confirmingQuit=true;try require(model.fileDragProvider(model.captureFileMenu([c.path]))==nil,"Quit comparison accepted drag");model.confirmingQuit=false
        for path in ["gone.txt","module"] {try require(model.fileDragProvider(model.captureFileMenu([path]))==nil,"Excluded comparison row offered file: "+path)}
        phase("Log history")
        let log=c.own(LogWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),labelDefaults:c.prefs,savesColumnLayout:false,savesGeometry:false))
        try await wait{!log.model.busy && !log.model.entries.isEmpty};log.model.select([c.head]);try await wait{!log.model.busy && log.model.files.contains{$0.path==c.path}}
        let file=try unwrap(log.model.files.first{$0.path==c.path},"Log file"),logReceipt=log.model.fileMenuSnapshot([file.id])
        let logProvider=try unwrap(log.model.fileDragProvider(logReceipt),"Log historical provider")
        log.model.select([c.first]);try await wait{!log.model.busy};try require(log.model.fileDragProvider(logReceipt)==nil,"Log stale selection accepted drag")
        try require(try await load(logProvider).bytes==Data("source target\n".utf8),"Log delivery retargeted selection")
        log.model.select([c.first,c.head]);try await wait{!log.model.busy};try require(log.model.fileDragProvider(log.model.fileMenuSnapshot([file.id]))==nil,"Multi-commit Log invented a drag revision")
        phase("Log working file")
        log.model.select([""]);try await wait{!log.model.busy && log.model.selectedWorkingTree && log.model.files.contains{$0.path==c.path}}
        let workingRow=try unwrap(log.model.files.first{$0.path==c.path},"Log working file")
        let workingProvider=try unwrap(log.model.fileDragProvider(log.model.fileMenuSnapshot([workingRow.id])),"Log working provider")
        try require(try await load(workingProvider).bytes==Data("source dirty working\n".utf8),"Log working drag exported index/historical bytes")
        phase("Rebase embedded revision")
        let replay=RebaseWindowModel(repository:c.repo,access:RepositoryAccessLease(url:c.root),messageDefaults:c.prefs)
        defer{replay.retire()}
        replay.revisionFiles.window=compare.window
        replay.revisionFiles.installEmbeddedSnapshot(try unwrap(model.snapshot,"Rebase child source snapshot"),bare:false)
        let replayReceipt=replay.revisionFiles.captureFileMenu([c.path])
        let replayProvider=try unwrap(replay.revisionFiles.fileDragProvider(replayReceipt),"Rebase revision provider")
        replay.busy=true;try require(replay.revisionFiles.fileDragProvider(replayReceipt)==nil,"Busy Rebase parent accepted late new drag");replay.busy=false
        replay.retire();try require(replay.revisionFiles.fileDragProvider(replayReceipt)==nil,"Retired Rebase accepted new drag")
        try require(try await load(replayProvider).bytes==Data("source target\n".utf8),"Accepted Rebase drag did not survive parent retirement")
        phase("Sync prepare")
        let sync=c.own(SynchronizationWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),preferences:c.prefs));sync.model.sshSettings.enabled=false
        try await wait{!sync.model.busy && sync.model.outgoing != nil && !sync.model.hasPendingInlineWork}
        phase("Sync snapshots")
        let outgoing=try await c.repo.revisionComparison(from:.revision(c.first),to:.revision(c.head))
        phase("Sync incoming snapshot")
        let incoming=try await c.repo.revisionComparison(from:.revision(c.head),to:.revision(c.first))
        for (tab,snapshot,expected) in [(1,outgoing,"source base\n"),(5,incoming,"source target\n")] {
            phase("Sync \(tab)")
            let child=tab==1 ? sync.model.comparison:sync.model.incomingComparison
            child.installEmbeddedSnapshot(snapshot,bare:false)
            sync.model.tab=tab
            let state=sync.model.displayedFileList
            let identifier=NSUserInterfaceItemIdentifier("TurtleGit.Sync.Files."+(tab==1 ? "Out":"In"))
            // SwiftUI dismantles the previous tab asynchronously. Await the
            // actual new table and its source-bound datasource, not any table
            // still present during that transition.
            try await wait {
                views(sync.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.contains {table in
                    guard table.identifier==identifier,let coordinator=table.dataSource as? SynchronizationFiles.Coordinator else{return false}
                    return coordinator.state === state && state.available && table.numberOfRows==state.rows.count
                }
            }
            let table=try unwrap(views(sync.window?.contentView).compactMap{$0 as? SynchronizationFileNativeTable}.first{$0.identifier==identifier},"Sync native file table for tab \(tab)")
            let coordinator=try unwrap(table.dataSource as? SynchronizationFiles.Coordinator,"Sync real table datasource");coordinator.refresh()
            let row=try unwrap(state.rows.firstIndex{$0.path==c.path},"Sync source row")
            let writer=try unwrap(coordinator.tableView(table,pasteboardWriterForRow:row) as? NSFilePromiseProvider,"Sync actual delegate writer")
            let destination=c.base.appendingPathComponent("sync-\(tab).txt");try await promised(writer,to:destination)
            try require(try Data(contentsOf:destination)==Data(expected.utf8),"Sync drag substituted target for base")
            let oldEpoch=state.menuEpoch,current=state.rows[row];state.sort(by:.path,ascending:false)
            try require(state.dragWriter(current,epoch:oldEpoch)==nil,"Sync stale render epoch accepted")
            if tab==1 {
                let newFile=try unwrap(state.rows.first{$0.path=="new.txt"},"Sync new row")
                let absent=try unwrap(state.dragWriter(newFile,epoch:state.menuEpoch) as? NSFilePromiseProvider,"New row missing promised error delivery")
                let failed=c.base.appendingPathComponent("must-not-substitute.txt")
                do{try await promised(absent,to:failed);throw Failure(message:"Missing base file silently substituted target")}catch let error as Failure where error.message=="Missing base file silently substituted target"{throw error}catch{}
                try require(!FileManager.default.fileExists(atPath:failed.path),"Missing base drag wrote destination")
            }
            sync.model.refresh()
            try require(sync.model.busy && state.dragWriter(current,epoch:state.menuEpoch)==nil,"Busy Sync offered drag")
            try await wait{!sync.model.busy && !sync.model.hasPendingInlineWork}
        }
        compare.close();try require(model.fileDragProvider(model.captureFileMenu([c.path]))==nil,"Closed comparison offered drag")
        try await c.preserved()
    }
    static func delivery(_ c:Context)async throws {
        let plan=try await c.plan(["one/same.txt","two/same.txt",c.literal,"run.sh"])
        var providers=try plan.items.indices.map{try unwrap(FileListDrag.provider(repository:c.repo,access:RepositoryAccessLease(url:c.root),plan:plan,itemAt:$0),"Provider missing")}
        try require(providers[0].suggestedName=="same.txt" && providers[1].suggestedName=="same.txt","Leaf names collapsed or renamed")
        let a=try await load(providers[0]),again=try await load(providers[0]),b=try await load(providers[1])
        try require(a.bytes==Data("one target\n".utf8) && b.bytes==Data("two target\n".utf8) && again.bytes==a.bytes && a.url != b.url,"Duplicate leaves/repeated request lost identity")
        try require(try await load(providers[2]).bytes==Data([0,254,13,10,9]),"Literal binary file changed")
        try require(try await load(providers[3]).mode & 0o111 != 0,"Executable delivery lost mode")
        let existing=c.base.appendingPathComponent("existing.txt");try Data("keep\n".utf8).write(to:existing)
        let promise=try FileListFilePromise(repository:c.repo,access:RepositoryAccessLease(url:c.root),plan:plan,itemAt:0)
        do{try await promised(promise.provider(),to:existing);throw Failure(message:"Promise overwrote existing destination")}catch let error as Failure where error.message=="Promise overwrote existing destination"{throw error}catch{}
        try require(try Data(contentsOf:existing)==Data("keep\n".utf8),"Exclusive delivery changed existing destination")
        for (item,name) in [(0,"same.txt"),(1,"same 2.txt")] {let p=try FileListFilePromise(repository:c.repo,access:nil,plan:plan,itemAt:item);try await promised(p.provider(),to:c.base.appendingPathComponent(name))}
        let working=try await c.plan([c.path],revision:.workingTree)
        let writer=try unwrap(FileListDrag.itemWriter(repository:c.repo,access:nil,plan:working,itemAt:0),"Working URL writer")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};try require(board.writeObjects([writer]),"Private working pasteboard write")
        try require(board.string(forType:.fileURL)==c.root.appendingPathComponent(c.path).absoluteString,"Working drag offered temporary/index file")
        providers=[];FileListDrag.discardAll();try require(!FileManager.default.fileExists(atPath:a.url.path),"Released provider exports survived cleanup")
        try require(try FileManager.default.contentsOfDirectory(atPath:c.base.path).allSatisfy{!$0.hasPrefix(".turtlegit-promise-")},"Promise left destination staging")
        try await c.preserved()
    }
    static func ownership(_ c:Context)async throws {
        let filter=c.base.appendingPathComponent("smudge"),hold=c.base.appendingPathComponent("smudge.hold"),ready=c.base.appendingPathComponent("smudge.ready")
        let script="""
        #!/bin/sh
        if [ -f "$0.hold" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
          /bin/mv "$0.ready.tmp" "$0.ready"
          wait "$task_child"
        fi
        exec /usr/bin/sed 's/source/FILTERED/g'
        """
        try script.write(to:filter,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:filter.path)
        _ = try await c.repo.run(["config","filter.qa.smudge","'"+filter.path.replacingOccurrences(of:"'",with:"'\\''")+"'"])
        c.prefs.set(true,forKey:"UseLibgit2");c.prefs.set(0x200,forKey:"UseLibgit2_mask")
        let compare=try await c.comparison();compare.model.captureMaterializationBackend={.load(from:c.prefs,helperURL:c.helper)}
        let scope=Scope();var lease:RepositoryAccessLease?=RepositoryAccessLease(url:c.root,provider:scope)
        let plan=try await c.plan([c.path],backend:.load(from:c.prefs,helperURL:c.helper))
        var accepted:NSItemProvider?=FileListDrag.provider(repository:c.repo,access:lease,plan:plan,itemAt:0);lease=nil
        let fromUI=try unwrap(compare.model.fileDragProvider(compare.model.captureFileMenu([c.path])),"Filtered comparison provider")
        compare.close();c.prefs.set(false,forKey:"UseLibgit2")
        try require(scope.stops==0,"Provider lost originating lease before delivery")
        try require(try await load(accepted!).bytes==Data("FILTERED target\n".utf8),"Accepted provider lost captured backend after owner close")
        try require(try await load(fromUI).bytes==Data("FILTERED target\n".utf8),"UI provider bypassed captured engine")
        accepted=nil;FileListDrag.discardAll();try await wait{scope.stops==1}
        try Data().write(to:hold)
        let cancellationProvider=try unwrap(FileListDrag.provider(repository:c.repo,access:nil,plan:plan,itemAt:0),"Cancellation provider"),result=LoadResult()
        let progress=cancellationProvider.loadFileRepresentation(forTypeIdentifier:cancellationProvider.registeredTypeIdentifiers[0]){url,error in result.finish(url,error)}
        defer{progress.cancel()}
        try await wait{FileManager.default.fileExists(atPath:ready.path) && FileListDrag.activeLoads>0}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Actual drag read lost Quit ownership")
        progress.cancel();try await wait{result.value != nil && FileListDrag.activeLoads==0 && pids.allSatisfy{kill($0,0) != 0}}
        if case .success?=result.value{throw Failure(message:"Canceled provider delivered content")}
        try FileManager.default.removeItem(at:hold);try FileManager.default.removeItem(at:ready)
        let token=OperationCancellation();token.cancel();let dest=c.base.appendingPathComponent("canceled.txt")
        do{try await FileListFilePromise(repository:c.repo,access:nil,plan:plan,itemAt:0).write(to:dest,cancellation:token);throw Failure(message:"Canceled promise succeeded")}catch let error as Failure where error.message=="Canceled promise succeeded"{throw error}catch{}
        try require(!FileManager.default.fileExists(atPath:dest.path),"Canceled promise published destination")
        // The shared exclusive writer also serves the existing Browser promise.
        let listing=try await c.repo.browseRepository(revision:c.head,directory:"nested"),entry=try unwrap(listing.entries.first{$0.path==c.path},"Browser regression entry")
        let browser=RepositoryBrowserFilePromise(repository:c.repo,access:nil,snapshot:listing,entry:entry,backend:.init(enabled:false))
        let browserDestination=c.base.appendingPathComponent("browser.txt");try await browser.write(to:browserDestination)
        try require(try Data(contentsOf:browserDestination)==Data("source target\n".utf8),"Shared writer broke Browser delivery")
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let normal=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.fileListDragHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(normal,hidden);defer{method_exchangeImplementations(normal,hidden)}
        let c=Context(base:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]),helper:URL(fileURLWithPath:CommandLine.arguments[3])),which=CommandLine.arguments[4]
        DialogGeometry.install(preferences:c.prefs)
        defer{DialogGeometry.install(preferences:.standard);c.clean();FileListDrag.discardAll();RepositoryBrowserExportFiles.discardAll()}
        do {
            phase("Fixture");try await c.prepare();phase("Prepared "+which)
            switch which {case "lists":try await lists(c);case "delivery":try await delivery(c);case "ownership":try await ownership(c);default:throw Failure(message:"Unknown file-drag case")}
            c.clean();try await wait{drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
            FileListDrag.discardAll();RepositoryBrowserExportFiles.discardAll()
            print("PASS: file-list drag \(which)")
        }catch {
            c.clean();NSApp.windows.forEach{window in if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};window.close()}
            try? await wait{drained()};throw error
        }
    }
}
