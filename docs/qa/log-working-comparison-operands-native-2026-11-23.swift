// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func logOperandHiddenOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));logOperandHiddenOrder(mode,relativeTo:number)
    }
}

/// Real native Log input and actual Root preparation; external presentation is
/// injected. No current-file/editor process or shared pasteboard is launched.
@MainActor @main enum LogWorkingComparisonOperandsVerification {
    typealias Prior=LogPrimaryActivationVerification
    struct Delivery {let snapshot:RevisionComparisonSnapshot,file:CommitFile}
    static weak var diagnosticContext:Prior.Context?
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {try Prior.require(value,"Working operands \(line): "+text)}
    static func diagnostic(_ phase:String,_ c:Prior.Context)->String {
        let model=c.owner?.model,table=try? c.table(),window=c.owner?.window
        let rows=(model?.visibleFiles ?? []).prefix(12).map{file->[String:Any] in
            let status=model?.workingStatusEntry(file)
            return ["id":file.id,"path":file.path,"pathUTF8":Data(file.path.utf8).base64EncodedString(),
                    "action":file.action,"oldPath":file.oldPath ?? "<none>",
                    "rawStatus":status.map{String([$0.index,$0.worktree])} ?? "<missing>",
                    "acceptedOriginalPath":status?.originalPath ?? "<none>",
                    "acceptedOriginalUTF8":status?.originalPath.map{Data($0.utf8).base64EncodedString()} ?? "<none>",
                    "retainedCopy":status?.hasUnversionedCopy ?? false]
        }
        let record:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,
            "error":model?.error ?? "<none>","busy":model?.busy ?? false,"canInspect":model?.canInspectHistory ?? false,
            "workingSentinel":model?.selectedWorkingTree ?? false,"workingParents":model?.workingTreeSnapshot?.entry.parents ?? [],
            "selected":Array(model?.selectedFiles ?? []),"visibleRows":rows,"nativeRows":table?.numberOfRows ?? -1,
            "nativeSelected":table.map{Array($0.selectedRowIndexes)} ?? [],"nativeEnabled":table?.isEnabled ?? false,
            "nativeAvailable":table?.ownerAvailable() ?? false,"nativeOwnsFirstResponder":window?.firstResponder === table,
            "nativeOwnsCommandWindow":table?.commandKeyWindow() === window,"windowVisible":window?.isVisible ?? false,
            "firstResponder":window?.firstResponder.map{String(reflecting:type(of:$0))} ?? "<none>",
            "sheet":window?.attachedSheet.map{String(reflecting:type(of:$0))} ?? "<none>",
            "warnings":c.warnings,"extraWarnings":c.extraWarnings,"plans":c.plans.count,
            "gateEntered":c.warningGate?.entered ?? false,"activeNavigation":LogWindowModel.activeFileNavigationActivities,
            "activeComparisonSessions":FileListComparisonSession.activeOperations]
        let bytes=(try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])) ?? Data()
        try? bytes.write(to:c.base.appendingPathComponent("log-operand-phase.json"),options:.atomic)
        return String(decoding:bytes,as:UTF8.self)
    }
    static func wait(_ text:String,_ value:()->Bool)async throws {
        if let c=diagnosticContext {_=diagnostic("waiting: "+text,c)}
        do {try await Prior.wait(text,window:diagnosticContext?.owner?.window,diagnostic:{diagnosticContext.map{diagnostic("timeout: "+text,$0)} ?? ""},value)}
        catch {if let c=diagnosticContext {print("LOG_OPERAND_FAILURE "+diagnostic("failed: "+text,c));fflush(stdout)};throw error}
    }
    static func entry(_ path:String,_ code:String,old:String?=nil)->StatusEntry {
        StatusEntry.parse(Data((code+" "+path+"\0"+(old.map{$0+"\0"} ?? "")).utf8))[0]
    }
    static func menu(_ c:Prior.Context,ids:GitPathSet,title:String,shift:Bool=false)throws {
        let model=try Prior.unwrap(c.owner?.model,"Log missing")
        let menu=LogChangedFileMenus.make(model:model,ids:ids,column:.path,shift:shift)
        let item=try Prior.unwrap(menu.items.first{$0.title==NSLocalizedString(title,comment:"")},"Actual menu item missing: "+title)
        try require(item.isEnabled && item.image != nil,"Actual menu action/icon unavailable")
        let action=try Prior.unwrap(item.action,"Actual menu selector missing")
        try require(NSApp.sendAction(action,to:item.target,from:item),"Actual menu selector refused")
    }
    static func settled(_ c:Prior.Context)async throws {
        try await wait("accepted operand owner drained"){FileListComparisonSession.activeOperations==0 && LogWindowModel.activeFileNavigationActivities==0 && c.owner?.model.canInspectHistory==true}
    }
    static func reload(_ c:Prior.Context,contains paths:[String])async throws {
        let model=try Prior.unwrap(c.owner?.model,"Source Log missing");model.reload()
        try await wait("new accepted working snapshot"){!model.busy && model.pendingHistoryLoads==0 && model.workingTreeSnapshot != nil}
        model.select([""])
        try await wait("accepted literal working rows"){!model.busy && model.selectedWorkingTree && paths.allSatisfy{path in model.visibleFiles.contains{GitReferenceName.equal($0.path,path)}}}
    }
    static func operands(_ c:Prior.Context)async throws {
        let model=try Prior.unwrap(c.owner?.model,"Source Log missing")
        var deliveries:[Delivery]=[]
        c.workspace.fileComparisonPresentation={deliveries.append(Delivery(snapshot:$0,file:$1))}
        let added="z added 雪.md"
        try Data("accepted newly added contents\n".utf8).write(to:c.root.appendingPathComponent(added));try await c.repo.stage([added])
        _=try await c.repo.run(["rm","-f","--",c.second])
        try await reload(c,contains:[added,c.second])
        let accepted=try Prior.unwrap(model.visibleFiles.first{$0.path==added},"Accepted Added missing")
        try require(model.workingStatusEntry(accepted)?.index=="A","Fixture did not capture an Added row")
        c.preferences.set(1,forKey:"NumDiffWarning");c.warningGate=Prior.Gate<Bool>()
        // The source warning has a hard lower bound of three even when the
        // saved threshold is smaller. Exercise its real four-row boundary.
        try await c.select(GitPathSet([added,c.normal,c.second,c.unknown]));try c.activate()
        try await wait("native Return accepted one warning"){c.warningGate?.entered==true}
        try Data("merged\n".utf8).write(to:c.root.appendingPathComponent(added))
        let index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),head=try await c.repo.run(["rev-parse","HEAD"]).stdout
        let generic=try await c.repo.revisionFileComparison(from:.revision(c.head),to:.workingTree,paths:[added])
        try require(generic.files.contains{$0.action.hasPrefix("R") || $0.action.hasPrefix("C")},"Fixture did not create a competing fresh pairing")
        c.warningGate?.finish(true);c.warningGate=nil
        try await wait("actual Root typed comparisons"){deliveries.count==4};try await settled(c)
        try require(c.warnings==[4] && c.extraWarnings==0,"Selection warning was duplicated or recounted")
        let plan=try Prior.unwrap(c.plans.last,"Native accepted plan missing")
        try require(plan.alternateTool && plan.repository.root==c.repo.root && plan.preferences===c.preferences,"Native Shift/repository/preferences receipt changed")
        try require(deliveries.map(\.file.path)==plan.actions.map{$0.file.path},"Actual Root changed native selected order")
        let addition=try Prior.unwrap(deliveries.first{$0.file.path==added},"Root Added delivery missing")
        try require(addition.file.action=="A" && addition.snapshot.from == .emptyTree,"Fresh pairing replaced accepted Added/null intent")
        let addedDocument=try await c.repo.comparisonFile(addition.snapshot,path:added)
        try require(addedDocument.base.bytes.isEmpty && addedDocument.destination.bytes==Data("merged\n".utf8),"Actual Added operands differ")

        // Explicit Compare is not the retained-copy/current-file primary path.
        let deletedIDs=GitPathSet([c.second]);try await c.select(deletedIDs)
        try Data("recreated after accepted deletion\n".utf8).write(to:c.root.appendingPathComponent(c.second))
        let before=deliveries.count;try menu(c,ids:deletedIDs,title:"Compare with base")
        try await wait("actual Deleted menu Root delivery"){deliveries.count==before+1};try await settled(c)
        let deletion=deliveries.last!
        try require(deletion.file.action=="D" && deletion.snapshot.to == .emptyTree,"Recreated disk leaf replaced accepted Deleted/null intent")
        let deletedDocument=try await c.repo.comparisonFile(deletion.snapshot,path:c.second)
        try require(deletedDocument.base.bytes==Data("merged\n".utf8) && deletedDocument.destination.bytes.isEmpty,"Actual Deleted operands differ")

        let conflictIDs=GitPathSet([c.conflict]);try await c.select(conflictIDs)
        let conflictBefore=deliveries.count,childrenBefore=c.children.count
        try menu(c,ids:conflictIDs,title:"Compare with base")
        try await wait("explicit conflict comparison Root delivery"){deliveries.count==conflictBefore+1};try await settled(c)
        let conflictComparison=deliveries.last!,conflictDocument=try await c.repo.comparisonFile(conflictComparison.snapshot,path:c.conflict)
        try require(conflictComparison.file.action=="M" && conflictComparison.snapshot.from == .revision(c.head) && conflictDocument.base.bytes==Data("merged\n".utf8) && c.children.count==childrenBefore,"Explicit conflicted Compare became null-side or conflict-editor activation")

        try await c.select(GitPathSet([c.unknown]));let unknownBefore=deliveries.count;try c.activate()
        try await wait("native current-file Root delivery"){deliveries.count==unknownBefore+1};try await settled(c)
        let unknown=deliveries.last!,unknownDocument=try await c.repo.comparisonFile(unknown.snapshot,path:c.unknown)
        try require(unknown.snapshot.from == .workingTree && unknown.snapshot.to == .workingTree && unknownDocument.base.bytes==Data("untracked\n".utf8) && unknownDocument.destination.bytes==unknownDocument.base.bytes,"Unversioned primary lost captured working/current-file behavior")

        // CLI status does not naturally discover C. This synthetic accepted C
        // receipt exercises actual Root with real historical/disk source bytes.
        try await c.select(GitPathSet([added]))
        c.forward=false;let capturedBefore=c.plans.count;model.compareFiles([added])
        try await wait("accepted explicit working plan"){c.plans.count==capturedBefore+1};try await settled(c)
        let original=c.plans.last!,file=try Prior.unwrap(model.visibleFiles.first{$0.path==added},"Copy destination missing")
        let intent=StatusListFileComparisonIntent(entry:entry(added,"C ",old:c.normal),base:.revision(c.head),isSubmodule:false)
        let copyPlan=LogFilePrimaryActivation(actions:[.statusComparison(file,intent:intent)],selectedCount:1,repository:original.repository,preferences:original.preferences,window:original.window,workingBase:original.workingBase,isRebase:original.isRebase,alternateTool:original.alternateTool,mergeTools:original.mergeTools,conflictIdentity:original.conflictIdentity,ownerIsCurrent:original.ownerIsCurrent)
        // A completed source activity deliberately retires its earlier owner.
        // Use a new current owner for this receiving-Root operand-only witness.
        let current=model.captureFileNavigationOwner(ids:GitPathSet([added]))
        let liveCopy=LogFilePrimaryActivation(actions:copyPlan.actions,selectedCount:1,repository:copyPlan.repository,preferences:copyPlan.preferences,window:copyPlan.window,workingBase:copyPlan.workingBase,isRebase:copyPlan.isRebase,alternateTool:copyPlan.alternateTool,mergeTools:copyPlan.mergeTools,conflictIdentity:copyPlan.conflictIdentity,ownerIsCurrent:current)
        try await c.workspace.showLogPrimaryFiles(liveCopy,access:c.lease,cancellation:OperationCancellation())
        let copied=deliveries.last!
        try require(copied.file.action=="C" && copied.file.oldPath?.utf8.elementsEqual(c.normal.utf8)==true,"Root replaced accepted copy origin")
        let copyDocument=try await c.repo.comparisonFile(copied.snapshot,path:added)
        try require(copyDocument.base.bytes==Data("merged\n".utf8) && copyDocument.destination.bytes==Data("merged\n".utf8),"Accepted copy did not read actual source operands")
        let beforeQuit=deliveries.count;model.confirmingQuit=true
        do {try await c.workspace.showLogPrimaryFiles(liveCopy,access:c.lease,cancellation:OperationCancellation())}
        catch OperationCancellationFailure.cancelled {}
        model.confirmingQuit=false
        try require(deliveries.count==beforeQuit,"Quit owner admitted stale Root operands")
        c.forward=true;try await reload(c,contains:[c.second])
        let retained=try Prior.unwrap(model.visibleFiles.first{$0.path==c.second},"Retained copy row missing")
        try require(model.workingStatusEntry(retained)?.hasUnversionedCopy==true,"Fixture did not capture retained-copy coalescing")
        try await c.select(GitPathSet([retained.id]));let retainedBefore=deliveries.count;try c.activate()
        try await wait("native retained-copy Root delivery"){deliveries.count==retainedBefore+1};try await settled(c)
        let retainedDelivery=deliveries.last!,retainedDocument=try await c.repo.comparisonFile(retainedDelivery.snapshot,path:c.second)
        try require(retainedDelivery.snapshot.from == .workingTree && retainedDelivery.snapshot.to == .workingTree && retainedDocument.base.bytes==Data("recreated after accepted deletion\n".utf8) && retainedDocument.destination.bytes==retainedDocument.base.bytes,"Retained-copy primary lost current-file adaptation")
        let finalIndex=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalIndex==index && finalHead==head,"Comparisons changed index or HEAD")
        let finalAdded=try Data(contentsOf:c.root.appendingPathComponent(added)),finalDeleted=try Data(contentsOf:c.root.appendingPathComponent(c.second)),finalNormal=try Data(contentsOf:c.root.appendingPathComponent(c.normal))
        try require(finalAdded==Data("merged\n".utf8) && finalDeleted==Data("recreated after accepted deletion\n".utf8) && finalNormal==Data("normal dirty\n".utf8),"Operand inspection changed working contents")
    }
    static func rename(_ c:Prior.Context)async throws {
        let model=try Prior.unwrap(c.owner?.model,"Source Log missing"),renamed="renamed e\u{301} 雪.md"
        _=try await c.repo.run(["config","core.precomposeunicode","false"])
        try Data("merged\n".utf8).write(to:c.root.appendingPathComponent(c.normal))
        _=try await c.repo.run(["mv","--",c.normal,renamed])
        try await reload(c,contains:[renamed])
        let file=try Prior.unwrap(model.visibleFiles.first{$0.path==renamed},"Actual rename row missing")
        try require(model.workingStatusEntry(file)?.originalPath?.utf8.elementsEqual(c.normal.utf8)==true,"Accepted rename origin missing")
        var deliveries:[Delivery]=[];c.workspace.fileComparisonPresentation={deliveries.append(Delivery(snapshot:$0,file:$1))}
        try await c.select(GitPathSet([file.id]));try c.activate()
        try await wait("native renamed Root delivery"){deliveries.count==1};try await settled(c)
        try require(deliveries[0].file.action=="R" && deliveries[0].file.oldPath?.utf8.elementsEqual(c.normal.utf8)==true && deliveries[0].file.path.utf8.elementsEqual(renamed.utf8),"Root changed accepted literal rename pair")
        try Data("merged\n".utf8).write(to:c.root.appendingPathComponent(c.normal))
        try await c.repo.stage([c.normal])
        let index=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),head=try await c.repo.run(["rev-parse","HEAD"]).stdout
        let fresh=try await c.repo.revisionFileComparison(from:.revision(c.head),to:.workingTree,paths:[renamed])
        try require(!fresh.files.contains{$0.action.hasPrefix("R")},"Fixture did not replace fresh rename classification")
        try menu(c,ids:GitPathSet([file.id]),title:"Compare with base",shift:true)
        try await wait("explicit accepted rename survives fresh pairing"){deliveries.count==2};try await settled(c)
        let delivered=deliveries.last!,document=try await c.repo.comparisonFile(delivered.snapshot,path:renamed)
        try require(delivered.file.action=="R" && delivered.file.oldPath?.utf8.elementsEqual(c.normal.utf8)==true && document.base.bytes==Data("merged\n".utf8) && document.destination.bytes==Data("merged\n".utf8),"Explicit renamed operands were redetected")
        let afterIndex=try Data(contentsOf:c.root.appendingPathComponent(".git/index")),afterHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(afterIndex==index && afterHead==head,"Rename comparison changed repository")
    }
    static func historical(_ c:Prior.Context)async throws {
        let model=try Prior.unwrap(c.owner?.model,"Source Log missing");c.forward=false;model.select([c.head])
        try await wait("historical merge groups"){!model.busy && model.fileGroups.count==2}
        let files=model.fileTableRows.compactMap(\.file),ids=GitPathSet(files.map(\.id))
        try await c.select(ids);try c.activate();try await wait("historical typed plan"){!c.plans.isEmpty};try await settled(c)
        for action in c.plans.last!.actions {
            guard case .comparison(let file,let from,let to)=action else{throw Prior.Failure(description:"Historical row became a working status intent")}
            try require(from == .revision(c.mergeParents[file.parentIndex ?? 0]) && to == .revision(c.head),"Historical merge parent changed")
        }
        var requests:[(ComparisonRevision,ComparisonRevision,[String])]=[]
        model.onFileComparisons={requests=$0};model.compareFiles(ids,workingTree:true)
        try require(!requests.isEmpty && requests.allSatisfy{$0.0 == .revision(c.head) && $0.1 == .workingTree},"Historical current→working route changed")
        requests=[];model.compareFiles(ids,parentWorkingTree:true)
        try require(requests.count==2 && requests.enumerated().allSatisfy{$0.element.0 == .revision(c.mergeParents[$0.offset]) && $0.element.1 == .workingTree},"Historical parent→working route changed")
    }
    static func ownership(_ c:Prior.Context)async throws {
        let model=try Prior.unwrap(c.owner?.model,"Source Log missing"),ids=GitPathSet([c.normal,c.second,c.conflict,c.unknown]);c.forward=false
        c.preferences.set(1,forKey:"NumDiffWarning");c.warningGate=Prior.Gate<Bool>()
        try await c.select(ids);try c.activate();try await wait("held source warning"){c.warningGate?.entered==true}
        model.select([c.head]);c.warningGate?.finish(true);c.warningGate=nil
        try await wait("replacement cancels owner"){LogWindowModel.activeFileNavigationActivities==0}
        try require(c.plans.isEmpty,"Replacement delivered stale working operands")
        try await c.working();try await c.select(ids);c.warningGate=Prior.Gate<Bool>();try c.activate()
        try await wait("held preference receipt"){c.warningGate?.entered==true}
        c.preferences.set(true,forKey:"UseLibgit2");c.warningGate?.finish(true);c.warningGate=nil
        try await wait("changed backend cancels source"){LogWindowModel.activeFileNavigationActivities==0}
        try require(c.plans.isEmpty,"Changed backend revived old operand request")
        c.preferences.set(false,forKey:"UseLibgit2");try await c.select(ids);c.warningGate=Prior.Gate<Bool>();try c.activate()
        try await wait("held cancelled warning"){c.warningGate?.entered==true};c.warningGate?.finish(false);c.warningGate=nil
        try await wait("cancelled warning owner drained"){LogWindowModel.activeFileNavigationActivities==0}
        try require(c.plans.isEmpty,"Declined warning delivered operands")
        try await c.select(ids);c.warningGate=Prior.Gate<Bool>();try c.activate()
        try await wait("held closing owner"){c.warningGate?.entered==true};c.owner?.close();c.warningGate?.finish(true);c.warningGate=nil
        try await wait("closed owner comparison drained"){LogWindowModel.activeFileNavigationActivities==0}
        try require(c.plans.isEmpty,"Closed owner delivered stale operands")
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.logOperandHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let c=Prior.Context(base:URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL,git:URL(fileURLWithPath:CommandLine.arguments[2]))
        diagnosticContext=c;defer{diagnosticContext=nil}
        DialogGeometry.install(preferences:c.preferences);defer{DialogGeometry.install(preferences:.standard)}
        let mode=CommandLine.arguments[3]
        do {
            try await c.prepare()
            switch mode {case "operands":try await operands(c);case "rename":try await rename(c);case "historical":try await historical(c);case "ownership":try await ownership(c);default:throw Prior.Failure(description:"Unknown Log operand mode")}
            try await c.cleanup();print("PASS: Log working comparison operands "+mode)
        } catch {
            let failure=error
            do {try await c.cleanup()} catch {throw NSError(domain:"TurtleGit.LogWorkingOperands.Cleanup",code:1,userInfo:[NSLocalizedDescriptionKey:String(describing:failure)+"; cleanup: "+String(describing:error)])}
            throw failure
        }
    }
}
