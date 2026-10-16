import AppKit
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
        try await wait { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 }
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.model.retire(); $0.close() }; owners = [] }
        catch { owners.forEach { $0.model.retire(); $0.close() }; owners = []; fputs("Add preparation failed: \(error)\n", stderr); exit(1) }
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
        // Cherry Pick parent metadata and actual native parent question share the
        // same cancellable preparation lifetime and never mutate on cancellation.
        let parentController = make(), parent = parentController.model
        parent.load(cherryPick: [merge.hash]); try await drain()
        try require(parent.canStart && parent.isCherryPick, "Merge Cherry Pick unavailable")
        var parentReply: CheckedContinuation<[LogParentChoice], Error>?
        parent.readMainlineChoices = { _, token in ownedToken = token; return try await withCheckedThrowingContinuation { parentReply = $0 } }
        parent.request("start"); try await wait { parentReply != nil }
        try require(parent.preparingMainline && parent.hasCancellablePreparation && parent.busy, "Parent metadata lacks preparation ownership")
        _ = parent.cancelPreparation(); parentReply?.resume(returning: try await repo.logParentChoices(merge)); parentReply = nil; try await drain()
        try require(parent.plan!.entries.first?.mainline == nil && !parent.busy && parent.error == nil && !parent.active, "Cancelled mainline read started replay")
        parent.readMainlineChoices = { try await repo.logParentChoices($0, cancellation: $1) }
        parent.request("start"); try await wait { parent.hasReplayQuestion && parentController.window?.attachedSheet != nil }
        try require(parent.preparingMainline && parent.busy && parent.cancelPreparation(), "Actual parent question cannot cancel")
        try await drain(); try await wait { parentController.window?.attachedSheet == nil }
        try require(!parent.hasReplayQuestion && !parent.busy && !parent.active && parent.plan!.entries.first?.mainline == nil, "Cancelled parent sheet left replay/continuation ownership")
        // Forced owner closure retires a pending actual sheet once and rejects its
        // delayed answer. A held Add reply similarly cannot publish after retire.
        parent.request("start"); try await wait { parent.hasReplayQuestion }; parentController.close(); try await drain()
        try require(parent.retired && !parent.hasReplayQuestion && !parent.active && RebaseWindowModel.activePreparationReads == 0, "Forced parent closure retained question")
        model.readAddedPlan = { _, _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        model.addCommits([side.hash]); try await wait { reply != nil }; let retiredIDs = model.entries.map(\.id)
        controller.close(); reply?.resume(returning: added); reply = nil; try await drain()
        try require(model.retired && model.entries.map(\.id) == retiredIDs && model.error == nil, "Closed Add published late reply")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout
        let afterState = try await repo.rebaseState()
        try require(afterHead == originalHead && afterIndex == originalIndex && !afterState.active, "Preparation changed Git state")
        owners.forEach { $0.model.retire(); $0.close() }; owners = []; try await drain()
        try require(RebaseWindowController.activeCommitPickers == 0, "Picker counter leaked")
        print("PASS: owned Add/draft/picker and Cherry Pick merge-parent preparation; cancellation, failure/retry, stale reply and forced close; Git \(CommandLine.arguments[2])")
    }
}
