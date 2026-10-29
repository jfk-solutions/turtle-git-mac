// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private extension NSWindow {
    @objc func quietStreamFilesOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));quietStreamFilesOrder(mode,relativeTo:number)
    }
    @objc func quietStreamFilesSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));quietStreamFilesSheet(sheet,completionHandler:completionHandler)
    }
}
/// Next-batch executable specification (not yet run): the accepted historical
/// revision and changed-file projection remain inspectable during the independent
/// history stream. Actual native row selection precedes the same captured menu
/// guard used by the production menu. Model actions must deliver exact real Git
/// revision/path/parent records; no pointer gesture or callback availability is
/// treated as evidence that a command executed. Mutating menu admission stays
/// closed. Revision navigation, reload, Quit and retirement revoke old receipts.
@MainActor @main struct LogStreamedFileNavigationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ message:String,line:Int = #line,_ predicate:()->Bool)async throws {
        for _ in 0..<2000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): "+message)
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func drained()->Bool {LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileOpenReads==0 && LogWindowModel.activeFileNavigationActivities==0 && LogWindowModel.activeHistoryProjectionWorkers==0 && LogMessageView.Coordinator.activeOperations==0 && LogDocumentOpenSession.activeRequests==0 && ExternalDocumentApplication.activeRequests==0 && FileListComparisonSession.activeOperations==0 && FileListDrag.activeLoads==0}
    private final class PromiseReply:@unchecked Sendable {
        private let lock=NSLock();private var stored:Result<Void,Error>?
        var value:Result<Void,Error>?{lock.lock();defer{lock.unlock()};return stored}
        func finish(_ error:Error?){lock.lock();defer{lock.unlock()};stored=error.map{.failure($0)} ?? .success(())}
    }
    @MainActor final class Context {
        let root:URL,git:URL,repository:GitRepository,preferences:UserDefaults,suite:String,board:NSPasteboard
        let old="old 雪\t[*].txt",renamed="renamed 雪\t[*].txt",other="peer.txt"
        var latest="",previous="",childHash="",head=Data(),index=Data(),childIndex=Data(),working:[String:Data]=[:],owners:[LogWindowController]=[]
        var rootOwners:[RepositoryModel]=[],comparisons:[FileComparisonWindowController]=[],previews:[URL]=[]
        var releases:[()->Void]=[]
        var fifo:URL{root.appendingPathComponent("history.fifo")}
        var first:URL{root.appendingPathComponent("history.first")}
        var released:URL{root.appendingPathComponent("history.released")}
        var moduleArm:URL{root.appendingPathComponent("module.arm")}
        var moduleWaiting:URL{root.appendingPathComponent("held-helper.module-waiting")}
        var moduleFIFO:URL{root.appendingPathComponent("module.fifo")}
        func waiting(_ number:Int)->URL{root.appendingPathComponent("held-helper.waiting-\(number)")}
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.LogStreamFiles."+UUID().uuidString;preferences=try unwrap(UserDefaults(suiteName:suite),"No private preferences");board=NSPasteboard.withUniqueName()
            for key in ["UseLibgit2","EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges"]{preferences.set(false,forKey:key)}
            preferences.set(true,forKey:"ShowAppContextMenuIcons")
        }
        func setup()async throws {
            _=try await repository.run(["init","--template=","-b","main"])
            for(key,value)in [("user.name","Stream File QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
            // Reuse the established 128-row real history/notes boundary. Only
            // two recent commits contain files, avoiding a large working fixture.
            let tree=try await repository.run(["mktree"],input:Data()).text.trimmingCharacters(in:.newlines)
            var parent:String?
            for number in 0..<130 {
                var args=["commit-tree",tree];if let parent{args += ["-p",parent]}
                parent=try await repository.run(args,input:Data("Older stream \(number)\n".utf8)).text.trimmingCharacters(in:.newlines)
            }
            _=try await repository.run(["update-ref","refs/heads/main",try unwrap(parent,"Missing source history")])
            let original=Data((0..<80).map{"original distinctive \($0)\n"}.joined().utf8)
            let module=root.appendingPathComponent("module",isDirectory:true);try FileManager.default.createDirectory(at:module,withIntermediateDirectories:true)
            let child=GitRepository(root:module,executable:git,libgit2Configuration:.init(enabled:false));_=try await child.run(["init","--template=","-b","main"])
            for(key,value)in [("user.name","Stream Child QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await child.run(["config",key,value])}
            try Data("child previous\n".utf8).write(to:module.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"previous child")
            let firstChild=try await child.rebaseCommit("HEAD").hash
            try original.write(to:root.appendingPathComponent(old));try Data("peer base\n".utf8).write(to:root.appendingPathComponent(other));try await repository.stage([old,other]);_=try await repository.run(["update-index","--add","--cacheinfo","160000,"+firstChild+",module"]);_=try await repository.commit(message:"Previous file source")
            previous=try await repository.rebaseCommit("HEAD").hash
            try Data("child selected\n".utf8).write(to:module.appendingPathComponent("child.txt"));try await child.stage(["child.txt"]);_=try await child.commit(message:"selected child");childHash=try await child.rebaseCommit("HEAD").hash
            _=try await repository.run(["mv","--",old,renamed]);try (original+Data("renamed extension\n".utf8)).write(to:root.appendingPathComponent(renamed));try Data("peer revised\n".utf8).write(to:root.appendingPathComponent(other));try await repository.stage([renamed,other]);_=try await repository.run(["update-index","--cacheinfo","160000,"+childHash+",module"]);_=try await repository.commit(message:"Latest renamed files\n\nStream navigation details")
            latest=try await repository.rebaseCommit("HEAD").hash
            _=try await repository.run(["notes","add","-m","Force notes batch boundary",try unwrap(parent,"No notes ancestor")])
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            childIndex=try Data(contentsOf:module.appendingPathComponent(".git/index"))
            for path in [renamed,other,"module/child.txt"]{working[path]=try Data(contentsOf:root.appendingPathComponent(path))}
            try authorHeldGit()
        }
        func authorHeldGit()throws {
            try require(mkfifo(fifo.path,mode_t(0o600))==0,"Private notes FIFO unavailable")
            try require(mkfifo(moduleFIFO.path,mode_t(0o600))==0,"Private submodule FIFO unavailable")
            func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="""
            #!/bin/sh
            task_notes=false
            task_child=false
            task_discovery=false
            if [ "$PWD" = \(quote(root.appendingPathComponent("module").path)) ] || [ "$PWD" = \(quote(root.appendingPathComponent("module").resolvingSymlinksInPath().path)) ]; then task_child=true; fi
            for task_arg in "$@"; do
              if [ "$task_arg" = --log-size ]; then task_notes=true; fi
              if [ "$task_arg" = --show-toplevel ]; then task_discovery=true; fi
              if [ "$task_arg" = \(quote(root.appendingPathComponent("module").path)) ] || [ "$task_arg" = \(quote(root.appendingPathComponent("module").resolvingSymlinksInPath().path)) ]; then task_child=true; fi
            done
            if [ "$task_child" = true ] && [ "$task_discovery" = true ] && [ -f \(quote(moduleArm.path)) ]; then
              printf '%s\\n' "$$" > \(quote(moduleWaiting.path))
              IFS= read -r task_child_release < \(quote(moduleFIFO.path))
            fi
            if [ "$task_notes" = true ] && [ ! -f \(quote(released.path)) ]; then
              task_count=0
              if [ -f \(quote(first.path)) ]; then IFS= read -r task_count < \(quote(first.path)); fi
              task_count=$((task_count + 1))
              printf '%s\\n' "$task_count" > \(quote(first.path))
              if [ "$task_count" -gt 1 ]; then
                printf '%s\\n' "$$" > "$0.waiting-$task_count"
                IFS= read -r task_release < \(quote(fifo.path))
              fi
            fi
            exec \(quote(git.path)) "$@"
            """
            let wrapper=root.appendingPathComponent("held-helper");try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        }
        func open()throws->LogWindowController {
            let slow=GitRepository(root:root,executable:root.appendingPathComponent("held-helper"),libgit2Configuration:.init(enabled:false))
            let owner=LogWindowController(repository:slow,access:RepositoryAccessLease(url:root),labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owner.model.clipboard=board;owners.append(owner);owner.showWindow(nil);owner.model.reload();return owner
        }
        func clean()async {
            releases.forEach{$0()};releases=[]
            for owner in owners{if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};owner.close();owner.model.invalidate()}
            comparisons.forEach{$0.close()};rootOwners.forEach{
                $0.stopMonitoringForTermination();$0.logWindowFactory=nil;$0.logWindowPresentation=nil;$0.fileComparisonWindowPresentation=nil
            }
            for _ in 0..<2000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.configureDocumentOpen={_ in};$0.chooseFileDestination=nil}
            previews.forEach{HistoricalPreviewFiles.discard($0)};preferences.removePersistentDomain(forName:suite);board.releaseGlobally()
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Read-only Log file navigation changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Read-only Log file navigation changed actual index")
            for(path,bytes)in working{try require(try Data(contentsOf:root.appendingPathComponent(path))==bytes,"Read-only Log file navigation changed working bytes")}
            try require(try Data(contentsOf:root.appendingPathComponent("module/.git/index"))==childIndex,"Read-only submodule navigation changed child index")
        }
    }
    static func history(_ owner:LogWindowController)throws->HistoryTableView {try unwrap(views(owner.window?.contentView).compactMap{$0 as? HistoryTableView}.first,"Actual native history table absent")}
    static func revision(_ hash:String,owner:LogWindowController)async throws {
        let model=owner.model,table=try history(owner)
        try await wait("Rendered revision prefix did not match native rows"){owner.window?.contentView?.layoutSubtreeIfNeeded();return table.numberOfRows==model.entries.count && (table.delegate as? RevisionTable.Coordinator)?.revisionInputAvailable==true}
        let index=try unwrap(model.entries.firstIndex{$0.hash==hash},"Requested real source hash not in prefix")
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
        try await wait("Selected revision details/files did not load"){model.selected==[hash] && model.revision?.hash==hash && model.files.count==3 && LogWindowModel.activeActionReads==0 && model.canInspectHistory}
    }
    static func select(_ paths:[String],owner:LogWindowController)async throws->[CommitFile] {
        let model=owner.model,wanted=GitPathSet(paths)
        try await wait("Actual changed-file probe did not render selected revision"){views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.contains{$0.nativeTable != nil && $0.rows.map(\.rawID)==model.fileTableRows.map(\.rawID)}}
        // A SwiftUI row-count update precedes completion of its native binding
        // installation. Observe a stable rendered projection across two layout
        // turns before the deterministic native keyboard sequence.
        struct Rendered:Equatable {let table:ObjectIdentifier;let ids:[String];let captions:[String]}
        func rendered()->Rendered? {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            guard let current=views(owner.window?.contentView).compactMap({$0 as? LogFileDragInteraction.Probe}).first(where:{$0.nativeTable != nil && $0.rows.map(\.rawID)==model.fileTableRows.map(\.rawID)}),let table=current.nativeTable,table.numberOfRows==current.rows.count else{return nil}
            guard (0..<table.numberOfRows).allSatisfy({row in
                table.rowView(atRow:row,makeIfNecessary:false) != nil && table.view(atColumn:0,row:row,makeIfNecessary:false)?.window === owner.window
            }) else{return nil}
            let captions=(0..<table.numberOfRows).map { row -> String in
                if let label=NativeListSelection.labelDrawing(in:table,row:row){return label.cell.stringValue}
                return views(table.rowView(atRow:row,makeIfNecessary:false)).compactMap{($0 as? NSTextField)?.stringValue}.joined(separator:"\u{1f}")
            }
            return Rendered(table:ObjectIdentifier(table),ids:current.rows.map(\.rawID),captions:captions)
        }
        var last=rendered(),stableTurns=0
        for _ in 0..<1000 {
            try await Task.sleep(nanoseconds:20_000_000)
            let current=rendered()
            stableTurns = current != nil && current==last ? stableTurns+1:0
            last=current
            if stableTurns>=2 {break}
        }
        try require(stableTurns>=2,"Changed-file native projection did not settle before selection")
        let probe=try unwrap(views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.first{$0.nativeTable != nil && $0.rows.map(\.rawID)==model.fileTableRows.map(\.rawID)},"No current native file probe")
        let rows=model.fileTableRows,indexes=IndexSet(rows.indices.filter{rows[$0].file.map{wanted.contains($0.path)}==true}),files=indexes.compactMap{rows[$0].file}
        try require(files.count==paths.count,"Actual native changed-file rows omitted requested source")
        let table=try unwrap(probe.nativeTable,"Detached native file table")
        func delegateDiagnostic()->String {
            guard let original=NativeListSelection.originalDelegate(of:table) else{return "original=nil"}
            let selectors=["selectionShouldChangeInTableView:","tableView:shouldSelectRow:","tableViewSelectionDidChange:","outlineViewSelectionDidChange:","outlineView:shouldSelectItem:","outlineView:selectionIndexesForProposedSelection:"]
            let responses=selectors.map{($0,original.responds(to:NSSelectorFromString($0)))}
            let proxy=table.delegate
            let proxyResponses=selectors.map{($0,proxy?.responds(to:NSSelectorFromString($0))==true)}
            return "original=\(ObjectIdentifier(original)) class=\(type(of:original)) outlineDelegate=\(original is NSOutlineViewDelegate) responses=\(responses) proxyOutlineDelegate=\(proxy.map{$0 is NSOutlineViewDelegate} ?? false) proxyResponses=\(proxyResponses) tableType=\(type(of:table)) action=\(String(describing:table.action)) target=\(String(describing:table.target))"
        }
        let beforeDelegate=delegateDiagnostic()
        let window=try unwrap(table.window,"Native file keyboard target has no owner window")
        try require(window.makeFirstResponder(table) && window.firstResponder === table,"Native file table refused first responder")
        let first=try unwrap(indexes.first,"No native file rows requested"),lastIndex=try unwrap(indexes.last,"No last native file row")
        try require(indexes==IndexSet(integersIn:first...lastIndex),"Fixture native keyboard group must be contiguous")
        table.deselectAll(nil)
        try await Task.sleep(nanoseconds:20_000_000)
        try require(table.selectedRowIndexes.isEmpty,"Native file deselection did not clear highlight")
        for row in 0...lastIndex {
            let extending=row>first
            let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:extending ? [.shift]:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\u{f701}",charactersIgnoringModifiers:"\u{f701}",isARepeat:false,keyCode:125),"Cannot create owned native Down event")
            table.keyDown(with:event)
            try await Task.sleep(nanoseconds:20_000_000)
            let expected=extending ? IndexSet(integersIn:first...row):IndexSet(integer:row)
            try require(table.selectedRowIndexes==expected,"Native Down sequence refused expected file row transition \(row); actual \(Array(table.selectedRowIndexes))")
        }
        let immediate="requested=\(Array(indexes)) selected=\(Array(table.selectedRowIndexes)) modelNative=\(model.nativeFileSelection) modelSelected=\(Array(model.selectedFiles)) rows=\(table.numberOfRows) enabled=\(table.isEnabled) visible=\(table.window?.isVisible == true) key=\(table.window?.isKeyWindow == true) allowsEmpty=\(table.allowsEmptySelection) allowsMultiple=\(table.allowsMultipleSelection) \(delegateDiagnostic())"
        do {try await wait("Native changed-file highlight did not update model"){model.selectedFiles==GitPathSet(files.map(\.id))}}
        catch {
            let probes=views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}
            print("FILE BEFORE \(beforeDelegate)")
            print("FILE IMMEDIATE \(immediate)")
            print("FILE AFTER \(delegateDiagnostic())")
            print("FILE SELECTION FAILURE requested=\(paths) indexes=\(indexes) table=\(ObjectIdentifier(table)) window=\(table.window === owner.window) delegate=\(String(describing:table.delegate)) nativeIndexes=\(table.selectedRowIndexes) modelNative=\(model.nativeFileSelection) modelSelected=\(Array(model.selectedFiles)) inspect=\(model.canInspectHistory) busy=\(model.busy) loading=\(model.loadingHistory) pending=\(model.fileNavigationReadPending) activities=\(LogWindowModel.activeFileNavigationActivities) error=\(model.error ?? "none")")
            print("FILE PROJECTIONS model=\(model.fileTableRows.map(\.rawID)) captured=\(probe.rows.map(\.rawID))")
            for item in probes {
                let current=item.nativeTable
                print("FILE PROBE table=\(String(describing:current.map{ObjectIdentifier($0)})) indexes=\(String(describing:current?.selectedRowIndexes)) rows=\(item.rows.map(\.rawID))")
            }
            // Historical direct-setter controls remain in the failed-attempt
            // receipts. This keyboard verification does not retry selection.
            throw error
        }
        if table is NSOutlineView {
            let original=try unwrap(NativeListSelection.originalDelegate(of:table),"Outline table lost original native selection delegate")
            try require(table.delegate === original,"Outline table selection still replaces SwiftUI's NSOutlineView delegate")
            try require(NativeListSelection.usesFullRowSelection(in:table) != nil,"Outline table lost owned native selection decoration")
        }
        model.focusedChangedFile=files.first?.id
        return files
    }
    static func menu(_ owner:LogWindowController,ids:GitPathSet,_ action:()->Void) {
        // This is the actual captured menu admission used by SwiftUI actions,
        // after real native row selection. It does not claim pointer dispatch.
        owner.model.withFileMenu(owner.model.fileMenuSnapshot(ids),inspection:true,action:action)
    }
    static func documentSettled(_ owner:LogWindowController)async throws {
        try await wait("Historical document/panel activity did not settle"){owner.documentOpen==nil && owner.filePanels.currentPanel==nil && owner.window?.attachedSheet==nil && !owner.model.fileNavigationReadPending && LogDocumentOpenSession.activeRequests==0 && owner.model.canInspectHistory}
        try require(owner.model.loadingHistory && owner.model.busy,"Historical document completion cleared the independent history walk")
        try require(owner.model.error==nil,"Historical document activity error: "+(owner.model.error ?? "none"))
    }
    static func documents(_ c:Context,owner:LogWindowController)async throws {
        let model=owner.model,delivery=c.root.deletingLastPathComponent().appendingPathComponent("historical-delivery",isDirectory:true)
        try FileManager.default.createDirectory(at:delivery,withIntermediateDirectories:true)
        let selected=try await select([c.renamed],owner:owner),ids=GitPathSet(selected.map(\.id)),bytes=try unwrap(c.working[c.renamed],"No historical expected bytes")
        let saved=delivery.appendingPathComponent("saved.txt"),exported=delivery.appendingPathComponent("exported",isDirectory:true)
        try FileManager.default.createDirectory(at:exported,withIntermediateDirectories:true)
        var choices=0
        owner.chooseFileDestination={panel in choices += 1;return panel is NSOpenPanel ? exported:saved}
        menu(owner,ids:ids){model.saveHistoricalFile(ids)}
        try await wait("Historical Save never reached captured chooser"){choices==1}
        try await documentSettled(owner)
        try require(try Data(contentsOf:saved)==bytes,"Save revision did not deliver exact selected historical bytes")
        let pair=try await select([c.renamed,c.other],owner:owner),pairIDs=GitPathSet(pair.map(\.id))
        menu(owner,ids:pairIDs){model.chooseHistoricalExport(pairIDs)}
        try await wait("Historical Export never reached captured chooser"){choices==2}
        try await documentSettled(owner)
        for file in pair{try require(try Data(contentsOf:exported.appendingPathComponent(file.path))==c.working[file.path],"Export changed selected historical bytes/path")}
        let app=delivery.appendingPathComponent("Reader.app",isDirectory:true);try FileManager.default.createDirectory(at:app,withIntermediateDirectories:true)
        AlternativeEditorPreferences(custom:true,applicationPath:app.path).save(to:c.preferences)
        var launches=0
        owner.configureDocumentOpen={operation in
            operation.defaultApplication={_ in app};operation.chooseApplication={_ in app}
            operation.launch={application,documents,configuration in
                try require(application.standardizedFileURL.path.utf8.elementsEqual(app.standardizedFileURL.path.utf8) && documents.count==1 && configuration.arguments.isEmpty && !configuration.createsNewApplicationInstance,"Historical Open/editor changed native document request")
                try require(try Data(contentsOf:documents[0])==bytes,"Historical Open/editor changed selected source bytes")
                let mode=try FileManager.default.attributesOfItem(atPath:documents[0].path)[.posixPermissions] as? NSNumber
                try require(mode.map{$0.intValue & 0o222==0}==true,"Historical preview lost readonly permissions")
                c.previews += documents;launches += 1
            }
        }
        _=try await select([c.renamed],owner:owner)
        for action in [HistoricalOpenAction.open,.openWith,.alternativeEditor] {
            let expected=launches+1;menu(owner,ids:ids){model.openHistoricalFile(ids,action:action)}
            try await wait("Historical Open/editor did not reach launch adapter"){launches==expected}
            try await documentSettled(owner)
        }
        var answer:CheckedContinuation<URL?,Never>?,staleLaunches=0
        c.releases.append{answer?.resume(returning:nil);answer=nil}
        owner.configureDocumentOpen={operation in operation.chooseApplication={_ in await withCheckedContinuation{answer=$0}};operation.launch={_,_,_ in staleLaunches += 1}}
        menu(owner,ids:ids){model.openHistoricalFile(ids,action:.openWith)}
        try await wait("Owned Open With chooser did not hold"){answer != nil && model.fileNavigationReadPending}
        _=try await select([c.other],owner:owner)
        try require(LogDocumentOpenSession.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Changed selection abandoned owned document chooser before actual return")
        answer?.resume(returning:app);answer=nil;try await documentSettled(owner)
        try require(staleLaunches==0,"Stale historical Open With launched after native selection changed")
        owner.chooseFileDestination=nil
        _=try await select([c.renamed],owner:owner);menu(owner,ids:ids){model.saveHistoricalFile(ids)}
        try await wait("Actual historical Save sheet did not attach"){owner.filePanels.currentPanel?.sheetParent === owner.window}
        let panel=try unwrap(owner.filePanels.currentPanel,"No actual historical Save panel")
        try require(panel.alphaValue==0 && model.fileNavigationReadPending && !model.canInspectHistory,"Historical Save sheet lost invisible owned activity")
        try require(model.cancelFileNavigationRead(),"Historical Save Cancel did not reach the owned panel delivery")
        owner.filePanels.receive(panel,response:.OK) // a retired chooser reply cannot revive delivery
        try await documentSettled(owner)
        let peer=try await select([c.other],owner:owner),peerIDs=GitPathSet(peer.map(\.id))
        for information in [LogWindowModel.CopyFileInformation.relativePaths,.fullPaths,.names,.all] {
            c.board.clearContents();menu(owner,ids:peerIDs){model.copyFiles(peerIDs,information:information)}
            let text=c.board.string(forType:.string) ?? ""
            try require(text.contains(c.other) && text != "","Historical Copy menu failed during history stream")
            if information == .fullPaths {try require(text.contains(c.root.path),"Full-path clipboard omitted requesting repository")}
            if information == .all {try require(text.contains("\t"),"Copy all omitted selected file columns")}
        }
        model.copyChangedFileIDs(Array(peerIDs),status:true)
        try require(c.board.string(forType:.string)?.hasPrefix(c.other+"\t")==true,"Changed-file Copy status failed during history stream")
        model.copyChangedFileIDs(Array(peerIDs),column:.status)
        try require(c.board.string(forType:.string)==model.changedFileText(peer[0],column:.status),"Changed-file column Copy failed during history stream")
        let probe=try unwrap(views(owner.window?.contentView).compactMap{$0 as? LogFileDragInteraction.Probe}.first{$0.nativeTable != nil && $0.rows.map(\.rawID)==model.fileTableRows.map(\.rawID)},"No actual historical drag adapter")
        let drag=try unwrap(probe.captureSelection(),"Historical promise capture refused during history stream")
        let promises=drag.writers.compactMap{$0 as? NSFilePromiseProvider}
        try require(promises.count==1 && drag.operationMask == .copy,"Historical selected source did not offer readonly file promise")
        let provider=promises[0],delegate=try unwrap(provider.delegate as? FileListFilePromise,"No production promise delegate"),reply=PromiseReply()
        let output=delivery.appendingPathComponent(delegate.name)
        delegate.filePromiseProvider(provider,writePromiseTo:output){reply.finish($0)}
        try require(FileListDrag.activeLoads>0,"Accepted historical promise lost queued ownership")
        try await wait("Historical promise queued behind held history instead of independent blob read"){reply.value != nil}
        try unwrap(reply.value,"No promise completion").get()
        try require(try Data(contentsOf:output)==c.working[c.other] && model.loadingHistory,"Historical promise changed bytes or released held history")
        AlternativeEditorPreferences().save(to:c.preferences)
    }
    static func rootConsumer(_ c:Context)async throws {
        // One actual Root-installed callback completes the chain from native
        // historical rows to a real viewer. Other callback assertions above do
        // not substitute for this adapter/repository/preferences ownership check.
        for url in [c.first,c.waiting(2),c.released,c.moduleArm]{try? FileManager.default.removeItem(at:url)}
        let executable=c.git,preferences=c.preferences
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:executable,libgit2Configuration:.init(enabled:false))},snapshotStore:FinderSnapshotStore(url:c.root.deletingLastPathComponent().appendingPathComponent("root-finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.deletingLastPathComponent().appendingPathComponent("root-marks.json")),cachePersistenceDefaults:preferences)
        c.rootOwners.append(workspace);workspace.fileComparisonPreferences=preferences
        workspace.logWindowFactory={repository,access in
            let slow=GitRepository(root:repository.root,executable:c.root.appendingPathComponent("held-helper"),libgit2Configuration:.init(enabled:false))
            let owner=LogWindowController(repository:slow,access:access,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)
            owner.model.clipboard=c.board;c.owners.append(owner);return owner
        }
        workspace.logWindowPresentation={owner in owner.window?.appearance=NSAppearance(named:.darkAqua);owner.showWindow(nil)}
        workspace.fileComparisonWindowPresentation={controller in c.comparisons.append(controller);controller.showWindow(nil)}
        workspace.open(c.root)
        try await wait("Actual Root private repository did not open"){workspace.root?.resolvingSymlinksInPath().standardizedFileURL.path==c.root.resolvingSymlinksInPath().standardizedFileURL.path && !workspace.busy && !workspace.hasPendingRepositoryWork}
        workspace.activate(.log)
        try await wait("Root-created Log did not expose held history prefix"){c.owners.last?.model.loadingHistory==true && c.owners.last?.model.entries.count==128 && FileManager.default.fileExists(atPath:c.waiting(2).path)}
        let owner=try unwrap(c.owners.last,"No Root-owned source Log")
        try await revision(c.latest,owner:owner);let files=try await select([c.renamed,c.other],owner:owner),ids=GitPathSet(files.map(\.id))
        menu(owner,ids:ids){owner.model.compareFilePair(ids)}
        try await wait("Root-installed historical pair did not open actual comparison"){!workspace.busy && c.comparisons.count==1 && c.comparisons[0].model.document != nil}
        let comparison=c.comparisons[0],document=try unwrap(comparison.model.document,"No Root comparison document")
        try require(document.base.path==files[0].path && document.destination.path==files[1].path && document.base.bytes==c.working[files[0].path] && document.destination.bytes==c.working[files[1].path],"Root adapter lost captured historical pair paths/order/bytes")
        try require(comparison.model.comparisonDefaults === preferences && comparison.window?.appearance?.name==owner.window?.effectiveAppearance.name && owner.model.loadingHistory,"Root adapter lost source preferences/appearance or waited for entire history")
        comparison.close();owner.close()
        try await wait("Root-owned source/viewer did not drain"){drained() && !workspace.busy}
    }
    static func verify(_ c:Context)async throws {
        let owner=try c.open(),model=owner.model
        try await wait("Real history stream did not hold at its first prefix"){model.loadingHistory && model.entries.count==128 && FileManager.default.fileExists(atPath:c.waiting(2).path)}
        try await revision(c.latest,owner:owner)
        try require(model.busy && model.canInspectHistory,"Fixture did not retain independent streamed-history busy state")
        var logs:[(String,String?)]=[],blames:[(String,String)]=[],pairs:[(String,[CommitFile])]=[],marks:[(PreparedFileComparisonMark,PreparedFileComparisonMark)]=[]
        model.onFileLog={logs.append(($0,$1))};model.onBlame={blames.append(($0,$1))};model.onFilePairCompare={pairs.append(($0,$1))};model.onPreparedFileCompare={marks.append(($0,$1))}
        let renamed=try await select([c.renamed],owner:owner),ids=GitPathSet(renamed.map(\.id))
        try require(renamed[0].oldPath==c.old && model.revision?.parents==[c.previous],"Real selected renamed-file parent/source metadata missing")
        menu(owner,ids:ids){model.fileLog(ids)};menu(owner,ids:ids){model.fileLog(ids,oldName:true)}
        try require(logs.count==2 && logs[0].0==c.renamed && logs[0].1==c.latest && logs[1].0==c.old && logs[1].1==nil,"Historical Show log/old-name navigation lost source path/hash policy while streaming")
        try require(model.canBlameFile(ids),"Loaded historical file cannot Blame while independent history streams")
        menu(owner,ids:ids){model.blameFile(ids)}
        try require(blames.count==1 && blames[0].0==c.renamed && blames[0].1==c.latest,"Blame used a live workspace or parent hash instead of selected historical source")
        let both=try await select([c.renamed,c.other],owner:owner),bothIDs=GitPathSet(both.map(\.id))
        try require(model.canCompareFilePair(bothIDs),"Loaded historical pair unavailable during streaming")
        menu(owner,ids:bothIDs){model.compareFilePair(bothIDs)}
        try require(pairs.count==1 && pairs[0].0==c.latest && pairs[0].1==both && GitPathSet(pairs[0].1.map(\.path))==GitPathSet([c.renamed,c.other]),"Historical pair lost captured selected hash/path/parent records")
        let warningOwner=model.captureFileNavigationOwner(),question=NSAlert()
        question.messageText="Private captured comparison question";question.addButton(withTitle:"Continue");question.addButton(withTitle:"Cancel")
        let window=try unwrap(owner.window,"No owned question window")
        window.beginSheet(question.window,completionHandler:{_ in})
        try require(warningOwner() && question.window.alphaValue==0,"Owned comparison question revoked its captured file-navigation authority or became visible")
        window.endSheet(question.window,returnCode:.cancel);question.window.orderOut(nil)
        try await wait("Owned comparison question did not detach"){question.window.sheetParent==nil && window.attachedSheet==nil}
        try require(warningOwner(),"Owned comparison question invalidated unchanged source after detachment")
        try await documents(c,owner:owner)
        _=try await select([c.renamed],owner:owner)
        menu(owner,ids:ids){model.markForComparison(ids)}
        try require(model.comparisonMark?.path==c.renamed && model.comparisonMark?.revision==c.latest,"Mark for comparison ignored loaded source during stream")
        let stale=model.fileMenuSnapshot(ids),navigationOwner=model.captureFileNavigationOwner()
        try await revision(c.previous,owner:owner)
        var admitted=0
        model.withFileMenu(stale,inspection:true){admitted += 1;model.fileLog(ids)}
        try require(admitted==0 && logs.count==2 && !navigationOwner(),"Previous revision's captured menu/async owner survived actual native history navigation")
        let current=try await select([c.other],owner:owner),currentIDs=GitPathSet(current.map(\.id))
        menu(owner,ids:currentIDs){model.compareWithMarkedFile(currentIDs)}
        try require(marks.count==1 && marks[0].0.path==c.renamed && marks[0].0.revision==c.latest && marks[0].1.path==c.other && marks[0].1.revision==c.previous,"Marked comparison lost cross-revision captured endpoints")
        let mutation=model.fileMenuSnapshot(currentIDs)
        model.withFileMenu(mutation){admitted += 1}
        try require(admitted==0 && !model.canRevertHistoricalFiles(currentIDs,parent:false),"History stream admitted a mutating file-menu action")
        let quitting=model.fileMenuSnapshot(currentIDs);model.confirmingQuit=true
        model.withFileMenu(quitting,inspection:true){admitted += 1};model.fileLog(currentIDs);model.blameFile(currentIDs)
        try require(admitted==0 && logs.count==2 && blames.count==1,"Quit-owned Log admitted read-only navigation")
        model.confirmingQuit=false
        // A real child-discovery Git process is held independently of history.
        // Finishing the stream must not clear that owned navigation's busy state.
        try await revision(c.latest,owner:owner)
        let module=try await select(["module"],owner:owner),moduleIDs=GitPathSet(module.map(\.id))
        var sublogs:[(URL,String?)]=[],acceptedBackend:[Bool]=[]
        model.onSubmoduleFileLog={sublogs.append(($0,$1));acceptedBackend.append(model.acceptedNavigationRepository?.libgit2Configuration?.enabled ?? true)}
        try Data().write(to:c.moduleArm)
        menu(owner,ids:moduleIDs){model.showSubmoduleFileLog(moduleIDs)}
        try await wait("Owned submodule discovery did not enter actual held Git"){model.fileNavigationReadPending && FileManager.default.fileExists(atPath:c.moduleWaiting.path)}
        try require(model.loadingHistory && model.busy && !model.canInspectHistory && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Child discovery lost independent history/read/Quit ownership")
        try Data().write(to:c.released)
        let fifo=c.fifo
        try await Task.detached {let handle=try FileHandle(forWritingTo:fifo);try handle.write(contentsOf:Data("continue\n".utf8));try handle.close()}.value
        try await wait("Actual history stream did not finish while child discovery remained held"){!model.loadingHistory && LogWindowModel.activeHistoryLoads==0 && model.entries.count==132}
        try require(model.busy && model.fileNavigationReadPending && LogWindowModel.activeFileOpenReads==1,"History completion released an unfinished owned file-navigation read")
        let childPID=Int32(try String(contentsOf:c.moduleWaiting).trimmingCharacters(in:.whitespacesAndNewlines))
        try require(model.cancelFileNavigationRead(),"Explicit file-navigation Cancel was not admitted")
        try require(model.fileNavigationReadPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Cancel abandoned child discovery before process drain")
        try await wait("Canceled actual child discovery did not drain"){!model.fileNavigationReadPending && !model.busy && LogWindowModel.activeFileOpenReads==0}
        try require(sublogs.isEmpty && model.error==nil,"Canceled child discovery delivered a late Log/error")
        if let childPID{try require(kill(childPID,0) != 0 && errno==ESRCH,"Canceled child-discovery helper remained alive")}
        try FileManager.default.removeItem(at:c.moduleArm)
        menu(owner,ids:moduleIDs){model.showSubmoduleFileLog(moduleIDs)}
        c.preferences.set(true,forKey:"UseLibgit2")
        try await wait("Accepted initialized submodule history navigation did not settle"){sublogs.count==1 && !model.fileNavigationReadPending}
        let expectedChild=c.root.appendingPathComponent("module").resolvingSymlinksInPath().standardizedFileURL.path
        try require(sublogs[0].0.resolvingSymlinksInPath().standardizedFileURL.path.utf8.elementsEqual(expectedChild.utf8),"Child Log lost exact captured child root")
        // Pinned CGit::GetSubmoduleHash returns success with no hash when the
        // captured libgit master flag is off. A later preference edit must not
        // introduce a pin that was absent in this accepted request.
        try require(sublogs[0].1==nil,"Disabled captured libgit master unexpectedly pinned child Log revision")
        try require(acceptedBackend==[false],"Child Log changed captured backend after settings changed")
        c.preferences.set(false,forKey:"UseLibgit2")
        let oldPID=Int32(try String(contentsOf:c.waiting(2)).trimmingCharacters(in:.whitespacesAndNewlines))
        for url in [c.first,c.waiting(2),c.released]{try FileManager.default.removeItem(at:url)}
        let reloading=model.fileMenuSnapshot(currentIDs);model.reload()
        model.withFileMenu(reloading,inspection:true){admitted += 1}
        try require(admitted==0,"Reload retained an old file-menu receipt")
        try await wait("Replacement stream did not hold with fresh prefix"){model.loadingHistory && model.entries.count==128 && FileManager.default.fileExists(atPath:c.waiting(2).path)}
        if let oldPID{try require(kill(oldPID,0) != 0 && errno==ESRCH,"Refresh left the superseded owned history helper alive")}
        try await revision(c.latest,owner:owner);_=try await select([c.renamed],owner:owner)
        let completionOwner=model.captureFileNavigationOwner(),completionMenu=model.fileMenuSnapshot(GitPathSet(model.files.map(\.id))),completionDragEpoch=model.fileDragGeneration
        func completionDiagnostic()->String {
            "selectedHashes=\(model.selected) selectedFiles=\(Array(model.selectedFiles)) fileSelectionGeneration=\(model.fileSelectionGeneration) projectionEpoch=\(model.historyProjectionEpoch) controlsEpoch=\(model.logControlsEpoch) files=\(model.files) revision=\(model.revision?.hash ?? "none") activeActionReads=\(LogWindowModel.activeActionReads) inspect=\(model.canInspectHistory) loading=\(model.loadingHistory) busy=\(model.busy) invalidated=\(model.isInvalidated) quitting=\(model.confirmingQuit) filePending=\(model.fileNavigationReadPending) dragEpoch=\(String(describing:model.fileDragGeneration)) error=\(model.error ?? "none")"
        }
        let beforeCompletion=completionDiagnostic()
        try require(completionOwner(),"Loaded source owner was not live before successful final history publication")
        try require(completionDragEpoch != nil,"Historical drag source was not live before completion")
        try Data().write(to:c.released)
        try await Task.detached {let handle=try FileHandle(forWritingTo:fifo);try handle.write(contentsOf:Data("complete\n".utf8));try handle.close()}.value
        try await wait("Successful replacement stream did not complete"){!model.loadingHistory && !model.busy && !model.historyProjectionWorkPending && model.entries.count==132}
        if !completionOwner() || model.fileDragGeneration != completionDragEpoch {
            print("FILE COMPLETION BEFORE \(beforeCompletion)")
            print("FILE COMPLETION AFTER \(completionDiagnostic())")
        }
        try require(completionOwner(),"Successful history completion revoked unchanged captured file-navigation source")
        try require(model.fileDragGeneration==completionDragEpoch,"Successful history completion revoked unchanged historical drag source")
        model.withFileMenu(completionMenu,inspection:true){admitted += 1}
        try require(admitted==0,"Successful history busy settlement left an old native menu receipt active")
        for url in [c.first,c.waiting(2),c.released]{try FileManager.default.removeItem(at:url)}
        model.reload();try require(!completionOwner(),"A later refresh revived the previous completed source owner")
        try await wait("Final owned stream did not hold for close"){model.loadingHistory && model.entries.count==128 && FileManager.default.fileExists(atPath:c.waiting(2).path)}
        try await revision(c.latest,owner:owner);let retired=model.fileMenuSnapshot(GitPathSet(model.files.map(\.id)))
        let pid=Int32(try String(contentsOf:c.waiting(2)).trimmingCharacters(in:.whitespacesAndNewlines))
        owner.close()
        try await wait("Closed read-only file navigation owner did not drain"){drained() && owner.window?.isVisible != true}
        model.withFileMenu(retired,inspection:true){admitted += 1}
        try require(admitted==0 && model.error==nil,"Retired Log accepted stale menu or diagnosed canceled history")
        if let pid{try require(kill(pid,0) != 0 && errno==ESRCH,"Owned held history helper survived actual close/drain")}
        // Normal window Close requests cancellation first; it cannot drop an
        // accepted child read merely because the background walk has settled.
        try Data().write(to:c.released)
        let closing=try c.open();try await wait("Normal-close owner stable history did not load"){!closing.model.loadingHistory && !closing.model.busy && closing.model.entries.count==132}
        try await revision(c.latest,owner:closing);let closeFiles=try await select(["module"],owner:closing),closeIDs=GitPathSet(closeFiles.map(\.id))
        try FileManager.default.removeItem(at:c.moduleWaiting);try Data().write(to:c.moduleArm)
        var lateChildren=0;closing.model.onSubmoduleFileLog={_,_ in lateChildren += 1}
        menu(closing,ids:closeIDs){closing.model.showSubmoduleFileLog(closeIDs)}
        try await wait("Normal-close child discovery did not enter"){closing.model.fileNavigationReadPending && FileManager.default.fileExists(atPath:c.moduleWaiting.path)}
        let closingPID=Int32(try String(contentsOf:c.moduleWaiting).trimmingCharacters(in:.whitespacesAndNewlines))
        closing.window?.performClose(nil)
        try require(closing.model.fileNavigationReadPending && closing.window?.isVisible==true && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Normal Close released the owner before child Git drained")
        try await wait("Normal Close failed to finish after owned navigation drained"){!closing.model.fileNavigationReadPending && closing.window?.isVisible != true && drained()}
        try require(lateChildren==0 && closing.model.error==nil,"Normal Close published late child navigation/error")
        if let closingPID{try require(kill(closingPID,0) != 0 && errno==ESRCH,"Normal Close left child discovery helper alive")}
        try await rootConsumer(c)
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietStreamFilesOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietStreamFilesSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let c=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do{try await c.setup();try await verify(c);await c.clean()}catch{await c.clean();throw error}
        let owners=c.owners.map{$0 as NSWindowController}+c.comparisons.map{$0 as NSWindowController}
        try require(drained() && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Owned Log windows/operations survived cleanup")
        print("PASS: Log streamed file navigation, actual native revisions/files, readonly captured menu routes, stale fences and drain")
    }
}
