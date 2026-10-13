import AppKit
import TurtleGitCore

@main struct InputDialogsVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out at line \(line)")
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS Input: shared font/caret, UTF-16 minimum, optional checkbox, captured drafts, save failure/retry, forced-close accounting, owned Log notes and unchanged HEAD/index") }
        catch { fputs("FAIL Input: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.Input.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set("Menlo", forKey: "LogFontName"); prefs.set(14, forKey: "LogFontSize")
        var captured = "", checked = false, closes = 0, fail = true
        let input = InputWindowController(text: "🐢", checkboxTitle: "Option", checked: true, minimumLength: 3, preferences: prefs) { text, state, _ in
            captured = text; checked = state
            if fail { throw Failure(message: "Owned fixture failure") }
        }
        defer { input.close() }
        input.onClosed = { closes += 1 }; input.focusEditor()
        try require(!input.canAccept && !input.ok.isEnabled && !input.checkbox.isHidden, "UTF-16 initial gate / checkbox")
        try require(input.editor.font?.pointSize == 14 && input.editor.selectedRange().location == 2, "Shared font / end caret")
        input.editor.string = "🐢x"; input.textDidChange(Notification(name: NSText.didChangeNotification))
        try require(input.canAccept && input.ok.isEnabled, "Updated UTF-16 gate")
        input.save(); input.editor.string = "changed after click"; input.checkbox.state = .off
        try await wait { !input.busy }
        try require(captured == "🐢x" && checked && !input.errorLabel.stringValue.isEmpty && closes == 0, "Captured input and retryable failure")
        fail = false; input.save(); try await wait { closes == 1 && InputWindowController.activeSaves == 0 }
        try require(input.saved, "Successful completion")

        var continuation: CheckedContinuation<Void, Never>?
        let retired = InputWindowController(text: "held", preferences: prefs) { _, _, _ in
            await withCheckedContinuation { continuation = $0 }
        }
        var retiredCloses = 0; retired.onClosed = { retiredCloses += 1 }; retired.save()
        try await wait { continuation != nil }
        retired.close()
        try require(InputWindowController.activeSaves == 1 && retiredCloses == 1, "Retired operation remains counted")
        continuation?.resume(); continuation = nil
        try await wait { InputWindowController.activeSaves == 0 }
        try require(!retired.saved && retiredCloses == 1, "Late result is fenced")

        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Input QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "first"])
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["commit", "--allow-empty", "-m", "second"])
        let head = try await repo.run(["rev-parse", "HEAD"]).text
        let index = root.appendingPathComponent(".git/index"), before = try? Data(contentsOf: index)
        _ = try await repo.run(["config", "tgit.logminsize", "3"])
        let log = LogWindowController(repository: repo, access: nil, labelDefaults: prefs)
        defer { log.close() }
        var callbackSettled = false
        log.model.onRevisionChanged = { _ in callbackSettled = !log.model.savingNote && !log.model.busy }
        log.model.reload(); try await wait { !log.model.busy && log.model.entries.filter { !$0.hash.isEmpty }.count == 2 }
        log.model.selected = [first]; log.model.editNotes()
        try await wait { log.noteEditor != nil }
        guard let notes = log.noteEditor else { throw Failure(message: "Missing owned notes editor") }
        try require(notes.window?.sheetParent === log.window && notes.checkbox.isHidden && !notes.canAccept, "Owned source-shaped notes sheet")
        notes.editor.string = "note 🐢\nsecond line"; notes.textDidChange(Notification(name: NSText.didChangeNotification))
        log.model.selected = [log.model.entries.first!.hash]
        notes.save(); try await wait { log.noteEditor == nil && !log.model.savingNote && InputWindowController.activeSaves == 0 && callbackSettled }
        let saved = try await repo.editableCommitNote(revision: first)
        try require(saved.text == "note 🐢\nsecond line", "Captured revision / exact multiline bytes")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).text
        try require(afterHead == head && (try? Data(contentsOf: index)) == before, "HEAD/index unchanged")
        log.model.selected = [first]; log.model.editNotes(); try await wait { log.noteEditor != nil }
        log.noteEditor?.editor.string = "cancelled"; log.noteEditor?.cancel()
        try await wait { log.noteEditor == nil }
        let unchanged = try await repo.editableCommitNote(revision: first)
        try require(unchanged.text == saved.text && log.window?.attachedSheet == nil, "Cancel leaves note / parent sheet clean")
    }
}
