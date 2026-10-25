// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

enum MergeToolLaunchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Merge-tool launch timeout at \(line)")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeToolLaunch." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let base = root.appendingPathComponent("base [literal]\nfile"), mine = root.appendingPathComponent("mine file"), output = root.appendingPathComponent("merged file")
        try Data("before\nshared\n".utf8).write(to: base); try Data("after\nshared\n".utf8).write(to: mine)
        let originalMine = try Data(contentsOf: mine)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        var shown: [NSWindowController] = [], completions: [Int32] = []
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.configurePatchWorkflow = { workflow in workflow.chooseBetterTarget = { _, _ in .original } }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        defer { workspace.stopMonitoringForTermination(); shown.forEach { $0.close() } }
        func launch(_ arguments: [String]) throws {
            workspace.error = nil
            try require(workspace.handleMergeToolCommandLine(arguments: ["--merge-tool"] + arguments, currentDirectory: root.path, completion: { completions.append($0) }), "Merge invocation not recognized")
        }
        func pair() async throws -> FileComparisonWindowController {
            try await wait { shown.last is FileComparisonWindowController }
            let controller = shown.last as! FileComparisonWindowController
            try await wait { !controller.model.mergeToolHasPendingWork && controller.model.document != nil && !controller.model.filtering }
            return controller
        }
        try require(!workspace.handleMergeToolCommandLine(arguments: ["--command=log", "--path", root.path], currentDirectory: root.path), "Merge parser consumed repository command")
        try launch(["--base", base.path, "--mine", mine.path, "--readonly", "--oneway", "--basename", "Original", "--minename", "Changed", "--line", "2"])
        let readonly = try await pair()
        try require(readonly.model.mergeToolReadOnly && readonly.model.paneTitle(base: true) == "Original" && readonly.model.document?.destination.path == mine.path, "Launch lost labels, paths or readonly policy")
        let originalWindow = readonly.window
        try readonly.replaceEditor(.compare(base: mine, mine: base, single: false), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor !== readonly }
        let replacement = workspace.mergeToolLaunches.values.first!.editor as! FileComparisonWindowController
        try await wait { !replacement.model.mergeToolHasPendingWork && replacement.model.document != nil && !replacement.model.filtering }
        try require(replacement.window === originalWindow && readonly.window == nil && replacement.model.mergeToolReadOnly && replacement.model.onePaneActive && replacement.model.paneTitle(base: true) != "Original", "Open replacement lost current owner, readonly/view policy or reset names")
        replacement.close(); try await wait { completions.count == 1 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0 && (try Data(contentsOf: mine)) == originalMine, "Readonly compare close changed input or exit status")
        shown = []
        try launch(["--base", base.path, "--mine", mine.path, "--merged", output.path, "--saverequired"])
        let writable = try await pair(); var saved: Bool?
        writable.model.save { saved = $0 }; try await wait { saved != nil && !writable.model.mergeToolHasPendingWork }
        try require(saved == true && (try Data(contentsOf: output)) == originalMine && (try Data(contentsOf: mine)) == originalMine, "Session output did not save separately")
        writable.close(); try await wait { completions.count == 2 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0, "Accepted saved output did not return success")
        // Accepted Don't Save/Open resets the editor, while the original Git result remains failed.
        let abandonedOutput = root.appendingPathComponent("abandoned-result")
        shown = []; try launch(["--base", base.path, "--mine", mine.path, "--merged", abandonedOutput.path, "--saverequired"])
        let abandoned = try await pair()
        try abandoned.replaceEditor(.compare(base: mine, mine: base, single: false), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor !== abandoned }
        let opened = workspace.mergeToolLaunches.values.first!.editor as! FileComparisonWindowController
        try await wait { !opened.model.mergeToolHasPendingWork && opened.model.document != nil && !opened.model.filtering }
        try require(!opened.model.dirty && workspace.mergeToolLaunches.values.first?.completionStatus == 1, "Open erased the original unsaved Git result obligation")
        opened.close(); try await wait { completions.count == 3 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 1 && !FileManager.default.fileExists(atPath: abandonedOutput.path), "Discarded original result became successful or wrote an output")
        // Explicit cleanup preserves modified inputs and the configured output.
        let scratchBase = root.appendingPathComponent("cleanup-base"), scratchMine = root.appendingPathComponent("cleanup-mine"), scratchOutput = root.appendingPathComponent("cleanup-output")
        try Data("base\n".utf8).write(to: scratchBase); try Data("mine\n".utf8).write(to: scratchMine)
        shown = []; try launch(["--base", scratchBase.path, "--mine", scratchMine.path, "--merged", scratchOutput.path, "--saverequired", "--deletebasetheirsmineonclose"])
        let cleanup = try await pair(); saved = nil; cleanup.model.save { saved = $0 }; try await wait { saved == true && !cleanup.model.mergeToolHasPendingWork }
        try Data("external edit\n".utf8).write(to: scratchBase); cleanup.close()
        try await wait { completions.count == 4 && workspace.mergeToolLaunches.isEmpty }
        try require(FileManager.default.fileExists(atPath: scratchBase.path) && !FileManager.default.fileExists(atPath: scratchMine.path) && (try Data(contentsOf: scratchOutput)) == Data("mine\n".utf8), "Owned cleanup removed changed input/output or retained unchanged temporary input")
        // Byte-oriented unified output uses the same finite completion protocol.
        let patchFile = root.appendingPathComponent("review.patch")
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path, "--outfile", patchFile.path])
        try await wait { completions.count == 5 && workspace.mergeToolLaunches.isEmpty }
        let patchBytes = try Data(contentsOf: patchFile)
        try require(completions.last == 0 && String(decoding: patchBytes, as: UTF8.self).contains("+after"), "Unified command did not write reviewed patch bytes")
        // Source reverse/readonly and labels reach the actual patch parent and child.
        let target = root.appendingPathComponent("patch-target"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sample = target.appendingPathComponent("sample"); try Data("after\n".utf8).write(to: sample)
        let left = root.appendingPathComponent("patch-left"), right = root.appendingPathComponent("patch-right")
        try Data("before\n".utf8).write(to: left); try Data("after\n".utf8).write(to: right)
        let reviewBytes = try await MergeUnifiedPatch.create(base: WorkingFileComparison.workingContent(at: left), destination: WorkingFileComparison.workingContent(at: right), baseLabel: "sample", destinationLabel: "sample", executable: git)
        try reviewBytes.write(to: patchFile); shown = []
        try launch(["--diff", patchFile.path, "--patchpath", target.path, "--readonly", "--reversedpatch", "--patchoriginal", "Original", "--patchpatched", "Patched"])
        try await wait { shown.last is WorkingTreePatchWindowController }
        let review = shown.last as! WorkingTreePatchWindowController
        try await wait { !review.model.busy && review.model.review != nil }
        try require(review.model.reversed && review.model.mergeToolReadOnly && review.model.mergeToolOriginalLabel == "Original" && !review.model.canApply && !review.model.canSaveDraft && !review.model.canResolveSpecial, "Patch entry lost reversed/readonly/source captions")
        review.model.apply(); review.model.saveDraft(); try require((try Data(contentsOf: sample)) == Data("after\n".utf8), "Readonly patch entry mutated target")
        review.close(); try await wait { completions.count == 6 && workspace.mergeToolLaunches.isEmpty }
        // A cancelled, noncooperative authorization retains lifetime and refuses late presentation.
        var authorization: CheckedContinuation<RepositoryAccessLease?, Error>?
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.authorize = { _, _ in try await withCheckedThrowingContinuation { authorization = $0 } }
            session.presentation = { _ in fatalError("Cancelled launch presented a late editor") }
        }
        try launch(["--base", base.path, "--mine", mine.path])
        try await wait { authorization != nil }
        workspace.mergeToolLaunches.values.first!.cancel()
        try require(workspace.hasPendingRepositoryWork && completions.count == 6, "Cancelled authorization was released before its real reply")
        authorization?.resume(returning: RepositoryAccessLease(url: root)); authorization = nil
        try await wait { completions.count == 7 && workspace.mergeToolLaunches.isEmpty && MergeToolLaunchSession.activePreparations == 0 }
        try require(completions.last == 1 && (try Data(contentsOf: mine)) == originalMine, "Late authorization changed result or input")
        // Empty source entry owns Open and retains an outstanding native path choice through close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        shown = []; try launch([])
        try await wait { shown.last is MergeOpenWindowController }
        let open = shown.last as! MergeOpenWindowController
        var pathChoice: CheckedContinuation<URL?, Never>?
        open.choosePath = { _, _ in await withCheckedContinuation { pathChoice = $0 } }; open.browse(.base)
        try await wait { pathChoice != nil && open.pendingChoices == 1 }
        open.close(); try require(completions.count == 7 && workspace.hasPendingRepositoryWork, "Open discarded a still-owned chooser worker")
        pathChoice?.resume(returning: base); pathChoice = nil
        try await wait { completions.count == 8 && workspace.mergeToolLaunches.isEmpty && open.pendingChoices == 0 }
        try require(completions.last == 1 && open.base.stringValue.isEmpty && open.window?.isVisible == false, "Retired Open choice changed a field or revived its owner")
        // Default Save As has an owned ownerless panel and one-shot retirement.
        var outputReply: ((NSApplication.ModalResponse) -> Void)?
        var sawOwnerlessPanel = false
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentOutputPanel = { _, owner, reply in sawOwnerlessPanel = owner == nil; outputReply = reply }
            session.selectedOutputURL = { _ in root.appendingPathComponent("cancelled.patch") }
        }
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path])
        try await wait { outputReply != nil }
        let pendingOutput = workspace.mergeToolLaunches.values.first!
        try require(sawOwnerlessPanel && pendingOutput.outputPanel != nil && workspace.hasPendingRepositoryWork, "Ownerless Save As was skipped or lost ownership")
        pendingOutput.cancel(); try await wait { completions.count == 9 && workspace.mergeToolLaunches.isEmpty }
        outputReply?(.OK); outputReply = nil
        try require(completions.count == 9 && completions.last == 1 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.patch").path), "Retired Save As callback wrote output or completed twice")
        let chosenPatch = root.appendingPathComponent("chosen.patch")
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentOutputPanel = { _, _, reply in reply(.OK) }; session.selectedOutputURL = { _ in chosenPatch }
        }
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path])
        try await wait { completions.count == 10 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0 && (try Data(contentsOf: chosenPatch)) == patchBytes, "Ownerless Save As acceptance lost exact unified bytes")
        // A recognized request with no loaded document must not report success on close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0 }
        }
        shown = []; try launch(["--base", target.path, "--mine", mine.path, "--readonly"])
        try await wait { shown.last is FileComparisonWindowController }
        let failed = shown.last as! FileComparisonWindowController
        try await wait { !failed.model.mergeToolHasPendingWork && failed.model.error != nil }
        try require(failed.model.document == nil && workspace.mergeToolLaunches.values.first?.completionStatus == 1, "Failed comparison load became successful tool completion")
        failed.model.error = nil; try await wait { failed.window?.attachedSheet == nil }
        failed.close(); try await wait { completions.count == 11 && workspace.mergeToolLaunches.isEmpty && failed.window?.isVisible == false }
        try require(completions.last == 1, "Failed comparison close returned success")
        try await verifyInitialAuthorization(root:root,base:base,mine:mine,patchFile:patchFile,patchTarget:target,preferences:prefs,git:git)
        // Real startup dispatch chooses the Merge route once and uses injected process exit only after close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        let startup = TurtleGitApplicationDelegate(); var exitStatus: Int32?
        startup.startupArguments = ["--merge-tool", "--base", base.path, "--mine", mine.path, "--readonly"]
        startup.startupDirectory = root.path; startup.startupMergeToolExit = { exitStatus = $0 }
        shown = []; startup.repositoryModel = workspace; startup.startupDidFinishLaunching()
        let started = try await pair(); try require(exitStatus == nil, "Startup returned before the editor finished")
        let quitReply = startup.applicationShouldTerminate(NSApp)
        try require(quitReply == .terminateLater, "Standalone Quit bypassed owned completion: reply=\(quitReply.rawValue), windows=\(NSApp.windows.map { "\(type(of:$0)),visible=\($0.isVisible),sheet=\($0.attachedSheet != nil),delegate=\(String(describing:$0.delegate))" }), fileSessions=\(FileListComparisonSession.activeOperations), paneExports=\(FileComparisonWindowModel.activePaneExports)")
        try await wait { exitStatus != nil && workspace.mergeToolLaunches.isEmpty }
        try require(exitStatus == 0 && startup.startupDelivered && started.window?.isVisible == false, "Startup Merge Quit did not deliver exact exit after close")
        print("PASS: Merge tool launch: source routing, labels, exact private grants, separate saved output, changed-input cleanup fencing, raw unified output, reverse/readonly patch entry, held cancellation drain, failed-load exit and one-shot startup process completion")
    }
    private struct ScopeProvider:RepositoryBookmarkProvider {
        let allowed:Bool
        func create(for url:URL)throws->Data {Data(url.path.utf8)}
        func resolve(_ data:Data)throws->ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
        func startAccessing(_ url:URL)->Bool {allowed}
        func stopAccessing(_ url:URL) {}
    }
    // Invoke the public AppKit validation selector without Swift 6.4's
    // crashing optional-throwing protocol thunk; retain the actual NSError.
    @MainActor private static func validation(_ panel:NSOpenPanel,_ url:URL)throws->(Bool,NSError?) {
        guard let delegate=panel.delegate,let type=object_getClass(delegate as AnyObject),
              let method=class_getInstanceMethod(type,NSSelectorFromString("panel:validateURL:error:")) else{throw Failure(description:"Missing authorization validator selector")}
        typealias Validate = @convention(c) (AnyObject,Selector,AnyObject,NSURL,UnsafeMutablePointer<Unmanaged<AnyObject>?>)->ObjCBool
        let call=unsafeBitCast(method_getImplementation(method),to:Validate.self)
        var error:Unmanaged<AnyObject>?
        let accepted=call(delegate as AnyObject,NSSelectorFromString("panel:validateURL:error:"),panel,url as NSURL,&error)
        return(accepted.boolValue,error?.takeUnretainedValue() as? NSError)
    }
    @MainActor static func verifyInitialAuthorization(root:URL,base:URL,mine:URL,patchFile:URL,patchTarget:URL,preferences:UserDefaults,git:URL) async throws {
        let owner=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:500,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.orderFront(nil)
        var sessions=[MergeToolLaunchSession]()
        defer {sessions.forEach{$0.cancel()};owner.orderOut(nil);owner.close()}
        func session(_ arguments:[String])throws->MergeToolLaunchSession {
            guard let invocation=try MergeToolInvocation.parse(arguments:["--merge-tool"]+arguments,currentDirectory:root.path) else{throw Failure(description:"Missing authorization invocation")}
            let next=MergeToolLaunchSession(invocation:invocation,preferences:preferences,owner:owner)
            next.executable={git};sessions.append(next);return next
        }
        let args=["--base",base.path,"--mine",mine.path,"--readonly"]
        let cancelled=try session(args);var cancelErrors=[String](),cancelResults=[Int32]()
        cancelled.authorize={_,_ in nil};cancelled.onError={cancelErrors.append($0)};cancelled.onFinished={cancelResults.append($0)}
        cancelled.start();try await wait {cancelResults.count==1 && !cancelled.hasPendingWork}
        try require(cancelErrors.isEmpty && cancelResults==[1] && cancelled.editor==nil,"Initial chooser Cancel became a saved-permission error")
        cancelled.cancel();await Task.yield();try require(cancelResults==[1],"Cancelled authorization finished twice")
        let absentBase=root.appendingPathComponent("missing-authorization-base"),missing=try session(["--base",absentBase.path,"--mine",mine.path])
        var missingRequest:(String,Bool)?,missingDone=false,missingErrors=[String]()
        missing.authorize={url,folder in missingRequest=(url.path,folder);return nil};missing.onError={missingErrors.append($0)};missing.onFinished={_ in missingDone=true};missing.start()
        try await wait {missingDone && !missing.hasPendingWork}
        try require(missingRequest?.0==root.path && missingRequest?.1==true && missingErrors.isEmpty,"Missing input did not request cancellable parent-folder access")
        let wrong=try session(args);var wrongErrors=[String](),wrongDone=false
        wrong.requiresScopes=false;wrong.authorize={_,_ in RepositoryAccessLease(url:root.appendingPathComponent("unrelated"))}
        wrong.onError={wrongErrors.append($0)};wrong.onFinished={_ in wrongDone=true};wrong.start()
        try await wait {wrongDone && !wrong.hasPendingWork}
        try require(wrongErrors.count==1 && wrongErrors[0].contains(base.path) && !wrongErrors[0].contains("renew"),"Wrong selection lost requested-path diagnostic")
        let scope=try session(args);var scopeErrors=[String](),scopeDone=false
        scope.requiresScopes=true;scope.authorize={url,_ in RepositoryAccessLease(url:url,provider:ScopeProvider(allowed:false))}
        scope.onError={scopeErrors.append($0)};scope.onFinished={_ in scopeDone=true};scope.start()
        try await wait {scopeDone && !scope.hasPendingWork}
        try require(scopeErrors.count==1 && scopeErrors[0].contains(base.path) && scopeErrors[0].contains("obtain access") && !scopeErrors[0].contains("renew"),"Fresh scope failure was mislabeled as expired saved permission")
        let corrective=try session(args);var panels=[NSOpenPanel](),replies=[(NSApplication.ModalResponse)->Void](),selected:URL?,correctedResults=[Int32](),correctedErrors=[String]()
        corrective.requiresScopes=true;corrective.makePermissionLease={RepositoryAccessLease(url:$0,provider:ScopeProvider(allowed:true))}
        corrective.presentPermissionPanel={panel,parent,reply in panel.alphaValue=0;panels.append(panel);replies.append(reply);parent!.beginSheet(panel,completionHandler:nil)}
        corrective.selectedPermissionURL={_ in selected};corrective.onError={correctedErrors.append($0)};corrective.onFinished={correctedResults.append($0)}
        corrective.presentation={$0.window?.alphaValue=0;$0.window?.orderFront(nil)}
        corrective.start();try await wait {panels.count==1 && panels[0].sheetParent===owner}
        try require(panels[0].canChooseFiles && !panels[0].canChooseDirectories && panels[0].alphaValue==0,"File authorization did not retain exact owned native panel")
        let rejected=try validation(panels[0],mine)
        try require(!rejected.0 && rejected.1?.localizedDescription.contains(base.path)==true && panels[0].sheetParent===owner && corrective.preparing,"Wrong file closed the corrective picker or lost its diagnostic")
        let accepted=try validation(panels[0],base)
        try require(accepted.0 && accepted.1==nil,"Correct requested file was rejected by the native picker")
        selected=base;replies[0](.OK);replies[0](.OK)
        try await wait {panels.count==2 && panels[1].sheetParent===owner && panels[0].sheetParent==nil}
        selected=mine;replies[1](.OK)
        try await wait {corrective.editor is FileComparisonWindowController && !corrective.preparing}
        let comparison=corrective.editor as! FileComparisonWindowController
        try await wait {!comparison.model.busy && comparison.model.document != nil}
        try require(correctedErrors.isEmpty && owner.attachedSheet==nil && panels.allSatisfy{$0.sheetParent==nil && !$0.isVisible},"Editor published before authorization panels drained")
        comparison.close();try await wait {correctedResults==[0] && !corrective.hasPendingWork}
        let retired=try session(args);var lateReply:((NSApplication.ModalResponse)->Void)?,latePanel:NSOpenPanel?,retiredResults=[Int32](),retiredErrors=[String]()
        retired.requiresScopes=true;retired.presentPermissionPanel={panel,parent,reply in latePanel=panel;lateReply=reply;panel.alphaValue=0;parent!.beginSheet(panel,completionHandler:nil)}
        retired.selectedPermissionURL={_ in base};retired.onError={retiredErrors.append($0)};retired.onFinished={retiredResults.append($0)}
        retired.start();try await wait {latePanel?.sheetParent===owner};retired.cancel()
        try await wait {retiredResults==[1] && !retired.hasPendingWork && owner.attachedSheet==nil && latePanel?.sheetParent==nil}
        lateReply?(.OK);await Task.yield()
        try require(retiredResults==[1] && retiredErrors.isEmpty && retired.editor==nil,"Late authorization callback reopened a retired launch")
        let theirs=root.appendingPathComponent("authorization-theirs"),mergeFolder=root.appendingPathComponent("authorization-result")
        try Data("theirs\nshared\n".utf8).write(to:theirs);try FileManager.default.createDirectory(at:mergeFolder,withIntermediateDirectories:false)
        let mergeOutput=mergeFolder.appendingPathComponent("result"),merge=try session(["--base",base.path,"--theirs",theirs.path,"--mine",mine.path,"--merged",mergeOutput.path])
        var mergeRequests=[(String,Bool)](),mergeResults=[Int32](),mergeErrors=[String]()
        merge.requiresScopes=true;merge.authorize={url,folder in mergeRequests.append((url.path,folder));return RepositoryAccessLease(url:url,provider:ScopeProvider(allowed:true))}
        merge.presentation={$0.window?.alphaValue=0;$0.window?.orderFront(nil)};merge.onError={mergeErrors.append($0)};merge.onFinished={mergeResults.append($0)};merge.start()
        try await wait {merge.editor is TextConflictWindowController && !merge.preparing}
        let merged=merge.editor as! TextConflictWindowController
        try await wait {!merged.model.busy && merged.model.document != nil}
        try require(mergeErrors.isEmpty && mergeRequests.map{$0.0} == [base.path,theirs.path,mine.path,mergeFolder.path] && mergeRequests.map{$0.1} == [false,false,false,true],"Three-way initial roles or result-folder grant were conflated")
        merged.close();try await wait {mergeResults==[1] && !merge.hasPendingWork}
        try require(!FileManager.default.fileExists(atPath:mergeOutput.path),"Authorization alone wrote an unsaved merge output")
        let patchLaunch=try session(["--diff",patchFile.path,"--patchpath",patchTarget.path,"--reversedpatch","--readonly"])
        var patchRequests=[(String,Bool)](),patchResults=[Int32](),patchErrors=[String]()
        patchLaunch.requiresScopes=true;patchLaunch.authorize={url,folder in patchRequests.append((url.path,folder));return RepositoryAccessLease(url:url,provider:ScopeProvider(allowed:true))}
        patchLaunch.configurePatchWorkflow={$0.chooseBetterTarget={_,_ in .original}}
        patchLaunch.presentation={$0.window?.alphaValue=0;$0.window?.orderFront(nil)};patchLaunch.onError={patchErrors.append($0)};patchLaunch.onFinished={patchResults.append($0)};patchLaunch.start()
        try await wait {patchLaunch.editor is WorkingTreePatchWindowController && !patchLaunch.preparing}
        let patchReview=patchLaunch.editor as! WorkingTreePatchWindowController
        try await wait {!patchReview.model.busy && patchReview.model.review != nil}
        try require(patchErrors.isEmpty && patchRequests.map{$0.0} == [patchFile.path,patchTarget.path] && patchRequests.map{$0.1} == [false,true] && patchReview.model.mergeToolReadOnly,"Patch input and target-folder permissions were conflated")
        patchReview.close();try await wait {patchResults==[0] && !patchLaunch.hasPendingWork}
        let unifiedOutput=root.appendingPathComponent("authorized-unified.patch"),unified=try session(["--createunifieddiff","--origfile",base.path,"--modifiedfile",mine.path,"--outfile",unifiedOutput.path])
        var requests=[(String,Bool)](),unifiedResults=[Int32](),unifiedErrors=[String]()
        unified.requiresScopes=true;unified.authorize={url,folder in requests.append((url.path,folder));return RepositoryAccessLease(url:url,provider:ScopeProvider(allowed:true))}
        unified.onError={unifiedErrors.append($0)};unified.onFinished={unifiedResults.append($0)};unified.start()
        try await wait {unifiedResults==[0] && !unified.hasPendingWork}
        try require(unifiedErrors.isEmpty && requests.count==3 && requests[0].0==base.path && !requests[0].1 && requests[1].0==mine.path && !requests[1].1 && requests[2].0==unifiedOutput.deletingLastPathComponent().path && requests[2].1,"Unified input/output grant roles were not captured separately")
        let unifiedBytes=try Data(contentsOf:unifiedOutput)
        try require(String(decoding:unifiedBytes,as:UTF8.self).contains("+after"),"Authorized unified output did not contain actual input change")
        print("PASS: initial CLI access Cancel/wrong selection/fresh scope failure, corrective native file picker, retired/double callback drain and exact unified-output parent grants")
    }

}
