// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import Combine
import TurtleGitCore

private extension NSWindow {
    @objc func logSelectionOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));logSelectionOrder(mode,relativeTo:number)
    }
}
/// Delays real graph computation without MainActor work or fabricated output.
/// It deliberately returns the actual old projection even after cancellation,
/// exercising the owner's late-result fence independently of cooperation.
private final class LogProjectionWorkerProbe:@unchecked Sendable {
    private let lock=NSLock(),gate=DispatchSemaphore(value:0)
    private var armed=false,held=false,entered=false,onMain=false,canceledReturns=0
    func arm(){lock.lock();armed=true;entered=false;lock.unlock()}
    var state:(held:Bool,entered:Bool,onMain:Bool,canceledReturns:Int){lock.lock();defer{lock.unlock()};return(held,entered,onMain,canceledReturns)}
    func release(){lock.lock();let needs=held;lock.unlock();if needs{gate.signal()}}
    func compute(_ input:LogWindowModel.HistoryProjectionInput)->LogWindowModel.HistoryProjection {
        lock.lock();onMain = onMain || Thread.isMainThread
        let wait=armed && input.entries.count==128
        if wait{armed=false;held=true;entered=true};lock.unlock()
        if wait{gate.wait();lock.lock();held=false;lock.unlock()}
        let result=CommitGraph.project(input.entries,walk:input.walk,references:input.references,rollupStates:input.rollupStates)
        if input.cancellation.isCancelled{lock.lock();canceledReturns += 1;lock.unlock()}
        return result
    }
}
@MainActor @main enum LogNativeSelectionVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Log native selection timeout: "+message)}
    static func views(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(views)}
    static func projectionWorkers(repository:GitRepository,preferences:UserDefaults,hashes:[String],name:String)async throws {
        let original=try await repository.rebaseCommit("HEAD").hash,indexURL=repository.root.appendingPathComponent(".git/index"),index=try Data(contentsOf:indexURL)
        let workingURL=repository.root.appendingPathComponent(name),working=try Data(contentsOf:workingURL)
        let owner=LogWindowController(repository:repository,access:RepositoryAccessLease(url:repository.root),labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false),model=owner.model
        let probe=LogProjectionWorkerProbe();var replacement:String?,publication:AnyCancellable?,published=[(String,Int)]()
        defer{probe.release();publication?.cancel();owner.close()}
        do {
            owner.showWindow(nil);model.reload()
            try await wait("projection case actual stable baseline"){!model.loadingHistory && !model.busy && model.entries.count==258 && !model.historyProjectionWorkPending}
            guard let window=owner.window,let content=window.contentView else{throw Failure(description:"Projection owner absent")}
            content.layoutSubtreeIfNeeded()
            guard let table=views(content).compactMap({$0 as? HistoryTableView}).first else{throw Failure(description:"Projection native table absent")}
            model.readHistoryProjection={probe.compute($0)}
            probe.arm();model.reload()
            try await wait("real128 projection worker held"){probe.state.held && model.historyProjectionWorkPending}
            try require(!probe.state.onMain && LogWindowModel.activeHistoryProjectionWorkers>0,"Heavy real graph worker executed inline or lost actual ownership")
            try await wait("native stable rows during held projection"){table.numberOfRows==258 && model.entries.count==258 && (table.delegate as? RevisionTable.Coordinator)?.revisionInputAvailable==true}
            guard let chosen=model.entries.firstIndex(where:{$0.hash==hashes[1]})else{throw Failure(description:"Stable inspected commit absent")}
            table.selectRowIndexes(IndexSet(integer:chosen),byExtendingSelection:false)
            try await wait("native inspection while graph worker held"){
                model.selected==[hashes[1]] && model.files.contains{$0.path==name} && views(content).compactMap{$0 as? LogMessageTextView}.contains{$0.string.contains("Native detail body 2")}
            }
            var heartbeat=false;DispatchQueue.main.async{heartbeat=true}
            try await wait("MainActor heartbeat during actual graph work"){heartbeat}
            try require(probe.state.held && model.loadingHistory,"Inspection released or replaced actual held projection")
            // A real new source revision makes late old-prefix publication
            // observable without fitting expected graph internals.
            let tree=try await repository.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines)
            let new=try await repository.run(["commit-tree",tree,"-p",original],input:Data("New projection generation\n".utf8)).text.trimmingCharacters(in:.newlines)
            _=try await repository.run(["update-ref","refs/heads/main",new,original]);replacement=new
            publication=model.$entries.dropFirst().sink{published.append(($0.first?.hash ?? "",$0.count))}
            model.reload()
            try require(probe.state.held && model.historyProjectionWorkPending,"New reload abandoned old graph worker lifetime")
            probe.release()
            try await wait("new final source projection drains old generation"){!model.loadingHistory && !model.busy && !model.historyProjectionWorkPending && model.entries.count==259 && model.entries.first?.hash==new}
            try require(probe.state.canceledReturns>0,"Fixture did not deliver an actual retired projection result")
            try require(!published.contains{$0.0==original && ($0.1==128 || $0.1==256)},"Retired old-head prefix overwrote newer reload")
            try require(model.selected==[hashes[1]] && model.graph.count==model.entries.count && !model.historyHasHiddenRows && model.loadedRevisionCount==259,"Final projection mixed graph/source count or lost inspection")
            try await wait("details preserved after latest final projection"){model.files.contains{$0.path==name} && views(content).compactMap{$0 as? LogMessageTextView}.contains{$0.string.contains("Native detail body 2")}}
            publication?.cancel();publication=nil
            probe.arm();model.reload()
            try await wait("actual projection held for close cancellation"){probe.state.held && model.historyProjectionWorkPending}
            let active=LogWindowModel.activeHistoryProjectionWorkers
            owner.close()
            try require(LogWindowModel.activeHistoryProjectionWorkers==active && model.historyProjectionWorkPending,"Closing owner abandoned held graph worker instead of draining it")
            try await wait("history/details drain while only graph worker remains held"){LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0}
            try require(probe.state.held && LogWindowModel.activeHistoryProjectionWorkers>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit abandoned the actual held graph worker")
            probe.release()
            try await wait("retired actual graph workers drained"){!model.historyProjectionWorkPending && LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && owner.window?.isVisible != true}
            try require(model.entries.count==259 && model.entries.first?.hash==new && model.selected==[hashes[1]],"Late retired graph result changed closed owner's stable snapshot")
            _=try await repository.run(["update-ref","refs/heads/main",original,new]);replacement=nil
            try require((try Data(contentsOf:indexURL))==index && (try Data(contentsOf:workingURL))==working,"Graph pipeline changed index/working bytes")
        }catch{
            probe.release();owner.close();model.invalidate()
            try? await wait("failed graph worker drain"){!model.historyProjectionWorkPending && LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeHistoryLoads==0}
            if let replacement{_=try? await repository.run(["update-ref","refs/heads/main",original,replacement])}
            throw error
        }
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.logSelectionOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Log selection QA"),("user.email","selection@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repo.run(["config",key,value])}
        let name="history 雪.txt",file=root.appendingPathComponent(name)
        // Older history forces the real128-row stream/notes boundary while
        // keeping the latest three commits useful for native detail inspection.
        let emptyTree=try await repo.run(["mktree"],input:Data()).text.trimmingCharacters(in:.newlines)
        var older:String?
        for number in 0..<255 {
            var arguments=["commit-tree",emptyTree];if let older{arguments += ["-p",older]}
            older=try await repo.run(arguments,input:Data("Older \(number)\n".utf8)).text.trimmingCharacters(in:.newlines)
        }
        if let older{_=try await repo.run(["update-ref","refs/heads/main",older])}
        var hashes=[String]()
        for number in 1...3 {
            try Data("version \(number)\n".utf8).write(to:file);try await repo.stage([name]);_=try await repo.commit(message:"Selection \(number)\n\nNative detail body \(number)")
            hashes.append(try await repo.rebaseCommit("HEAD").hash)
        }
        guard let older else{throw Failure(description:"Older history setup missing")}
        _=try await repo.run(["notes","add","-m","Preserved streaming note",older])
        let indexURL=root.appendingPathComponent(".git/index"),index=try Data(contentsOf:indexURL),working=try Data(contentsOf:file)
        let suite="TurtleGit.LogNativeSelection."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,board=NSPasteboard.withUniqueName()
        defer{prefs.removePersistentDomain(forName:suite);board.releaseGlobally()}
        for key in ["EnableLogCache","EnableGravatar","LogIncludeWorkingTreeChanges","UseLibgit2"]{prefs.set(false,forKey:key)}
        prefs.set(true,forKey:"DiffByDoubleClickInLog")
        let helper=root.appendingPathComponent("held-history"),fifo=root.appendingPathComponent("held-history.fifo"),waiting=root.appendingPathComponent("held-history.waiting-2"),waitingNext=root.appendingPathComponent("held-history.waiting-3"),first=root.appendingPathComponent("held-history.first"),released=root.appendingPathComponent("held-history.released")
        guard mkfifo(fifo.path,mode_t(0o600))==0 else{throw Failure(description:"Private history FIFO unavailable")}
        func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        task_notes=false
        for task_arg in "$@"; do if [ "$task_arg" = --log-size ]; then task_notes=true; fi; done
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
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let slow=GitRepository(root:root,executable:helper,libgit2Configuration:.init(enabled:false))
        let owner=LogWindowController(repository:slow,access:RepositoryAccessLease(url:root),labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false),model=owner.model
        model.clipboard=board
        var comparisons=[(ComparisonRevision,ComparisonRevision)](),fileComparisons=[(ComparisonRevision,ComparisonRevision,[String])]();model.onCompare={comparisons.append(($0,$1))}
        model.onFileCompare={fileComparisons.append(($0,$1,$2))}
        do {
            owner.showWindow(nil);model.reload()
            try await wait("actual provisional history held after128 rows"){model.loadingHistory && model.entries.count==128 && FileManager.default.fileExists(atPath:waiting.path)}
            guard let window=owner.window,let content=window.contentView else{throw Failure(description:"Actual Log window missing")}
            content.layoutSubtreeIfNeeded()
            try await wait("actual revision table attached"){views(content).contains{$0 is HistoryTableView}}
            guard let table=views(content).compactMap({$0 as? HistoryTableView}).first else{throw Failure(description:"Revision table missing")}
            try await wait("displayed native history matches provisional projection"){content.layoutSubtreeIfNeeded();return table.numberOfRows==model.entries.count && table.numberOfRows==128 && !table.visibleRect.isEmpty}
            func row(_ hash:String)throws->Int{guard let value=model.entries.firstIndex(where:{$0.hash==hash})else{throw Failure(description:"Expected actual commit missing")};return value}
            func assertDetails(_ hash:String,_ number:Int)async throws {
                try await wait("native selected commit, message and changed files") {
                    model.selected==[hash] && model.revision?.hash==hash && model.files.contains{$0.path==name} &&
                    views(content).compactMap{$0 as? LogMessageTextView}.contains{$0.string.contains("Native detail body \(number)")}
                }
                try require(model.error==nil,"Native selection detail read failed")
            }
            let middle=try row(hashes[1]);table.scrollRowToVisible(middle);content.layoutSubtreeIfNeeded()
            let local=NSPoint(x:min(table.bounds.maxX-8,table.rect(ofColumn:table.column(withIdentifier:.init("message"))).midX),y:table.rect(ofRow:middle).midY)
            let contentPoint=(content.superview ?? content).convert(local,from:table),hit=content.hitTest(contentPoint)
            try require(hit === table || hit?.isDescendant(of:table)==true,"Log row pointer target intercepted outside native revision list: hit=\(hit.map{String(describing:type(of:$0))} ?? "nil") local=\(local) converted=\(contentPoint) tableframe=\(table.frame) tablebounds=\(table.bounds) visible=\(table.visibleRect) contentframe=\(content.frame)")
            // AppKit's actual row selection sends the production delegate
            // notification. Never seed model.select to make this assertion pass.
            table.selectRowIndexes(IndexSet(integer:middle),byExtendingSelection:false)
            try await assertDetails(hashes[1],2)
            var heartbeat=false;DispatchQueue.main.async{heartbeat=true}
            try await wait("MainActor responsive while actual history held"){heartbeat}
            try require(window.makeFirstResponder(table) && window.firstResponder === table,"Native revision list refused keyboard focus")
            guard let down=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{f701}",charactersIgnoringModifiers:"\u{f701}",isARepeat:false,keyCode:125)else{throw Failure(description:"Native arrow event unavailable")}
            table.keyDown(with:down)
            try await assertDetails(hashes[0],1)
            guard let up=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{f700}",charactersIgnoringModifiers:"\u{f700}",isARepeat:false,keyCode:126)else{throw Failure(description:"Native arrow event unavailable")}
            table.keyDown(with:up)
            try await assertDetails(hashes[1],2)
            guard let action=table.doubleAction,let target=table.target else{throw Failure(description:"Native revision double action absent")}
            try require(NSApp.sendAction(action,to:target,from:table),"Native revision double action refused")
            try require(comparisons.count==1 && comparisons[0].0 == .revision(hashes[0]) && comparisons[0].1 == .revision(hashes[1]),"Native selected revision double action did not request its correct previous-version diff")
            try await wait("actual changed-file native table ready"){views(content).compactMap{$0 as? CommitFileInteraction.Probe}.contains{$0.nativeTable != nil && $0.nativeTable?.numberOfRows==model.fileTableRows.count}}
            guard let fileTable=views(content).compactMap({$0 as? CommitFileInteraction.Probe}).first(where:{$0.nativeTable != nil})?.nativeTable,
                  let fileRow=model.fileTableRows.firstIndex(where:{$0.file?.path==name}),let fileID=model.fileTableRows[fileRow].file?.id else{throw Failure(description:"Actual native changed-file row missing")}
            fileTable.selectRowIndexes(IndexSet(integer:fileRow),byExtendingSelection:false)
            try await wait("native changed-file selection adopted"){model.selectedFiles.contains(fileID)}
            // Invoke the exact shared SwiftUI primary-action handler after real
            // native file selection; this boundary is not a physical double click.
            model.primaryFileAction(model.selectedFiles)
            try require(fileComparisons.count==1 && fileComparisons[0].0 == .revision(hashes[0]) && fileComparisons[0].1 == .revision(hashes[1]) && fileComparisons[0].2==[name],"Selected file primary action refused or used stale revision/path during streaming")
            try require(model.loadingHistory && model.entries.count==128,"Inspection silently completed or replaced the held actual history read")
            let heldPID=Int32(try String(contentsOf:waiting).trimmingCharacters(in:.whitespacesAndNewlines))
            func releaseChunk()throws{let handle=try FileHandle(forWritingTo:fifo);try handle.write(contentsOf:Data("continue\n".utf8));try handle.close()}
            try releaseChunk()
            try await wait("next actual prefix preserves inspected commit"){model.loadingHistory && model.entries.count==256 && FileManager.default.fileExists(atPath:waitingNext.path)}
            try await assertDetails(hashes[1],2)
            try require(table.selectedRowIndexes==IndexSet(integer:try row(hashes[1])),"Next provisional prefix lost native inspected row")
            try Data().write(to:released);try releaseChunk()
            try await wait("actual final history preserves inspected commit"){!model.loadingHistory && !model.busy && model.entries.count==258}
            try await assertDetails(hashes[1],2)
            try require(model.entries.first(where:{$0.hash==older})?.notes=="Preserved streaming note","Final actual notes metadata was lost")
            try require(table.selectedRowIndexes==IndexSet(integer:try row(hashes[1])),"Final stream publication lost native inspected row")
            if let heldPID{try require(kill(heldPID,0) != 0,"Held actual history helper survived completion")}
            // Repeat a real stream, change its provisional selection and close
            // while Git is held. Retirement must drain the worker and restore
            // stable rows without reverting the user's inspected revision.
            for url in [first,released,waiting,waitingNext]{try? FileManager.default.removeItem(at:url)}
            model.reload()
            try await wait("second actual history held for cancellation"){model.loadingHistory && model.entries.count==128 && FileManager.default.fileExists(atPath:waiting.path)}
            table.selectRowIndexes(IndexSet(integer:try row(hashes[2])),byExtendingSelection:false)
            try await assertDetails(hashes[2],3)
            let cancelledPID=Int32(try String(contentsOf:waiting).trimmingCharacters(in:.whitespacesAndNewlines))
            owner.close()
            try await wait("Log native owner/readers drained"){LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogMessageView.Coordinator.activeOperations==0 && owner.window?.isVisible != true}
            try require(model.selected==[hashes[2]] && model.entries.count==258,"Canceled stream rollback lost valid user selection or stable history")
            if let cancelledPID{try require(kill(cancelledPID,0) != 0,"Canceled history helper survived actual owner drain")}
            let head=try await repo.rebaseCommit("HEAD").hash
            try require(head==hashes[2] && (try Data(contentsOf:indexURL))==index && (try Data(contentsOf:file))==working,"Native Log interaction changed repository bytes")
        }catch{
            let count=(try? String(contentsOf:first))?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "missing"
            fputs("LOG_SELECTION_STATE entries=\(model.entries.count) loading=\(model.loadingHistory) busy=\(model.busy) limit=\(model.historyLimit.scale.rawValue)/\(model.historyLimit.number) note_queries=\(count) waiting2=\(FileManager.default.fileExists(atPath:waiting.path)) waiting3=\(FileManager.default.fileExists(atPath:waitingNext.path)) error=\(model.error ?? "none")\n",stderr)
            owner.close();model.invalidate();try? await wait("failed Log receiver actual worker drain"){LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeActionReads==0 && LogMessageView.Coordinator.activeOperations==0};throw error}
        try await projectionWorkers(repository:repo,preferences:prefs,hashes:hashes,name:name)
        print("PASS: actual native Log row selection and arrow keys update message/changed files; row hit target and selected revision double-action diff preserve ownership and repository bytes")
    }
}
