// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum StashOperationVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2400 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Stash operation timed out at \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func click(_ title:String,in window:NSWindow) throws {
        guard let content=window.contentView,let button=views(content).compactMap({$0 as? NSButton}).first(where:{$0.title == title}) else {throw Failure(message:"Missing native button \(title)")}
        button.performClick(nil)
    }
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Stash Operation QA"),("user.email","stash@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let suite="TurtleGit.StashOperation.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"HintHierarchicalConfig")
        defer {prefs.removePersistentDomain(forName:suite)}
        var owners:[StashWindowController]=[],restores:[StashRestoreWindowController]=[],held:CheckedContinuation<ReplayUserIdentity,Error>?
        func drained()->Bool {StashWindowModel.activePreparations == 0 && StashWindowController.activeChildReleases == 0 && StashRestoreWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0 && SettingsSheetController.activeSheets == 0}
        func make()->StashWindowController {
            let owner=StashWindowController(repository:repo,access:nil,preferences:prefs);owner.window?.alphaValue=0;owner.window?.appearance=NSAppearance(named:.darkAqua);owner.window?.orderFront(nil);owners.append(owner);return owner
        }
        func cleanup() async throws {
            owners.forEach {$0.close()};restores.forEach {$0.close()};let pending=held;held=nil;pending?.resume(throwing:OperationCancellationFailure.cancelled)
            try await wait {drained() && owners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil} && restores.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil}}
        }
        do {
            let cancelled=make()
            cancelled.model.readIdentity = {_ in .init(authorName:"",authorEmail:"",committerName:"",committerEmail:"")}
            cancelled.model.prepare();try await wait {cancelled.identitySettingsWindow != nil}
            try require(cancelled.model.preparing && cancelled.model.hasIdentitySettings && cancelled.identitySettingsWindow?.alphaValue == 0 && !cancelled.model.canEditForm,"Missing identity did not own hidden disabled preparation")
            cancelled.model.cancel();try await wait {cancelled.model.closed && drained()}

            let owner=make(),model=owner.model;var repaired=false,reads=0
            model.readIdentity = {token in reads += 1;if repaired {return try await repo.replayUserIdentity(cancellation:token)};return .init(authorName:"",authorEmail:"",committerName:"",committerEmail:"")}
            model.prepare();try await wait {owner.identitySettingsWindow != nil}
            repaired=true;try click("OK",in:owner.identitySettingsWindow!)
            try await wait {model.prepared && !model.busy && owner.identitySettingsWindow == nil && owner.window?.attachedSheet == nil}
            try require(reads >= 2,"Settings acceptance skipped effective identity reread")
            let old=model.formContext
            model.confirmingQuit=true;model.option(\.message,context:old).wrappedValue="stale";model.save()
            try require(model.options.message.isEmpty && model.progress == nil && !owner.windowShouldClose(owner.window!),"Deferred Quit accepted Save/form action")
            model.confirmingQuit=false;model.option(\.message,context:old).wrappedValue="stale"
            try require(model.options.message.isEmpty,"Cancelled Quit revived obsolete input receipt")
            model.options.all=true;model.option(\.includeUntracked,context:model.formContext).wrappedValue=true
            try require(!model.options.includeUntracked,"Disabled option accepted retained mutation")
            model.options.all=false;model.options.includeUntracked=true
            try Data("working\n".utf8).write(to:root.appendingPathComponent("file"));try Data("new\n".utf8).write(to:root.appendingPathComponent("untracked"))
            model.save();try await wait {owner.window?.attachedSheet != nil && model.confirmingUntracked}
            let warning=owner.window!.attachedSheet!
            try require(warning.alphaValue == 0 && warning.appearance?.name == owner.window?.appearance?.name && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pending warning escaped appearance/Quit ownership")
            try click("Abort",in:warning);try await wait {!model.confirmingUntracked && owner.window?.attachedSheet == nil && drained()}
            try require(model.progress == nil && !prefs.bool(forKey:"Stash.NoIncludeUntrackedWarning"),"Aborted warning changed suppression or launched Save")
            model.options.message="native stash"
            var dispatched=0,detached=false
            model.followUp.showPull=true
            model.onPostAction = {action,_ in dispatched += 1;detached = action == .pull && owner.window?.attachedSheet == nil && owner.window?.isVisible != true && StashWindowController.activeChildReleases == 0}
            model.save();try await wait {model.confirmingUntracked && owner.window?.attachedSheet != nil}
            try click("Continue",in:owner.window!.attachedSheet!)
            try await wait {owner.progressController != nil && model.progress?.busy == false}
            let progress=owner.progressController!
            try require(progress.window?.alphaValue == 0 && progress.window?.appearance?.name == owner.window?.appearance?.name && progress.model.result?.created == true && progress.model.options.requireIdentity && progress.model.postActions == [.pull,.pop,.apply],"Source Save options/identity/completion order missing")
            model.confirmingQuit=true;progress.model.perform(.pull);try require(dispatched == 0,"Deferred Quit accepted progress follow-up")
            model.confirmingQuit=false;progress.model.perform(.pull);progress.model.perform(.pull)
            try await wait {dispatched == 1 && model.closed && drained()}
            try require(detached,"Save follow-up preceded actual options/progress closure")

            let restore=StashRestoreWindowController(repository:repo,access:nil,pop:false,preferences:prefs)
            restores.append(restore);restore.window?.alphaValue=0;restore.window?.appearance=NSAppearance(named:.darkAqua);restore.window?.orderFront(nil)
            var viewed=0,restoreDetached=false
            restore.onViewChanges = {viewed += 1;restoreDetached=restore.window?.isVisible != true && restore.window?.attachedSheet == nil && StashWindowController.activeChildReleases == 0}
            restore.start();try await wait {restore.model.prompt != nil && restore.window?.attachedSheet != nil}
            let question=restore.window!.attachedSheet!
            try require(question.alphaValue == 0 && question.appearance?.name == restore.window?.appearance?.name && restore.model.result?.conflicted == false,"Apply result did not inherit hidden native presentation")
            try click("Yes",in:question)
            try await wait {viewed == 1 && drained()}
            try require(restoreDetached,"View Changes preceded actual result/restore closure")
            let retained=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
            try require(!retained.isEmpty,"Apply dropped the saved stash")

            let retiring=make();retiring.model.readIdentity = {_ in try await withCheckedThrowingContinuation {held=$0}}
            retiring.model.prepare();try await wait {held != nil};retiring.close()
            try require(StashWindowModel.activePreparations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced closure released noncooperative preflight ownership early")
            let late=held;held=nil;late?.resume(returning:try await repo.replayUserIdentity())
            try await wait {drained()};try require(retiring.model.closed && !retiring.model.prepared && retiring.model.progress == nil,"Late identity read revived retired Save")
            try await cleanup()
            print("PASS: Stash actual Settings cancel/repair/reread, stale form/option receipts, hidden warning Abort/Quit, real captured Save with source postactions, once-only sheet-drained follow-up and Apply View Changes, retained stash and retired preparation ownership")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
}
