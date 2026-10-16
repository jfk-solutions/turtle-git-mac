import AppKit
import TurtleGitCore

@main struct LogReferenceNavigationVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Log reference navigation timeout")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Log reference navigation failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Ref QA"), ("user.email", "ref@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .newlines)
        var tips: [String: String] = [:]
        for (name, ref) in [("topic", "refs/heads/topic"), ("tag", "refs/tags/only-tag"), ("other", "refs/other/private")] {
            let hash = try await repo.run(["commit-tree", tree, "-p", base], input: Data((name + "\n").utf8)).text.trimmingCharacters(in: .newlines)
            _ = try await repo.run(["update-ref", ref, hash]); tips[name] = hash
        }
        let fetch = root.appendingPathComponent(".git/FETCH_HEAD")
        try Data((base + "\t\tfixture\n").utf8).write(to: fetch)
        let suite = "TurtleGit.LogReferences." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(2, forKey: "MaxRefHistoryItems"); prefs.set(false, forKey: "EnableGravatar")
        defer { prefs.removePersistentDomain(forName: suite) }
        let controller = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false), model = controller.model
        defer { controller.close() }
        model.reload(); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.startReferenceTitle == "main" && model.fetchHeadRevision == base, "Initial reference label/metadata missing")
        // Model settlement precedes SwiftUI's representable update on some SDKs.
        // Wait for the actual enabled control, then assert its synchronous action;
        // waiting only on !busy can accidentally click the previous disabled view.
        @MainActor func clickScope(from scope: HistoryReferenceScope, to expected: HistoryReferenceScope) async throws {
            let state: NSControl.StateValue = scope == .current ? .off : scope == .all ? .on : .mixed
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            try await wait {
                model.effectiveReferenceScope == scope && model.canChangeStartReference &&
                descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }
                    .contains { $0.title == "All Branches" && $0.state == state && $0.isEnabled }
            }
            let checkbox = descendants(controller.window!.contentView!).compactMap { $0 as? NSButton }
                .first { $0.title == "All Branches" && $0.state == state && $0.isEnabled }!
            checkbox.performClick(nil)
            try require(model.effectiveReferenceScope == expected && model.referenceExpression == "HEAD",
                        "Reference checkbox \(scope) -> \(expected) failed: scope=\(model.effectiveReferenceScope), enabled=\(checkbox.isEnabled), state=\(checkbox.state.rawValue)")
            try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        }
        model.chooseReferenceScope(.local); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(Set(model.entries.filter { !$0.hash.isEmpty }.map(\.hash)) == [base, tips["topic"]!], "Local scope includes non-local refs")
        try await clickScope(from: .local, to: .current)
        try await clickScope(from: .current, to: .all)
        try require(model.entries.contains { $0.hash == tips["other"] }, "All scope omitted non-basic ref")
        try await clickScope(from: .all, to: .current)
        model.chooseReferenceScope(.basic); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(!model.entries.contains { $0.hash == tips["other"] } && model.entries.contains { $0.hash == tips["tag"] }, "Basic scope incorrect")
        try await clickScope(from: .basic, to: .current)
        model.chooseStartReference("refs/heads/main refs/heads/topic", remember: true)
        try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.startRevisions == ["refs/heads/main", "refs/heads/topic"] && model.revisionRange == nil, "Multi-reference choice became a single token")
        model.setPathScope(["file"]); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.canFollowRenames, "Single-file follow fixture unavailable")
        model.toggleHistoryWalk(.followRenames); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.historyWalk.followRenames && model.startRevisions == ["refs/heads/main", "refs/heads/topic"], "Enabling Follow silently replaced multiple tips")
        model.chooseStartReference("refs/heads/main refs/heads/topic")
        try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.historyWalk.followRenames, "Multi-tip choice disabled source-supported Follow")
        model.toggleHistoryWalk(.followRenames); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        model.setPathScope([]); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        model.chooseStartReference("HEAD..refs/heads/topic", remember: true)
        try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.entries.filter { !$0.hash.isEmpty }.map(\.hash) == [tips["topic"]!], "Range choice failed")
        try Data((tips["topic"]! + "\t\tchanged fixture\n").utf8).write(to: fetch)
        model.chooseFetchHead()
        try require(LogWindowModel.activeReferenceReads == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Reference preparation lost Quit ownership")
        try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 && LogWindowModel.activeReferenceReads == 0 }
        try require(model.endRevision == tips["topic"] && model.fetchHeadRevision == tips["topic"], "FETCH_HEAD used stale loaded hash")
        model.chooseStartReference("HEAD"); try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        controller.showStartReferencePicker()
        try await wait { controller.startReferencePicker != nil && controller.startReferencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let picker = controller.startReferencePicker!
        try require(model.referencePickerBlocked && LogWindowController.activeReferencePickers == 1 && !controller.windowShouldClose(controller.window!), "Picker does not own its source")
        picker.model.select(["refs/heads/main", "refs/heads/topic"], last: "refs/heads/main")
        try require(picker.model.pickRangeChoices.count == 3, "Two-ref range choices missing")
        picker.model.acceptRange(1)
        try await wait { !model.busy && LogWindowModel.activeHistoryLoads == 0 }
        try require(!model.referencePickerBlocked && controller.startReferencePicker == nil && LogWindowController.activeReferencePickers == 0 && model.revisionRange?.to == "refs/heads/topic", "Accepted range was lost during picker close")
        let reopened = HistoryReferenceRecents(root: root, defaults: prefs)
        try require(reopened.entries.first == "refs/heads/main..refs/heads/topic", "Recent picker selection not saved")
        // Force retirement before a delayed injected picker selection.
        var late: ((String?) -> Void)?
        controller.makeStartReferencePicker = { repository, access, initial, preferences, choose in
            late = choose
            return ReferenceBrowserWindowController(repository: repository, access: access, initial: initial, preferences: preferences, pickMultiple: true, allowsRangeSelection: true, onChoose: choose)
        }
        controller.showStartReferencePicker()
        try await wait { controller.startReferencePicker?.model.busy == false && ReferenceBrowserWindowModel.activeReads == 0 }
        let previous = model.referenceExpression
        controller.close(); let saved = prefs.dictionaryRepresentation(); late?("refs/tags/only-tag")
        try require(model.isInvalidated && model.referenceExpression == previous && LogWindowController.activeReferencePickers == 0 && prefs.dictionaryRepresentation() as NSDictionary == saved as NSDictionary, "Retired picker changed range/history")
        // A started browser Git read remains owned through forced retirement.
        let wrapper = root.appendingPathComponent("slow-git"), marker = root.appendingPathComponent("browser-started")
        let script = "#!/bin/sh\nif [ \"$4\" = for-each-ref ]; then\n : > \"$3/browser-started\"\n /bin/sleep 30\nfi\nexec \"$TG_REF_REAL_GIT\" \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        setenv("TG_REF_REAL_GIT", git.path, 1); defer { unsetenv("TG_REF_REAL_GIT") }
        let slow = ReferenceBrowserWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, initial: "HEAD", preferences: prefs)
        slow.load(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
        slow.invalidate()
        try require(ReferenceBrowserWindowModel.activeReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired browser read lost Quit guard")
        try await wait { ReferenceBrowserWindowModel.activeReads == 0 }
        try require(slow.snapshot == nil && slow.error == nil, "Cancelled retired browser published data/error")
        print("Log reference navigation: source all/basic/local scopes, enabled native off/on/basic-mixed/local-mixed checkbox transitions, multi-tip/range/FETCH_HEAD freshness, exact recent persistence, owned two-ref picker acceptance/retirement, cancelled browser process/Quit accounting passed. Owned windows closed.")
    }
}
