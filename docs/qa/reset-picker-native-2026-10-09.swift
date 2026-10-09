import AppKit
import SwiftUI
import TurtleGitCore

@main struct ResetPickerVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String? = nil, text: String? = nil) -> T? {
        if let result = view as? T, (label == nil || result.accessibilityLabel() == label), (text == nil || (result as? NSTextField)?.stringValue == text) { return result }
        for child in view.subviews { if let result = find(type, child, label: label, text: text) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000)
        }; throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    static func phase(_ message: String) { print("PHASE: " + message); fflush(stdout) }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ResetPicker.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Reset Picker QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        func commit(_ message: String) async throws -> String {
            _ = try await repo.run(["commit", "--allow-empty", "-m", message]); return try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        }
        let base = try await commit("base"), prior = try await commit("prior"), head = try await commit("latest")
        _ = try await repo.run(["checkout", "-b", "sibling", base]); let sibling = try await commit("sibling"); _ = try await repo.run(["checkout", "main"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config")), tree = try await repo.run(["write-tree"]).text
        let titles: [ResetMode: String] = [.soft: "Soft: Leave working tree and index untouched", .mixed: "Mixed: Leave working tree untouched, reset index", .hard: "Hard: Reset working tree and index (discard all local changes)"]
        phase("Reset focus controls")
        for mode in ResetMode.allCases {
            let controller = ResetWindowController(repository: repo, access: nil, revision: prior, preferences: prefs)
            controller.model.mode = mode; defer { controller.close() }
            controller.model.load()
            try await wait([controller.window!]) { !controller.model.busy && !controller.model.chooser.busy && !controller.model.initialModeFocusPending }
            guard let button = find(NSButton.self, controller.window!.contentView!, label: titles[mode]!) else { throw Failure(description: "Reset radio missing") }
            try require(controller.window!.firstResponder === button && button.state == .on && button.isEnabled, "Initial focus differs from chosen mode")
            guard let field = find(NSTextField.self, controller.window!.contentView!, text: prior) else { throw Failure(description: "Commit field missing") }
            field.selectText(nil); let responder = controller.window!.firstResponder
            controller.model.mode = mode == .hard ? .mixed : .hard
            for _ in 0..<20 { controller.window!.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
            try require(controller.window!.firstResponder === responder, "Ordinary mode change stole focus")
            controller.close(); try require(!controller.model.initialModeFocusAvailable, "Close left initial focus available")
        }
        phase("Owned Log setup")
        let owner = ResetWindowController(repository: repo, access: nil, revision: prior, preferences: prefs); defer { owner.close() }
        owner.model.load(); try await wait([owner.window!]) { !owner.model.busy && !owner.model.chooser.busy && !owner.model.initialModeFocusPending }
        var callbacks: [(LogEntry?) -> Void] = [], presentations = 0
        owner.makeCommitPicker = { repository, access, choose, preferences in
            callbacks.append(choose)
            return LogWindowController(repository: repository, access: access, onChoose: choose, labelDefaults: preferences, savesColumnLayout: false)
        }
        owner.presentCommitPicker = { [weak owner] parent, child in presentations += 1; parent.makeFirstResponder(nil); return parent === owner?.window && !parent.isVisible && !child.isVisible }
        phase("First full Log picker")
        owner.model.showCommitPicker()
        guard let first = owner.commitPicker else { throw Failure(description: "Log picker missing") }
        try await wait([first.window!]) { !first.model.busy && first.model.entries.count == 2 }
        try require(first.model.selecting && !first.model.selectingMultiple && !first.model.showWorkingTree && !first.model.canShowWorkingTree, "Wrong selection mode or working-tree row")
        try require(first.model.endRevision == prior && Set(first.model.entries.map(\.hash)) == [base, prior] && !first.model.entries.contains(where: { $0.hash == head || $0.hash == sibling }), "Picker ignores typed revision ancestry")
        try require(first.model.graph.count == 2 && first.model.revision?.hash == prior, "Initial revision/graph missing")
        guard let table = find(HistoryTableView.self, first.window!.contentView!) else { throw Failure(description: "Actual Log table missing") }
        try require(table.numberOfRows == 2 && !table.allowsMultipleSelection, "Native table is not single-select")
        try require(owner.model.showingCommitPicker && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Parent/Quit escaped picker lock")
        owner.model.showCommitPicker(); owner.model.showModifiedFiles(); owner.model.reset(); owner.model.apply(try await repo.prepareReset(to: base, mode: .mixed))
        try require(presentations == 1 && owner.modifiedComparison == nil && !owner.model.busy && owner.model.progress == nil, "Duplicate/compare/reset/apply escaped picker lock")
        guard let entry = first.model.entries.first(where: { $0.hash == base }) else { throw Failure(description: "Base not listed") }
        phase("Log selection and accept")
        first.model.select([base]); first.model.accept()
        try require(owner.commitPicker == nil && !owner.model.showingCommitPicker && owner.model.chooser.commitRevision == base && owner.model.chooser.options.target == .commit, "Accept lost result across child-close ordering")
        phase("Reopen/stale/cancel/reject/forced-close")
        owner.model.chooser.commitRevision = prior; owner.model.showCommitPicker()
        guard let second = owner.commitPicker else { throw Failure(description: "Second picker missing") }
        try await wait([second.window!]) { !second.model.busy && second.model.entries.count == 2 }
        callbacks[0](entry)
        try require(owner.model.chooser.commitRevision == prior && owner.model.showingCommitPicker && owner.commitPicker === second, "Stale callback changed newer picker")
        second.model.close()
        try require(owner.commitPicker == nil && !owner.model.showingCommitPicker && owner.model.chooser.commitRevision == prior, "Cancel changed revision or retained picker")
        owner.presentCommitPicker = { _, _ in false }; owner.model.showCommitPicker()
        try require(owner.commitPicker == nil && !owner.model.showingCommitPicker, "Failed presentation retained picker")
        owner.model.chooser.options.target = .branch; owner.model.showCommitPicker(); try require(owner.commitPicker == nil, "Inactive Commit browse opened")
        owner.model.chooser.options.target = .commit; owner.presentCommitPicker = { parent, _ in parent.makeFirstResponder(nil); return true }; owner.model.showCommitPicker()
        guard let final = owner.commitPicker else { throw Failure(description: "Final picker missing") }
        try await wait([final.window!]) { !final.model.busy }
        let lastCallback = callbacks.last!; owner.close(); lastCallback(entry)
        try require(owner.commitPicker == nil && !owner.model.showingCommitPicker && owner.model.chooser.commitRevision == prior, "Forced close or late result leaked picker")
        owner.model.showCommitPicker(); try require(owner.commitPicker == nil, "Closed parent reopened picker")
        // Ordinary and explicitly multiple selection Log tables retain multiple selection.
        phase("Ordinary/multiple table regression")
        for multiple in [false, true] {
            let log = LogWindowModel(repository: repo, access: nil, selecting: multiple, selectingMultiple: multiple, labelDefaults: prefs)
            let host = NSHostingView(rootView: RevisionTable(model: log, savesColumnLayout: false).defaultAppStorage(prefs)); host.frame = .init(x: 0, y: 0, width: 1000, height: 300); host.layoutSubtreeIfNeeded()
            guard let table = find(HistoryTableView.self, host) else { throw Failure(description: "Regression table missing") }
            try require(table.allowsMultipleSelection, "Ordinary/multiple Log restricted")
        }
        phase("Bare Reset focus")
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["init", "--bare", bareRoot.path])
        let bare = ResetWindowController(repository: GitRepository(root: bareRoot, executable: git), access: nil, preferences: prefs); defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && !bare.model.chooser.busy && !bare.model.initialModeFocusPending }
        guard let soft = find(NSButton.self, bare.window!.contentView!, label: titles[.soft]!), let mixed = find(NSButton.self, bare.window!.contentView!, label: titles[.mixed]!) else { throw Failure(description: "Bare mode controls missing") }
        try require(bare.model.bare && bare.model.mode == .soft && bare.window!.firstResponder === soft && soft.isEnabled && !mixed.isEnabled, "Bare initial focus/type differs")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines), afterTree = try await repo.run(["write-tree"]).text
        try require(head == afterHead && tree == afterTree && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Picker changed HEAD/index/config")
        print("PASS: real Reset Soft/Mixed/Hard and bare Soft initial native focus, once-only retention/close invalidation; full owned Log picker anchored at typed revision with native graph/table and single selection; accept/cancel/stale/reject/duplicate/cross-route/reset/apply/close/Quit/forced-close gates; ordinary/multiple Log tables preserved; unchanged HEAD/staged tree/config. Private defaults/fixtures; no ordered windows or actual sheets.")
    }
}
