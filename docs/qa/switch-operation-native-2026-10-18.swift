// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum SwitchOperationVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2400 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Switch operation timed out at \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func click(_ title:String,in window:NSWindow) throws {
        guard let content=window.contentView,let button=views(content).compactMap({$0 as? NSButton}).first(where:{$0.title == title}) else{throw Failure(message:"Native Switch button missing: "+title)}
        button.performClick(nil)
    }
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Switch Operation QA"),("user.email","switch@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["checkout","-b","topic"])
        try Data("topic\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"topic")
        let topic=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        _ = try await repo.run(["tag","new-work"]);_ = try await repo.run(["checkout","main"])
        let suite="TurtleGit.SwitchOperation.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"ConfirmKillProcess")
        defer {prefs.removePersistentDomain(forName:suite)}
        var owners:[SwitchWindowController]=[],progressOwners:[SwitchProgressWindowController]=[]
        var heldRead:CheckedContinuation<([CheckoutReference],String),Error>?,heldGit:CheckedContinuation<String,Error>?
        func drained()->Bool {SwitchWindowModel.activeReads == 0 && SwitchProgressWindowModel.activeOperations == 0 && SwitchWindowController.activeChildReleases == 0 && LocalGitCommandProgress.activeOperations == 0}
        func make(_ revision:String?=nil)->SwitchWindowController {
            let owner=SwitchWindowController(repository:repo,access:nil,revision:revision,preferences:prefs)
            owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);owner.window?.orderFront(nil);owners.append(owner);return owner
        }
        func cleanup() async throws {
            owners.forEach {$0.close()};progressOwners.forEach {$0.close()}
            let read=heldRead,command=heldGit;heldRead=nil;heldGit=nil;read?.resume(throwing:OperationCancellationFailure.cancelled);command?.resume(throwing:OperationCancellationFailure.cancelled)
            try await wait {drained() && owners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil} && progressOwners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil}}
        }
        do {
            let owner=make(topic),model=owner.model;model.load();try await wait {model.canEditForm}
            let old=model.formContext
            model.confirmingQuit=true;model.option(\.merge,context:old).wrappedValue=true;model.browse(.commit);model.checkout()
            try require(!model.options.merge && model.pickerTarget == nil && model.progress == nil && !owner.windowShouldClose(owner.window!),"Deferred Quit allowed Switch form/commands")
            model.confirmingQuit=false;model.option(\.merge,context:old).wrappedValue=true
            try require(!model.options.merge,"Cancelled Quit revived a retained form receipt")
            model.options.createBranch=true;model.options.branchName="new-work"
            model.checkout();try await wait {model.hasPendingTagConflict && owner.window?.attachedSheet != nil && !model.busy}
            let question=owner.window!.attachedSheet!
            try require(question.alphaValue == 0 && question.appearance?.name == owner.window?.appearance?.name && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Tag warning lost hidden appearance/ownership")
            // Validation captured this exact options draft before the modal warning.
            model.options.branchName="must-not-be-created"
            var actions=0,detached=false,oldBranch=""
            model.onPostAction = {action,previous in actions += 1;oldBranch=previous;detached = action == .mergePreviousBranch && owner.window?.isVisible != true && owner.window?.attachedSheet == nil && SwitchWindowController.activeChildReleases == 0}
            try click("Continue",in:question)
            try await wait {owner.progressController?.model.busy == false}
            let progress=owner.progressController!
            let actual=try await repo.branch()
            try require(actual == "new-work" && progress.model.options.branchName == "new-work" && progress.model.success && progress.model.postActions == [.mergePreviousBranch,.pull,.commit] && progress.window?.alphaValue == 0 && progress.window?.appearance?.name == owner.window?.appearance?.name,"Captured warning/options or source successful actions changed")
            model.confirmingQuit=true;progress.model.perform(.mergePreviousBranch);try require(actions == 0,"Deferred Quit accepted completed Switch action")
            model.confirmingQuit=false;progress.model.perform(.mergePreviousBranch);progress.model.perform(.mergePreviousBranch)
            try await wait {actions == 1 && model.closed && drained()}
            try require(detached && oldBranch == "main","Switch follow-up preceded actual closure or lost original branch")

            _ = try await repo.run(["checkout","main"])
            try Data("dirty\n".utf8).write(to:file)
            let failing=make("refs/heads/new-work");failing.model.load();try await wait {failing.model.canEditForm}
            failing.model.checkout();try await wait {failing.progressController?.model.busy == false}
            let failed=failing.progressController!
            try require(!failed.model.success && failed.model.postActions == [.stash,.retry,.switchWithMerge],"Failed checkout lost source recovery choices")
            failed.model.perform(.switchWithMerge);failed.model.perform(.switchWithMerge)
            try await wait {!failed.model.busy && failed.model.postActions == [.resolve,.retry]}
            try require(!failed.model.success && failed.model.output.contains("Has merge conflict"),"Switch with Merge failed to expose real conflict recovery")
            var resolves=0,resolveDetached=false
            failing.model.onPostAction = {action,_ in resolves += 1;resolveDetached = action == .resolve && failing.window?.isVisible != true && failing.window?.attachedSheet == nil}
            failed.model.perform(.resolve);failed.model.perform(.resolve)
            try await wait {resolves == 1 && failing.model.closed && drained()}
            try require(resolveDetached,"Failed Switch recovery kept the obsolete options modal alive")
            _ = try await repo.run(["reset","--hard","HEAD"])

            // A held backend exercises the actual Cancel sheet and retirement,
            // without creating a helper process or modifying the user's desktop.
            let slowModel=SwitchProgressWindowModel(repository:repo,access:nil,reference:"refs/heads/main",preferences:prefs)
            var token:OperationCancellation?
            slowModel.checkoutOperation = {_,cancel,_ in token=cancel;return try await withCheckedThrowingContinuation {heldGit=$0}}
            let slow=SwitchProgressWindowController(model:slowModel);progressOwners.append(slow)
            slow.window?.alphaValue=0;slow.window?.appearance=NSAppearance(named:.darkAqua);slow.window?.orderFront(nil);slowModel.start()
            try await wait {heldGit != nil};slowModel.cancel();try await wait {slow.window?.attachedSheet != nil}
            let cancel=slow.window!.attachedSheet!
            try require(cancel.alphaValue == 0 && cancel.appearance?.name == slow.window?.appearance?.name,"Cancellation sheet escaped hidden source appearance")
            try click("No",in:cancel);try await wait {!slowModel.confirmingCancellation && slow.window?.attachedSheet == nil}
            try require(token?.isCancelled == false && slowModel.busy,"Declining Cancel killed Switch")
            slowModel.cancel();try await wait {slow.window?.attachedSheet != nil};try click("Yes",in:slow.window!.attachedSheet!)
            try await wait {token?.isCancelled == true}
            slow.close();try require(SwitchProgressWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed progress released its backend early")
            let late=heldGit;heldGit=nil;late?.resume(returning:"late success")
            try await wait {drained()};try require(!slowModel.success,"Late backend revived closed progress")

            let retiring=make();retiring.model.readInitialReferences = {_ in try await withCheckedThrowingContinuation {heldRead=$0}}
            retiring.model.load();try await wait {heldRead != nil};retiring.close()
            try require(SwitchWindowModel.activeReads > 0,"Retired initial catalog lost owned work")
            let lateRead=heldRead;heldRead=nil;lateRead?.resume(returning:([],"main"))
            try await wait {drained()};try require(retiring.model.closed && retiring.model.references.isEmpty,"Late catalog revived retired Switch")
            try await cleanup()
            print("PASS: Switch hidden native tag warning/captured options, successful source action order, once-only detached follow-up, real failed checkout/merge conflict recovery, deferred Quit/stale controls, actual Cancel No/Yes, retired backend/catalog ownership")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
}
