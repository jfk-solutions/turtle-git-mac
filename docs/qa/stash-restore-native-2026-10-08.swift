import AppKit
import TurtleGitCore

@main struct StashRestoreVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(condition(), "Stash restore timed out")
    }
    @MainActor static func main() async throws {
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
        controller.start(); precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await wait { !controller.model.busy }; precondition(changed == 1 && errorPrompt?.kind == .error && errorPrompt?.rememberKey == nil && controller.model.error != nil)
        precondition(!controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        errorAnswer?(true,true); errorAnswer?(true,true); precondition(closed == 1)
        // A dismissed/invalidated result cannot save or open a delayed handoff.
        let delayedRepo = try await fixture("delayed"), delayed = StashRestoreWindowModel(repository:delayedRepo,access:nil,pop:false,preferences:prefs)
        var delayedAnswer:((Bool,Bool)->Void)?; delayed.onPresent = { _,choose in delayedAnswer = choose }; delayed.onViewChanges = { preconditionFailure("Invalidated handoff") }; delayed.start(); try await wait { !delayed.busy }; delayed.invalidate(); delayedAnswer?(true,true)
        print("Stash Apply/Pop: actual restore/drop/conflict retention, selected older Apply, separate remembered No/Yes through fresh preferences, once close-before-Status handoff, source silent/conflict/notice modes, errors, duplicate/delayed callback gates, native close/Quit guards. Owned hidden window closed; no displayed UI or standard preferences.")
    }
}
