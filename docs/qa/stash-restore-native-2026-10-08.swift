import AppKit
import TurtleGitCore

@main struct StashRestoreVerification {
    @MainActor static func wait(line: UInt = #line, _ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Stash restore timed out at fixture line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Stash restore failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.StashRestore.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite); prefs.synchronize() }
        func fixture(_ name:String, conflict:Bool = false, stash:Bool = true) async throws -> GitRepository {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo = GitRepository(root:path,executable:git); _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Stash QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("base\n".utf8).write(to:path.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
            if stash { try Data("stash\n".utf8).write(to:path.appendingPathComponent("file")); _ = try await repo.saveStash(StashSaveOptions()) }
            if conflict { try Data("divergent\n".utf8).write(to:path.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"divergent") }
            return repo
        }
        // Default Pop: real success, independent remembered No, duplicate answers ignored.
        let firstRepo = try await fixture("success"), first = StashRestoreWindowModel(repository:firstRepo,access:nil,pop:true,preferences:prefs)
        var answer:((Bool,Bool)->Void)?, prompts:[StashRestorePrompt] = [], order:[String] = []
        first.onPresent = { prompts.append($0); answer = $1 }; first.onChanged = { _ in order.append("changed") }; first.close = { order.append("close") }; first.onViewChanges = { order.append("status") }
        first.start(); first.start(); try await wait { !first.busy }
        precondition(first.result?.conflicted == false && first.error == nil && prompts.count == 1 && prompts[0].kind == .question && prompts[0].rememberKey == "StashPop.ShowChanges" && order == ["changed"])
        let stashGone = try? await firstRepo.run(["rev-parse","--verify","refs/stash"]); precondition(stashGone == nil)
        answer?(false,true); answer?(true,true); first.start(); precondition(order == ["changed","close"] && prefs.object(forKey:"StashPop.ShowChanges") as? Bool == false && prefs.object(forKey:"StashPop.ShowConflictChanges") == nil)
        prefs.synchronize()
        let savedNoRepo = try await fixture("saved-no"), savedNo = StashRestoreWindowModel(repository:savedNoRepo,access:nil,pop:true,preferences:UserDefaults(suiteName:suite)!)
        var savedNoCloses = 0; savedNo.close = { savedNoCloses += 1 }; savedNo.onPresent = { _,_ in preconditionFailure("Saved No presented") }; savedNo.onViewChanges = { preconditionFailure("Saved No showed status") }
        savedNo.start(); try await wait { !savedNo.busy }; precondition(savedNoCloses == 1 && savedNo.prompt == nil)
        // Conflict uses its separate key and a real native Status model handoff.
        let conflictRepo = try await fixture("conflict",conflict:true), conflict = StashRestoreWindowModel(repository:conflictRepo,access:nil,pop:true,preferences:prefs)
        let conflictHead = try await conflictRepo.run(["rev-parse","HEAD"]).stdout, stashHash = try await conflictRepo.run(["rev-parse","refs/stash"]).stdout
        var conflictPrompt:StashRestorePrompt?, conflictAnswer:((Bool,Bool)->Void)?, status:StatusWindowModel?, conflictOrder:[String] = []
        conflict.onPresent = { conflictPrompt = $0; conflictAnswer = $1 }; conflict.close = { conflictOrder.append("close") }
        conflict.onViewChanges = { conflictOrder.append("status"); let model = StatusWindowModel(repository:conflictRepo,access:nil); status = model; model.reload() }
        conflict.start(); try await wait { !conflict.busy }; precondition(conflict.result?.conflicted == true && conflictPrompt?.rememberKey == "StashPop.ShowConflictChanges")
        conflictAnswer?(true,true); conflictAnswer?(false,true); try await wait { status != nil && status?.busy == false }
        precondition(conflictOrder == ["close","status"] && status?.error == nil && status?.files.contains(where: { $0.state == .conflicted }) == true)
        let afterHead = try await conflictRepo.run(["rev-parse","HEAD"]).stdout, afterStash = try await conflictRepo.run(["rev-parse","refs/stash"]).stdout
        precondition(afterHead == conflictHead && afterStash == stashHash && prefs.object(forKey:"StashPop.ShowConflictChanges") as? Bool == true && prefs.object(forKey:"StashPop.ShowChanges") as? Bool == false)
        prefs.synchronize()
        let savedYesRepo = try await fixture("saved-conflict-yes",conflict:true), savedYes = StashRestoreWindowModel(repository:savedYesRepo,access:nil,pop:true,preferences:UserDefaults(suiteName:suite)!)
        var savedYesOrder:[String] = []; savedYes.close = { savedYesOrder.append("close") }; savedYes.onViewChanges = { savedYesOrder.append("status") }; savedYes.onPresent = { _,_ in preconditionFailure("Saved conflict Yes presented") }
        savedYes.start(); try await wait { !savedYes.busy }; precondition(savedYesOrder == ["close","status"])
        // Selected Apply always asks, never suppresses, and retains all stash refs.
        let applyRepo = try await fixture("apply"), older = try await applyRepo.run(["rev-parse","refs/stash"]).stdout
        try Data("newer\n".utf8).write(to:applyRepo.root.appendingPathComponent("file")); _ = try await applyRepo.saveStash(StashSaveOptions())
        let newest = try await applyRepo.run(["rev-parse","refs/stash"]).stdout, savedPreferences = prefs.persistentDomain(forName:suite)!
        let apply = StashRestoreWindowModel(repository:applyRepo,access:nil,pop:false,reference:"refs/stash@{1}",preferences:prefs)
        var applyPrompt:StashRestorePrompt?, applyAnswer:((Bool,Bool)->Void)?, applyCloses = 0
        apply.onPresent = { applyPrompt = $0; applyAnswer = $1 }; apply.close = { applyCloses += 1 }; apply.start(); try await wait { !apply.busy }
        precondition(applyPrompt?.kind == .question && applyPrompt?.rememberKey == nil && apply.result?.conflicted == false)
        applyAnswer?(false,true); precondition(applyCloses == 1 && NSDictionary(dictionary:prefs.persistentDomain(forName:suite)!).isEqual(to:savedPreferences))
        let retainedNewest = try await applyRepo.run(["rev-parse","refs/stash"]).stdout, retainedOlder = try await applyRepo.run(["rev-parse","stash@{1}"]).stdout, contents = try String(contentsOf:applyRepo.root.appendingPathComponent("file"))
        precondition(retainedNewest == newest && retainedOlder == older && contents == "stash\n")
        // Source Pop 0 is silent on success, but still offers changes on conflict.
        let silentRepo = try await fixture("silent"), silent = StashRestoreWindowModel(repository:silentRepo,access:nil,pop:true,showChanges:0,preferences:prefs)
        var silentCloses = 0; silent.close = { silentCloses += 1 }; silent.onPresent = { _,_ in preconditionFailure("Silent success presented") }; silent.start(); try await wait { !silent.busy }; precondition(silentCloses == 1)
        prefs.removeObject(forKey:"StashPop.ShowConflictChanges")
        let zeroConflictRepo = try await fixture("zero-conflict",conflict:true), zeroConflict = StashRestoreWindowModel(repository:zeroConflictRepo,access:nil,pop:true,showChanges:0,preferences:prefs)
        var zeroAnswer:((Bool,Bool)->Void)?; zeroConflict.onPresent = { precondition($0.kind == .question && $0.conflicted); zeroAnswer = $1 }; zeroConflict.start(); try await wait { !zeroConflict.busy }; precondition(zeroAnswer != nil); zeroAnswer?(false,false)
        // Pop >1 and Apply false acknowledge a notice without showing status.
        for (index,pop,mode) in [(0,true,2),(1,false,0)] {
            let repo = try await fixture("notice-\(index)"), model = StashRestoreWindowModel(repository:repo,access:nil,pop:pop,showChanges:mode,preferences:prefs)
            var notice:StashRestorePrompt?, respond:((Bool,Bool)->Void)?, closed = 0
            model.close = { closed += 1 }; model.onViewChanges = { preconditionFailure("Notice showed status") }; model.onPresent = { notice = $0; respond = $1 }; model.start(); try await wait { !model.busy }
            precondition(notice?.kind == .notice && notice?.rememberKey == nil && closed == 0); respond?(true,true); precondition(closed == 1)
        }
        // Native owned window blocks close/Quit while executing and awaiting answer.
        let controllerRepo = try await fixture("controller",stash:false), controller = StashRestoreWindowController(repository:controllerRepo,access:nil,pop:true,preferences:prefs)
        var errorAnswer:((Bool,Bool)->Void)?, errorPrompt:StashRestorePrompt?, changed = 0, closed = 0
        controller.onChanged = { _ in changed += 1 }; controller.onClosed = { closed += 1 }; controller.onViewChanges = { preconditionFailure("Error showed status") }; controller.model.onPresent = { errorPrompt = $0; errorAnswer = $1 }
        // This scenario injects result presentation. Decline its close-triggered
        // Cancel request too; actual native Cancel sheets are exercised below.
        controller.model.confirmCancellation = {$0(false)}
        controller.start(); precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await wait { !controller.model.busy }; precondition(changed == 1 && errorPrompt?.kind == .error && errorPrompt?.rememberKey == nil && controller.model.error != nil)
        precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        errorAnswer?(true,true); errorAnswer?(true,true)
        let closeWindow=controller.window,closeSheet=closeWindow?.attachedSheet
        func closeButtons(_ view:NSView)->[String] {([view as? NSButton].compactMap {$0?.title})+view.subviews.flatMap(closeButtons)}
        precondition(closed == 1,"Restore close diagnostic: closed=\(closed), answer=\(errorAnswer != nil), busy=\(controller.model.busy), confirmingQuit=\(controller.model.confirmingQuit), confirmingCancellation=\(controller.model.confirmingCancellation), prompt=\(controller.model.prompt?.message ?? "nil"), error=\(controller.model.error ?? "nil"), visible=\(closeWindow?.isVisible.description ?? "nil"), sheet=\(closeSheet?.title ?? "nil"), sheetButtons=\(closeSheet?.contentView.map(closeButtons) ?? []), sheetParent=\(closeWindow?.sheetParent != nil), releases=\(StashWindowController.activeChildReleases), operations=\(StashRestoreWindowModel.activeOperations)")
        // A dismissed/invalidated result cannot save or open a delayed handoff.
        let delayedRepo = try await fixture("delayed"), delayed = StashRestoreWindowModel(repository:delayedRepo,access:nil,pop:false,preferences:prefs)
        var delayedAnswer:((Bool,Bool)->Void)?; delayed.onPresent = { _,choose in delayedAnswer = choose }; delayed.onViewChanges = { preconditionFailure("Invalidated handoff") }; delayed.start(); try await wait { !delayed.busy }; delayed.invalidate(); delayedAnswer?(true,true)

        // Cancellation owns its question and never publishes late success.
        prefs.set(true,forKey:"ConfirmKillProcess")
        let cancelling = StashRestoreWindowController(repository:controllerRepo,access:nil,pop:false,preferences:prefs)
        cancelling.window?.alphaValue=0
        defer { cancelling.close() }
        var held:CheckedContinuation<StashRestoreResult,Error>?, capturedToken:OperationCancellation?, cancelClosed = 0
        cancelling.model.restore = { _,_,token in capturedToken = token; return try await withCheckedThrowingContinuation { held = $0 } }
        cancelling.onClosed = { cancelClosed += 1 }
        cancelling.start(); try await wait { held != nil }
        cancelling.model.cancel(); try await wait { cancelling.window?.attachedSheet != nil }
        let firstQuestion = cancelling.window!.attachedSheet!
        cancelling.model.cancel(); precondition(cancelling.window!.attachedSheet === firstQuestion)
        cancelling.window!.endSheet(firstQuestion,returnCode:.alertFirstButtonReturn)
        try await wait { !cancelling.model.confirmingCancellation }
        precondition(capturedToken?.isCancelled == false && cancelling.model.busy)
        cancelling.model.cancel(); try await wait { cancelling.window?.attachedSheet != nil }
        cancelling.window!.endSheet(cancelling.window!.attachedSheet!,returnCode:.alertSecondButtonReturn)
        try await wait { cancelling.model.cancelling }
        precondition(capturedToken?.isCancelled == true)
        held?.resume(returning:StashRestoreResult(output:"late success",conflicted:false)); held = nil
        try await wait { !cancelling.model.busy && cancelling.model.prompt != nil && cancelling.window?.attachedSheet != nil }
        precondition(cancelling.model.cancelled && cancelling.model.result == nil && cancelling.model.error == nil && cancelling.model.prompt?.kind == .notice)
        cancelling.window!.endSheet(cancelling.window!.attachedSheet!,returnCode:.alertFirstButtonReturn)
        try await wait { cancelClosed == 1 }
        // Forced close ends the owned question; Quit still waits for its provider.
        let retired = StashRestoreWindowController(repository:controllerRepo,access:nil,pop:true,preferences:prefs)
        retired.window?.alphaValue=0
        var lateRestore:CheckedContinuation<StashRestoreResult,Error>?, lateToken:OperationCancellation?, lateChanges = 0
        retired.model.restore = { _,_,token in lateToken = token; return try await withCheckedThrowingContinuation { lateRestore = $0 } }
        retired.onChanged = { _ in lateChanges += 1 }
        retired.start(); try await wait { lateRestore != nil }
        retired.model.cancel(); try await wait { retired.window?.attachedSheet != nil }
        retired.close();try await wait {retired.window?.attachedSheet == nil && StashWindowController.activeChildReleases == 0}
        precondition(lateToken?.isCancelled == true)
        precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        lateRestore?.resume(returning:StashRestoreResult(output:"retired result",conflicted:false)); lateRestore = nil
        try await wait { StashRestoreWindowModel.activeOperations == 0 }
        precondition(retired.model.result == nil && retired.model.error == nil && retired.model.prompt == nil && lateChanges == 0)
        try await verifyReplay(root:root,git:git,prefs:prefs)
        print("Stash Apply/Pop: actual restore/drop/conflict retention, selected older Apply, separate remembered No/Yes through fresh preferences, once close-before-Status handoff, source silent/conflict/notice modes, errors, duplicate/delayed callback gates, native close/Quit guards. Owned hidden window closed; no displayed UI or standard preferences.")
    }
    @MainActor static func verifyReplay(root: URL, git: URL, prefs: UserDefaults) async throws {
        func require(_ value: Bool, _ message: String) throws { if !value { throw NSError(domain:message,code:1) } }
        func fixture(_ name: String, conflict: Bool = false) async throws -> GitRepository {
            let directory = root.appendingPathComponent(name); try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo = GitRepository(root:directory,executable:git)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Replay QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
            try Data("base\n".utf8).write(to:directory.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
            _ = try await repo.run(["checkout","-b","upstream"])
            try Data("upstream\n".utf8).write(to:directory.appendingPathComponent(conflict ? "file" : "upstream")); try await repo.stage([conflict ? "file" : "upstream"]); _ = try await repo.commit(message:"upstream")
            _ = try await repo.run(["checkout","-b","topic","main"])
            try Data("topic\n".utf8).write(to:directory.appendingPathComponent(conflict ? "file" : "topic")); try await repo.stage([conflict ? "file" : "topic"]); _ = try await repo.commit(message:"topic")
            // An older stash must remain below the replay-owned stash.
            try Data("older\n".utf8).write(to:directory.appendingPathComponent("file")); _ = try await repo.saveStash(StashSaveOptions())
            try Data("staged\n".utf8).write(to:directory.appendingPathComponent("file")); try await repo.stage(["file"])
            try Data("working\n".utf8).write(to:directory.appendingPathComponent("file"))
            try Data("untracked\n".utf8).write(to:directory.appendingPathComponent("untracked"))
            return repo
        }
        func configure(_ model:RebaseWindowModel) async throws {
            model.options.branch = "topic"; model.options.upstream = "upstream"
            model.plan = try await model.repository.rebasePlan(model.options)
            model.editorExecutable = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        }
        for (automatic,restoreAutomatic) in [(false,false),(true,true),(false,true),(true,false)] {
            let repo = try await fixture("replay-save-\(automatic)-restore-\(restoreAutomatic)")
            _ = try await repo.run(["config","rebase.autostash",automatic ? "true":"false"])
            let older = try await repo.run(["rev-parse","refs/stash"]).stdout
            let model = RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs)
            defer { model.retire() }
            try await configure(model)
            var saveQuestions = 0, restoreQuestions = 0, closes = 0, modes:[Int] = []
            model.completionAfterFetch = automatic
            var pushed = 0
            model.onCompletedPush = { _ in precondition(modes == [restoreAutomatic ? 0:1] && closes == 1); pushed += 1 }
            model.chooseStashBeforeReplay = { saveQuestions += 1; return true }
            model.chooseRestoreReplayStash = { restoreQuestions += 1; return true }
            model.restoreReplayStash = { mode in modes.append(mode); do { _ = try await repo.restoreStash(pop:true) } catch { preconditionFailure("Replay restore: \(error)") } }
            model.close = { closes += 1 }
            model.execute("start"); try await wait { !model.busy }
            try require(model.error == nil && model.finished && model.completedSuccessfully && model.hasReplayStash,"Replay did not finish with pending stash: \(model.error ?? "none")")
            try require((try? String(contentsOf:repo.root.appendingPathComponent("untracked"))) == "untracked\n","Untracked file was stashed")
            if automatic != restoreAutomatic { _ = try await repo.run(["config","rebase.autostash",restoreAutomatic ? "true":"false"]) }
            if automatic { model.performCompletionAction(.push); model.performCompletionAction(.push) }
            else { model.finishReplay(); model.finishReplay() }
            try await wait { !model.busy }
            let after = try await repo.run(["rev-parse","refs/stash"]).stdout
            let index = try await repo.run(["diff","--cached"]).text
            try require(after == older && index.isEmpty && (try? String(contentsOf:repo.root.appendingPathComponent("file"))) == "working\n","Restore changed older stash or index semantics")
            try require(saveQuestions == (automatic ? 0:1) && restoreQuestions == (restoreAutomatic ? 0:1) && modes == [restoreAutomatic ? 0:1] && closes == 1 && pushed == (automatic ? 1:0),"Automatic/manual questions or once-only completion differ")
        }
        // Existing no-stash completion commands retain immediate routing.
        let plainRepo = try await fixture("replay-plain-routes")
        let plain = RebaseWindowModel(repository:plainRepo,access:nil,messageDefaults:prefs)
        defer { plain.retire() }; try await configure(plain)
        plain.finished = true; plain.completedSuccessfully = true; plain.completionAfterFetch = true
        var routes:[String] = [], routeClosed = 0
        plain.close = { routeClosed += 1 }
        plain.onCompletedLog = { routes.append("log") }
        plain.onCompletedPush = { routes.append("push:" + $0) }
        plain.onCompletedMail = { _ in routes.append("mail") }
        plain.performCompletionAction(.log); plain.performCompletionAction(.push); plain.performCompletionAction(.mail)
        try require(routes == ["log","push:HEAD","mail"] && routeClosed == 3 && !plain.busy,"No-stash completion routing changed")
        // Production controller owns the restore sheet and awaits silent Pop
        // before closing its parent. Both windows must retire exactly once.
        let ownedRepo = try await fixture("replay-owned-controller")
        _ = try await ownedRepo.run(["config","rebase.autostash","true"])
        let owned = RebaseWindowController(repository:ownedRepo,access:nil,preferences:prefs)
        defer { owned.close() }; try await configure(owned.model)
        var ownedClosed = 0; owned.onClosed = { ownedClosed += 1 }
        owned.model.execute("start"); try await wait { !owned.model.busy }
        try require(owned.model.finished && owned.model.hasReplayStash,"Owned replay did not finish")
        owned.model.finishReplay(); try await wait { !owned.model.busy && ownedClosed == 1 }
        try require(owned.window?.attachedSheet == nil && StashRestoreWindowModel.activeOperations == 0 && (try? String(contentsOf:ownedRepo.root.appendingPathComponent("file"))) == "working\n","Owned Pop sheet did not restore/retire")
        // Abort before save preserves HEAD/index/worktree and does not invoke hooks.
        let declinedRepo = try await fixture("replay-declined"), declined = RebaseWindowModel(repository:declinedRepo,access:nil,messageDefaults:prefs)
        defer { declined.retire() }; try await configure(declined)
        let before = try await declinedRepo.run(["rev-parse","HEAD","refs/stash"]).stdout
        declined.execute("start"); try await wait { !declined.busy }
        let after = try await declinedRepo.run(["rev-parse","HEAD","refs/stash"]).stdout
        try require(before == after && !declined.hasReplayStash && !declined.active && declined.error == nil,"Abort-before-save mutated repository")
        // A manual No leaves the saved changes in stash and never opens Pop.
        declined.chooseStashBeforeReplay = { true }; declined.execute("start"); try await wait { !declined.busy }
        var noCloses = 0; declined.close = { noCloses += 1 }
        declined.restoreReplayStash = { _ in preconditionFailure("No restored stash") }
        declined.finishReplay(); try await wait { !declined.busy }
        let retained = try await declinedRepo.run(["stash","list","--format=%H"]).text.split(separator:"\n").count
        try require(noCloses == 1 && !declined.hasReplayStash && retained == 2,"No dropped saved changes")
        // Conflict replay keeps its save until Abort, then offers restoration once.
        let conflictRepo = try await fixture("replay-abort",conflict:true), conflict = RebaseWindowModel(repository:conflictRepo,access:nil,messageDefaults:prefs)
        defer { conflict.retire() }; try await configure(conflict)
        let conflictHead = try await conflictRepo.run(["rev-parse","HEAD"]).stdout
        conflict.chooseStashBeforeReplay = { true }; conflict.chooseRestoreReplayStash = { true }
        var abortMode:Int?, abortClosed = 0
        conflict.restoreReplayStash = { mode in abortMode = mode; do { _ = try await conflictRepo.restoreStash(pop:true) } catch { preconditionFailure("Abort restore failed: \(error)") } }
        conflict.close = { abortClosed += 1 }
        conflict.execute("start"); try await wait { !conflict.busy }
        try require(conflict.active && conflict.hasReplayStash,"Conflict lost pending stash")
        conflict.execute("abort"); try await wait { !conflict.busy }
        let restoredHead = try await conflictRepo.run(["rev-parse","HEAD"]).stdout
        try require(restoredHead == conflictHead && abortMode == 1 && abortClosed == 1 && !conflict.hasReplayStash && !conflict.active,"Abort failed restore/close workflow")
        // Cherry Pick still asks even when rebase.autostash is enabled, and
        // never invokes the client Pre-rebase hook.
        let cherryRepo = try await fixture("replay-cherry")
        _ = try await cherryRepo.run(["config","rebase.autostash","true"])
        let cherry = RebaseWindowModel(repository:cherryRepo,access:nil,messageDefaults:prefs)
        defer { cherry.retire(); prefs.removeObject(forKey:"hooks") }
        let revision = try await cherryRepo.run(["rev-parse","upstream"]).text.trimmingCharacters(in:.newlines)
        cherry.plan = try await cherryRepo.cherryPickPlan(revisions:[revision]); cherry.options = cherry.plan!.options
        cherry.editorExecutable = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        let invalid = ClientHook(type:.preRebase,path:cherryRepo.root.path,command:"/missing/rebase-hook",show:false)
        prefs.set(try ClientHookConfiguration.serialize([invalid]),forKey:"hooks")
        cherry.clientHooks.continueAfterFailure = { _ in preconditionFailure("Cherry Pick ran Pre-rebase hook") }
        var cherryQuestions = 0
        cherry.chooseStashBeforeReplay = { cherryQuestions += 1; return true }
        cherry.execute("start"); try await wait { !cherry.busy }
        try require(cherryQuestions == 1 && cherry.finished && cherry.completedSuccessfully && cherry.hasReplayStash && cherry.error == nil,"Cherry Pick autostash/hook gating differs")
        cherry.chooseRestoreReplayStash = { false }; cherry.finishReplay(); try await wait { !cherry.busy }
        prefs.removeObject(forKey:"hooks")
        // Pre-rebase runs after saving tracked changes. Abort preserves the
        // saved draft; closing still offers restoration of that stash.
        let hookRepo = try await fixture("replay-hook-failure"), hook = RebaseWindowModel(repository:hookRepo,access:nil,messageDefaults:prefs)
        defer { hook.retire(); prefs.removeObject(forKey:"hooks") }; try await configure(hook)
        let script = root.appendingPathComponent("inspect-clean.sh")
        let scriptText = "#!/bin/sh\n'" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "' -C \"$4\" diff --quiet -- && '" + git.path.replacingOccurrences(of:"'",with:"'\\''") + "' -C \"$4\" diff --cached --quiet -- && printf clean > \"$4/hook-clean\"\nexit 8\n"
        try Data(scriptText.utf8).write(to:script)
        let pre = ClientHook(type:.preRebase,path:hookRepo.root.path,command:"/bin/sh '" + script.path + "'",show:false)
        prefs.set(try ClientHookConfiguration.serialize([pre]),forKey:"hooks")
        hook.clientHooks.continueAfterFailure = { _ in false }; hook.chooseStashBeforeReplay = { true }
        hook.execute("start"); try await wait { !hook.busy }
        try require(hook.hasReplayStash && !hook.active && hook.error?.contains("Pre-rebase hook failed") == true && (try? String(contentsOf:hookRepo.root.appendingPathComponent("hook-clean"))) == "clean","Pre-rebase order or saved draft differs")
        hook.chooseRestoreReplayStash = { true }
        hook.restoreReplayStash = { _ in do { _ = try await hookRepo.restoreStash(pop:true) } catch { preconditionFailure("Failed hook stash restore: \(error)") } }
        hook.finishReplay(); try await wait { !hook.busy }
        try require((try? String(contentsOf:hookRepo.root.appendingPathComponent("file"))) == "working\n","Closing after hook Abort lost draft")
        prefs.removeObject(forKey:"hooks")
        // Retiring while the question is pending rejects a delayed Yes.
        let lateRepo = try await fixture("replay-retired"), late = RebaseWindowModel(repository:lateRepo,access:nil,messageDefaults:prefs)
        try await configure(late)
        var answer:CheckedContinuation<Bool,Never>?
        late.chooseStashBeforeReplay = { await withCheckedContinuation { answer = $0 } }
        let lateBefore = try await lateRepo.run(["rev-parse","HEAD","refs/stash"]).stdout
        late.execute("start"); try await wait { answer != nil }; late.retire(); answer?.resume(returning:true); answer = nil
        try await wait { !late.busy }
        let lateAfter = try await lateRepo.run(["rev-parse","HEAD","refs/stash"]).stdout
        try require(lateBefore == lateAfter && !late.hasReplayStash,"Retired question saved changes")
        print("Replay stash: manual/automatic save and Done, tracked-only/index semantics, older stash preservation, No, conflict Abort and delayed retired choice passed.")
    }

}
