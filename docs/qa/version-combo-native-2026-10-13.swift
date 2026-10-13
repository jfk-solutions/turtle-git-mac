import AppKit
import TurtleGitCore

@main struct VersionComboVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Version combo did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async {
        do { try await run(); print("PASS Version combo: six native dialog consumers, editable popup/session choices, exact case/Unicode, normalized programmatic selection/cap/no persistence, typed and popup binding, caret/disabled/retired callbacks, Log result not added to session and unchanged Git state") }
        catch { fputs("FAIL Version combo: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.VersionCombo.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Version Combo QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repository.run(["config",key,value]) }
        _ = try await repository.run(["commit","--allow-empty","-m","base"])
        let entry = try await repository.history().first!, refs = try await repository.run(["show-ref"]).stdout
        let head = try await repository.run(["rev-parse","HEAD"]).stdout
        var choices: [String] = []
        let normalized = RevisionSessionChoices.select("  refs/notes/雪\r\n ", choices: &choices)
        try require(normalized == "refs/notes/雪" && choices == ["refs/notes/雪"], "Source programmatic folding/trim")
        _ = RevisionSessionChoices.select("topic", choices: &choices); _ = RevisionSessionChoices.select("TOPIC", choices: &choices)
        _ = RevisionSessionChoices.select("e\u{301}", choices: &choices); _ = RevisionSessionChoices.select("é", choices: &choices)
        try require(choices.count == 5, "Exact byte identity in case/Unicode choices")
        for number in 0..<30 { _ = RevisionSessionChoices.select("ref\(number)", choices: &choices) }
        try require(choices.count == 26 && choices.last == "ref29", "Source bounded append behavior")
        let coordinator = VersionRevisionField.Coordinator(), combo = NSComboBox()
        combo.isEditable = true; combo.completes = false; combo.delegate = coordinator
        var bound = "HEAD~1", changes = 0
        coordinator.configure(combo, text: bound, choices: ["refs/notes/雪","topic","TOPIC"], enabled: true) { bound = $0; changes += 1 }
        try require(combo.numberOfItems == 3 && combo.stringValue == "HEAD~1" && changes == 0, "Editable value retained while loading choices")
        combo.selectItem(at: 2); coordinator.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
        try require(bound == "TOPIC", "Native popup writes selected spelling")
        combo.stringValue = " HEAD~2 "; coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
        try require(bound == " HEAD~2 ", "Ordinary typing is not normalized or autocompleted")
        coordinator.configure(combo, text: bound, choices: ["refs/notes/雪","topic","TOPIC"], enabled: false) { bound = $0 }
        combo.stringValue = "disabled"; coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); try require(bound == " HEAD~2 ", "Disabled callback gate")
        let fieldWindow = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 400,height: 100),styleMask: [.titled],backing: .buffered,defer: false)
        fieldWindow.isReleasedWhenClosed = false; combo.frame = NSRect(x: 10,y: 20,width: 360,height: 26); fieldWindow.contentView?.addSubview(combo)
        coordinator.configure(combo,text: bound,choices: ["topic"],enabled: true) { bound = $0 }
        fieldWindow.makeFirstResponder(combo)
        guard let editor = combo.currentEditor() as? NSTextView else { throw Failure(message: "Combo field editor missing") }
        editor.setSelectedRange(NSRange(location: 2,length: 0))
        coordinator.configure(combo,text: bound,choices: ["topic","TOPIC"],enabled: true) { bound = $0 }
        try require(editor.selectedRange() == NSRange(location: 2,length: 0) && combo.stringValue == bound, "Choice refresh retains typed text and caret")
        fieldWindow.close()
        coordinator.retire(combo); combo.isEnabled = true; combo.stringValue = "retired"; coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); try require(bound == " HEAD~2 " && combo.delegate == nil, "Retired callback gate")

        let switching = SwitchWindowController(repository: repository, access: nil, revision: "HEAD~1", preferences: prefs)
        switching.model.load(); try await wait { !switching.model.busy && !switching.model.references.isEmpty }
        try require(switching.model.commitChoices == ["HEAD~1"], "Initial custom revision in Switch session")
        switching.model.selectCustomRevision("refs/notes/雪"); switching.model.options.target = .commit
        try require(switching.model.beginPicker(.commit), "Commit picker gate"); switching.model.acceptCommitSelection(entry)
        try require(switching.model.commitRevision == entry.hash && !switching.model.commitChoices.contains(entry.hash), "Source Log SetWindowText does not insert history")
        let merge = MergeWindowController(repository: repository, access: nil, preferences: prefs)
        merge.model.selectCustomRevision("HEAD~1"); merge.model.target = .commit
        let branch = BranchTagWindowController(repository: repository, access: nil, isTag: false, preferences: prefs)
        branch.model.useHead = false; branch.model.chooser.selectCustomRevision("HEAD~1"); branch.model.chooser.options.target = .commit
        let worktree = WorktreeCreateWindowController(repository: repository, access: nil, preferences: prefs)
        worktree.model.useHead = false; worktree.model.chooser.selectCustomRevision("HEAD~1"); worktree.model.chooser.options.target = .commit
        let reset = ResetWindowController(repository: repository, access: nil, revision: "HEAD~1", preferences: prefs)
        reset.model.chooser.selectCustomRevision("HEAD~1"); reset.model.chooser.options.target = .commit
        let export = ExportWindowController(repository: repository, access: nil, revision: "HEAD~1", preferences: prefs)
        try await wait { !export.model.busy }
        let windows: [(NSWindowController,String)] = [(switching,"Switch commit revision"),(merge,"Merge commit revision"),(branch,"Base commit revision"),(worktree,"Base commit revision"),(reset,"Reset commit revision"),(export,"Export commit revision")]
        defer { windows.forEach { $0.0.close() } }
        for (owner,label) in windows {
            owner.window!.alphaValue = 0; owner.showWindow(nil); owner.window!.contentView!.layoutSubtreeIfNeeded()
            try await wait { descendants(owner.window!.contentView!).contains { ($0 as? NSComboBox)?.accessibilityLabel() == label } }
            let field = descendants(owner.window!.contentView!).compactMap { $0 as? NSComboBox }.first { $0.accessibilityLabel() == label }!
            try require(field.isEditable && !field.completes && field.numberOfItems > 0, "Actual shared combo in " + label)
        }
        let fresh = SwitchWindowModel(repository: repository, access: nil, preferences: prefs)
        try require(fresh.commitChoices.isEmpty && (prefs.persistentDomain(forName: suite) ?? [:]).isEmpty, "Session choices are not persisted")
        let finalRefs = try await repository.run(["show-ref"]).stdout, finalHead = try await repository.run(["rev-parse","HEAD"]).stdout
        try require(finalRefs == refs && finalHead == head, "No ref/HEAD mutations")
    }
}
