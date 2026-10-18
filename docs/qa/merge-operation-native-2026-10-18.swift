// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MergeOperationVerification {
    struct Failure: Error, LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ ok:Bool,_ message:String) throws {if !ok {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2400 {if ready() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Merge operation did not settle at \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Merge QA"),("user.email","merge@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("base"));try await repo.stage(["base"]);_ = try await repo.commit(message:"base")
        let initial=try await repo.run(["rev-parse","HEAD"]).text
        _ = try await repo.run(["checkout","-b","topic"])
        try Data("topic\n".utf8).write(to:root.appendingPathComponent("topic"));try await repo.stage(["topic"]);_ = try await repo.commit(message:"topic")
        _ = try await repo.run(["checkout","main"])
        let suite="TurtleGit.MergeOperation.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"StripCommentedLines");prefs.set(true,forKey:"SanitizeCommitMsg");prefs.set(0,forKey:"AutoCloseGitProgress")
        defer {prefs.removePersistentDomain(forName:suite)}
        var owners:[MergeWindowController]=[],held:CheckedContinuation<MergePreparation,Error>?
        func drained()->Bool {MergeWindowModel.activeReads == 0 && MergeProgressWindowModel.activeOperations == 0 && MergeWindowController.activeChildReleases == 0 && SettingsSheetController.activeSheets == 0}
        func make()->MergeWindowController {
            let owner=MergeWindowController(repository:repo,access:nil,preferences:prefs);owner.window?.alphaValue=0;owner.window?.orderFront(nil);owners.append(owner);return owner
        }
        func cleanup() async throws {
            owners.forEach {$0.close()};let reply=held;held=nil;reply?.resume(throwing:OperationCancellationFailure.cancelled)
            try await wait {drained() && owners.allSatisfy {$0.window?.isVisible != true && $0.window?.attachedSheet == nil}}
        }
        do {
            let owner=make(),model=owner.model,window=owner.window!
            var repaired=false,preparations=0
            model.readPreparation = {token in
                preparations += 1
                let real=try await repo.prepareMerge(cancellation:token)
                if !repaired {return MergePreparation(identity:.init(authorName:"",authorEmail:"",committerName:"",committerEmail:""),replayActive:false,hasGitSVN:false)}
                return real
            }
            model.load(revision:"refs/heads/topic")
            try await wait {owner.identitySettingsWindow != nil}
            try require(model.preparing && model.hasIdentitySettings && !model.canEditForm && owner.identitySettingsWindow?.sheetParent === window && owner.identitySettingsWindow?.alphaValue == 0 && !owner.windowShouldClose(window),"Identity repair did not own a hidden Settings sheet/preparation")
            // windowShouldClose above requests preparation cancellation; use a
            // fresh owner for the accepted repair so cancellation remains real.
            try await wait {model.closed && drained()}
            let repairedOwner=make(),repairedModel=repairedOwner.model
            repaired=false
            repairedModel.readPreparation = {token in
                preparations += 1
                let real=try await repo.prepareMerge(cancellation:token)
                return repaired ? real:MergePreparation(identity:.init(authorName:"",authorEmail:"",committerName:"",committerEmail:""),replayActive:false,hasGitSVN:false)
            }
            repairedModel.load(revision:"refs/heads/topic");try await wait {repairedOwner.identitySettingsWindow != nil}
            let settings=repairedOwner.identitySettingsWindow!
            repaired=true
            guard let okay=views(settings.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title == "OK"}) else {throw Failure(message:"Settings OK footer missing")}
            okay.performClick(nil)
            try await wait {repairedModel.prepared && !repairedModel.busy && repairedOwner.identitySettingsWindow == nil && repairedOwner.window?.attachedSheet == nil && drained()}
            try require(preparations >= 3 && repairedModel.branchRevision == "refs/heads/topic","Settings return skipped identity reread/reference preparation")
            let old=repairedModel.formContext
            repairedModel.confirmingQuit=true
            repairedModel.option(\.noFastForward,context:old).wrappedValue=true;repairedModel.merge()
            try require(!repairedModel.options.noFastForward && repairedModel.progress == nil && !repairedOwner.windowShouldClose(repairedOwner.window!),"Deferred Quit accepted Merge/form action")
            repairedModel.confirmingQuit=false
            repairedModel.option(\.noFastForward,context:old).wrappedValue=true
            try require(!repairedModel.options.noFastForward,"Cancelled Quit revived an old Merge form receipt")
            repairedModel.options.noFastForward=true
            repairedModel.options.squash=false
            repairedModel.option(\.squash,context:repairedModel.formContext).wrappedValue=true
            try require(!repairedModel.options.squash,"Disabled mutually exclusive Merge option accepted retained write")
            repairedModel.messageHistory.add("history message")
            var selectedHistory=0
            repairedOwner.showHistory {text in selectedHistory += 1;repairedModel.message=text}
            try await wait {repairedOwner.historyWindow?.sheetParent === repairedOwner.window}
            guard let history=repairedOwner.historyWindow,let historyView=history.contentView as? MessageHistoryPickerView else {throw Failure(message:"History native report missing")}
            try require(repairedModel.hasHistory && !repairedModel.canEditMessage && history.alphaValue == 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"History lost owner/Quit gates")
            historyView.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);historyView.ok.performClick(nil);historyView.ok.performClick(nil)
            try await wait {repairedOwner.historyWindow == nil && repairedOwner.window?.attachedSheet == nil && !repairedModel.hasHistory && drained()}
            try require(selectedHistory == 1 && repairedModel.message == "history message","History reply lost or repeated before sheet release")

            // Both UI preflight and Core final check reject a replay created
            // after the dialog was prepared without mutating HEAD/index.
            repairedModel.readPreparation = {token in
                let real=try await repo.prepareMerge(cancellation:token)
                return MergePreparation(identity:real.identity,replayActive:true,hasGitSVN:false)
            }
            repairedModel.merge();try await wait {!repairedModel.busy && !repairedModel.preparing && drained()}
            let blockedHead=try await repo.run(["rev-parse","HEAD"]).text
            try require(repairedModel.progress == nil && repairedModel.error != nil && blockedHead == initial,"Late replay gate allowed native Merge mutation")
            repairedModel.error=nil;repairedModel.readPreparation=nil
            try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/svn"),withIntermediateDirectories:true)
            try Data().write(to:root.appendingPathComponent(".git/svn/.metadata"))
            repairedModel.message="  Native merge\n\n# secret comment\n\n\nbody\n"
            var actions=0,detached=false
            repairedModel.onPostAction = {action,request in
                actions += 1;detached=action == .svnDCommit && request.requireIdentity && request.stripComments && request.sanitizeMessage && repairedOwner.window?.attachedSheet == nil && repairedOwner.window?.isVisible == false && repairedModel.closed
            }
            repairedModel.merge();try await wait {repairedOwner.progressController?.model.busy == false && drained()}
            guard let progress=repairedOwner.progressController else {throw Failure(message:"Native Merge progress missing")}
            print("Merge completion: success=\(progress.model.success), sheetAttached=\(progress.window?.sheetParent === repairedOwner.window), alpha=\(String(describing:progress.window?.alphaValue)), actions=\(progress.model.postActions)")
            try require(progress.model.success && progress.window?.sheetParent === repairedOwner.window && progress.window?.alphaValue == 0 && progress.model.postActions == [.removeBranch,.push,.svnDCommit],"Source committed Merge completion/menu/SVN action missing")
            let committed=try await repo.run(["log","-1","--format=%B"]).text
            try require(committed.contains("Native merge") && !committed.contains("secret comment"),"Native Merge did not capture source message cleanup preferences")
            repairedModel.confirmingQuit=true;progress.model.perform(.svnDCommit);try require(actions == 0,"Deferred Quit accepted Merge progress action");repairedModel.confirmingQuit=false
            progress.model.perform(.svnDCommit);progress.model.perform(.svnDCommit)
            try await wait {actions == 1 && repairedModel.closed && drained()}
            try require(detached,"Merge follow-up preceded actual progress/options sheet release")

            let retiring=make();var effects=0
            retiring.model.readPreparation = {_ in try await withCheckedThrowingContinuation {held=$0}}
            retiring.model.onProgress = {_ in effects += 1};retiring.model.load(revision:"refs/heads/topic")
            try await wait {held != nil};retiring.close()
            try require(MergeWindowModel.activeReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired preparation lost actual work/Quit ownership")
            let late=held;held=nil;late?.resume(returning:try await repo.prepareMerge())
            try await wait {drained()};try require(retiring.model.closed && !retiring.model.prepared && effects == 0,"Late preparation revived closed Merge")
            try await cleanup()
            print("PASS: Merge identity Settings cancel/repair/recheck, late replay refusal, guarded option receipts/Quit, actual hidden History single reply, source message cleanup/SVN completion and sheet-drained follow-up, retired preparation ownership")
        } catch {let original=error;do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
}
