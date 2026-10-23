// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import UniformTypeIdentifiers
import TurtleGitCore

private extension NSWindow {
    @objc func rebaseDragFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func rebaseDragOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));rebaseDragOrder(mode,relativeTo:number)}
}
@MainActor @main enum RebaseFileDragsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Rebase drag \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase drag timeout \(line)")}
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
        func finish(_ bytes:Data?,_ error:Error?){lock.lock();defer{lock.unlock()};if let error{stored = .failure(error)}else if let bytes{stored = .success(bytes)}else{stored = .failure(Failure(description:"Missing provider bytes"))}}
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.RebaseDrag."+UUID().uuidString,prefs:UserDefaults,scope=Scope()
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!
        let literal="literal\tline\n雪.txt"
        var owners:[RebaseWindowController]=[]
        var changed:[String]{["a.txt",literal,"z.txt"]}
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["UseLibgit2","EnableLogCache","EnableGravatar","Autocompletion","ConfirmKillProcess"]{prefs.set(false,forKey:key)}}
        func write(_ name:String,_ text:String)throws{try Data(text.utf8).write(to:root.appendingPathComponent(name))}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Rebase drag QA"),("user.email","drag@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for name in changed+["missing.txt","deleted.txt","directory.txt"]{try write(name,"base\n")}
            try await repo.stage(["."]);_=try await repo.commit(message:"base")
            let moduleBase=try await repo.rebaseCommit("HEAD").hash
            try FileManager.default.createDirectory(at:root.appendingPathComponent("module"),withIntermediateDirectories:true)
            _=try await repo.run(["update-index","--add","--cacheinfo","160000",moduleBase,"module"])
            _=try await repo.commit(message:"base gitlink")
            _=try await repo.run(["switch","-c","upstream"])
            for name in changed{try write(name,"upstream\n")};try await repo.stage(["."]);_=try await repo.commit(message:"upstream")
            _=try await repo.run(["switch","-c","topic","main"])
            for name in changed{try write(name,"topic \(name)\n")};try await repo.stage(["."]);_=try await repo.commit(message:"topic")
            try write("a.txt","HEAD-only bytes\n");try await repo.stage(["a.txt"]);_=try await repo.commit(message:"later")
        }
        func open()async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repo,access:RepositoryAccessLease(url:root,provider:scope),preferences:prefs)
            owners.append(owner);owner.showWindow(nil);owner.window?.orderFront(nil);owner.model.load(upstream:"refs/heads/upstream")
            try await wait(owner.window){!owner.model.busy && !owner.model.loadingPlan && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
            return owner
        }
        func cleanup()async{for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[];for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};FileListDrag.discardAll();prefs.removePersistentDomain(forName:suite)}
    }
    static func drained()->Bool{FileListDrag.activeLoads==0 && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
    static func sheetFence<T>(_ owner:RebaseWindowController,capture:()->T?)async throws {
        let window=try unwrap(owner.window,"Missing Rebase window"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;defer{if sheet.sheetParent != nil{window.endSheet(sheet,returnCode:.abort)};sheet.close()}
        window.beginSheet(sheet,completionHandler:{_ in});try await wait{window.attachedSheet === sheet}
        try require(capture()==nil,"Attached sheet permitted a new outbound drag")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
    }
    static func text(_ value:String,paths:[String])throws{try require(Data(value.utf8)==Data((paths.joined(separator:"\r\n")+"\r\n").utf8),"Drag text changed literal paths/order")}
    static func historical(_ c:Context)async throws {
        let owner=try await c.open(),model=owner.model
        model.tab=0
        let topic=try unwrap(model.entries.first{$0.commit.subject=="topic"},"Historical replay occurrence missing")
        model.selection=[topic.id];model.selectCommit()
        try await wait(owner.window){model.revisionFiles.snapshot != nil && model.revisionMenuOwnerAvailable && model.revisionFiles.visibleFiles.count==c.changed.count}
        let selected=try unwrap(model.entries.first{$0.id==model.selection.first},"Selected replay occurrence missing")
        let expectedRevision=selected.commit.hash
        var probe:FileListDragInteraction.Probe?
        try await wait(owner.window){probe=views(owner.window?.contentView).compactMap{$0 as? FileListDragInteraction.Probe}.first;return probe?.nativeTable != nil}
        let adapter=try unwrap(probe,"Missing embedded historical adapter"),table=try unwrap(adapter.nativeTable,"Missing embedded native table")
        model.revisionFiles.sortOrder=[KeyPathComparator(\CommitFile.sortPath,order:.reverse)]
        try await wait(owner.window){adapter.rows.map(\.id)==model.revisionFiles.visibleFiles.map(\.path)}
        let paths=model.revisionFiles.visibleFiles.map(\.path)
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<paths.count))
        try await wait(owner.window){model.revisionFiles.selection.count==paths.count && model.revisionFiles.fileDragGeneration != nil}
        let drag=try unwrap(adapter.captureSelection(),"Embedded selected historical drag refused")
        try require(drag.paths==paths && drag.providers.count==paths.count && drag.fileURLs.isEmpty,"Embedded drag omitted selected historical rows or substituted working URLs")
        try text(drag.text,paths:paths)
        guard case .revision(let hash)=drag.revision else{throw Failure(description:"Historical drag used noncommit revision")}
        try require(hash==expectedRevision,"Historical drag used HEAD instead of selected replay commit")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};try require(drag.write(to:board) && board.string(forType:.string)==drag.text,"Historical private pasteboard lost aggregate text")
        model.busy=true;try require(adapter.captureSelection()==nil,"Busy replay exported new historical drag");model.busy=false
        model.revisionMenuLog.confirmingQuit=true;try require(adapter.captureSelection()==nil,"Quit replay exported new historical drag");model.revisionMenuLog.confirmingQuit=false
        model.fileRecovery=true;try require(model.revisionFiles.captureFileDrag(paths)==nil,"Historical snapshot remained exportable after recovery transition");model.fileRecovery=false
        try await sheetFence(owner){adapter.captureSelection()}
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        owner.close();c.owners.removeAll{$0 === owner}
        try await wait{model.retired && drained()}
        try require(adapter.captureSelection()==nil && model.revisionFiles.captureFileDrag(paths)==nil,"Closed replay exported new historical drag")
        // Ask only after owner close. Capture bytes inside the provider callback,
        // while AppKit's temporary receiver URL remains valid.
        for (provider,path) in zip(drag.providers,paths) {
            let reply=Reply(),type=try unwrap(provider.registeredTypeIdentifiers.first,"Historical promise had no registered representation")
            provider.loadFileRepresentation(forTypeIdentifier:type){url,error in
                if let url{do{reply.finish(try Data(contentsOf:url),nil)}catch{reply.finish(nil,error)}}else{reply.finish(nil,error)}
            }
            try await wait{reply.value != nil};let bytes=try reply.value!.get()
            try require(bytes==Data("topic \(path)\n".utf8),"Historical promise returned working/other-commit bytes")
        }
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Historical drag changed replay repository")
        try require(c.scope.starts>0 && c.scope.stops==0,"Accepted historical providers lost captured permission after close")
    }
    static func conflicts(_ c:Context)async throws {
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let plan=try await c.repo.rebasePlan(options)
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _=try await c.repo.startRebase(plan,editorExecutable:editor)
        // Actual paused replay plus missing/deleted/directory working records.
        try FileManager.default.removeItem(at:c.root.appendingPathComponent("missing.txt"))
        _=try await c.repo.run(["rm","--","deleted.txt"])
        try FileManager.default.removeItem(at:c.root.appendingPathComponent("directory.txt"))
        try FileManager.default.createDirectory(at:c.root.appendingPathComponent("directory.txt"),withIntermediateDirectories:true)
        let moduleChanged=try await c.repo.rebaseCommit("topic").hash
        _=try await c.repo.run(["update-index","--cacheinfo","160000",moduleChanged,"module"])
        let owner=try await c.open(),model=owner.model;model.tab=0
        try await wait(owner.window){model.fileRecovery && model.revisionMenuOwnerAvailable && model.conflictRows.count>=7}
        var probe:CommitFileInteraction.Probe?
        try await wait(owner.window){probe=views(owner.window?.contentView).compactMap{$0 as? CommitFileInteraction.Probe}.first{$0.captureWorkingDrag != nil && $0.nativeTable != nil};return probe != nil}
        let adapter=try unwrap(probe,"Missing paused conflict outbound adapter"),table=try unwrap(adapter.nativeTable,"Missing paused conflict native table")
        model.setConflictSort([RebaseConflictSort(column:.path,order:.reverse)])
        try await wait(owner.window){adapter.rows.compactMap{$0.entry?.path}==model.conflictTableRows.map(\.entry.path)}
        let paths=model.conflictTableRows.map(\.entry.path)
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<paths.count))
        try await wait(owner.window){model.selectedConflicts.count==paths.count}
        model.checkedConflicts=[];let checked=model.checkedConflicts
        let drag=try unwrap(adapter.workingDragSelection(),"Paused selected working drag refused")
        try require(drag.paths==paths,"Paused drag lost highlighted native row order")
        try text(drag.text,paths:paths)
        try require(model.checkedConflicts==checked && checked.isEmpty,"Drag used or changed replay commit checkboxes")
        let expectedURLs=paths.filter{c.changed.contains($0)}.map{c.root.appendingPathComponent($0)}
        try require(drag.fileURLs==expectedURLs,"Paused drag exported missing/deleted/directory paths or used temporary files")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};try require(drag.write(to:board) && board.string(forType:.string)==drag.text,"Working drag lost complete selected text")
        let index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),head=try await c.repo.run(["rev-parse","HEAD"]).stdout
        let before=try Dictionary(uniqueKeysWithValues:expectedURLs.map{($0,try Data(contentsOf:$0))})
        model.busy=true;try require(adapter.workingDragSelection()==nil,"Busy paused replay exported files");model.busy=false
        model.revisionMenuLog.confirmingQuit=true;try require(adapter.workingDragSelection()==nil,"Quit paused replay exported files");model.revisionMenuLog.confirmingQuit=false
        model.fileRecovery=false;try require(model.captureWorkingDrag(paths)==nil,"Nonrecovery replay exported paused files");model.fileRecovery=true
        try await sheetFence(owner){adapter.workingDragSelection()}
        owner.close();c.owners.removeAll{$0 === owner};try await wait{model.retired && drained()}
        try require(adapter.workingDragSelection()==nil && model.captureWorkingDrag(paths)==nil && owner.window?.attachedSheet==nil && owner.window?.isVisible != true,"Retired paused owner accepted a new drag or remained visible")
        for provider in drag.providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let reply=Reply();provider.loadDataRepresentation(forTypeIdentifier:UTType.fileURL.identifier){reply.finish($0,$1)}
            try await wait{reply.value != nil};let bytes=try reply.value!.get(),url=try unwrap(URL(string:String(decoding:bytes,as:UTF8.self)),"Invalid working URL")
            try require(before[url] != nil && (try Data(contentsOf:url))==before[url],"Accepted paused provider changed captured working bytes after close")
        }
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Outbound drag mutated paused replay/index")
        try require(c.scope.starts>0 && c.scope.stops==0,"Accepted paused providers lost captured permission after close")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let methods=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.rebaseDragFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.rebaseDragOrder(_:relativeTo:))))]
        for(a,b)in methods{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in methods.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "historical":try await historical(c);case "conflicts":try await conflicts(c);default:throw Failure(description:"Unknown Rebase drag case")};await c.cleanup();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Rebase windows/work survived cleanup");print("PASS: rebase file drags "+kind);fflush(stdout)}catch{await c.cleanup();fputs("Rebase file drags failed: \(error)\n",stderr);exit(1)}
    }
}
