import AppKit
import SwiftUI
import TurtleGitCore

@main struct BranchTagHandoffVerification {
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws { let end = Date().addingTimeInterval(30); while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }; precondition(condition(),"Branch/Tag timed out") }
    @MainActor static func wait(_ name:String,state:()->String = {""},_ condition:@escaping ()->Bool) async throws {
        let end=Date().addingTimeInterval(30)
        while !condition() && Date()<end {try await Task.sleep(nanoseconds:10_000_000)}
        precondition(condition(),"\(name): \(state())")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2]), suite = "TurtleGit.BranchTagHandoff.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!; defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }; prefs.set(0,forKey:"AutoCloseGitProgress")
        DialogGeometry.install(preferences:prefs);defer {DialogGeometry.install(preferences:.standard)}
        let repo = GitRepository(root:root,executable:git); _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Reference QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let base = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("next\n".utf8).write(to:root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"next")
        let next = try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        // Production-style callback hosts the real Switch model. Description is
        // written after result acknowledgement, not before checkout.
        let owner = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); owner.load(revision:"HEAD"); try await wait { !owner.busy && !owner.chooser.busy }; precondition(owner.useHead)
        owner.options.name = "topic"; owner.options.message = "  first\r\nsecond  "; owner.switchAfterCreation = true
        var result:SwitchProgressWindowModel?, acknowledge:(()->Void)?, events:[String] = []
        owner.onCreated = { _ in events.append("created") }; owner.close = { events.append("close") }
        owner.onSwitch = { ref,done in precondition(ref == "refs/heads/topic"); events.append("switch"); acknowledge = done; let model = SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs); result = model; model.close = done; model.start() }
        owner.create(); owner.load(revision:base); try await wait { result?.busy == false }
        precondition(owner.busy && result!.success && events == ["created","switch"] && owner.options.name == "topic")
        let beforeDescription = try await repo.run(["config","--get","branch.topic.description"],successfulExitCodes:0...1); precondition(beforeDescription.exitCode == 1)
        let branch = try await repo.branch(); precondition(branch == "topic")
        acknowledge?(); acknowledge?(); try await wait { !owner.busy }; let description = try await repo.run(["config","--get","branch.topic.description"]).text; precondition(description == "first\nsecond\n" && events == ["created","switch","close"]); owner.create(); precondition(events.count == 3)
        // Failed checkout exposes source Stash/Retry/merge recovery and still
        // writes the description after closing, while the created ref survives.
        _ = try await repo.run(["checkout","main"]); try Data("working\n".utf8).write(to:root.appendingPathComponent("file"))
        let failure = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); failure.load(revision:base); try await wait { !failure.busy && !failure.chooser.busy }; failure.options.name = "older"; failure.options.message = "older description"; failure.switchAfterCreation = true
        var failedResult:SwitchProgressWindowModel?, failedDone:(()->Void)?; failure.onSwitch = { ref,done in failedDone = done; let model = SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs); failedResult = model; model.start() }; failure.create(); try await wait { failedResult?.busy == false }
        precondition(!failedResult!.success && failedResult!.postActions == [.stash,.retry,.switchWithMerge] && failure.busy)
        let oldRef = try await repo.run(["rev-parse","refs/heads/older"]).text.trimmingCharacters(in:.newlines); precondition(oldRef == base)
        failedDone?(); try await wait { !failure.busy }; let retainedBranch = try await repo.branch(), retainedWorking = try String(contentsOf:root.appendingPathComponent("file")), failedDescription = try await repo.run(["config","--get","branch.older.description"]).text; precondition(retainedBranch == "main" && retainedWorking == "working\n" && failedDescription == "older description\n")
        _ = try await repo.run(["reset","--hard",next])
        // A foreign config lock after actual checkout keeps only description
        // retry. Retry neither recreates the ref nor switches again.
        let lockedOwner = BranchTagWindowController(repository:repo,access:nil,isTag:false,preferences:prefs), locked=lockedOwner.model
        defer { lockedOwner.window?.close() }
        guard let lockedWindow=lockedOwner.window else {preconditionFailure("Config-lock owner missing")}
        lockedWindow.alphaValue=0;lockedWindow.setFrameOrigin(NSPoint(x:-18000,y:-18000));lockedWindow.orderFront(nil)
        var lockedErrorReply:((NSApplication.ModalResponse)->Void)?,lockedAlert:NSAlert?,lockedErrorQuestions=0
        lockedOwner.presentQuestion={kind,alert,parent,reply in
            guard case .error(let message)=kind else {preconditionFailure("Unexpected config-lock question")}
            precondition(parent === lockedWindow && !message.isEmpty && alert.buttons.count==1 && lockedErrorReply==nil)
            lockedErrorQuestions += 1;lockedAlert=alert;lockedErrorReply=reply
            alert.window.alphaValue=0;alert.window.setFrameOrigin(NSPoint(x:-18000,y:-18000));parent.beginSheet(alert.window)
        }
        locked.load(revision:nil);try await wait {!locked.busy && !locked.chooser.busy}
        locked.options.name="locked";locked.options.message="captured description";locked.switchAfterCreation=true
        var lockedDone:(()->Void)?,lockedSwitch:SwitchProgressWindowModel?,switchCalls=0,lockedCloses=0
        lockedOwner.onClosed={lockedCloses += 1}
        locked.onSwitch={ref,done in switchCalls += 1;lockedDone=done;let model=SwitchProgressWindowModel(repository:repo,access:nil,reference:ref,preferences:prefs);lockedSwitch=model;model.start()}
        locked.create();try await wait {lockedSwitch?.busy==false}
        let lock=root.appendingPathComponent(".git/config.lock");try Data("foreign lock".utf8).write(to:lock);lockedDone?()
        try await wait {!locked.busy && lockedErrorReply != nil && lockedAlert?.window.sheetParent === lockedWindow}
        precondition(locked.retryDescription && locked.error != nil && lockedCloses==0 && lockedErrorQuestions==1)
        precondition(lockedOwner.questionWindow === lockedAlert?.window && lockedWindow.attachedSheet === lockedAlert?.window && lockedWindow.alphaValue==0 && lockedAlert?.window.alphaValue==0)
        let lockedRef=try await repo.run(["rev-parse","refs/heads/locked"]).stdout,lockBytes=try Data(contentsOf:lock)
        precondition(lockBytes==Data("foreign lock".utf8));try FileManager.default.removeItem(at:lock)
        // Retry is unavailable until the actual owned error question is accepted.
        // Retain the failed phase and captured text despite later form edits.
        let capturedError=locked.error;locked.options.message="wrong later edit";locked.create()
        let beforeAcknowledgment=try await repo.run(["config","--get","branch.locked.description"],successfulExitCodes:0...1)
        precondition(!locked.busy && locked.error==capturedError && locked.retryDescription && beforeAcknowledgment.exitCode==1 && switchCalls==1 && lockedCloses==0)
        let errorReply=lockedErrorReply!;errorReply(.alertFirstButtonReturn);errorReply(.alertFirstButtonReturn)
        try await wait {locked.error==nil && lockedOwner.questionWindow==nil && lockedWindow.attachedSheet==nil && lockedAlert?.window.sheetParent==nil}
        precondition(locked.retryDescription && lockedCloses==0 && lockedErrorQuestions==1)
        locked.create();try await wait {!locked.busy && !lockedOwner.hasPendingWork && lockedCloses==1}
        errorReply(.alertFirstButtonReturn)
        let sameRef=try await repo.run(["rev-parse","refs/heads/locked"]).stdout,lockedDescription=try await repo.run(["config","--get","branch.locked.description"]).text
        precondition(sameRef==lockedRef && lockedDescription=="captured description\n" && switchCalls==1 && lockedCloses==1 && lockedErrorQuestions==1 && lockedOwner.questionWindow==nil)
        // Tag Push and cross-name Continue use captured names/options/intent.
        var shared = ReferenceCreationOptions(); shared.name = "shared"; _ = try await repo.createReference(shared)
        let tag = BranchTagWindowModel(repository:repo,access:nil,isTag:true,preferences:prefs); tag.load(revision:nil); try await wait { !tag.busy && !tag.chooser.busy }; tag.onSwitch = { _,_ in preconditionFailure("Tag must not Switch") }; tag.options.name = "shared"; tag.options.message = "captured tag"; tag.pushAfterCreation = true
        var pushed:[String] = []; tag.onPushTag = { pushed.append($0) }; tag.create(); try await wait { !tag.busy }; precondition(tag.hasPendingNameConflict)
        tag.options.name = "wrong-name"; tag.options.message = "wrong message"; tag.pushAfterCreation = false; tag.create(); tag.create(allowNameConflict:true); try await wait { !tag.busy }
        let tagMessage = try await repo.run(["for-each-ref","--format=%(contents)","refs/tags/shared"]).text; precondition(pushed == ["refs/tags/shared"] && tagMessage.contains("captured tag")); let wrongTag = try? await repo.run(["show-ref","--verify","refs/tags/wrong-name"]); precondition(wrongTag == nil)
        let noPush = BranchTagWindowModel(repository:repo,access:nil,isTag:true,preferences:prefs); noPush.load(revision:nil); try await wait { !noPush.busy && !noPush.chooser.busy }; noPush.onSwitch = { _,_ in preconditionFailure("Tag must not Switch") }; noPush.options.name = "no-push"; noPush.pushAfterCreation = false; noPush.onPushTag = { _ in preconditionFailure("Later Push edit") }; noPush.create(); noPush.pushAfterCreation = true; try await wait { !noPush.busy }
        // A production presenter with unchecked Switch still saves description,
        // and force + whitespace removes old config without moving HEAD.
        let unchecked = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); unchecked.load(revision:nil); try await wait { !unchecked.busy && !unchecked.chooser.busy }
        unchecked.options.name = "unswitched"; unchecked.options.message = "old description"; unchecked.switchAfterCreation = false
        unchecked.onSwitch = { _,_ in preconditionFailure("Unchecked Switch") }; unchecked.create(); try await wait { !unchecked.busy }
        let unswitchedValue = try await repo.run(["config","--get","branch.unswitched.description"]).text; precondition(unswitchedValue == "old description\n")
        let whitespace = BranchTagWindowModel(repository:repo,access:nil,isTag:false,preferences:prefs); whitespace.load(revision:nil); try await wait { !whitespace.busy && !whitespace.chooser.busy }
        whitespace.options.name = "unswitched"; whitespace.options.force = true; whitespace.options.message = " \r\n\t "; whitespace.switchAfterCreation = false; whitespace.onSwitch = { _,_ in preconditionFailure("Unchecked Switch") }; whitespace.create(); try await wait { !whitespace.busy }
        let absent = try await repo.run(["config","--get","branch.unswitched.description"],successfulExitCodes:0...1), untouchedBranch = try await repo.branch(); precondition(absent.exitCode == 1 && untouchedBranch == "locked")
        // Closing during initial reads is a real cancellation: the owner retires
        // after drainage. A separate live owner is needed for the conflict case.
        let loadingOwner=BranchTagWindowController(repository:repo,access:nil,isTag:true,preferences:prefs)
        defer {loadingOwner.window?.close()}
        guard let loadingWindow=loadingOwner.window else {preconditionFailure("Initial-read owner missing")}
        loadingWindow.alphaValue=0;loadingWindow.setFrameOrigin(NSPoint(x:-18000,y:-18000));loadingWindow.orderFront(nil)
        var loadingCloses=0;loadingOwner.onClosed={loadingCloses += 1}
        loadingOwner.model.load(revision:nil)
        precondition(loadingOwner.model.hasPendingWork,"Initial load did not own pending work")
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit admitted an initial Branch/Tag read")
        precondition(!loadingOwner.windowShouldClose(loadingWindow),"Initial-read close bypassed owned cancellation")
        try await wait("Initial-read cancellation drains and retires",state:{"pending=\(loadingOwner.hasPendingWork), active=\(loadingOwner.model.active), closes=\(loadingCloses)"}) {!loadingOwner.hasPendingWork && !loadingOwner.model.active && loadingCloses==1}
        precondition(loadingCloses==1,"Initial-read cancellation did not close exactly once")

        let controller=BranchTagWindowController(repository:repo,access:nil,isTag:true,preferences:prefs)
        defer {controller.window?.close()}
        guard let conflictWindow=controller.window else {preconditionFailure("Conflict owner missing")}
        conflictWindow.alphaValue=0;conflictWindow.setFrameOrigin(NSPoint(x:-18000,y:-18000));conflictWindow.orderFront(nil)
        var conflictReply:((NSApplication.ModalResponse)->Void)?,conflictAlert:NSAlert?,conflictQuestions=0,conflictCloses=0
        controller.onClosed={conflictCloses += 1}
        controller.presentQuestion={kind,alert,parent,reply in
            precondition(kind == .nameConflict,"Unexpected conflict-owner question: \(kind)")
            precondition(parent === conflictWindow && conflictReply==nil && alert.buttons.count==2,"Conflict question lost native owner/one-shot identity")
            conflictQuestions += 1;conflictReply=reply;conflictAlert=alert
            alert.window.alphaValue=0;alert.window.setFrameOrigin(NSPoint(x:-18000,y:-18000));parent.beginSheet(alert.window)
        }
        controller.model.load(revision:nil);try await wait("Fresh conflict owner becomes editable",state:{"busy=\(controller.model.busy), chooser=\(controller.model.chooser.busy), active=\(controller.model.active), error=\(controller.model.error ?? "nil")"}) {!controller.model.busy && !controller.model.chooser.busy && controller.model.canEditForm}
        let host=NSHostingView(rootView:BranchTagDialog(model:controller.model,chooser:controller.model.chooser));host.frame=NSRect(x:0,y:0,width:660,height:480);host.layoutSubtreeIfNeeded()
        precondition(host.fittingSize.width>0,"Conflict form has no native layout")
        controller.model.options.name="topic";controller.model.create()
        try await wait("Actual cross-name conflict question attaches",state:{"busy=\(controller.model.busy), conflict=\(controller.model.hasPendingNameConflict), questions=\(conflictQuestions), active=\(controller.model.active), error=\(controller.model.error ?? "nil")"}) {!controller.model.busy && controller.model.hasPendingNameConflict && conflictReply != nil && conflictAlert?.window.sheetParent === conflictWindow}
        precondition(controller.model.hasPendingNameConflict,"Cross-name creation lost pending conflict: error=\(controller.model.error ?? "nil"), active=\(controller.model.active), pending=\(controller.model.hasPendingWork)")
        precondition(controller.questionWindow === conflictAlert?.window && conflictWindow.attachedSheet === conflictAlert?.window,"Conflict alert lost actual sheet ownership")
        precondition(conflictQuestions==1 && conflictCloses==0,"Conflict question repeated or closed its owner")
        precondition(!controller.windowShouldClose(conflictWindow),"Pending conflict admitted ordinary owner close")
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit admitted an owned conflict question")
        let lateConflictReply=conflictReply!;controller.close()
        lateConflictReply(.alertFirstButtonReturn);lateConflictReply(.alertFirstButtonReturn);controller.model.create(allowNameConflict:true)
        try await wait("Retired conflict owner and sheet drain",state:{"pending=\(controller.hasPendingWork), questions=\(conflictQuestions), closes=\(conflictCloses)"}) {!controller.hasPendingWork && conflictCloses==1}
        let lateTag=try? await repo.run(["show-ref","--verify","refs/tags/topic"])
        precondition(lateTag==nil,"Retired conflict response created the late tag")
        precondition(conflictCloses==1 && controller.questionWindow==nil && conflictWindow.attachedSheet==nil && conflictAlert?.window.sheetParent==nil,"Retired conflict failed once-only native question drainage")
        print("Branch/Tag: source-order real Switch/description acknowledgement, failed-checkout recovery actions/ref retention, foreign config lock with actual owned error acknowledgment/detach, refused early retry and captured description-only retry, captured Tag Push/cross-name intent, duplicate/load/invalidation guards and native close/Quit. Hidden controller closed; no displayed UI/push/network or standard preference writes.")
    }
}
