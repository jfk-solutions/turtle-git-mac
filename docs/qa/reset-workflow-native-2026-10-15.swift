import AppKit
import TurtleGitCore

@main struct ResetWorkflowVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !ready() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(ready(), "Reset workflow timeout at line \(line)")
    }
    @MainActor static func button(_ root: NSView, _ title: String) -> NSButton? {
        if let button = root as? NSButton, button.title == title { return button }
        for child in root.subviews { if let result = button(child, title) { return result } }
        return nil
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Reset workflow failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reset Workflow QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for tag in ["alpha", "zulu"] { _ = try await repo.run(["tag", tag]) }
        try Data("next\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "next")
        let next = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data((next + "\t\tbranch 'main' of private-fixture\n").utf8).write(to: root.appendingPathComponent(".git/FETCH_HEAD"))
        try Data("index\n".utf8).write(to: file); try await repo.stage(["file"]); try Data("working\n".utf8).write(to: file)
        let originalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.ResetWorkflow." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "BranchesIncludeFetchHead"); prefs.set(true, forKey: "SortTagsReversed"); prefs.set(0, forKey: "AutoCloseGitProgress")
        let owner = ResetWindowController(repository: repo, access: nil, revision: base, preferences: prefs)
        defer { owner.close() }
        owner.model.load(); try await wait { !owner.model.busy && !owner.model.chooser.busy }
        try require(!owner.model.chooser.references.contains(where: \.isFetchHead) && owner.model.chooser.tags.first?.name == "refs/tags/zulu", "Chooser ignored private reference settings")
        owner.presentModifiedComparison = { _, _ in true }
        owner.model.showModifiedFiles()
        try require(owner.modifiedComparison?.model.preferences === prefs, "Modified Files lost preferences")
        owner.modifiedComparison?.close(); try await wait { !owner.model.showingModifiedFiles }
        owner.window?.appearance = NSAppearance(named: .darkAqua); owner.window?.alphaValue = 0.87
        owner.presentCommitPicker = { _, _ in true }
        var configured = 0
        owner.configureCommitPicker = { _ in configured += 1 }
        owner.model.showCommitPicker()
        let picker = owner.commitPicker!
        try await wait { !picker.model.busy && !picker.model.entries.isEmpty }
        try require(configured == 1 && picker.model.endRevision == base && picker.window?.appearance == owner.window?.appearance && picker.window?.alphaValue == owner.window?.alphaValue, "Log picker setup lost range/commands/appearance")
        owner.model.chooser.commitRevision = next
        picker.model.select([base]); picker.model.accept()
        try require(!owner.model.showingCommitPicker && owner.model.chooser.commitRevision == next, "Stale picker selection replaced changed draft")
        owner.model.showCommitPicker(); let accepted = owner.commitPicker!
        try await wait { !accepted.model.busy && accepted.model.entries.count == 2 }
        accepted.model.select([base]); accepted.model.accept()
        try require(owner.model.chooser.commitRevision == base && owner.model.chooser.commitChoices.contains(base), "Accepted commit missing from editable history")

        // A caller that refuses progress must release its owner without starting Git.
        let refused = ResetWindowModel(repository: repo, access: nil, revision: base, preferences: prefs)
        refused.onProgress = { [weak refused] in refused?.abandonProgressPresentation($0) }
        refused.apply(try await repo.prepareReset(to: base, mode: .hard))
        try await Task.sleep(nanoseconds: 20_000_000)
        try require(refused.progress == nil && !refused.busy, "Refused progress retained owner")
        refused.invalidate()

        var answers: [(Bool) -> Void] = [], applied = 0
        let questions = ResetWindowModel(repository: repo, access: nil, revision: base, preferences: prefs)
        questions.chooser.options.target = .commit; questions.chooser.commitRevision = base; questions.mode = .hard
        questions.confirmHard = { _, answer in answers.append(answer) }
        questions.onProgress = { [weak questions] result in applied += 1; questions?.abandonProgressPresentation(result) }
        questions.reset(); try await wait { answers.count == 1 }
        answers[0](false); questions.reset(); try await wait { answers.count == 2 }
        answers[0](true); try require(questions.confirmingHard && applied == 0, "Obsolete confirmation consumed newer request")
        questions.chooser.commitRevision = next; answers[1](true)
        try require(!questions.confirmingHard && applied == 0, "Changed confirmation draft executed")
        questions.invalidate()

        let held = ResetWindowController(repository: repo, access: nil, revision: base, preferences: prefs)
        var state: CheckedContinuation<(String, Bool), Error>?
        var references: CheckedContinuation<([CheckoutReference], String), Error>?
        held.model.readState = { _ in try await withCheckedThrowingContinuation { state = $0 } }
        held.model.chooser.readInitialReferences = { _ in try await withCheckedThrowingContinuation { references = $0 } }
        held.model.load(); try await wait { state != nil && references != nil }
        try require(!held.windowShouldClose(held.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Close/Quit escaped initial readers")
        state?.resume(returning: ("obsolete", false)); state = nil
        try await wait { !held.model.busy }
        try require(held.model.currentBranch.isEmpty && held.model.chooser.busy, "Canceled initial read published or closed early")
        references?.resume(returning: ([CheckoutReference(name: "refs/heads/obsolete")], "obsolete")); references = nil
        try await wait { !held.model.chooser.busy && ResetWindowModel.activeReads == 0 && SwitchWindowModel.activeReads == 0 }
        try require(!held.model.initialModeFocusAvailable && held.model.chooser.references.isEmpty, "Close failed to retire both readers")
        held.model.showCommitPicker(); held.model.showModifiedFiles(); held.model.reset()
        try require(held.commitPicker == nil && held.modifiedComparison == nil && !held.model.busy, "Retired owner reopened work")

        var preparation: CheckedContinuation<ResetPlan, Error>?
        let plan = try await repo.prepareReset(to: base, mode: .soft)
        let retiring = ResetWindowModel(repository: repo, access: nil, revision: base, preferences: prefs)
        retiring.chooser.options.target = .commit; retiring.chooser.commitRevision = base
        retiring.preparePlan = { _, _, _ in try await withCheckedThrowingContinuation { preparation = $0 } }
        retiring.reset(); try await wait { preparation != nil }; retiring.invalidate()
        try require(ResetWindowModel.activeReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired preparation lost ownership")
        preparation?.resume(returning: plan); preparation = nil
        try await wait { ResetWindowModel.activeReads == 0 }
        try require(retiring.progress == nil, "Retired preparation opened progress")
        try require(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines) == next, "Read/picker/refused workflow changed HEAD")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == originalIndex && String(contentsOf: file) == "working\n", "Read/picker/refused workflow changed files")

        // Exercise the actual NSAlert -> progress sheet -> acknowledgement route.
        owner.window?.appearance = NSAppearance(named: .aqua); owner.window?.alphaValue = 1
        owner.showWindow(nil); owner.model.chooser.options.target = .commit; owner.model.chooser.commitRevision = base; owner.model.mode = .hard
        var resetCompletions = 0
        owner.model.onReset = { _ in resetCompletions += 1 }
        owner.model.reset(); try await wait { owner.window?.attachedSheet != nil }
        guard let alertView = owner.window?.attachedSheet?.contentView, let resetButton = button(alertView, "Reset") else { throw Failure(description: "Hard reset alert missing") }
        resetButton.performClick(nil)
        try await wait { owner.model.progress != nil }
        try await wait { owner.model.progress?.busy == false }
        try require(owner.model.progress?.success == true && resetCompletions == 0, "Actual hard-reset handoff failed or acknowledged early")
        owner.model.progress?.close(); try await wait { owner.model.progress == nil }
        try require(resetCompletions == 1 && (try String(contentsOf: file)) == "base\n", "Reset result acknowledgement lost completion")
        print("Reset workflow passed: preferences, owned picker drafts, modified comparison, canceled/retired readers and preparation, one-use hard confirmation, refused progress, actual NSAlert/progress/acknowledgment. Owned windows closed.")
    }
}
