import AppKit
import Darwin
import TurtleGitCore

struct MergePatchOpenNativeVerification {
    struct Failure:Error,CustomStringConvertible {let message:String;var description:String {message}}
    @MainActor static var phase="initial patch",diagnostics:()->String={""}
    @MainActor static func wait(_ yes:()->Bool,line:UInt=#line)async throws {
        for _ in 0..<2000 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Patch Open timeout line \(line); phase=\(phase); \(diagnostics())")
    }
    @MainActor static func begin(_ name:String,_ state:@escaping()->String={""}) {phase=name;diagnostics=state;print("Patch Open phase: "+name+"; "+state());fflush(stdout)}
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitPatchOpen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.PatchOpen." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        let board=NSPasteboard(name:.init("TurtleGit.PatchOpen."+UUID().uuidString))
        defer {board.releaseGlobally();prefs.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:folder)}
        func makeWorkflow(_ window:NSWindow,_ grants:[RepositoryAccessLease],_ defaults:UserDefaults)->MergeEditorOpenWorkflow {
            let value=MergeEditorOpenWorkflow(window:window,permissions:grants,preferences:defaults)
            value.makeOpener={defaults,permissions in let chooser=MergeOpenWindowController(preferences:defaults,pasteboard:board,permissions:permissions);chooser.window?.alphaValue=0;return chooser}
            return value
        }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), patchFile = folder.appendingPathComponent("change.patch")
        let baseBytes = Data("head\nbase\ntail\n".utf8), mineBytes = Data("head\nmine\ntail\n".utf8)
        try baseBytes.write(to: base); try mineBytes.write(to: mine)
        let patch = Data("diff --git a/base.cpp b/base.cpp\n--- a/base.cpp\n+++ b/base.cpp\n@@ -1,3 +1,3 @@\n head\n-base\n+patched\n tail\n".utf8)
        try patch.write(to: patchFile)
        let root = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        let window=root.window!
        MergeEditorOpenNativeVerification.hidden(window);let frame=window.frame
        root.makeEditorOpenWorkflow=makeWorkflow
        let owner = MergeEditorReplacementOwner(onClosed: {})
        root.replacementOwner=owner
        owner.makePatchWorkflow={file,target,bytes,grants,defaults in ReviewPatchWorkflow(file:file,target:target,grants:grants,executable:try GitRuntime.executable(),preferences:defaults,clipboardBytes:bytes,pasteboard:board)}
        defer { owner.pendingPatch?.cancel(); (owner.current ?? root).close() }
        root.model.load(); try await TwoPaneEngineVerification.settled(root.model)
        let original=root.model.document
        let state={
            "rootOwns=\(root.window === window) current=\(owner.current.map{String(describing:type(of:$0))} ?? "nil") parentSheet=\(String(describing:window.attachedSheet)) prepSheetParent=\(String(describing:owner.pendingPatch?.window?.sheetParent)) pending=\(owner.pendingPatch?.hasPendingWork==true) loading=\(owner.pendingPatch?.loading==true) error=\(String(reflecting:owner.pendingPatch?.error)) status=\(owner.pendingPatch?.status ?? "none") loads=\(ReviewPatchWorkflow.activeLoads) releases=\(ReviewPatchWorkflow.activeReleases) openChoices=\(MergeOpenWindowController.activeChoices) transactions=\(MergeEditorOpenWorkflow.activeTransactions)"
        }
        begin("invalid patch preserves original",state)
        let broken = folder.appendingPathComponent("bad.patch"); try Data("not a patch\n".utf8).write(to: broken)
        try root.replaceEditor(.patch(file: broken, directory: folder, clipboard: nil), permissions: [])
        try await wait { owner.pendingPatch?.error != nil }
        try require(root.window === window && root.model.document?.base.bytes == original?.base.bytes && owner.current == nil, "Invalid patch retired original editor")
        owner.pendingPatch?.cancel(); try await wait { owner.pendingPatch == nil }

        begin("owned Git preparation cancellation",state)
        let helper = folder.appendingPathComponent("held-git"), ready = folder.appendingPathComponent("ready")
        try Data("#!/bin/sh\nfor argument in \"$@\"; do\nif [ \"$argument\" = --is-inside-work-tree ]; then : > \"$TG_PATCH_READY\"; /bin/sleep 30; break; fi\ndone\nexec \"$TG_PATCH_GIT\" \"$@\"\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_PATCH_READY", ready.path, 1); setenv("TG_PATCH_GIT", try GitRuntime.executable().path, 1)
        defer { unsetenv("TG_PATCH_READY"); unsetenv("TG_PATCH_GIT") }
        owner.makePatchWorkflow = { file, target, bytes, grants, defaults in ReviewPatchWorkflow(file: file, target: target, grants: grants, executable: helper, preferences:defaults,clipboardBytes:bytes,pasteboard:board) }
        try root.replaceEditor(.patch(file: patchFile, directory: folder, clipboard: nil), permissions: [])
        try await wait { FileManager.default.fileExists(atPath: ready.path) }
        try require(root.window === window && owner.current == nil && !root.windowShouldClose(window), "Pending patch did not preserve/guard original editor")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Pending patch allowed Quit")
        owner.pendingPatch?.cancel()
        try await wait { owner.pendingPatch == nil && ReviewPatchWorkflow.activeLoads == 0 }
        try require(root.window === window, "Canceled preparation replaced original")
        let auxiliaryScopes=Scopes(),auxiliaryURL=folder.appendingPathComponent("auxiliary-metadata",isDirectory:true)
        try FileManager.default.createDirectory(at:auxiliaryURL,withIntermediateDirectories:true)
        var auxiliary:RepositoryAccessLease?=RepositoryAccessLease(url:auxiliaryURL,provider:auxiliaryScopes)
        weak var auxiliaryWitness=auxiliary
        weak var preparationWitness:ReviewPatchWorkflow?
        owner.makePatchWorkflow={file,target,bytes,grants,defaults in
            let retained=grants+[auxiliary].compactMap{$0};auxiliary=nil
            let workflow=ReviewPatchWorkflow(file:file,target:target,grants:retained,executable:try GitRuntime.executable(),preferences:defaults,clipboardBytes:bytes,pasteboard:board)
            preparationWitness=workflow;return workflow
        }
        var preparedEnd:(NSWindow,NSWindow)?,endCalls=0
        owner.configurePatchWorkflow={workflow in
            workflow.presentPreparedSheetEnd={parent,sheet in endCalls+=1;preparedEnd=(parent,sheet)}
        }
        begin("checked review awaits actual preparation sheet detach",state)
        root.openMergeDocument(nil)
        guard let open = root.editorOpenWorkflow?.opener else { throw Failure(message: "Missing File/Open") }
        open.setMode(.applyUnifiedDiff); open.diff.stringValue = patchFile.path; open.directory.stringValue = folder.path; open.accept()
        try await wait{preparedEnd != nil}
        let (preparationParent,preparationSheet)=preparedEnd!
        try require(endCalls==1 && preparationParent === window && window.attachedSheet === preparationSheet && preparationSheet.sheetParent === window && owner.current==nil && root.window === window && owner.pendingPatch?.hasPendingWork==true && ReviewPatchWorkflow.activeLoads==1,"Checked patch adopted or released work before native preparation detach: "+state())
        try require(!root.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held preparation sheet lost Close/Quit ownership")
        window.endSheet(preparationSheet);preparationSheet.orderOut(nil)
        try await wait{owner.current is WorkingTreePatchWindowController && owner.pendingPatch==nil && preparationSheet.sheetParent==nil && window.attachedSheet==nil}
        begin("accepted review outlives preparation and owns auxiliary role",{"preparationAlive=\(preparationWitness != nil) auxiliaryAlive=\(auxiliaryWitness != nil) scopes=\(auxiliaryScopes.starts)/\(auxiliaryScopes.stops); "+state()})
        try await wait{preparationWitness==nil}
        do {
        guard let review = owner.current as? WorkingTreePatchWindowController else { throw Failure(message: "Missing adopted Review/Apply") }
        try require(review.window === window && root.window == nil && window.frame == frame && window.delegate === review, "Patch adoption changed native window/frame/delegate")
        try require(review.model.review?.files.count == 1 && !review.model.busy, "Patch adopted before checked model was ready")
        try require(auxiliaryWitness?.url==auxiliaryURL && auxiliaryWitness?.contains(folder)==false && auxiliaryWitness?.contains(patchFile)==false,"Auxiliary witness accidentally duplicated target/file authority")
        try require(auxiliary==nil && auxiliaryWitness != nil && auxiliaryScopes.starts==1 && auxiliaryScopes.stops==0 && review.model.openPermissions.contains{$0 === auxiliaryWitness},"Accepted review lost auxiliary grant after preparation retired")
        begin("accepted patch returns to text",state)
        var forwardedAuxiliary=false
        review.makeEditorOpenWorkflow={window,permissions,defaults in
            forwardedAuxiliary=permissions.contains{$0 === auxiliaryWitness}
            return makeWorkflow(window,permissions,defaults)
        }
        review.openMergeDocument(nil)
        try require(forwardedAuxiliary && auxiliaryScopes.stops==0,"Actual next Open omitted the accepted auxiliary grant")
        guard let returnOpen = review.editorOpenWorkflow?.opener else { throw Failure(message: "Patch viewer could not reopen text comparison") }
        returnOpen.setMode(.merging); returnOpen.base.stringValue = base.path; returnOpen.mine.stringValue = mine.path; returnOpen.accept()
        try await wait {owner.current is FileComparisonWindowController}
        guard let pair = owner.current as? FileComparisonWindowController else { throw Failure(message: "Patch→text transition failed") }
        try await TwoPaneEngineVerification.settled(pair.model)
        try require(pair.window === window && review.window == nil && window.frame == frame, "Return to text lost native window geometry")
        try require(auxiliaryWitness != nil && auxiliaryScopes.stops==0 && pair.model.openPermissions.contains{$0 === auxiliaryWitness},"Accepted Open replacement failed to retain auxiliary authority")
        try require(try Data(contentsOf: base) == baseBytes && Data(contentsOf: mine) == mineBytes && Data(contentsOf: patchFile) == patch, "Preparation/replacement mutated input files")
        pair.close();try await wait{owner.current==nil && !owner.hasPendingRetiredWork && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 && MergeEditorOpenWorkflow.activeTransactions==0}
        }
        // Geometry assertions intentionally retained this closed native window.
        // Release its test-owned hosted model only after every actual owner drains.
        window.contentViewController=nil
        begin("accepted auxiliary role releases after final owner drain",{"starts=\(auxiliaryScopes.starts) stops=\(auxiliaryScopes.stops) leaseAlive=\(auxiliaryWitness != nil) preparationAlive=\(preparationWitness != nil) registryPending=\(owner.hasPendingRetiredWork)"})
        try await wait{auxiliaryScopes.stops==1 && auxiliaryWitness==nil}
        let scopes=try await heldPreparationRetirement(folder:folder,base:base,mine:mine,patch:patchFile,preferences:prefs,board:board)
        begin("all captured patch grants release",{scopes.enumerated().map{"record\($0.offset)={\($0.element.details())}"}.joined(separator:"; ")})
        try await wait{scopes.allSatisfy{$0.starts==$0.stops}}
        diagnostics={""}
        print("PASS: invalid patch and actual Git preparation cancellation preserve original; Close/Quit fences; checked text→patch→text adoption in same native window/frame; input bytes preserved")
    }
}

extension MergePatchOpenNativeVerification {
    final class Scopes:RepositoryBookmarkProvider {
        var starts=0,stops=0
        weak var lease:RepositoryAccessLease?
        weak var editor:FileComparisonWindowController?
        weak var editorWindow:NSWindow?
        weak var preparation:ReviewPatchWorkflow?
        weak var preparationWindow:NSWindow?
        weak var registry:MergeEditorReplacementOwner?
        @MainActor func details()->String {
            "starts=\(starts) stops=\(stops) leaseAlive=\(lease != nil) editorAlive=\(editor != nil) editorWindowAlive=\(editorWindow != nil) registryAlive=\(registry != nil) registryPending=\(registry?.hasPendingRetiredWork==true) preparationAlive=\(preparation != nil) preparationPending=\(preparation?.hasPendingWork==true) preparationWindowAlive=\(preparationWindow != nil) hostAlive=\(preparationWindow?.contentViewController != nil)"
        }
        func create(for url:URL)throws->Data {Data()}
        func resolve(_ data:Data)throws->ResolvedBookmark {throw Failure(message:"Unused bookmark resolution")}
        func startAccessing(_ url:URL)->Bool {starts+=1;return true}
        func stopAccessing(_ url:URL) {stops+=1}
    }
    @MainActor static func heldPreparationRetirement(folder:URL,base:URL,mine:URL,patch:URL,preferences:UserDefaults,board:NSPasteboard)async throws->[Scopes] {
        var roots=[FileComparisonWindowController](),workflows=[ReviewPatchWorkflow](),registries=[MergeEditorReplacementOwner](),scopeRecords=[Scopes](),releaseTargets=[()->Void]()
        func clean()async throws {
            workflows.forEach{$0.cancel()};roots.forEach{$0.close()};releaseTargets.forEach{$0()};releaseTargets=[]
            try await wait{workflows.allSatisfy{!$0.hasPendingWork} && registries.allSatisfy{!$0.hasPendingRetiredWork} && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0}
            diagnostics={""};roots=[];workflows=[];registries=[]
        }
        do {
            for scenario in 0..<3 {
                let forceClose=scenario>0,targetHeld=scenario==2
                let scopes=Scopes();scopeRecords.append(scopes)
                var grant:RepositoryAccessLease?=RepositoryAccessLease(url:folder,provider:scopes)
                weak var witness=grant;scopes.lease=grant
                let root=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[grant!],preferences:preferences)
                roots.append(root);scopes.editor=root;scopes.editorWindow=root.window;MergeEditorOpenNativeVerification.hidden(root.window)
                var rootClosed=0
                root.onClosed={rootClosed+=1}
                let window=root.window!,owner=MergeEditorReplacementOwner(onClosed:{})
                registries.append(owner);scopes.registry=owner;root.replacementOwner=owner
                var boundary:(NSWindow,NSWindow)?,adoptions=0,targetReply:CheckedContinuation<URL?,Never>?
                owner.configureBeforeAdopt={_ in adoptions+=1}
                owner.makePatchWorkflow={file,target,bytes,permissions,defaults in
                    let workflow=ReviewPatchWorkflow(file:file,target:target,grants:permissions,executable:try GitRuntime.executable(),preferences:defaults,clipboardBytes:bytes,pasteboard:board)
                    scopes.preparation=workflow;scopes.preparationWindow=workflow.window
                    workflow.presentPreparedSheetEnd={parent,sheet in boundary=(parent,sheet)}
                    if targetHeld {workflow.chooseTarget={await withCheckedContinuation{targetReply=$0}}}
                    workflows.append(workflow);return workflow
                }
                root.model.load();try await TwoPaneEngineVerification.settled(root.model)
                let original=root.model.document
                releaseTargets.append{targetReply?.resume(returning:nil);targetReply=nil}
                begin(targetHeld ? "original registry close waits for held target worker":forceClose ? "forced parent close while checked preparation awaits detach":"cancel while checked preparation awaits detach",{
                    "rootClosed=\(rootClosed) targetHeld=\(targetHeld) targetReply=\(targetReply != nil) adoptions=\(adoptions) rootOwns=\(root.window === window) pending=\(owner.pendingPatch?.hasPendingWork==true) parentSheet=\(String(describing:window.attachedSheet)) sheetParent=\(String(describing:boundary?.1.sheetParent)) loads=\(ReviewPatchWorkflow.activeLoads) releases=\(ReviewPatchWorkflow.activeReleases) scopes=\(scopes.starts)/\(scopes.stops) error=\(String(reflecting:owner.pendingPatch?.error))"
                })
                try root.replaceEditor(.patch(file:patch,directory:targetHeld ? nil:folder,clipboard:nil),permissions:[grant!]);grant=nil
                try await wait{targetHeld ? targetReply != nil:boundary != nil}
                guard let workflow=owner.pendingPatch,let preparation=workflow.window else {throw Failure(message:"Missing held actual preparation owner")}
                let (parent,sheet)=boundary ?? (window,preparation)
                try require(parent === window && parent.attachedSheet === sheet && sheet.sheetParent === parent && adoptions==0 && workflow.hasPendingWork && ReviewPatchWorkflow.activeLoads==(targetHeld ? 0:1) && rootClosed==0 && witness != nil && scopes.stops==0,"Held checked preparation lost exact owner/grant: "+diagnostics())
                if forceClose {window.close()} else {workflow.cancel()}
                try require(rootClosed==0 && adoptions==0 && (workflow.hasPendingWork || ReviewPatchWorkflow.activeLoads>0) && witness != nil && scopes.stops==0,"Cancel/forced close fired original registry callback or abandoned preparation before worker drain: "+diagnostics())
                if targetHeld {
                    await Task.yield()
                    try require(rootClosed==0 && owner.pendingPatch === workflow && workflow.hasPendingWork && targetReply != nil,"Original registry closed while real target worker was still held: "+diagnostics())
                    targetReply?.resume(returning:folder);targetReply=nil
                }
                try await wait{owner.pendingPatch==nil && !workflow.hasPendingWork && ReviewPatchWorkflow.activeLoads==0 && ReviewPatchWorkflow.activeReleases==0 && sheet.sheetParent==nil && window.attachedSheet==nil}
                try require(adoptions==0 && owner.current==nil && workflow.error==nil && root.model.document?.base.bytes==original?.base.bytes && root.model.document?.destination.bytes==original?.destination.bytes,"Cancelled preparation adopted/reported late error or changed original document: "+diagnostics())
                if forceClose {try await wait{rootClosed==1}}
                else {try require(rootClosed==0,"Cancellation closed the original editor");root.close();try await wait{rootClosed==1}}
                try require(rootClosed==1,"Original registry close callback wasn't exactly once after preparation drain")
            }
            try await clean();return scopeRecords
        } catch {let original=error;do {try await clean()} catch {throw Failure(message:"Original failure: \(original); cleanup: \(error)")};throw original}
    }
}
