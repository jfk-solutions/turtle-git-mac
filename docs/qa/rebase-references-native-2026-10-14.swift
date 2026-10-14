import AppKit
import TurtleGitCore

@main struct RebaseReferencesVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Rebase reference timeout")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Rebase references failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Ref QA"), ("user.email", "ref@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "-c", "upstream"])
        try Data("upstream\n".utf8).write(to: root.appendingPathComponent("upstream")); try await repo.stage(["upstream"]); _ = try await repo.commit(message: "upstream")
        let upstream = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["switch", "-c", "topic", base])
        try Data("topic\n".utf8).write(to: root.appendingPathComponent("topic")); try await repo.stage(["topic"]); _ = try await repo.commit(message: "topic")
        _ = try await repo.run(["tag", "alias-topic", "topic"]); _ = try await repo.run(["update-ref", "refs/remotes/origin/foreign", upstream])
        try Data((upstream + "\t\tfixture\n").utf8).write(to: root.appendingPathComponent(".git/FETCH_HEAD"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.RebaseReferences." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let controller = RebaseWindowController(repository: repo, access: nil, preferences: prefs), model = controller.model
        defer { controller.close() }
        @MainActor func settled() -> Bool { !model.busy && !model.loadingPlan && RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 }
        model.load(upstream: "refs/heads/upstream"); try await wait(settled)
        try require(model.plan != nil && model.referenceChoices(nil).contains { $0.name == "refs/remotes/origin/foreign" } && !model.referenceChoices(nil).contains { $0.name == "refs/tags/alias-topic" }, "Branch dropdown does not include exactly source branch kinds")
        try require(model.referenceChoices(.upstream).contains { $0.name == "FETCH_HEAD" } && model.referenceChoices(.upstream).contains { $0.name == "refs/tags/alias-topic" }, "Upstream omitted tag/FETCH_HEAD")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(controller.window!.contentView!).compactMap { $0 as? NSPopUpButton }.contains { $0.accessibilityLabel() == "Branch" } }
        let branchButton = descendants(controller.window!.contentView!).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Branch" }!
        try require(branchButton.itemArray.contains { $0.image != nil }, "Original reference artwork missing")
        let originalBranch = model.options.branch; branchButton.isEnabled = false
        branchButton.selectItem(at: max(0, branchButton.numberOfItems - 1)); if let action = branchButton.action { _ = NSApp.sendAction(action, to: branchButton.target, from: branchButton) }
        try require(model.options.branch == originalBranch, "Disabled dropdown callback changed the branch")
        branchButton.isEnabled = true
        controller.showReferencePicker(.upstream)
        try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let first = controller.referencePicker!
        try require(model.pickingReference != nil && RebaseWindowController.activeReferencePickers == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Picker lacks source/Quit ownership")
        first.model.setFolder("refs/tags"); first.model.select(["refs/tags/alias-topic"], last: "refs/tags/alias-topic"); first.model.accept()
        try await wait(settled)
        try require(model.options.upstream == "refs/tags/alias-topic" && model.pickingReference == nil && RebaseWindowController.activeReferencePickers == 0, "Upstream selection lost on child close")
        model.chooseUpstream("refs/heads/upstream"); try await wait(settled)
        controller.showReferencePicker(.onto); try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let alias = controller.referencePicker!; alias.model.setFolder("refs/tags"); alias.model.select(["refs/tags/alias-topic"], last: "refs/tags/alias-topic"); alias.model.accept()
        try await wait(settled); try require(!model.ontoEnabled && model.options.onto.isEmpty, "Onto alias of Branch accepted")
        controller.showReferencePicker(.onto); try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let onto = controller.referencePicker!; onto.model.setFolder("refs/heads"); onto.model.select(["refs/heads/main"], last: "refs/heads/main"); onto.model.accept()
        try await wait(settled); try require(model.ontoEnabled && model.options.onto == "refs/heads/main" && model.plan?.ontoHash == base, "Distinct Onto not selected/captured")
        controller.showReferencePicker(.onto); try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        controller.referencePicker?.model.cancel(); try await wait(settled)
        try require(!model.ontoEnabled && model.options.onto.isEmpty, "Onto Cancel did not clear source selection")
        // An old result must neither publish nor clear a replacement read's loading state.
        let oldPlan = try await repo.rebasePlan(model.options)
        var nextOptions = model.options; nextOptions.upstream = "refs/heads/main"
        let newPlan = try await repo.rebasePlan(nextOptions)
        var oldReply: CheckedContinuation<RebasePlan, Error>?, newReply: CheckedContinuation<RebasePlan, Error>?, reads = 0
        model.readPlan = { _, _ in reads += 1; return try await withCheckedThrowingContinuation { if reads == 1 { oldReply = $0 } else { newReply = $0 } } }
        model.reloadPlan(force: true); try await wait { oldReply != nil }
        model.chooseUpstream("refs/heads/main"); try await wait { newReply != nil }
        oldReply?.resume(returning: oldPlan); oldReply = nil
        try await wait { RebaseWindowModel.activePreparationReads == 1 }
        try require(model.loadingPlan && model.plan == nil && !model.canStart, "Old read cleared replacement ownership")
        newReply?.resume(returning: newPlan); newReply = nil; try await wait(settled)
        try require(model.plan?.upstreamHash == base && model.options.upstream == "refs/heads/main", "Replacement plan not retained")
        model.readPlan = { try await repo.rebasePlan($0, cancellation: $1) }
        // PickRefForCombo always refreshes an accepted selection, even when its
        // spelling is unchanged and its ref moved while the dialog was open.
        model.chooseUpstream("refs/heads/upstream"); try await wait(settled)
        let oldUpstreamHash = model.plan!.upstreamHash
        let upstreamTree = try await repo.run(["rev-parse", "refs/heads/upstream^{tree}"]).text.trimmingCharacters(in: .newlines)
        let moved = try await repo.run(["commit-tree", upstreamTree, "-p", oldUpstreamHash], input: Data("moved upstream\n".utf8)).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/heads/upstream", moved])
        controller.showReferencePicker(.upstream); try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        controller.referencePicker?.model.accept(); try await wait(settled)
        try require(model.options.upstream == "refs/heads/upstream" && model.plan?.upstreamHash == moved, "Accepted unchanged ref reused a stale plan")
        var late: ((String?) -> Void)?
        controller.makeReferencePicker = { repository, access, initial, preferences, choose in
            late = choose; return ReferenceBrowserWindowController(repository: repository, access: access, initial: initial, preferences: preferences, onChoose: choose)
        }
        controller.showReferencePicker(.upstream); try await wait { controller.referencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let previous = model.options.upstream; controller.close(); late?("refs/tags/alias-topic")
        try require(model.retired && model.options.upstream == previous && RebaseWindowController.activeReferencePickers == 0, "Retired picker changed fields")
        // Initial-load Git children stay cancellable/owned after the source is removed.
        let helper = root.appendingPathComponent("slow-reference-git"), marker = root.appendingPathComponent("reference-started")
        let script = "#!/bin/sh\nif [ \"$4\" = for-each-ref ]; then\n : > \"$3/reference-started\"\n /bin/sleep 30\nfi\nexec \"$TG_REBASE_REF_GIT\" \"$@\"\n"
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_REBASE_REF_GIT", git.path, 1); defer { unsetenv("TG_REBASE_REF_GIT") }
        let slow = RebaseWindowModel(repository: GitRepository(root: root, executable: helper), access: nil, messageDefaults: prefs)
        slow.load(upstream: "refs/heads/upstream"); try await wait { FileManager.default.fileExists(atPath: marker.path) }
        slow.retire(); try require(RebaseWindowModel.activePreparationReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Removed initial reader lost Quit ownership")
        try await wait { RebaseWindowModel.activePreparationReads == 0 && RebaseWindowModel.activeColumnReads == 0 }
        try require(slow.references.isEmpty && slow.plan == nil && slow.error == nil, "Retired initial load published data/error")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(after == head && afterIndex == index, "Reference preparation changed HEAD/index")
        print("Rebase references: source dropdown kinds/icons/disabled callbacks, full Upstream/Onto browser and alias/Cancel rules, superseded plan ownership, accepted/retired picker ordering, real initial-read cancellation/Quit, unchanged HEAD/index passed. Owned windows closed.")
    }
}
