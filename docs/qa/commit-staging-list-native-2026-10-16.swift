import AppKit
import Darwin
import TurtleGitCore

@main struct CommitStagingListVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Staging list timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Staging list failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Staging List QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("tgit.commitstagingsupport", "true")] { _ = try await repo.run(["config", key, value]) }
        let base = Data((1...24).map { "context \($0)\n" }.joined().utf8)
        let working = Data(String(decoding: base, as: UTF8.self).replacingOccurrences(of: "context 2\n", with: "change 2\n").replacingOccurrences(of: "context 22\n", with: "change 22\n").utf8)
        for path in ["file", "outside", "remove", "rename"] { try base.write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["file", "outside", "remove", "rename"]); _ = try await repo.commit(message: "base")
        try working.write(to: root.appendingPathComponent("file")); try working.write(to: root.appendingPathComponent("outside")); try await repo.stage(["outside"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("remove"))
        _ = try await repo.run(["mv", "rename", "renamed"])
        try Data("new content\n".utf8).write(to: root.appendingPathComponent("new"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let outside = try await repo.run(["show", ":outside"]).stdout
        let suite = "TurtleGit.StagingList.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "HintStagingMode"); prefs.set(true, forKey: "Commit.SkipCancelConfirmation")
        defer { prefs.removePersistentDomain(forName: suite) }
        var owners: [CommitWindowController] = []; defer { owners.forEach { $0.close() } }
        func make() -> CommitWindowController {
            let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs); owners.append(owner)
            owner.window?.alphaValue = 0; owner.window?.orderFront(nil); owner.model.reload(paths: ["file", "new", "remove", "renamed"]); return owner
        }
        func ready(_ model: CommitWindowModel) async throws { try await wait { !model.busy && !model.savingPreferences && CommitWindowModel.activeFileOperations == 0 } }
        let owner = make(), model = owner.model; try await ready(model)
        try require(model.error == nil && model.stagingEnabled, "Initial staging list failed")
        model.message = "retained draft"; model.checked = ["new"]; model.selection = ["new"]
        let rows = model.visibleEntries, stats = model.statistics, scope = model.scopePaths
        let groups = StatusListGroups.rows(entries: rows, changelists: model.changelists)
        let fileMetadata = model.fileMetadata
        var reads = 0
        model.queryCommitStatus = { amend, token in reads += 1; return try await repo.commitDialogStatus(amendToParent: amend, cancellation: token) }
        model.queryStagingStates = { entries, base, token in reads += 1; return try await repo.commitStagingStates(for: entries, base: base, cancellation: token) }
        func unchanged() throws {
            try require(model.visibleEntries == rows && model.statistics == stats && model.fileMetadata == fileMetadata && model.scopePaths == scope && model.message == "retained draft" && model.checked == ["new"], "Incremental staging rebuilt source rows/statistics/metadata or lost draft/checks/scope")
            try require(StatusListGroups.rows(entries: model.visibleEntries, changelists: model.changelists) == groups, "Incremental staging regrouped rows")
        }
        func entry(_ path: String) throws -> StatusEntry { guard let entry = model.entries.first(where: { $0.path == path }) else { throw Failure(description: "Missing row " + path) }; return entry }
        func button(_ path: String) throws -> NSButton {
            guard let button = views(owner.window?.contentView).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "Stage " + path }) else { throw Failure(description: "Missing native checkbox " + path) }; return button
        }
        try await wait { views(owner.window?.contentView).compactMap { $0 as? NSButton }.contains { $0.accessibilityLabel() == "Stage new" } }
        try button("new").performClick(nil); try await ready(model); try unchanged()
        try require(model.stagingState(try entry("new")) == .on && model.isStaged(try entry("new")) && model.canCommit && reads == 1, "Native checkbox did not update independent staging state")
        try await wait { (try? button("new").state) == .on }
        try button("new").performClick(nil); try await ready(model); try unchanged()
        try require(model.stagingState(try entry("new")) == .off && reads == 2, "Native unstage retained checked state")
        model.check { $0.state == .untracked }; try await ready(model); try unchanged()
        try require(model.stagingState(try entry("new")) == .on, "Source Unversioned category stopped selecting retained unversioned row")
        model.setGroupChecked([try entry("remove"), try entry("new")], checked: false); try await ready(model); try unchanged()
        model.setFileChecked(try entry("remove"), files: rows, highlighted: ["remove", "file"], checked: true); try await ready(model); try unchanged()
        try require(model.stagingState(try entry("remove")) == .on && model.stagingState(try entry("file")) == .on, "Marked multi-row checkbox did not stage highlighted files: error=\(model.error ?? "nil"), states=\(model.entries.map { "\($0.path):\($0.index)\($0.worktree):\(model.stagingState($0).rawValue):\($0.originalPath ?? "-")" })")
        model.uncheckAll(); try await ready(model); try unchanged()
        try require(model.stagedEntries.isEmpty && !model.canCommit && model.visibleEntries.contains { $0.path == "outside" }, "None left stale staged state or hid original outside-scope row")
        try await repo.stage(["outside"])
        model.refreshStagingState(); try await ready(model)
        let partialOwner = owner
        model.selection = ["file"]; model.showPartial(false)
        try await wait { partialOwner.partial?.model.busy == false && !model.savingPreferences }
        let patch = partialOwner.partial!.model
        guard let hunk = patch.document.files.first?.hunks.first else { throw Failure(description: "Missing first partial hunk") }
        patch.selectedLines = [hunk.header]; try require(patch.canApplyHunks, "Partial stage unavailable")
        patch.apply(entireHunks: true); try await wait { !patch.busy && !model.busy && PatchWindowModel.activeOperations == 0 && CommitWindowModel.activeFileOperations == 0 }
        try unchanged(); try require(model.stagingState(try entry("file")) == .mixed, "Partial stage did not show mixed state")
        model.showPartial(true); try await wait { !patch.busy && patch.staged && !model.savingPreferences && !patch.document.files.isEmpty }
        patch.selectedLines = [patch.document.files[0].hunks[0].header]; patch.apply(entireHunks: true)
        try await wait { !patch.busy && !model.busy && PatchWindowModel.activeOperations == 0 && CommitWindowModel.activeFileOperations == 0 }
        try unchanged(); try require(model.stagingState(try entry("file")) == .off, "Partial unstage retained mixed state")
        model.moveToStage(["new"], staged: true); try await ready(model)
        let beforeRefresh = reads
        let main=NSMenu(title:"Staging list commands")
        owner.commandMenu?.applicationMenu={main};owner.commandMenu?.keyWindow={owner.window};owner.commandMenu?.install()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 96)!
        try require(owner.window!.performKeyEquivalent(with: event), "Actual F5 route declined refresh"); try await ready(model)
        try require(reads == beforeRefresh + 1 && model.entries.first { $0.path == "new" }?.state == .added && model.entries != rows && model.stagingState(try entry("new")) == .on, "F5 failed to rebuild status/groups from index")
        // A failed/cancelled refresh must not allow a commit from a stale snapshot.
        model.queryStagingStates = { _, _, _ in throw Failure(description: "injected staging read failure") }
        model.refreshStagingState(); try await ready(model)
        try require(model.stagingStateNeedsRefresh && !model.canCommit && model.error?.contains("Press F5") == true, "Failed staging refresh exposed stale Commit")
        model.queryStagingStates = { entries, base, token in try await repo.commitStagingStates(for: entries, base: base, cancellation: token) }
        model.error = nil; model.reload(); try await ready(model)
        try require(!model.stagingStateNeedsRefresh && model.canCommit, "Full refresh failed to recover Commit")
        owner.close(); try await wait { PatchWindowModel.activeOperations == 0 && CommitWindowModel.activePreferenceOperations == 0 }
        let held = make(); try await ready(held.model)
        let retained = held.model.entries
        var started = false, release = false, cancelled = false
        held.model.queryStagingStates = { entries, base, token in
            started = true
            while !release { if token.isCancelled { cancelled = true }; try? await Task.sleep(nanoseconds: 10_000_000) }
            return try await repo.commitStagingStates(for: entries, base: base)
        }
        held.model.refreshStagingState(); try await wait { started }
        try require(held.model.inputsBlocked && !held.model.canCommit && CommitWindowModel.activeFileOperations == 1, "Owned staging read lost input/Quit gate")
        held.close(); try await wait { cancelled }
        try require(CommitWindowModel.activeFileOperations == 1, "Forced close released worker lifetime before drain")
        release = true; try await wait { CommitWindowModel.activeFileOperations == 0 }
        try require(held.model.entries == retained && held.model.error == nil, "Retired read published late rows/error")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalOutside = try await repo.run(["show", ":outside"]).stdout
        try require(finalHead == head && finalOutside == outside && Data(contentsOf: root.appendingPathComponent("file")) == working, "Staging modified HEAD, unrelated staged bytes or working file")
        print("PASS: Commit incremental staging rows/groups, native checks, bulk/multi checks, partial stage/unstage, F5, failed-read gate and retired ownership")
    }
}
