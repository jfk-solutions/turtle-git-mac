import AppKit
import Darwin
import TurtleGitCore

struct PatchRecoveryVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(description:message)}}
    @MainActor static func descendants(_ view:NSView?)->[NSView] {
        guard let view else{return []};return [view]+view.subviews.flatMap{descendants($0)}
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Patch recovery QA"),("user.email","recovery@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        let paths=["a.txt","b.txt","c.txt","d.txt"],base="head\nold\nkeep\ntail\n",patched="head\nnew\nkeep\ntail\n"
        for path in paths {try Data(base.utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(paths);_=try await repo.commit(message:"base")
        for path in paths {try Data(patched.utf8).write(to:root.appendingPathComponent(path))}
        let diff=try await repo.run(["diff","--full-index","--"]).stdout
        let patch=Data(String(decoding:diff,as:UTF8.self).components(separatedBy:"diff --git ").map {block in
            block.hasPrefix("a/c.txt b/c.txt\n") ? block.components(separatedBy:"\n").filter{!$0.hasPrefix("index ")}.joined(separator:"\n") : block
        }.joined(separator:"diff --git ").utf8)
        let currentB="head\ncurrent B 🐢\nkeep\ntail\n",currentC="head\ncurrent C\nkeep\ntail\n",currentD="head\nold\nkeep\nlocal tail\n"
        for (name,text) in [("a.txt",base),("b.txt",currentB),("c.txt",currentC),("d.txt",currentD)] {try Data(text.utf8).write(to:root.appendingPathComponent(name))}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let input=root.appendingPathComponent("input.diff");try patch.write(to:input)
        let suite="TurtleGit.PatchRecovery."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs);prefs.set(true,forKey:"TurtleGitMerge.UseUTF8")
        let owner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Recorded-base patch recovery",preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.orderFront(nil)
        @MainActor func state()->String {
            let conflict=model.conflictEditor,native=(window as! TextConflictNSWindow).mergedText,sheet=window.attachedSheet
            let actions=descendants(sheet?.contentView).compactMap{$0 as? NSButton}.map{"\($0.title):enabled=\($0.isEnabled)"}
            var fields:[String]=[]
            fields.append("parentBusy=\(model.busy),draftChoice=\(model.draftDecisionPending),dirty=\(model.dirty),save=\(model.canSaveDraft),retired=\(model.retired)")
            fields.append("conflict=\(conflict.map{String(describing:ObjectIdentifier($0))} ?? "nil"),childBusy=\(conflict?.busy == true),preparing=\(conflict?.preparing == true)")
            fields.append("nativeReady=\(conflict?.nativeEditorReady == true),choice=\(conflict?.canChooseConflict == true),unresolved=\(conflict?.hasUnresolvedConflicts == true)")
            let serialized=native.flatMap{view in conflict?.alignedResultProjection?.serializedRange(displayRange:view.selectedRange())}
            fields.append("serializedNative=\(String(describing:serialized)),selectedConflict=\(conflict?.selectedConflict ?? -1),firstConflict=\(String(describing:conflict?.blocks.first?.range))")
            fields.append("selectionRequest=\(String(describing:conflict?.selectionRequest)),result=\(String(reflecting:conflict?.result))")
            fields.append("native=\(native.map{String(describing:ObjectIdentifier($0))} ?? "nil"),range=\(String(describing:native?.selectedRange())),history=\((native as? MergeResultHistoryProviding)?.historyAllowed == true)")
            fields.append("responder=\(String(describing:window.firstResponder.map{type(of:$0)})),sheet=\(sheet.map{String(describing:type(of:$0))} ?? "nil"),actions=\(actions)")
            fields.append("notice=\(model.notice),childError=\(String(reflecting:conflict?.error))")
            return fields.joined(separator:",")
        }
        @MainActor func trace(_ phase:String) {print("PATCH RECOVERY "+phase+" "+state());fflush(stdout)}
        @MainActor func wait(_ phase:String,_ predicate:()->Bool) async throws {
            trace("BEGIN "+phase)
            for _ in 0..<1500 {window.contentView?.layoutSubtreeIfNeeded();if predicate(){trace("END "+phase);return};try await Task.sleep(nanoseconds:10_000_000)}
            throw Failure(description:"Patch recovery timeout "+phase+" "+state())
        }
        @MainActor func currentResult(_ conflict:TextConflictWindowModel)->NSTextView? {
            guard model.conflictEditor === conflict,conflict.nativeEditorReady,conflict.sourceToolsAllowed,
                  conflict.selectionRequest==nil,!conflict.busy,!conflict.preparing,!conflict.formatPending,
                  window.attachedSheet==nil,let native=(window as! TextConflictNSWindow).mergedText,
                  native.window === window,!native.isHiddenOrHasHiddenAncestor,
                  (native as? MergeFindProviding)?.mergeFindAllowed==true,
                  (native as? MergeResultHistoryProviding)?.historyAllowed==true else{return nil}
            return native
        }
        @MainActor func admitChoice(_ conflict:TextConflictWindowModel,_ phase:String) async throws {
            try await wait(phase+" current native/history projection"){currentResult(conflict) != nil}
            conflict.continueResolving()
            try await wait(phase+" current native conflict caret"){
                guard let native=currentResult(conflict),let expected=conflict.blocks.first,
                      window.firstResponder === native,conflict.selectedConflict==0,conflict.canChooseConflict else{return false}
                // Continue Resolving installs a block highlight separately from
                // the ordinary native selection, which may collapse to its
                // caret. Test the current caret's actual serialized conflict.
                let display=native.selectedRange()
                let serialized: NSRange?
                if (native as? MergePaneInputTextView)?.paneInputCells != nil {
                    serialized=conflict.alignedResultProjection?.serializedRange(displayRange:display)
                } else {serialized=display}
                guard let serialized else{return false}
                return serialized.length==0 ? NSLocationInRange(serialized.location,expected.range):NSIntersectionRange(serialized,expected.range).length>0
            }
        }
        let sheetObserver=NotificationCenter.default.addObserver(forName:NSWindow.willBeginSheetNotification,object:window,queue:.main){_ in
            MainActor.assumeIsolated{trace("NATIVE SHEET WILL BEGIN");DispatchQueue.main.async{trace("NATIVE SHEET PRESENTATION")}}
        }
        defer{NotificationCenter.default.removeObserver(sheetObserver)}
        try await wait("initial review"){!model.busy && model.editor?.filtering==false}
        let files=model.review!.files,b=files.first{$0.path=="b.txt"}!,c=files.first{$0.path=="c.txt"}!
        try require(model.fileState(files.first{$0.path=="a.txt"}!).isEmpty && model.fileState(b)=="conflict" && model.fileState(c)=="error","Initial ready/conflict/error rows")
        var parentBlocked=false;model.parentActive={parentBlocked}
        model.highlightFiles([b.id]);model.previewFiles([b.id],generation:model.fileListGeneration)
        parentBlocked=true;model.updateParentState()
        try await wait("blocked embedded admission"){!model.busy && model.conflictEditor != nil}
        let pending=model.conflictEditor!
        try require(pending.document==nil && !pending.busy && !pending.sourceToolsAllowed && !pending.canChooseConflict,"Blocked parent prematurely loaded or enabled its embedded conflict")
        pending.load();pending.choose(.theirs)
        try require(pending.document==nil && !pending.busy,"Blocked embedded appearance/action admitted its deferred read")
        // A different owner retired before admission must never start its child
        // when the former parent gate later clears.
        let lateOwner=WorkingTreePatchWindowController(repository:repo,access:nil,fileAccess:nil,bytes:patch,title:"Retired pending patch recovery",preferences:prefs),late=lateOwner.model
        defer{lateOwner.close()};lateOwner.window?.alphaValue=0;lateOwner.window?.setFrameOrigin(.init(x:-24000,y:-24000));lateOwner.window?.orderFront(nil)
        var lateBlocked=false;late.parentActive={lateBlocked}
        try await wait("late initial review"){!late.busy && late.editor?.filtering==false}
        let lateFile=late.review!.files.first{$0.path=="b.txt"}!
        late.previewFiles([lateFile.id],generation:late.fileListGeneration);lateBlocked=true;late.updateParentState()
        try await wait("late blocked embedded admission"){!late.busy && late.conflictEditor != nil}
        let retiredPending=late.conflictEditor!
        try require(retiredPending.document==nil && !retiredPending.sourceToolsAllowed,"Late-owner fixture did not retain a pending conflict")
        lateOwner.close();lateBlocked=false;late.updateParentState();retiredPending.load()
        try await wait("late retired owner drain"){!lateOwner.hasPendingWork && lateOwner.window?.isVisible != true && lateOwner.window?.sheetParent==nil && lateOwner.window?.attachedSheet==nil}
        try require(late.retired && retiredPending.retired && retiredPending.document==nil && !retiredPending.busy,"Retired pending child loaded or escaped ownership")
        parentBlocked=false;model.updateParentState()
        try await wait("first embedded editor"){!model.busy && model.conflictEditor?.sourceToolsAllowed==true && (window as! TextConflictNSWindow).mergedText != nil}
        var conflict=model.conflictEditor!
        try require(conflict === pending,"Clearing parent admission replaced the accepted conflict owner")
        try require(conflict.document?.base==base && conflict.document?.mine==currentB && conflict.document?.theirs==patched && conflict.blocks.count==1,"Recorded/current/patched three-pane contents")
        try require(owner.editorToolbar != nil && conflict.nativeToolbarInstalled && !conflict.repositoryResolutionAllowed,"Embedded native toolbar and no index-resolution action")
        try require(try Data(contentsOf:root.appendingPathComponent("b.txt"))==Data(currentB.utf8),"Preview wrote working contents")
        try await PatchFilePanelVerification.capture(window,name:"patch-recovery")
        try await admitChoice(conflict,"initial Mine choice")
        conflict.choose(.mine);try require(model.dirty && conflict.result==currentB,"Mine block choice")
        let undo=MergeCommandMenusVerification.event("z",code:6,flags:.command,window:window)
        try require(window.performKeyEquivalent(with:undo) && conflict.hasUnresolvedConflicts,"Embedded Command-Z")
        let redo=MergeCommandMenusVerification.event("z",code:6,flags:[.command,.shift],window:window)
        try require(window.performKeyEquivalent(with:redo) && conflict.result==currentB,"Embedded Redo")
        _=window.performKeyEquivalent(with:undo)
        var unresolvedQuestions=0
        conflict.confirmUnresolvedSave={_ in unresolvedQuestions += 1;trace("CHOICE unresolved Save Cancel");return false}
        trace("BEGIN unresolved Save Cancel")
        let cancelled=await withCheckedContinuation {continuation in model.saveDraft {value in trace("CALLBACK unresolved Save Cancel value=\(value)");continuation.resume(returning:value)}}
        trace("END unresolved Save Cancel")
        try require(!cancelled && conflict.hasUnresolvedConflicts && unresolvedQuestions==1,"Unresolved Save Cancel did not ask exactly once: "+state())
        try await admitChoice(conflict,"after Undo Theirs choice");try require(conflict.canChooseConflict,"Current conflict choice unavailable after Undo");conflict.choose(.theirs);model.highlightFiles([c.id]);try require(model.dirty && model.highlightedFiles==[b.id],"Dirty conflict selection changed: dirty=\(model.dirty), selected=\(model.highlightedFiles), result=\(conflict.result), blocks=\(conflict.blocks.count)")
        model.chooseDraft={trace("CHOICE dirty Cancel");return .cancel};trace("BEGIN dirty Cancel")
        try require(await model.resolveDraft()==false && model.dirty,"Dirty close Cancel");trace("END dirty Cancel")
        model.chooseDraft={trace("CHOICE dirty Discard");return .discard};trace("BEGIN dirty Discard")
        try require(await model.resolveDraft(),"Dirty discard refused");trace("END dirty Discard")
        try await wait("regenerated embedded owner"){model.conflictEditor?.sourceToolsAllowed==true}
        try require(conflict.retired && model.conflictEditor !== conflict,"Discard retained old conflict owner")
        conflict=model.conflictEditor!;try require(conflict.hasUnresolvedConflicts,"Discard lost regenerated conflict")
        try await admitChoice(conflict,"regenerated Theirs choice")
        conflict.choose(.theirs)
        try require(conflict.result==patched && !conflict.hasUnresolvedConflicts,"Regenerated Theirs choice did not resolve exact patched result: "+state())
        trace("BEGIN resolved Save")
        let saved=await withCheckedContinuation {continuation in model.saveDraft {value in trace("CALLBACK resolved Save value=\(value)");continuation.resume(returning:value)}}
        trace("END resolved Save")
        try require(saved && conflict.patchResultCompleted && !model.dirty && !model.canSaveDraft && !conflict.canUndo,"Completed conflict baseline/history/gates")
        try require(try Data(contentsOf:root.appendingPathComponent("b.txt"))==Data(patched.utf8),"Resolved Save bytes")
        model.patchFiles(Set(files.map(\.id)),generation:model.fileListGeneration)
        try await wait("Patch all completion"){!model.busy && !model.conflictOperationActive}
        try require(model.appliedPaths.count==3 && model.fileState(c)=="error","Patch all clean-recovery/error continuation")
        try require(try Data(contentsOf:root.appendingPathComponent("d.txt"))==Data("head\nnew\nkeep\nlocal tail\n".utf8),"Clean recovery lost independent context edit")
        try require(try Data(contentsOf:root.appendingPathComponent("a.txt"))==Data(patched.utf8) && Data(contentsOf:root.appendingPathComponent("c.txt"))==Data(currentC.utf8),"Patch all normal/error bytes")
        model.previewTab=1;try await PatchFilePanelVerification.capture(window,name:"patch-recovery-results")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:input)==patch,"Recovery changed HEAD/index/source patch")
        owner.close();conflict.choose(.mine);try require(model.retired && conflict.retired,"Retired recovery owner")
        print("PASS: initial ready/conflict/error states, recorded-base embedded three-pane and native toolbar, side choices/Undo/Redo, unresolved Save Cancel, dirty Cancel/discard/regeneration, exact resolved Save and completed gates, clean Patch all recovery with independent edit, missing-base error continuation, unchanged HEAD/index/source patch and retirement; owned window closed")
    }
}
