import AppKit
import TurtleGitCore

@main struct MessageSuggestionsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ text: String) throws { if !value { throw Failure(description: text) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !ready() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(ready(), "Message suggestions timeout")
    }
    @MainActor static func find(_ view: NSView) -> ProjectMessageTextView? {
        if let editor = view as? ProjectMessageTextView { return editor }
        for child in view.subviews { if let editor = find(child) { return editor } }; return nil
    }
    @MainActor static func key(_ code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Message suggestions failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func exercise(_ editor: ProjectMessageTextView, _ window: NSWindow, _ defaults: UserDefaults) throws {
        window.orderFront(nil); window.makeFirstResponder(editor)
        editor.isEditable = true; editor.allowsUndo = true; editor.spellingPreferences = defaults
        var settings = ProjectDialogSettings(); settings.language = .init(value: "1033", inherit: false); editor.applyProjectSettings(settings)
        var queries = 0, requestedWord = "", language: String?
        editor.spellingSuggestions = { word, value in queries += 1; requestedWord = word; language = value; return ["misspelled", "mis-spelled", "misspelled", ""] }
        editor.string = "Fix _mispelt_ suffix"; let range = (editor.string as NSString).range(of: "mispelt")
        editor.setSelectedRange(NSRange(location: range.location + 3, length: 0))
        editor.keyDown(with: key(48, .control))
        try require(editor.spellingPopupShown && editor.spellingChoices == ["misspelled", "mis-spelled"] && requestedWord == "mispelt" && language == "en_US", "Ctrl-Tab did not open source-style whole-word suggestions")
        editor.keyDown(with: key(125)); editor.keyDown(with: key(36))
        try require(editor.string == "Fix _mis-spelled_ suffix" && !editor.spellingPopupShown, "Suggestion lost suffix/markers or expanded a snippet")
        editor.undoManager?.undo(); try require(editor.string == "Fix _mispelt_ suffix", "Spelling replacement is not an independent Undo")
        editor.setSelectedRange(NSRange(location: range.location + 2, length: 0)); editor.keyDown(with: key(48, [.control, .shift])); editor.keyDown(with: key(53))
        try require(!editor.spellingPopupShown && editor.string == "Fix _mispelt_ suffix", "Escape changed message")
        editor.setSelectedRange(NSRange(location: range.location + 2, length: 0)); editor.showSpellingSuggestions()
        editor.string = "Changed draft"; editor.keyDown(with: key(36))
        try require(editor.string == "Changed draft", "Stale suggestion overwrote edited message")
        let prior = queries
        defaults.set(false, forKey: "Spellchecker"); editor.keyDown(with: key(48, .control))
        try require(queries == prior && !editor.spellingPopupShown, "Disabled spelling queried dictionary")
        defaults.set(true, forKey: "Spellchecker"); settings.language = .init(value: "-1", inherit: false); editor.applyProjectSettings(settings)
        editor.keyDown(with: key(48, .control)); try require(queries == prior, "Disabled project language queried suggestions")
        settings.language = .init(value: "1033", inherit: false); editor.applyProjectSettings(settings)
        editor.isEditable = false; editor.keyDown(with: key(48, .control)); try require(queries == prior, "Read-only editor queried suggestions")
        editor.isEditable = true; editor.string = "mispelt"; editor.setSelectedRange(NSRange(location: 3, length: 0))
        editor.setMarkedText("mispelt", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 7))
        editor.keyDown(with: key(48, .control)); try require(queries == prior && !editor.spellingPopupShown, "Suggestions interrupted input composition")
        editor.unmarkText(); editor.dismissSpellingSuggestions(); editor.spellingSuggestions = nil; window.orderOut(nil)
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: folder, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["-c", "user.name=Suggestions QA", "-c", "user.email=qa@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "baseline"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let suite = "TurtleGit.MessageSuggestions." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "Autocompletion"); defaults.set(true, forKey: "Spellchecker")
        let commit = CommitWindowController(repository: repo, access: nil, defaults: defaults)
        defer { commit.close() }
        commit.window?.contentView?.layoutSubtreeIfNeeded(); try await wait { !commit.model.busy }
        guard let commitEditor = find(commit.window!.contentView!) else { throw Failure(description: "Commit native editor missing") }
        try exercise(commitEditor, commit.window!, defaults)
        let merge = MergeMessageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        let shared = ProjectMessageTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 180))
        for (index, editor) in [merge as ProjectMessageTextView, shared].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: index == 0 ? .darkAqua : .aqua)
            let scroll = NSScrollView(frame: window.contentLayoutRect); scroll.documentView = editor; window.contentView = scroll
            try exercise(editor, window, defaults); window.close()
        }
        try require(MenuIcon.completionSpelling.image() != nil, "Original spell artwork unavailable")
        try require(try await repo.run(["rev-parse", "HEAD"]).stdout == head, "Editor suggestions changed HEAD")
        print("Message spelling suggestions passed: actual Commit editor and shared Merge/Rebase text views, Ctrl/Shift-Tab, original icon, whole-word suffix/markers, selection/Return/Escape/Undo, changed drafts, language/disabled/read-only/composition gates. Injected dictionary guesses and private defaults; owned windows closed.")
    }
}
