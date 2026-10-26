import AppKit
import ObjectiveC
import TurtleGitCore

@main struct RebaseAddPreparationVerification {
    struct Failure: LocalizedError, CustomStringConvertible { let description: String; var errorDescription: String? { description } }
    @MainActor static var owners: [RebaseWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Add preparation timeout at \(line)")
    }
    @MainActor static func drain() async throws {
        try await wait { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 && RebaseWindowModel.activeReplayOperations == 0 }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.model.retire(); $0.close() }; owners = [] }
        catch { owners.forEach { $0.model.retire(); $0.close() }; owners = []; fputs("Add preparation failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func start(_ model:RebaseWindowModel) {model.request("start");if let question=model.pendingConfirmation {model.answerConfirmation(question,proceed:true)}}
    @MainActor static func nativeViews(_ view:NSView)->[NSView] {
        let selector = #selector(getter:NSView.subviews)
        typealias Getter = @convention(c)(AnyObject,Selector)->Unmanaged<NSArray>
        let getter=unsafeBitCast(view.method(for:selector),to:Getter.self)
        let children=getter(view,selector).takeUnretainedValue().copy() as! NSArray
        var result=[view]
        for index in 0..<children.count {let object=children.object(at:index) as AnyObject;guard let native=object as? NSObject,native.isKind(of:NSView.self) else{continue};result += nativeViews(unsafeBitCast(object,to:NSView.self))}
        return result
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Add QA"), ("user.email", "add@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("side")); try await repo.stage(["side"]); _ = try await repo.commit(message: "side")
        let side = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch", "-c", "topic", base.hash])
        try Data("topic\n".utf8).write(to: root.appendingPathComponent("topic")); try await repo.stage(["topic"]); _ = try await repo.commit(message: "topic")
        let topic = try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["merge", "--no-ff", "side", "-m", "Merge for parent choice"])
        let merge = try await repo.rebaseCommit("HEAD"), originalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, originalIndex = try await repo.run(["write-tree"]).stdout
        let suite = "TurtleGit.AddPreparation." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "ContextMenuIcons")
        @MainActor func make() -> RebaseWindowController {
            let controller = RebaseWindowController(repository: repo, access: nil, preferences: prefs)
            owners.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil)
            return controller
        }
        let controller = make(), model = controller.model
        model.load(upstream: "refs/heads/side"); try await drain()
        try require(model.canAdd && model.plan != nil, "Initial Add plan unavailable")
        let initial = model.plan!, initialIDs = initial.entries.map(\.id)
        let added = try await repo.addingRebaseCommits(initial, revisions: [side.hash, topic.hash])
        // Delay a genuine completed read to prove that cancellation owns the reply
        // until drain and rejects even a successful result already in flight.
        var reply: CheckedContinuation<RebasePlan, Error>?, ownedToken: OperationCancellation?
        model.readAddedPlan = { _, _, token in ownedToken = token; return try await withCheckedThrowingContinuation { reply = $0 } }
        model.addCommits([side.hash, topic.hash]); try await wait { reply != nil }
        try require(model.addingCommits && model.busy && !model.canStart && model.hasCancellablePreparation && RebaseWindowModel.activePreparationReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Add read lost UI/Quit ownership")
        try require(model.cancelPreparation() && ownedToken?.isCancelled == true && model.busy, "Add Cancel released pending work")
        reply?.resume(returning: added); reply = nil; try await drain()
        try require(model.plan?.entries.map(\.id) == initialIDs && model.error == nil && !model.busy && !model.addingCommits, "Cancelled Add replaced the old plan")
        // Failure remains atomic, and a successful retry keeps picker ordering and
        // repeated occurrence identities, rather than replacing existing actions.
        model.readAddedPlan = { _, _, _ in throw Failure(description: "controlled Add failure") }
        model.addCommits([side.hash]); try await drain()
        try require(model.plan?.entries.map(\.id) == initialIDs && model.error == "controlled Add failure", "Failed Add discarded original plan or error: \(model.error ?? "nil"); IDs \(model.plan?.entries.map(\.id) ?? [])")
        model.readAddedPlan = { try await repo.addingRebaseCommits($0, revisions: $1, cancellation: $2) }
        model.addCommits([side.hash, topic.hash]); try await drain()
        try require(model.entries.prefix(2).map { $0.commit.hash } == [side.hash, topic.hash] && Set(model.plan!.entries.map(\.id)).count == model.plan!.entries.count, "Retry lost picker order or repeated occurrence identity")
        // Stale initiating inputs refuse successful insertion without publishing a
        // partial plan or turning the old request into a new one.
        let beforeStale = model.plan!.entries.map(\.id), stalePlan = try await repo.addingRebaseCommits(model.plan!, revisions: [base.hash])
        model.readAddedPlan = { _, _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        model.addCommits([base.hash]); try await wait { reply != nil }; model.options.upstream = "changed-input"
        reply?.resume(returning: stalePlan); reply = nil; try await drain()
        try require(model.plan!.entries.map(\.id) == beforeStale && !model.busy, "Stale Add published into edited inputs")
        model.options.upstream = "refs/heads/side"
        // Real owned Log sheet: private preferences, multi-selection, cancelled and
        // accepted callbacks, retained callback refusal, and refused presentation.
        var retained: (([LogEntry]?) -> Void)?
        controller.makeCommitPicker = { repository, access, preferences, choose in
            retained = choose
            return LogWindowController(repository: repository, access: access, onChooseMultiple: choose, labelDefaults: preferences)
        }
        controller.showAdditionalCommits(); try await wait { controller.logPicker != nil && controller.logPicker?.model.busy == false }
        try require(controller.logPicker!.model.selectingMultiple && controller.logPicker!.model.colorPreferences === prefs && model.pickingCommits && !model.canStart && RebaseWindowController.activeCommitPickers == 1, "Add picker does not own multi-selection/preferences")
        let cancelled = retained
        controller.logPicker!.model.finishMultipleSelection(nil)
        try await wait { RebaseWindowController.activeCommitPickers == 0 && !model.pickingCommits && controller.window?.attachedSheet == nil }
        cancelled?([base]); try require(!model.busy && model.plan!.entries.map(\.id) == beforeStale, "Old picker callback inserted rows")
        model.readAddedPlan = { try await repo.addingRebaseCommits($0, revisions: $1, cancellation: $2) }
        controller.showAdditionalCommits(); try await wait { controller.logPicker?.model.busy == false && controller.logPicker != nil }
        controller.logPicker!.model.finishMultipleSelection([base]); try await drain()
        try require(model.entries.first?.commit.hash == base.hash && !model.pickingCommits && RebaseWindowController.activeCommitPickers == 0 && controller.window?.attachedSheet == nil, "Accepted picker did not detach before Add")
        controller.presentCommitPicker = { _, _ in false }; controller.showAdditionalCommits(); try await drain()
        try require(!model.pickingCommits && controller.logPicker == nil && RebaseWindowController.activeCommitPickers == 0, "Refused picker leaked owner")
        // Before a valid plan exists, cancelled draft resolution keeps old draft;
        // a real successful resolution with invalid references stays editable.
        let draft = make().model
        draft.options.branch = "invalid-branch"; draft.options.upstream = "invalid-upstream"
        draft.addCommits([side.hash]); try await drain()
        try require(draft.plan == nil && draft.entries.map { $0.commit.hash } == [side.hash] && !draft.canStart && draft.error == nil, "Incomplete references lost source editable Add draft")
        let oldDraft = draft.entries.map(\.id)
        var draftReply: CheckedContinuation<[RebaseEntry], Error>?
        draft.readAddedEntries = { _, _, token in ownedToken = token; return try await withCheckedThrowingContinuation { draftReply = $0 } }
        draft.addCommits([base.hash]); try await wait { draftReply != nil }; _ = draft.cancelPreparation()
        draftReply?.resume(returning: try await repo.addingRebaseEntries([], revisions: [base.hash])); draftReply = nil; try await drain()
        try require(draft.entries.map(\.id) == oldDraft && draft.error == nil && !draft.busy, "Cancelled draft overwrote editable rows")
        let capture = make().model
        capture.options.branch = "refs/heads/topic"; capture.options.upstream = "refs/heads/side"
        capture.addCommits([base.hash]); try await drain()
        try require(capture.plan != nil && capture.plan!.hasAddedCommits && capture.entries.first?.commit.hash == base.hash && capture.canStart, "Add without loaded plan failed to capture valid destination")
        // A changed picker request cannot consume a newer picker or edit its plan.
        let firstRequest = draft.beginAdditionalSelection()!
        draft.finishAdditionalSelection(firstRequest, revisions: nil)
        let secondRequest = draft.beginAdditionalSelection()!
        draft.finishAdditionalSelection(firstRequest, revisions: [base.hash])
        try require(draft.pickingCommits && !draft.busy, "Old request consumed a newer picker")
        draft.finishAdditionalSelection(secondRequest, revisions: nil)
        // Parent preparation now happens only at a durable reached occurrence.
        // Cancel owns the outstanding read but retains that exact checkpoint.
        let parentController = make(), parent = parentController.model
        parent.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3])
        prefs.set(false,forKey:"ConfirmKillProcess")
        parent.load(cherryPick: [merge.hash]); try await drain()
        try require(parent.canStart && parent.isCherryPick, "Merge Cherry Pick unavailable")
        var parentReply: CheckedContinuation<[LogParentChoice], Error>?
        parent.readMainlineChoices = { _, token in ownedToken = token; return try await withCheckedThrowingContinuation { parentReply = $0 } }
        start(parent)
        do {try await wait {parentReply != nil}} catch {
            var actual:RebaseState?
            if !parent.busy {actual=try? await repo.rebaseState()}
            let cached=parent.state.flatMap{try? JSONEncoder().encode($0)}.map{String(decoding:$0,as:UTF8.self)} ?? "nil"
            let disk=actual.flatMap{try? JSONEncoder().encode($0)}.map{String(decoding:$0,as:UTF8.self)} ?? "not-read-while-busy"
            fputs("Reached-parent diagnostic: busy=\(parent.busy) active=\(parent.active) retired=\(parent.retired) replayOps=\(RebaseWindowModel.activeReplayOperations) preparations=\(RebaseWindowModel.activePreparationReads) question=\(parent.hasReplayQuestion) error=\(parent.error ?? "nil") editor=\(parent.editorExecutable?.path ?? "nil") ownerSheet=\(String(describing:parentController.window?.attachedSheet)) appModal=\(String(describing:NSApp.modalWindow)) cachedState=\(cached) actualState=\(disk) output=\(parent.output.suffix(16000))\n",stderr)
            throw error
        }
        let reached=try await repo.rebaseState(),reachedHead=try await repo.rebaseCommit("HEAD").hash
        try require(reached.mainlineDecision?.commit==merge.hash && parent.busy && parent.active && RebaseWindowModel.activeReplayOperations>0,"Reached parent metadata lacks durable replay ownership")
        parent.cancelReplay();try require(ownedToken?.isCancelled==true && parent.busy,"Cancel released noncooperative parent read")
        parentReply?.resume(returning: try await repo.logParentChoices(merge)); parentReply = nil; try await drain()
        let cancelledState=try await repo.rebaseState()
        try require(cancelledState.mainlineDecision==reached.mainlineDecision && parent.plan!.entries.first?.mainline == nil && !parent.busy && parent.error == nil && parent.active,"Cancelled reached read changed mainline or lost resumable session")
        try require((try await repo.rebaseCommit("HEAD")).hash==reachedHead,"Cancelled reached read changed earlier committed progress")
        parent.readMainlineChoices = { try await repo.logParentChoices($0, cancellation: $1) }
        parent.request("continue"); try await wait { parent.hasReplayQuestion && parentController.window?.attachedSheet != nil }
        let sheet=parentController.window!.attachedSheet!,buttons=nativeViews(sheet.contentView!).compactMap{$0 as? NSButton}.filter{!$0.isHiddenOrHasHiddenAncestor && !$0.title.isEmpty}
        let fields=nativeViews(sheet.contentView!).compactMap{$0 as? NSTextField}.map(\.stringValue)
        guard let cancel=buttons.first(where:{$0.title=="Cancel"}),let cancelAction=cancel.action else{throw Failure(description:"Actual parent Cancel missing")}
        try require(buttons.count==3 && sheet.defaultButtonCell === cancel.cell && sheet.alphaValue==0 && fields.contains(where:{$0.contains("Which parent do you want to pick?") && $0.contains(merge.hash)}),"Actual reached parent sheet lost source text/choices/default Cancel/owner")
        try require(NSApp.sendAction(cancelAction,to:cancel.target,from:cancel),"Native reached parent Cancel failed to dispatch")
        try await drain();try await wait {parentController.window?.attachedSheet==nil && !parent.hasReplayQuestion && !parent.busy}
        try require((try await repo.rebaseState()).mainlineDecision==reached.mainlineDecision && parent.active,"Native Cancel did not retain the reached parent decision")
        parent.request("continue"); try await wait { parent.hasReplayQuestion }; parentController.close(); try await drain()
        try require(parent.retired && !parent.hasReplayQuestion && !parent.busy,"Forced reached-parent closure retained question or worker")
        let retiredState=try await repo.rebaseState()
        try require(retiredState.mainlineDecision==reached.mainlineDecision,"Closing parent changed the durable decision")
        _ = try await repo.abortRebase()
        model.readAddedPlan = { _, _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        model.addCommits([side.hash]); try await wait { reply != nil }; let retiredIDs = model.entries.map(\.id)
        controller.close(); reply?.resume(returning: added); reply = nil; try await drain()
        try require(model.retired && model.entries.map(\.id) == retiredIDs && model.error == nil, "Closed Add published late reply")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout
        let afterState = try await repo.rebaseState()
        try require(afterHead == originalHead && afterIndex == originalIndex && !afterState.active, "Preparation changed Git state")
        owners.forEach { $0.model.retire(); $0.close() }; owners = []; try await drain()
        try await reachedOrdering()
        try await repeatedReachedSkip()
        try await reachedOwnership()
        try await noCommitSquashRecovery()
        try await noCommitSquashSplit()
        try require(RebaseWindowController.activeCommitPickers == 0, "Picker counter leaked")
        print("PASS: owned Add/draft/picker and reached Cherry Pick merge-parent recovery; cancellation, ordered empty review, repeated Skip, reopen, stale answer and forced close; Git \(CommandLine.arguments[2])")
    }

    @MainActor static func reachedOrdering()async throws {
        let c=try ReachedContext("reached-ordering")
        do {
            try await c.seed();let owner=try await c.open([c.last.hash,c.merge.hash,c.empty.hash,c.ordinary.hash]),model=owner.model
            let ids=model.plan!.entries.map(\.id),requested=model.plan!.entries.map(\.action)
            try require(model.plan!.entries.map{$0.commit.hash} == [c.ordinary.hash,c.empty.hash,c.merge.hash,c.last.hash],"Fixture did not preserve oldest-first advanced Cherry ordering")
            var events=[String](),parentChoices=[Int]()
            model.confirmEmptyMessageReview={events.append("empty");return true}
            c.hold(model){_,choices in events.append("parent");parentChoices=choices.map(\.number)}
            start(model);try await wait {!model.busy && model.state?.isEditPause==true};try await drain()
            try require(events==["empty"] && FileManager.default.fileExists(atPath:c.root.appendingPathComponent("ordinary.txt").path) && FileManager.default.fileExists(atPath:c.root.appendingPathComponent("empty.txt").path) && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Future merge parent was prompted before reached empty-message review")
            model.messageBinding(model.formContext).wrappedValue="Reviewed empty subject\n\nBody preserved for empty review\n"
            model.request("continue");try await wait {!c.answers.isEmpty}
            let before=try await c.repository.rebaseState(),head=try await c.repository.rebaseCommit("HEAD"),index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
            guard let decision=before.mainlineDecision else{throw Failure(description:"Missing durable reached parent decision")}
            try require(events==["empty","parent"] && parentChoices==[1,2] && decision.entryID==ids[2] && decision.commit==c.merge.hash && decision.requestedAction==requested[2] && decision.step==3 && decision.head==head.hash,"Reached choice lost exact occurrence/order/HEAD/parent metadata")
            try require(head.subject=="Reviewed empty subject" && head.author==c.empty.author && model.logicalProgressCompleted==2 && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("last.txt").path),"Parent question did not retain earlier actual progress")
            c.answer(nil);try await wait {!model.busy};try await drain()
            let cancelled=try await c.repository.rebaseState()
            try require(cancelled.mainlineDecision==decision && model.active && model.error==nil && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Parent Cancel changed durable progress/index or became failure")
            owner.close();try await drain()
            let reopened=try await c.open(),next=reopened.model
            try require(next.state?.mainlineDecision==decision,"Reopen lost reached parent selection")
            var resumedQuestions=0,resumedMetadataValid=false
            next.chooseMainline={commit,choices in resumedQuestions+=1;resumedMetadataValid=commit.hash==c.merge.hash && choices.map(\.number)==[1,2];return 1}
            next.request("continue");try await wait {!next.busy && next.finished};try await drain()
            let applied=try await c.repository.rebaseCommit("HEAD~1"),finalState=try await c.repository.rebaseState()
            try require(next.error==nil && !finalState.active && resumedQuestions==1 && resumedMetadataValid && applied.subject==c.merge.subject && applied.author==c.merge.author && applied.date==c.merge.date && applied.parents.count==1,"Accepted reached mainline failed actual replay/author/message or repeated prompt")
            for path in ["ordinary.txt","empty.txt","side.txt","last.txt","destination.txt"] {try require(FileManager.default.fileExists(atPath:c.root.appendingPathComponent(path).path),"Final selected parent lost "+path)}
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    @MainActor static func repeatedReachedSkip()async throws {
        let c=try ReachedContext("reached-repeat-skip")
        do {
            try await c.seed();let owner=try await c.open([c.merge.hash]),model=owner.model
            model.addCommits([c.merge.hash]);try await wait {!model.busy && !model.addingCommits && model.plan?.entries.count==2};try await drain()
            let ids=model.plan!.entries.map(\.id)
            try require(ids[0] != ids[1] && model.plan!.entries.allSatisfy{$0.commit.hash==c.merge.hash},"Add collapsed repeated merge occurrences")
            c.hold(model);start(model);try await wait {!c.answers.isEmpty}
            guard let first=try await c.repository.rebaseState().mainlineDecision else{throw Failure(description:"First repeated merge decision missing")}
            c.answer(nil);try await wait {!model.busy};try await drain()
            c.request(model,"skip");try await wait {!c.answers.isEmpty}
            guard let second=try await c.repository.rebaseState().mainlineDecision else{throw Failure(description:"Second repeated merge decision missing")}
            try require(first.entryID==ids[0] && second.entryID==ids[1] && first.commit==second.commit && first.step==1 && second.step==2 && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Skip applied merge or reused a hash-only parent receipt")
            c.answer(nil);try await wait {!model.busy};try await drain()
            c.request(model,"abort");try await wait {!model.busy && !model.active};try await drain()
            let head=try await c.repository.rebaseCommit("HEAD").hash,state=try await c.repository.rebaseState()
            try require(head==c.originalHead && !state.active && model.error==nil && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Abort did not restore original state after reached Skip")
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    @MainActor static func reachedOwnership()async throws {
        let c=try ReachedContext("reached-owner")
        do {
            try await c.seed();let owner=try await c.open([c.merge.hash,c.ordinary.hash]),model=owner.model
            c.hold(model);start(model);try await wait {!c.answers.isEmpty}
            let initial=try await c.repository.rebaseState(),head=try await c.repository.rebaseCommit("HEAD").hash
            owner.close()
            try require(model.retired && RebaseWindowModel.activeReplayOperations>0,"Retired owner released a noncooperative parent answer")
            c.answer(1);try await drain()
            let after=try await c.repository.rebaseState(),afterHead=try await c.repository.rebaseCommit("HEAD").hash
            try require(after.mainlineDecision==initial.mainlineDecision && afterHead==head && model.error==nil && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Retired answer selected or applied a merge parent")
            let reopened=try await c.open(),next=reopened.model
            c.hold(next);next.request("continue");try await wait {!c.answers.isEmpty}
            let replayBefore=try await c.repository.rebaseReplayEntries()
            _=try await c.repository.run(["commit","--allow-empty","-m","external while parent pending"])
            let externalHead=try await c.repository.rebaseCommit("HEAD").hash
            c.answer(1);try await wait {!next.busy};try await drain()
            let refused=try await c.repository.rebaseState(),refusedHead=try await c.repository.rebaseCommit("HEAD").hash
            let replayAfter=try await c.repository.rebaseReplayEntries()
            try require(refusedHead==externalHead && refused.mainlineDecision?.entryID==after.mainlineDecision?.entryID && refused.mainlineDecision?.parents==after.mainlineDecision?.parents && refused.mainlineDecision?.head==head && next.error != nil && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Changed HEAD accepted a stale mainline answer")
            try require(replayAfter.map(\.id)==replayBefore.map(\.id) && replayAfter.map(\.mainline)==replayBefore.map(\.mainline),"Stale answer persisted a parent into replay metadata")
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    @MainActor static func noCommitSquashRecovery()async throws {
        for mode in ["commit","abort","conflict"] {
            let c=try ReachedContext("reached-no-commit-"+mode)
            do {
                try await c.seed()
                if mode=="conflict" {
                    try Data("different destination contents\n".utf8).write(to:c.root.appendingPathComponent("last.txt"))
                    try await c.repository.stage(["last.txt"])
                    _=try await c.repository.commit(message:"destination owns last path")
                    c.originalHead=try await c.repository.rebaseCommit("HEAD").hash
                }
                let owner=try await c.open([c.last.hash,c.merge.hash]),model=owner.model
                let ids=model.plan!.entries.map(\.id)
                model.setAction(.squash,ids:[ids[1]])
                try require(model.plan!.entries.map(\.action)==[.pick,.squash] && model.canStart,"Following Squash plan unavailable")
                c.hold(model);start(model);try await wait {!c.answers.isEmpty}
                let reached=try await c.repository.rebaseState()
                try require(reached.mainlineDecision?.entryID==ids[0],"Leading merge parent was not reached before Squash")
                c.answer(nil);try await wait {!model.busy};try await drain()
                try require((try await c.repository.rebaseCommit("HEAD")).hash==c.originalHead,"Parent Cancel committed the leading merge")
                c.request(model,"skip");try await wait {!model.busy && model.state?.noCommitSquash != nil};try await drain()
                let stopped=try await c.repository.rebaseState(),before=try await c.repository.rebaseCommit("HEAD")
                try require(before.hash==c.originalHead && stopped.noCommitSquash?.baseHead==c.originalHead && stopped.noCommitSquash?.entryID==ids[1] && stopped.noCommitSquash?.preservesLeaderAuthor==true && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Skipped leader changed HEAD or lost reached author/group identity")
                if mode=="conflict" {
                    try require(stopped.noCommitSquash?.phase == .conflicted && stopped.conflicts.contains("last.txt") && model.fileRecovery,"No-commit apply conflict did not reach checked-file recovery")
                    try Data("resolved combined file\n".utf8).write(to:c.root.appendingPathComponent("last.txt"))
                    model.setConflictChecked("last.txt",checked:true)
                    try require(model.checkedConflicts.contains("last.txt"),"Resolved path could not be checked")
                    c.request(model,"continue");try await wait {!model.busy && model.state?.noCommitSquash?.phase == .approval};try await drain()
                    let resolvedHead=try await c.repository.rebaseCommit("HEAD").hash,resolvedState=try await c.repository.rebaseState()
                    try require(resolvedHead==c.originalHead && resolvedState.conflicts.isEmpty,"Selected resolution committed before combined message approval")
                }
                let approved=try await c.repository.rebaseState(),index=try await c.repository.run(["ls-files","--stage"]).stdout
                try require(approved.noCommitSquash?.phase == .approval && approved.squashMessage?.isNewCommit==true && model.canEditMessage && model.primaryActionTitle=="Commit","New combined commit approval was presented as amendment")
                let draft="Reviewed skipped leader group\n\n"+c.merge.message.trimmingCharacters(in:.newlines)+"\n\n"+c.last.message.trimmingCharacters(in:.newlines)+"\n"
                model.messageBinding(model.formContext).wrappedValue=draft
                owner.close();try await drain()
                let reopened=try await c.open(),next=reopened.model
                let reopenedHead=try await c.repository.rebaseCommit("HEAD").hash,reopenedIndex=try await c.repository.run(["ls-files","--stage"]).stdout
                try require(next.state?.noCommitSquash==approved.noCommitSquash && next.state?.squashMessage?.isNewCommit==true && reopenedHead==c.originalHead && reopenedIndex==index,"Reopen lost approval identity or altered staged combined changes")
                if mode=="abort" {
                    c.request(next,"abort");try await wait {!next.busy && !next.active};try await drain()
                    try require((try await c.repository.rebaseCommit("HEAD")).hash==c.originalHead && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("last.txt").path),"Abort failed to restore pre-group HEAD/worktree")
                } else {
                    next.messageBinding(next.formContext).wrappedValue=draft
                    c.request(next,"continue");try await wait {!next.busy && next.finished};try await drain()
                    let final=try await c.repository.rebaseCommit("HEAD"),state=try await c.repository.rebaseState()
                    try require(next.error==nil && !state.active && final.parents==[c.originalHead] && final.author==c.merge.author && final.email==c.merge.email && final.date==c.merge.date && final.message.trimmingCharacters(in:.newlines)==draft.trimmingCharacters(in:.newlines),"Normal combined commit lost original parent/reached source author/message")
                    let expected=mode=="conflict" ? "resolved combined file\n":"last.txt\n"
                    let actual=try Data(contentsOf:c.root.appendingPathComponent("last.txt"))
                    try require(actual==Data(expected.utf8),"Combined commit lost checked file contents")
                }
                await c.cleanup()
            }catch{await c.cleanup();throw error}
        }
    }
    @MainActor static func noCommitSquashSplit()async throws {
        let c=try ReachedContext("reached-no-commit-split")
        c.preferences.set(true,forKey:"HintStagingMode")
        do {
            try await c.seed()
            _=try await c.repository.run(["checkout","--detach",c.last.hash])
            try Data("extra split payload\n".utf8).write(to:c.root.appendingPathComponent("split-extra.txt"))
            try await c.repository.stage(["split-extra.txt"])
            _=try await c.repository.run(["commit","--amend","--no-edit"])
            c.last=try await c.repository.rebaseCommit("HEAD")
            _=try await c.repository.run(["checkout","destination"])
            let owner=try await c.open([c.last.hash,c.merge.hash]),model=owner.model
            model.setAction(.squash,ids:[model.plan!.entries[1].id])
            c.hold(model);start(model);try await wait {!c.answers.isEmpty}
            c.answer(nil);try await wait {!model.busy};try await drain()
            c.request(model,"skip");try await wait {!model.busy && model.state?.noCommitSquash?.phase == .approval};try await drain()
            try require(model.canSplit,"Final new-commit approval did not expose source Split")
            let group=try await c.repository.rebaseState()
            var children=[CommitWindowModel]()
            model.configureCommitSelection={child in children.append(child);child.confirmCancel={$0(true)}}
            let draft="Pending native Split draft\n\nOriginal group payload\n"
            model.messageBinding(model.formContext).wrappedValue=draft
            model.splitBinding(model.formContext).wrappedValue=true
            try require(model.splitCommit,"Actual Split checkbox binding rejected approval")
            model.request("continue")
            try await wait {children.first?.busy==false && children.first?.replaySplit != nil};try await drain()
            let cancelled=children[0]
            let cancelledWindow=owner.window?.attachedSheet
            try require(cancelled.replaySplit?.isNewCommit==true && !cancelled.amend && !cancelled.amendDiffToLastCommit && cancelled.message==draft && owner.window?.attachedSheet?.alphaValue==0,"First actual Split child amended base or lost draft/owned hidden presentation")
            cancelled.cancel();try await wait {!model.busy && !model.selectingSplit};try await drain()
            try require(model.state?.split==nil && model.amendMessage==draft && model.state?.noCommitSquash?.id==group.noCommitSquash?.id && cancelledWindow?.isVisible==false && cancelledWindow?.sheetParent==nil,"Unstarted child Cancel discarded pending approval/draft or survived callback")
            let base=try await c.repository.rebaseCommit("HEAD");try require(base.hash==c.originalHead,"Split child Cancel amended prior HEAD")
            owner.close();try await drain()
            let reopened=try await c.open(),next=reopened.model
            try require(next.state?.noCommitSquash?.id==group.noCommitSquash?.id && next.canSplit,"Reopen lost final approval Split ownership")
            children=[]
            next.configureCommitSelection={child in children.append(child);child.confirmCancel={$0(true)}}
            next.chooseAnotherSplit={false}
            next.splitBinding(next.formContext).wrappedValue=true;next.request("continue")
            try await wait {children.count==1 && children[0].busy==false && children[0].replaySplit != nil};try await drain()
            let first=children[0]
            let firstWindow=reopened.window?.attachedSheet
            try require(!first.amend && !first.amendDiffToLastCommit && first.replaySplit?.firstParents==[c.originalHead],"Reopened first Split child targeted prior commit")
            first.setStagingEnabled(true);try await wait {!first.busy && !first.savingPreferences && first.stagingEnabled}
            first.moveToStage(["split-extra.txt"],staged:false);try await wait {!first.busy}
            first.moveToStage(["split-extra.txt"],staged:true);try await wait {!first.busy}
            first.moveToStage(["split-extra.txt"],staged:false);try await wait {!first.busy}
            try Data("last.txt\nworking remainder\n".utf8).write(to:c.root.appendingPathComponent("last.txt"))
            first.refreshStagingState();try await wait {!first.busy && !first.stagingStateNeedsRefresh}
            guard let partial=first.entries.first(where:{$0.path=="last.txt"}),let extra=first.entries.first(where:{$0.path=="split-extra.txt"}) else{throw Failure(description:"Split staging rows missing")}
            try require(first.stagingState(partial) == .mixed && first.stagingState(extra) == .off,"Actual first child lost partial/unstaged index transitions")
            first.checked=["last.txt"];first.message="First native normal part";first.commit()
            try await wait {children.count==2 && children[1].busy==false && children[1].replaySplit?.parts==1};try await drain()
            let accepted=try await c.repository.rebaseCommit("HEAD")
            try require(accepted.parents==[c.originalHead],"Actual first Split child lost source parent: \(accepted.parents)")
            try require(accepted.author==c.merge.author && accepted.email==c.merge.email,"Actual first Split child lost source author identity: \(accepted.author) <\(accepted.email)>")
            guard let actualDate=ISO8601DateFormatter().date(from:accepted.date),let sourceDate=ISO8601DateFormatter().date(from:c.merge.date) else{throw Failure(description:"First Split author date is not ISO8601: actual=\(accepted.date), source=\(c.merge.date)")}
            try require(actualDate==sourceDate,"Actual first Split child changed author instant: actual=\(accepted.date), source=\(c.merge.date)")
            try require(accepted.subject=="First native normal part","Actual first Split child lost reviewed message: \(accepted.subject)")
            let cancelledRemainder=children[1],remainderWindow=reopened.window?.attachedSheet
            try require(!cancelledRemainder.amend && !cancelledRemainder.amendDiffToLastCommit && cancelledRemainder.replaySplit?.isNewCommit==true && cancelledRemainder.replaySplit?.expectedHead==accepted.hash && firstWindow?.isVisible==false && firstWindow?.sheetParent==nil && reopened.window?.attachedSheet !== firstWindow,"Remaining actual Split child lost accepted-part receipt or preceded old native sheet release")
            cancelledRemainder.cancel();try await wait {!next.busy && !next.selectingSplit};try await drain()
            let retained=try await c.repository.rebaseCommit("HEAD")
            try require(next.state?.split?.parts==1 && retained.hash==accepted.hash && remainderWindow?.isVisible==false && remainderWindow?.sheetParent==nil,"Later child Cancel discarded an accepted part or survived callback")
            next.beginSplitSelection();try await wait {children.count==3 && children[2].busy==false && children[2].replaySplit?.parts==1};try await drain()
            let second=children[2]
            second.setStagingEnabled(true);try await wait {!second.busy && !second.savingPreferences && second.stagingEnabled}
            second.moveToStage(["last.txt","split-extra.txt"],staged:true);try await wait {!second.busy}
            second.checked=["split-extra.txt"];second.message="Second native normal part";second.commit()
            try await wait {!next.busy && next.finished};try await drain()
            let final=try await c.repository.rebaseCommit("HEAD"),state=try await c.repository.rebaseState()
            try require(next.error==nil && !state.active && final.parents==[accepted.hash] && final.subject=="Second native normal part" && final.author=="Reached QA" && reopened.window?.attachedSheet==nil,"Actual remaining Split child did not finish once with configured identity/owned release")
            let count=try await c.repository.run(["rev-list","--count",c.originalHead+"..HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(count=="2" && !FileManager.default.fileExists(atPath:c.root.appendingPathComponent("side.txt").path),"Native Split repeated a part or applied skipped merge")
            await c.cleanup()
        }catch{await c.cleanup();throw error}
    }
    @MainActor final class ReachedContext {
        let root:URL,repository:GitRepository,preferences:UserDefaults,suite:String,editor:URL
        var ordinary:LogEntry!,empty:LogEntry!,merge:LogEntry!,last:LogEntry!,originalHead=""
        var controllers=[RebaseWindowController](),answers=[CheckedContinuation<Int?,Never>]()
        init(_ name:String)throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]),libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ReachedMainline."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(false,forKey:"EnableGravatar")
            editor=URL(fileURLWithPath:CommandLine.arguments[3])
        }
        func commit(_ path:String,_ message:String)async throws->LogEntry {
            try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repository.stage([path])
            let messageFile=root.appendingPathComponent(".git/reached-message")
            try Data(message.utf8).write(to:messageFile)
            _=try await repository.run(["commit","--allow-empty-message","--cleanup=verbatim","-F",messageFile.path],environmentOverrides:["GIT_AUTHOR_NAME":"Reached "+path,"GIT_AUTHOR_EMAIL":"reached@example.invalid","GIT_AUTHOR_DATE":"2026-10-10T10:00:00+0200"])
            try FileManager.default.removeItem(at:messageFile);return try await repository.rebaseCommit("HEAD")
        }
        func seed()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in [("user.name","Reached QA"),("user.email","reached@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("rebase.updateRefs","false")] {_=try await repository.run(["config",key,value])}
            let base=try await commit("base.txt","base")
            _=try await repository.run(["switch","-c","topic"])
            ordinary=try await commit("ordinary.txt","ordinary first")
            empty=try await commit("empty.txt","\nBody preserved for empty review\n")
            _=try await repository.run(["switch","-c","side",base.hash]);_=try await commit("side.txt","side")
            _=try await repository.run(["switch","topic"])
            _=try await repository.run(["merge","--no-ff","side","-m","Merge reached after earlier rows"])
            merge=try await repository.rebaseCommit("HEAD");last=try await commit("last.txt","last")
            _=try await repository.run(["switch","-c","destination",base.hash]);_=try await commit("destination.txt","destination")
            originalHead=try await repository.rebaseCommit("HEAD").hash
        }
        func open(_ selected:[String]?=nil)async throws->RebaseWindowController {
            let owner=RebaseWindowController(repository:repository,access:nil,preferences:preferences);controllers.append(owner);owners.append(owner)
            owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.window?.orderFront(nil)
            owner.model.editorExecutable=editor;owner.model.load(cherryPick:selected)
            try await wait {!owner.model.busy && (owner.model.plan != nil || owner.model.active)};try await drain()
            return owner
        }
        func hold(_ model:RebaseWindowModel,_ events:((LogEntry,[LogParentChoice])->Void)?=nil) {
            model.chooseMainline={ [self] commit,choices in events?(commit,choices);return await withCheckedContinuation{answers.append($0)}}
        }
        func answer(_ parent:Int?) {guard !answers.isEmpty else{return};answers.removeFirst().resume(returning:parent)}
        func request(_ model:RebaseWindowModel,_ action:String) {model.request(action);if let question=model.pendingConfirmation{model.answerConfirmation(question,proceed:true)}}
        func cleanup()async {
            for owner in controllers {owner.model.retire();owner.close();owner.model.chooseMainline={_,_ in nil};owner.model.confirmEmptyMessageReview={false}}
            while !answers.isEmpty {answer(nil)}
            try? await drain()
            try? await wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeCommitPreflights==0}
            if (try? await repository.rebaseState().active)==true {_=try? await repository.abortRebase()}
            preferences.removePersistentDomain(forName:suite)
        }
    }
}
