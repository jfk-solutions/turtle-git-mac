// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func mergeToolComparisonQAOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));mergeToolComparisonQAOrder(mode,relativeTo:number)}
}
enum TwoFileMergeToolVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 { if ready(){return};try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Merge-tool comparison timeout at line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(views) }
    @MainActor static func verify()async throws {
        let originalOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hiddenOrder=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.mergeToolComparisonQAOrder(_:relativeTo:)))!
        method_exchangeImplementations(originalOrder,hiddenOrder);defer{method_exchangeImplementations(originalOrder,hiddenOrder)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.MergeToolComparison."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let base=root.appendingPathComponent("tool-base"),mine=root.appendingPathComponent("tool-mine"),output=root.appendingPathComponent("tool-output")
        let baseBytes=Data("base\nunchanged\n".utf8),mineBytes=Data("mine 🐢\nunchanged\n".utf8)
        try baseBytes.write(to:base);try mineBytes.write(to:mine)
        var owners:[FileComparisonWindowController]=[],replacementOwners:[MergeEditorReplacementOwner]=[]
        var emptyAnswer:CheckedContinuation<MergeEmptyResult,Never>?
        func cleanOwners()async throws {
            emptyAnswer?.resume(returning:.keep);emptyAnswer=nil
            for replacement in replacementOwners {replacement.current?.close()}
            for owner in owners {
                owner.model.cancelPaneSave()
                if let sheet=owner.window?.attachedSheet {owner.window?.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)}
                owner.model.error=nil;owner.close()
            }
            try await wait {owners.allSatisfy{!$0.model.mergeToolHasPendingWork && $0.window?.attachedSheet==nil && $0.window?.isVisible != true} && replacementOwners.allSatisfy{!$0.hasPendingRetiredWork && $0.current==nil}}
        }
        do {
        func invocation(_ more:[String])throws->MergeToolInvocation {
            try MergeToolInvocation.parse(arguments:["--merge-tool","--base",base.path,"--mine",mine.path]+more,currentDirectory:root.path)!
        }
        func owner(_ request:MergeToolInvocation)throws->FileComparisonWindowController {
            let value=FileComparisonWindowController(comparison:try WorkingFileComparison(base:request.base ?? base,destination:request.mine ?? mine),permissions:[],preferences:prefs,deferInitialLoad:true)
            owners.append(value);value.model.editorConfigEnabled=[true:false,false:false]
            try value.model.configureMergeTool(request)
            value.window!.alphaValue=0;value.window!.orderFront(nil);value.model.beginTransferredDocument();return value
        }
        let locked=try owner(invocation(["--readonly","--oneway","--line","2","--basename","Original Name","--minename","Changed Name","--basereflectedname","Original/real.txt","--minereflectedname","Changed/real.txt","--merged",output.path,"--saverequired"]))
        let read=locked.model
        try await wait { !read.busy && !read.filtering && read.document != nil }
        try await wait { locked.window?.contentView?.layoutSubtreeIfNeeded(); return read.activeFindText != nil }
        try require(read.activeFindText?.isEditable==false,"Readonly native editor remains writable")
        try require(read.onePaneActive && read.requestedSourceLine==2 && read.mergeToolReadOnly,"Source readonly/oneway/line configuration lost")
        try require(read.paneTitle(base:true)=="Original Name" && read.paneTitle(base:false)=="Changed Name" && read.paneHelp(base:false).contains("Changed/real.txt"),"Descriptive/reflected names lost")
        try require(read.document?.base.path==base.path && read.document?.destination.path==mine.path,"Names replaced filesystem input paths")
        let original=read.draftText(base:false)
        read.editingEnabled=true;read.updateDraft("forbidden\n",base:false);read.changeEncoding(.utf16LE,base:false);read.changeLineEnding(.crlf,base:false);read.setPatchEditing(true)
        var chooserCalls=0;read.chooseExportLocation={_,_,_ in chooserCalls+=1;return output}
        var forbiddenSave:Bool?;read.save {forbiddenSave=$0};read.saveAs(base:false);read.export(base:false)
        try require(read.draftText(base:false)==original && !read.canEdit(base:false) && !read.canTransfer && !read.editingEnabled && !read.canSavePaneAs && !read.dirty && forbiddenSave==false && chooserCalls==0 && !read.mergeToolSaved,"Readonly mutation/save bypass")
        try require(!FileManager.default.fileExists(atPath:output.path),"Readonly invocation created merged output")
        read.switchPaneMode(false);try await wait { !read.busy && !read.filtering && !read.onePaneActive }
        try require(read.mergeToolReadOnly && !read.canEdit(base:true) && !read.canEdit(base:false),"View switching removed immutable source policy")
        let blame=try owner(invocation(["--blame"]))
        try await wait { !blame.model.busy && !blame.model.filtering && blame.model.document != nil }
        try require(blame.model.mergeToolReadOnly && !blame.model.canEdit(base:false),"Blame invocation allowed edits")
        // A clean Mine still needs Save when requested; /merged never overwrites either input.
        let result=try owner(invocation(["--merged",output.path,"--saverequired"])),model=result.model
        try await wait { !model.busy && !model.filtering && model.document != nil }
        try require(model.dirty && model.activeDirty && model.mergeToolSaveRequired && !model.mergeToolSaved,"Save-required clean result did not participate in close policy")
        try require(MergeEditorPreferences.load(from:prefs).autoAdd,"Clean required-output fixture lost default AutoAdd=true")
        var completed:Bool?;model.saveAll {completed=$0}
        do {try await wait { completed != nil && !model.mergeToolHasPendingWork }}
        catch {
            let saved=try? Data(contentsOf:output),sheet=result.window?.attachedSheet
            print("Required output timeout: completed=\(String(describing:completed)) bytes=\(saved?.count ?? -1) prefix=\(saved.map{Array($0.prefix(48))} ?? []) pendingAdd=\(model.pendingNewOutputAdd != nil) busy=\(model.busy) dirty=\(model.dirty) pending=\(model.mergeToolHasPendingWork) sheet=\(sheet.map{String(describing:type(of:$0))+":"+$0.title} ?? "nil") error=\(String((model.error ?? "").prefix(400)))")
            throw error
        }
        try require(completed==true && model.mergeToolSaved && !model.dirty && !model.mergeToolSaveRequired && (try Data(contentsOf:output))==mineBytes,"Unchanged required output save failed")
        try require(model.document?.destination.path==mine.path && (try Data(contentsOf:mine))==mineBytes && (try Data(contentsOf:base))==baseBytes,"Merged output rebound or overwrote an input")
        model.updateDraft("edited result\n",base:false);model.rebuildAlignment();try await wait { !model.filtering }
        try require(!model.mergeToolSaved && model.dirty,"Unsaved later edit retained successful-output exit status")
        completed=nil;model.save {completed=$0};try await wait {completed != nil && !model.mergeToolHasPendingWork}
        try require(completed==true && model.mergeToolSaved && (try Data(contentsOf:output))==Data("edited result\n".utf8) && (try Data(contentsOf:mine))==mineBytes,"Later output save wrote Mine or lost draft")
        // Existing output is snapshotted; an external replacement is not silently overwritten.
        let protected=root.appendingPathComponent("tool-existing");try Data("existing\n".utf8).write(to:protected)
        let held=try owner(invocation(["--merged",protected.path,"--saverequired"])),heldModel=held.model
        try await wait {!heldModel.busy && !heldModel.filtering && heldModel.document != nil}
        try Data("external\n".utf8).write(to:protected,options:.atomic)
        var failed:Bool?;heldModel.saveAll {failed=$0};try await wait {failed != nil}
        try require(failed==false && heldModel.mergeToolSaveRequired && !heldModel.mergeToolSaved && (try Data(contentsOf:protected))==Data("external\n".utf8),"Externally replaced output was overwritten")
        heldModel.error=nil;try await wait {held.window?.attachedSheet==nil}
        heldModel.load(discardingDraft:true);try await wait {!heldModel.busy && !heldModel.filtering}
        failed=nil;heldModel.saveAll {failed=$0};try await wait {failed != nil && !heldModel.mergeToolHasPendingWork}
        try require(failed==true && heldModel.mergeToolSaved && (try Data(contentsOf:protected))==mineBytes,"Explicit Reload did not acknowledge output replacement")
        // Named missing inputs are empty source panes, but a later appearance
        // cannot silently replace the source snapshot behind an edited output.
        let missingBase=root.appendingPathComponent("tool-missing-base"),missingMine=root.appendingPathComponent("tool-missing-mine"),missingOutput=root.appendingPathComponent("tool-missing-output")
        let missingRequest=try MergeToolInvocation.parse(arguments:["--merge-tool","--base",missingBase.path,"--mine",missingMine.path,"--merged",missingOutput.path,"--saverequired"],currentDirectory:root.path)!
        let missing=try owner(missingRequest),missingModel=missing.model
        try await wait {!missingModel.busy && !missingModel.filtering && missingModel.document != nil}
        try await wait { missing.window?.contentView?.layoutSubtreeIfNeeded(); return missingModel.activeFindText != nil }
        try require(missingModel.activeFindText?.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty==true && missingModel.paneTitle(base:true).contains("(not found)") && missingModel.paneTitle(base:false).contains("(not found)"),"Missing source panes lack native empty text/not-found indicators")
        try require(missingModel.document?.base.isDeleted==true && missingModel.document?.destination.isDeleted==true && missingModel.draftText(base:true).isEmpty && missingModel.draftText(base:false).isEmpty,"Missing source inputs did not load as empty panes")
        missingModel.updateDraft("created result\n",base:false);missingModel.rebuildAlignment();try await wait {!missingModel.filtering}
        try Data("appeared externally\n".utf8).write(to:missingMine)
        var appeared:Bool?;missingModel.saveAll {appeared=$0};try await wait {appeared != nil}
        try require(appeared==false && !missingModel.mergeToolSaved && !FileManager.default.fileExists(atPath:missingOutput.path) && (try Data(contentsOf:missingMine))==Data("appeared externally\n".utf8),"Late missing-input appearance was accepted or overwritten")
        missingModel.error=nil;try await wait {missing.window?.attachedSheet==nil}
        try FileManager.default.removeItem(at:missingMine)
        missingModel.load(discardingDraft:true);try await wait {!missingModel.busy && !missingModel.filtering}
        missingModel.updateDraft("created result\n",base:false);missingModel.rebuildAlignment();try await wait {!missingModel.filtering}
        appeared=nil;missingModel.saveAll {appeared=$0};try await wait {appeared != nil && !missingModel.mergeToolHasPendingWork}
        try require(appeared==true && missingModel.mergeToolSaved && !missingModel.dirty && missingModel.document?.destination.path==missingMine.path && (try Data(contentsOf:missingOutput))==Data("created result\n".utf8) && !FileManager.default.fileExists(atPath:missingBase.path) && !FileManager.default.fileExists(atPath:missingMine.path),"Absent input result did not save cleanly to separate merged output")
        // A held Save choice remains owned after close and cannot publish afterward.
        let cancelled=root.appendingPathComponent("tool-cancelled"),closing=try owner(invocation(["--merged",cancelled.path,"--saverequired"]))
        try await wait {!closing.model.busy && !closing.model.filtering && closing.model.document != nil}
        closing.model.updateDraft("",base:false);closing.model.rebuildAlignment();try await wait {!closing.model.filtering}
        var closedResult:Bool?
        closing.model.chooseEmptyResult={_ in await withCheckedContinuation {emptyAnswer=$0}}
        closing.model.saveAll {closedResult=$0};try await wait {emptyAnswer != nil}
        closing.close();try require(closing.model.mergeToolHasPendingWork,"Closed owner lost held output-work accounting")
        emptyAnswer?.resume(returning:.keep);emptyAnswer=nil
        try await wait {closedResult != nil && !closing.model.mergeToolHasPendingWork}
        try require(closedResult==false && !FileManager.default.fileExists(atPath:cancelled.path) && !closing.model.mergeToolSaved,"Retired output callback wrote a result")
        // File/Open adopts the actual current controller before first load.
        // A rejected policy leaves the old owner/window untouched; accepted
        // replacement keeps frame-wide readonly/view policy but resets output,
        // descriptive labels, save requirement and initial line intent.
        let replacementMine=root.appendingPathComponent("tool-open-mine")
        try Data("newly opened file\n".utf8).write(to:replacementMine)
        let oldWindow=locked.window!,oldOutput=try Data(contentsOf:output)
        var replacementCloses=0,publishedEditor:NSWindowController=locked,adoptions=0,rejectReplacement=true
        let replacementOwner=MergeEditorReplacementOwner(onClosed:{replacementCloses+=1});replacementOwners.append(replacementOwner)
        defer {replacementOwner.current?.close()}
        locked.sharedReplacementOwner=replacementOwner
        replacementOwner.configureBeforeAdopt={next in
            if rejectReplacement {throw Failure(description:"Injected policy rejection")}
            if let pair=next as? FileComparisonWindowController {
                pair.model.editorConfigEnabled=[true:false,false:false]
                pair.model.configureMergeToolReplacement(readOnly:read.mergeToolReadOnly,oneWay:read.onePaneMode,reflectedBase:read.mergeToolReflectedName(base:true),reflectedMine:read.mergeToolReflectedName(base:false))
            } else if let patch=next as? WorkingTreePatchWindowController { patch.model.mergeToolReadOnly=true }
            else {throw Failure(description:"Unexpected replacement editor")}
        }
        replacementOwner.onAdopt={next,previous in
            let prior=publishedEditor;adoptions+=1;publishedEditor=next
            // Runs before a comparison replacement's first deferred file read.
            if previous !== prior || (next as? FileComparisonWindowController)?.model.document != nil {adoptions = -100}
        }
        do {
            try locked.replaceEditor(.compare(base:base,mine:replacementMine,single:false),permissions:[])
            throw Failure(description:"Rejected replacement was adopted")
        } catch let error as Failure where error.description=="Injected policy rejection" { }
        try require(locked.window === oldWindow && replacementOwner.current==nil && publishedEditor === locked && adoptions==0,"Failed pre-adopt policy detached original editor")
        rejectReplacement=false;read.rebuildAlignment()
        // Inject already-owned work after Open acceptance; the controller's
        // ordinary Open entry correctly refuses a newly requested busy action.
        try replacementOwner.replace(.compare(base:base,mine:replacementMine,single:false),permissions:[],preferences:prefs,window:oldWindow,previous:locked)
        guard let opened=replacementOwner.current as? FileComparisonWindowController else {throw Failure(description:"Replacement owner did not publish its current editor")}
        owners.append(opened)
        try require(publishedEditor === opened && opened.window === oldWindow && locked.window==nil && adoptions==1 && replacementOwner.hasPendingRetiredWork,"Adoption/current publication or retired-operation ownership failed")
        try await wait {!opened.model.busy && !opened.model.filtering && opened.model.document != nil && !replacementOwner.hasPendingRetiredWork}
        try require(opened.model.document?.destination.path==replacementMine.path && opened.model.mergeToolReadOnly && opened.model.onePaneMode==read.onePaneMode && opened.model.mergeToolInvocation==nil && opened.model.mergeToolDescriptiveName(base:false)==nil && opened.model.requestedSourceLine==nil && !opened.model.mergeToolSaveRequired,"Replacement applied stale input/output/label/line policy")
        try require(opened.model.mergeToolReflectedName(base:false)=="Changed/real.txt" && !opened.model.canEdit(base:false) && !opened.model.canSavePaneAs && (try Data(contentsOf:output))==oldOutput,"Replacement lost readonly/reflected metadata or touched old output")
        // Patch policy must run before preparation builds its embedded editor,
        // not only after the already-loaded review has been adopted.
        var patchConfiguredBeforeLoad=false
        replacementOwner.makePatchWorkflow={file,target,bytes,grants,defaults in
            ReviewPatchWorkflow(file:file,target:target,preferred:target,grants:grants,executable:URL(fileURLWithPath:CommandLine.arguments[2]),preferences:defaults,clipboardBytes:bytes)
        }
        replacementOwner.configurePatchWorkflow={workflow in
            patchConfiguredBeforeLoad = !workflow.loading
            workflow.configureReview={review in review.mergeToolReadOnly=true;review.mergeToolOriginalLabel="Original source";review.mergeToolPatchedLabel="Patched source"}
        }
        let patchBytes=Data("--- a/tool-base\n+++ b/tool-base\n@@ -1,2 +1,2 @@\n-base\n+patched\n unchanged\n".utf8)
        try opened.replaceEditor(.patch(file:nil,directory:root,clipboard:patchBytes),permissions:[])
        try await wait {replacementOwner.current is WorkingTreePatchWindowController && !replacementOwner.hasPendingRetiredWork}
        guard let patchReplacement=replacementOwner.current as? WorkingTreePatchWindowController else {throw Failure(description:"Patch replacement missing")}
        try await wait {patchReplacement.model.editor != nil && !patchReplacement.activeOperation}
        try require(patchConfiguredBeforeLoad && adoptions==2 && publishedEditor === patchReplacement && patchReplacement.window === oldWindow && opened.window==nil && patchReplacement.model.mergeToolReadOnly && patchReplacement.model.editor?.mergeToolReadOnly==true && patchReplacement.model.editor?.canEdit(base:false)==false,"Patch pre-load readonly policy/current-controller adoption lost")
        let patchChild=patchReplacement.model.editor!
        patchReplacement.close();try await wait {!replacementOwner.hasPendingRetiredWork && !patchReplacement.activeOperation && !patchChild.mergeToolHasPendingWork}
        try require(replacementCloses==1 && replacementOwner.current==nil,"Replacement completion did not close current owner once")
        try await cleanOwners()
        try require((try Data(contentsOf:base))==baseBytes && (try Data(contentsOf:mine))==mineBytes,"Standalone source inputs changed")
        print("PASS: Merge-tool two-file labels/reflected metadata, source one-way/line, immutable readonly/blame, clean Save-required output, independent Mine, later output edits, changed-target refusal/Reload, held-close cancellation and owned operation drain")
        } catch {try? await cleanOwners();throw error}
    }
}
