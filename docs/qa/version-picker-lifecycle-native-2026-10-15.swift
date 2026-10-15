import AppKit
import TurtleGitCore

@main struct VersionPickerLifecycleVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !ready() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(ready(), "Version picker timeout at line \(line)")
    }
    @MainActor final class Probe: VersionPickerModel {
        let repository: GitRepository
        var target = CheckoutTarget.commit
        var revision: String { commitRevision }
        var commitRevision: String
        var error: String?
        var active = true, picking = false
        var commits: [String] = [], references: [String?] = []
        var onBrowsePicker: ((CheckoutTarget) -> Void)?
        var versionPickerDraft: [GitReferenceName] { [target.rawValue, commitRevision].map { GitReferenceName($0) } }
        init(_ repository: GitRepository, _ revision: String) { self.repository = repository; commitRevision = revision }
        func beginPicker(_ target: CheckoutTarget) -> Bool { guard active, !picking, self.target == target else { return false }; picking = true; return true }
        func finishPicker() { picking = false }
        func acceptReferenceSelection(_ name: String?, completion: @escaping () -> Void) { references.append(name); picking = false; completion() }
        func acceptCommitSelection(_ entry: LogEntry?) { if let entry { commits.append(entry.hash); commitRevision = entry.hash }; picking = false }
        func invalidate() { active = false; picking = false }
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Version picker lifecycle failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Version QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "next"])
        let next = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["tag", "release", base])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let suite = "TurtleGit.VersionPickerLifecycle." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.appearance = NSAppearance(named: .darkAqua); host.alphaValue = 0.83
        let probe = Probe(repo, next), coordinator = VersionPickerCoordinator(window: host, model: probe, access: nil, preferences: preferences)
        defer { coordinator.invalidate(); host.close() }
        var callbacks: [(LogEntry?) -> Void] = [], configured = 0, selections = 0
        var makerRevisions: [String?] = []
        coordinator.makeCommitPicker = { repo, access, choose, preferences, initial in
            callbacks.append(choose)
            makerRevisions.append(initial)
            return LogWindowController(repository: repo, access: access, onChoose: choose, labelDefaults: preferences, savesColumnLayout: false, initialRevision: initial)
        }
        coordinator.configureCommitPicker = { _ in configured += 1 }
        coordinator.onSelection = { selections += 1 }
        host.orderFront(nil); probe.onBrowsePicker?(.commit)
        try await wait { coordinator.commitPicker?.model.busy == false && coordinator.commitPicker?.model.entries.count == 2 }
        let first = coordinator.commitPicker!, entry = first.model.entries.first { $0.hash == base }!
        try require(first.window?.appearance == host.appearance && first.window?.alphaValue == host.alphaValue && configured == 1 && makerRevisions == [next], "Owned picker lost appearance/commands")
        callbacks[0](entry); callbacks[0](first.model.entries.first { $0.hash == next })
        try require(probe.picking && probe.commitRevision == next && selections == 0, "Selection applied before owned sheet closed")
        first.model.close(); try await wait { !probe.picking && host.attachedSheet == nil }
        try require(probe.commits == [base] && selections == 1, "Duplicate reply replaced first result")
        probe.commitRevision = next; probe.onBrowsePicker?(.commit)
        try await wait { coordinator.commitPicker?.model.busy == false && coordinator.commitPicker?.model.entries.count == 2 }
        let second = coordinator.commitPicker!
        callbacks[0](entry); probe.commitRevision = "changed draft"; callbacks[1](entry); second.model.close()
        try await wait { !probe.picking && host.attachedSheet == nil }
        try require(probe.commitRevision == "changed draft" && selections == 1, "Changed/newer picker consumed obsolete result")
        probe.commitRevision = next; coordinator.presentPicker = { _, _ in false }; probe.onBrowsePicker?(.commit)
        try require(coordinator.commitPicker == nil && !probe.picking && selections == 1, "Refused picker retained owner")
        // A canonically equivalent Git spelling is still a changed byte-exact draft.
        coordinator.presentPicker = { _, _ in true }; probe.commitRevision = "café"; probe.onBrowsePicker?(.commit)
        let unicode = coordinator.commitPicker!; probe.commitRevision = "cafe\u{301}"; callbacks.last?(entry); unicode.model.close()
        try require(probe.commits == [base] && !probe.picking, "Unicode-normalized equality accepted changed Git input")
        probe.target = .branch; probe.commitRevision = next; probe.onBrowsePicker?(.branch)
        try await wait { coordinator.referencePicker?.model.busy == false && coordinator.referencePicker?.model.snapshot != nil }
        let reference = coordinator.referencePicker!
        let tagSelection = reference.model.snapshot!.initialSelection("refs/tags/release")
        reference.model.setFolder(tagSelection.folder); reference.model.select(["refs/tags/release"], last: "refs/tags/release"); reference.model.accept()
        try await wait { !probe.picking }
        try require(probe.references.count == 1 && probe.references[0] == "refs/tags/release", "Reference result lost canonical name")

        let branch = BranchTagWindowController(repository: repo, access: nil, isTag: false, preferences: preferences)
        defer { branch.close() }
        branch.model.load(revision: next); try await wait { !branch.model.busy && !branch.model.chooser.busy }
        branch.model.useHead = false; branch.model.chooser.options.target = .commit; branch.model.chooser.commitRevision = next
        branch.presentPicker = { _, _ in true }; var branchCommands = 0; branch.configureCommitPicker = { _ in branchCommands += 1 }
        branch.model.chooser.browse(.commit); try await wait { branch.commitPicker?.model.busy == false && branch.commitPicker?.model.entries.count == 2 }
        let branchLog = branch.commitPicker!; branch.model.useHead = true; branchLog.model.select([base]); branchLog.model.accept()
        try require(branch.model.chooser.commitRevision == next && branchCommands == 1 && branch.model.chooser.pickerTarget == nil, "Branch HEAD change did not invalidate old base choice")
        branch.model.useHead = false; branch.model.chooser.browse(.commit); try await wait { branch.commitPicker?.model.busy == false && branch.commitPicker?.model.entries.count == 2 }
        branch.commitPicker?.model.select([base]); branch.commitPicker?.model.accept()
        try require(branch.model.chooser.commitRevision == base && branch.model.chooser.commitChoices.contains(base), "Branch accepted base missing from session choices")

        let worktree = WorktreeCreateWindowController(repository: repo, access: nil, preferences: preferences)
        defer { worktree.close() }
        try await wait { !worktree.model.busy && !worktree.model.chooser.busy }
        worktree.model.useHead = false; worktree.model.chooser.options.target = .commit; worktree.model.chooser.commitRevision = next
        worktree.presentPicker = { _, _ in true }; worktree.model.chooser.browse(.commit)
        try await wait { worktree.commitPicker?.model.busy == false && worktree.commitPicker?.model.entries.count == 2 }
        let worktreeLog = worktree.commitPicker!; worktree.model.directory += "-changed"; worktreeLog.model.select([base]); worktreeLog.model.accept()
        try require(worktree.model.chooser.commitRevision == next && worktree.model.chooser.pickerTarget == nil, "Changed worktree destination consumed old base result")
        worktree.model.chooser.browse(.commit); try await wait { worktree.commitPicker?.model.busy == false && worktree.commitPicker?.model.entries.count == 2 }
        let retired = worktree.commitPicker!; worktree.close(); retired.model.select([base]); retired.model.accept()
        try require(worktree.model.chooser.commitRevision == next && worktree.commitPicker == nil, "Retired Worktree consumed late picker")
        let export = ExportWindowController(repository: repo, access: nil, revision: next, preferences: preferences)
        defer { export.close() }
        try await wait { !export.model.busy }
        export.showWindow(nil); export.model.target = .commit; export.model.commit = next
        export.model.onBrowsePicker?(.commit)
        try await wait { export.commitPicker?.model.busy == false && export.commitPicker?.model.entries.count == 2 }
        export.model.destination += "-changed"; export.commitPicker?.model.select([base]); export.commitPicker?.model.accept()
        try await wait { export.model.pickerTarget == nil && export.window?.attachedSheet == nil }
        try require(export.model.commit == next, "Changed Export destination consumed old revision")
        export.model.onBrowsePicker?(.commit)
        try await wait { export.commitPicker?.model.busy == false && export.commitPicker?.model.entries.count == 2 }
        export.commitPicker?.model.select([base]); export.commitPicker?.model.accept()
        try await wait { export.model.pickerTarget == nil && export.window?.attachedSheet == nil }
        try require(export.model.commit == base && export.model.commitChoices.contains(base), "Export accepted revision missing from session choices")
        export.close()
        try await wait { ExportWindowModel.activeReads == 0 && SwitchWindowModel.activeReads == 0 && MergeWindowModel.activeReads == 0 && BranchTagWindowModel.activeReads == 0 && WorktreeCreateWindowModel.activeOperations == 0 && LogWindowModel.activeHistoryLoads == 0 && ReferenceBrowserWindowModel.activeReads == 0 }
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: root.appendingPathComponent(".git/config")) == config, "Picker workflows wrote index/config")
        try require(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines) == next, "Picker workflows changed HEAD")
        print("Shared version pickers passed: real sheet delayed/duplicate results, changed/Unicode drafts, refused/stale replies, canonical references, inherited appearance/configuration, Branch HEAD/session choices, Worktree destination and retirement. Private repos/preferences; owned windows closed.")
    }
}
