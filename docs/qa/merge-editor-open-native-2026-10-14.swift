import AppKit
import Darwin
import TurtleGitCore

struct MergeEditorOpenNativeVerification {
    struct Failure:Error,CustomStringConvertible,LocalizedError {let message:String;var description:String {message};var errorDescription:String? {message}}
    @MainActor static var phase="existing replacement"
    @MainActor static func wait(_ name:String,_ state:@escaping()->String={""},_ yes:()->Bool)async throws {
        phase=name;print("Editor Open phase: "+name);fflush(stdout)
        for _ in 0..<1000 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:name+"; "+state())
    }
    @MainActor static func hidden(_ window:NSWindow?) {
        guard let window else{return};window.alphaValue=0;window.ignoresMouseEvents=true
        // Preserve a genuine admissible native frame. AppKit may relocate an
        // offscreen window when adoption orders it, independently of the copy.
        if let screen=NSScreen.main {
            var frame=window.frame;frame.origin = .init(x:screen.visibleFrame.minX+20,y:screen.visibleFrame.minY+20)
            window.setFrame(window.constrainFrameRect(frame,to:screen),display:false)
        }
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func verify() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorOpen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "TurtleGit.EditorOpen." + UUID().uuidString, prefs = UserDefaults(suiteName: name)!
        let board=NSPasteboard(name:.init("TurtleGit.EditorOpen."+UUID().uuidString))
        defer {board.releaseGlobally();prefs.removePersistentDomain(forName:name);try? FileManager.default.removeItem(at:folder)}
        func makeWorkflow(_ owner:NSWindow,_ grants:[RepositoryAccessLease],_ defaults:UserDefaults)->MergeEditorOpenWorkflow {
            let workflow=MergeEditorOpenWorkflow(window:owner,permissions:grants,preferences:defaults)
            workflow.makeOpener={defaults,grants in let value=MergeOpenWindowController(preferences:defaults,pasteboard:board,permissions:grants);hidden(value.window);return value}
            return workflow
        }
        MergeGeneralPreferences(firstDifference: false, firstConflict: false).save(to: prefs)
        let base = folder.appendingPathComponent("base.cpp"), mine = folder.appendingPathComponent("mine.cpp"), theirs = folder.appendingPathComponent("theirs.cpp")
        let texts = ["head\nbase\ntail\n", "head\nmine\ntail\n", "head\ntheirs\ntail\n"]
        for (url, text) in zip([base, mine, theirs], texts) { try Data(text.utf8).write(to: url) }
        let root = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: prefs)
        let window=root.window!;hidden(window);root.makeEditorOpenWorkflow=makeWorkflow
        var closed = 0; root.onClosed = { closed += 1 }
        defer { (root.replacementOwner?.current ?? root).close() }
        root.model.load(); try await TwoPaneEngineVerification.settled(root.model)
        let frame=window.frame
        print("Editor frame before Open: \(frame)");fflush(stdout)
        root.openMergeDocument(nil)
        guard let workflow = root.editorOpenWorkflow, let opener = workflow.opener else { throw Failure(message: "Scoped Open did not own its dialog") }
        print("Editor frame while Open attached: \(window.frame); sheetParent=\(String(describing:opener.window?.sheetParent))");fflush(stdout)
        let endSheet=opener.presentAcceptedSheetEnd,accept=opener.onAccepted
        opener.presentAcceptedSheetEnd={parent,sheet in
            print("Editor frame before physical Open detach: \(parent.frame)");fflush(stdout);endSheet(parent,sheet)
        }
        opener.onAccepted={request,grants in
            print("Editor frame after detach/before adoption: \(window.frame); attached=\(String(describing:window.attachedSheet))");fflush(stdout)
            try accept(request,grants)
            print("Editor frame after adoption callback: \(window.frame)");fflush(stdout)
        }
        try require(!root.windowShouldClose(window), "Open owner allowed Close")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Open owner allowed Quit")
        root.openMergeDocument(nil); try require(root.editorOpenWorkflow === workflow, "Duplicate Open replaced owner")
        opener.base.stringValue = folder.appendingPathComponent("missing").path; opener.mine.stringValue = mine.path; opener.accept()
        try require(root.window === window && root.editorOpenWorkflow === workflow && !opener.status.stringValue.isEmpty, "Invalid paths retired original editor")
        opener.base.stringValue = base.path; opener.theirs.stringValue = theirs.path; opener.mine.stringValue = mine.path; opener.accept()
        try await wait("compare-to-merge detached acceptance",{ "workflow=\(root.editorOpenWorkflow?.hasPendingWork==true) sheet=\(String(describing:window.attachedSheet)) choices=\(MergeOpenWindowController.activeChoices)" }){root.replacementOwner?.current is TextConflictWindowController}
        guard let owner = root.replacementOwner, let triple = owner.current as? TextConflictWindowController else { throw Failure(message: "Three-pane replacement missing") }
        try require(root.window == nil && triple.window === window && window.delegate === triple && window.frame == frame, "Replacement identity rootDetached=\(root.window == nil), sameWindow=\(triple.window === window), sameDelegate=\(window.delegate === triple), oldFrame=\(frame), newFrame=\(window.frame)")
        try await ThreePaneEngineVerification.wait { !triple.model.busy && triple.model.document != nil }
        var answer: ((NSApplication.ModalResponse) -> Void)?
        triple.makeEditorOpenWorkflow = { owner, grants, defaults in
            let workflow=makeWorkflow(owner,grants,defaults)
            workflow.presentQuestion = { _, _, completion in answer = completion }; return workflow
        }
        let result = triple.model.result
        triple.openMergeDocument(nil); guard let cancel = answer else { throw Failure(message: "Dirty merge omitted Save question") }
        cancel(.alertThirdButtonReturn); cancel(.alertSecondButtonReturn)
        try require(triple.editorOpenWorkflow == nil && triple.model.result == result && triple.window === window, "Cancel/late answer changed original merge")
        triple.openMergeDocument(nil); answer?(.alertSecondButtonReturn)
        guard let nextOpener = triple.editorOpenWorkflow?.opener else { throw Failure(message: "Discard did not open dialog") }
        nextOpener.base.stringValue = base.path; nextOpener.mine.stringValue = mine.path; nextOpener.accept()
        try await wait("merge-to-compare detached acceptance"){owner.current is FileComparisonWindowController}
        guard let pair = owner.current as? FileComparisonWindowController else { throw Failure(message: "Return to two panes failed") }
        try require(pair.window === window && triple.window == nil && window.delegate === pair, "Second replacement lost existing window ownership")
        try await TwoPaneEngineVerification.settled(pair.model)
        pair.makeEditorOpenWorkflow=makeWorkflow
        pair.openMergeDocument(nil)
        let late = pair.editorOpenWorkflow
        window.close()
        try await wait("forced-close editor/Open drain"){closed==1 && owner.current==nil && pair.editorOpenWorkflow==nil}
        try require(closed == 1 && owner.current == nil && pair.editorOpenWorkflow == nil, "Forced close did not retire current session once")
        try require(late?.opener == nil, "Forced close retained Open dialog")

        let saveWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        saveWindow.isReleasedWhenClosed=false;hidden(saveWindow)
        defer { saveWindow.close() }
        let held=makeWorkflow(saveWindow,[],prefs)
        var choice: ((NSApplication.ModalResponse) -> Void)?, saved: ((Bool) -> Void)?
        held.presentQuestion = { _, _, completion in choice = completion }
        held.start(dirty: true, description: "held save", save: { saved = $0 })
        choice?(.alertFirstButtonReturn)
        try require(MergeEditorOpenWorkflow.activeSaves == 1, "Save lifetime missing")
        held.retire(); saved?(true); saved?(false)
        try require(MergeEditorOpenWorkflow.activeSaves == 0 && held.opener == nil, "Late/duplicate Save response reopened owner or leaked lifetime")
        for (url, text) in zip([base, mine, theirs], texts) { try require(try Data(contentsOf: url) == Data(text.utf8), "Open replacement modified input") }
        try await ownershipFamily(folder:folder,preferences:prefs,board:board)
        print("PASS: owned File/Open invalid input, duplicate/Close/Quit gates, same NSWindow/frame across two/three/two panes, dirty Cancel/discard/late replies, final retirement, held Save lifetime and original bytes")
    }
}

extension MergeEditorOpenNativeVerification {
    @MainActor final class OwnershipContext {
        let preferences:UserDefaults,board:NSPasteboard
        var windows=[NSWindow](),controllers=[NSWindowController](),workflows=[MergeEditorOpenWorkflow](),release=[()->Void]()
        init(_ preferences:UserDefaults,_ board:NSPasteboard) {self.preferences=preferences;self.board=board}
        func window()->NSWindow {
            let value=NSWindow(contentRect:.init(x:-14000,y:-14000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            value.isReleasedWhenClosed=false;MergeEditorOpenNativeVerification.hidden(value);value.orderFront(nil);windows.append(value);return value
        }
        func workflow(_ owner:NSWindow,_ grants:[RepositoryAccessLease]=[])->MergeEditorOpenWorkflow {
            let value=MergeEditorOpenWorkflow(window:owner,permissions:grants,preferences:preferences)
            value.makeOpener={ [self] defaults,permissions in
                let controller=MergeOpenWindowController(preferences:defaults,pasteboard:board,permissions:permissions)
                MergeEditorOpenNativeVerification.hidden(controller.window);controllers.append(controller);return controller
            }
            workflows.append(value);return value
        }
        func clean()async throws {
            workflows.forEach{$0.retire()};release.forEach{$0()};release=[]
            controllers.forEach{$0.close()}
            for window in windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)};window.close()}
            try await MergeEditorOpenNativeVerification.wait("all owned Open question/picker/read lifetimes drain",{ "transactions=\(MergeEditorOpenWorkflow.activeTransactions) saves=\(MergeEditorOpenWorkflow.activeSaves) choices=\(MergeOpenWindowController.activeChoices)" }) {
                workflows.allSatisfy{!$0.hasPendingWork} && MergeEditorOpenWorkflow.activeTransactions==0 && MergeEditorOpenWorkflow.activeSaves==0 && MergeOpenWindowController.activeChoices==0
            }
            workflows=[];controllers=[];windows=[]
        }
    }
    @MainActor static func ownershipFamily(folder:URL,preferences:UserDefaults,board:NSPasteboard)async throws {
        let context=OwnershipContext(preferences,board)
        do {
            let base=folder.appendingPathComponent("base.cpp"),mine=folder.appendingPathComponent("mine.cpp")
            for response in [NSApplication.ModalResponse.alertFirstButtonReturn,.alertSecondButtonReturn,.alertThirdButtonReturn] {
                let window=context.window(),workflow=context.workflow(window)
                var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?,save:((Bool)->Void)?,closed=0,accepted=0
                workflow.onClosed={closed+=1}
                workflow.presentQuestion={alert,parent,completion in
                    question=alert;reply=completion;hidden(alert.window)
                    parent.beginSheet(alert.window,completionHandler:{_ in})
                }
                workflow.start(dirty:true,description:"private owned draft",save:{save=$0})
                guard let question,let reply else {throw Failure(message:"Actual Save question missing")}
                try require(window.attachedSheet === question.window && question.window.sheetParent === window,"Question wasn't a real owned sheet")
                reply(response);reply(.alertSecondButtonReturn)
                try require(workflow.hasPendingWork && workflow.opener==nil && save==nil && closed==0,"Early/duplicate question response advanced before native detach")
                try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held question lost Quit ownership")
                window.endSheet(question.window,returnCode:response);question.window.orderOut(nil)
                if response == .alertFirstButtonReturn {
                    try await wait("Save starts only after question detach"){save != nil}
                    try require(workflow.opener==nil && MergeEditorOpenWorkflow.activeSaves==1,"Save worker wasn't independently owned")
                    workflow.retire();try require(workflow.hasPendingWork && closed==0,"Retire completed before actual held Save callback")
                    save?(true);save?(false)
                    try await wait("retired held Save settles once"){!workflow.hasPendingWork && closed==1}
                    try require(workflow.opener==nil && MergeEditorOpenWorkflow.activeSaves==0,"Late Save reopened Open")
                } else if response == .alertSecondButtonReturn {
                    try await wait("Don't Save mounts Open after exact detach"){workflow.opener?.window?.sheetParent === window}
                    let opener=workflow.opener!,sheet=opener.window!
                    opener.setMode(.merging);opener.base.stringValue=base.path;opener.mine.stringValue=mine.path
                    var sheetEnds=0,correctSheetOwner=true
                    opener.presentAcceptedSheetEnd={owner,child in sheetEnds+=1;correctSheetOwner = correctSheetOwner && owner === window && child === sheet}
                    workflow.accept={request,_ in
                        accepted+=1
                        try require(window.attachedSheet==nil && sheet.sheetParent==nil,"Replacement ran before exact Open detach")
                        if accepted==1 {throw Failure(message:"expected checked replacement refusal")}
                        guard case .compare(let left,let right,let single)=request else {throw Failure(message:"Captured comparison mode changed")}
                        try require(left==base && right==mine && !single,"Accepted inputs were retargeted")
                    }
                    let oldMode=preferences.integer(forKey:"TurtleGitMerge.OpenRadio")
                    opener.accept();opener.accept();opener.setMode(.applyUnifiedDiff)
                    try require(correctSheetOwner && sheetEnds==1 && accepted==0 && opener.hasPendingWork && opener.mode == .merging && window.attachedSheet === sheet,"Duplicate/competing acceptance escaped held native Open")
                    window.endSheet(sheet);sheet.orderOut(nil)
                    try await wait("rejected checked replacement restores same form"){accepted==1 && !opener.hasPendingWork && sheet.sheetParent === window && !opener.status.stringValue.isEmpty}
                    try require(workflow.opener === opener && opener.base.stringValue==base.path && opener.mine.stringValue==mine.path && preferences.integer(forKey:"TurtleGitMerge.OpenRadio")==oldMode,"Rejected acceptance lost captured draft/mode or ended workflow")
                    opener.accept();try require(sheetEnds==2 && accepted==1,"Retry recreated acceptance or skipped detach")
                    window.endSheet(sheet);sheet.orderOut(nil)
                    try await wait("retry acceptance drains once"){accepted==2 && closed==1 && !workflow.hasPendingWork}
                } else {
                    try await wait("Cancel question settles only after native detach"){closed==1 && !workflow.hasPendingWork}
                    try require(workflow.opener==nil && save==nil && accepted==0,"Cancelled question performed downstream work")
                }
                window.close()
            }
            // A custom asynchronous Browse result is still an owned worker when
            // both its Open sheet and editor are forcibly closed.
            let parent=context.window(),workflow=context.workflow(parent)
            workflow.start(dirty:false,description:"held picker",save:{$0(false)})
            guard let opener=workflow.opener else {throw Failure(message:"Held nested picker omitted Open")}
            var choice:CheckedContinuation<URL?,Never>?,closed=0,accepted=0
            workflow.onClosed={closed+=1};workflow.accept={_,_ in accepted+=1}
            opener.choosePath={_,_ in await withCheckedContinuation{choice=$0}}
            context.release.append{choice?.resume(returning:nil);choice=nil}
            opener.browse(.base);try await wait("held nested Browse worker admitted"){choice != nil}
            parent.close();workflow.retire()
            try require(workflow.hasPendingWork && opener.hasPendingWork && closed==0 && MergeOpenWindowController.activeChoices==1,"Forced close released Browse worker ownership early")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced-close Browse drain lost Quit guard")
            choice?.resume(returning:base);choice=nil
            try await wait("retired nested Browse actual return drains"){!workflow.hasPendingWork && !opener.hasPendingWork && closed==1}
            try require(opener.base.stringValue.isEmpty && accepted==0,"Late Browse republished or accepted after owner close")
            try await dirtyEditorQuestions(folder:folder,context:context)
            try await context.clean()
        } catch {let failure=error;do {try await context.clean()} catch {throw Failure(message:"Original failure: \(failure); cleanup: \(error)")};throw failure}
    }
    @MainActor static func dirtyEditorQuestions(folder:URL,context:OwnershipContext)async throws {
        for save in [true,false] {
            let location=folder.appendingPathComponent(save ? "actual Save":"actual Don't Save",isDirectory:true)
            try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
            let left=location.appendingPathComponent("base.txt"),right=location.appendingPathComponent("mine.txt"),next=location.appendingPathComponent("next.txt")
            let old=Data("mine original\n".utf8),edited="mine edited through actual draft\n"
            try Data("base\n".utf8).write(to:left);try old.write(to:right);try Data("new destination\n".utf8).write(to:next)
            let editor=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:context.preferences)
            context.controllers.append(editor);let window=editor.window!;hidden(window);context.windows.append(window)
            var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?,policyAttempts=0
            var policyState="not reached"
            let registry=MergeEditorReplacementOwner(onClosed:{})
            editor.replacementOwner=registry
            registry.configureBeforeAdopt={candidate in
                policyAttempts+=1
                policyState="attempt=\(policyAttempts) detached=\(window.attachedSheet==nil) candidate=\(type(of:candidate))"
                try require(window.attachedSheet==nil,"Replacement policy ran before Open detach")
                guard let pair=candidate as? FileComparisonWindowController else {throw Failure(message:"Replacement policy received unexpected mode")}
                policyState+=" samePreferences=\(pair.model.comparisonDefaults === context.preferences) single=\(pair.model.singleFileMode)"
                print("Editor policy: "+policyState);fflush(stdout)
                try require(pair.model.comparisonDefaults === context.preferences && !pair.model.singleFileMode,"Replacement lost captured preferences/compare mode")
                if save && policyAttempts==1 {throw Failure(message:"expected policy refusal before adoption")}
            }
            editor.makeEditorOpenWorkflow={owner,permissions,_ in
                let workflow=context.workflow(owner,permissions)
                workflow.presentQuestion={question,parent,reply in alert=question;answer=reply;hidden(question.window);parent.beginSheet(question.window,completionHandler:{_ in})}
                return workflow
            }
            editor.model.load();try await TwoPaneEngineVerification.settled(editor.model)
            editor.model.activatePane(base:false);editor.model.editingEnabled=true;editor.model.updateDraft(edited,base:false)
            try require(editor.model.dirty,"Actual draft edit did not require Save question")
            editor.openMergeDocument(nil)
            guard let workflow=editor.editorOpenWorkflow,let alert,let answer else {throw Failure(message:"Dirty two-pane Open omitted real question")}
            answer(save ? .alertFirstButtonReturn:.alertSecondButtonReturn)
            try require(workflow.opener==nil && window.attachedSheet === alert.window && editor.model.dirty,"Dirty source advanced before actual question detach")
            try require(try Data(contentsOf:right)==old,"Save wrote before question detached")
            window.endSheet(alert.window);alert.window.orderOut(nil)
            try await wait(save ? "actual Save completion then Open":"actual Don't Save then Open"){workflow.opener != nil}
            try require(try Data(contentsOf:right)==(save ? Data(edited.utf8):old),"Save/Don't Save changed the wrong captured bytes")
            let opener=workflow.opener!,frame=window.frame
            let admissionState={
                "policy={\(policyState)} parentBusy=\(editor.model.busy) filtering=\(editor.model.filtering) editorChoice=\(editor.model.hasPendingEditorChoice) preparingReplacement=\(editor.preparingReplacement) workflowSame=\(editor.editorOpenWorkflow === workflow) openerSame=\(workflow.opener === opener) openerPending=\(opener.hasPendingWork) ok=\(opener.ok.isEnabled) parentAttached=\(window.attachedSheet === opener.window) sheetParent=\(opener.window?.sheetParent === window) rootSame=\(editor.window === window) registryEmpty=\(registry.current==nil) status=\(String(reflecting:opener.status.stringValue))"
            }
            try await wait("parent saved projection and mounted Open admit replacement",admissionState){
                !editor.model.busy && !editor.model.filtering && !editor.model.hasPendingEditorChoice && !editor.preparingReplacement && editor.editorOpenWorkflow === workflow && workflow.opener === opener && !opener.hasPendingWork && opener.ok.isEnabled && window.attachedSheet === opener.window && opener.window?.sheetParent === window
            }
            opener.setMode(.merging);opener.base.stringValue=left.path;opener.mine.stringValue=next.path
            let storedMode=context.preferences.integer(forKey:"TurtleGitMerge.OpenRadio")
            opener.accept()
            if save {
                try await wait("real policy refusal restores same Open/original editor",admissionState){policyAttempts==1 && !opener.hasPendingWork && opener.window?.sheetParent === window && opener.status.stringValue=="expected policy refusal before adoption"}
                let ownerRestored=policyAttempts==1 && editor.window === window && window.delegate === editor && registry.current==nil && editor.editorOpenWorkflow === workflow && workflow.opener === opener
                let formRestored=opener.mode == .merging && opener.base.stringValue==left.path && opener.mine.stringValue==next.path && opener.ok.isEnabled && context.preferences.integer(forKey:"TurtleGitMerge.OpenRadio")==storedMode
                let pathsRestored=editor.model.document?.base.path==left.path && editor.model.document?.destination.path==right.path
                let bytesRestored=editor.model.document?.base.bytes==Data("base\n".utf8) && editor.model.document?.destination.bytes==Data(edited.utf8)
                let restored=ownerRestored && formRestored && pathsRestored && bytesRestored && editor.model.draftText(base:false)==edited && !editor.model.dirty
                try require(restored,"Policy refusal lost original document/draft/window/form: "+admissionState()+" basePath=\(editor.model.document?.base.path ?? "none") minePath=\(editor.model.document?.destination.path ?? "none") baseBytes=\(editor.model.document?.base.bytes.count ?? -1) mineBytes=\(editor.model.document?.destination.bytes.count ?? -1) dirty=\(editor.model.dirty) mode=\(opener.mode) persistedMode=\(context.preferences.integer(forKey:"TurtleGitMerge.OpenRadio"))")
                opener.accept()
            }
            try await wait("dirty source accepted replacement after Open detach",admissionState){editor.replacementOwner?.current is FileComparisonWindowController && editor.editorOpenWorkflow==nil}
            let replacement=editor.replacementOwner!.current as! FileComparisonWindowController
            context.controllers.append(replacement);replacement.makeEditorOpenWorkflow={owner,grants,_ in context.workflow(owner,grants)}
            try await TwoPaneEngineVerification.settled(replacement.model)
            try require(editor.window==nil && replacement.window === window && window.attachedSheet==nil && window.frame==frame,"Dirty replacement lost exact native window/frame or retained Open sheet")
            try require(replacement.model.document?.destination.bytes==Data("new destination\n".utf8),"Accepted replacement used previous draft")
            replacement.close()
        }
    }
}
