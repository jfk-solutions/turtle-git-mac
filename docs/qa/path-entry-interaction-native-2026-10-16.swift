import AppKit
import TurtleGitCore

@main struct PathEntryInteractionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [NSWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1800 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Path interaction timeout at \(line)")
    }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func invoke(_ item: NSMenuItem) { if let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) } }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.close() }; owners = [] }
        catch { owners.forEach { $0.close() }; owners = []; fputs("Path interaction failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Input QA"), ("user.email", "input@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for name in ["source.txt", "file one.patch", "file two.patch"] { try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name)) }
        try await repo.stage(["source.txt"]); _ = try await repo.commit(message: "baseline")
        let suite = "TurtleGit.PathInteraction." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let rename = RenameWindowController(repository: repo, access: nil, source: "source.txt", preferences: prefs)
        let clone = CloneWindowController(directory: root, access: nil, preferences: prefs, executable: repo.executable)
        let worktree = WorktreeCreateWindowController(repository: repo, access: nil, preferences: prefs)
        let export = ExportWindowController(repository: repo, access: nil, revision: "HEAD", preferences: prefs)
        owners = [rename, clone, worktree, export]
        worktree.model.load(); export.model.load(revision: "HEAD")
        try await wait { !worktree.model.busy && !worktree.model.chooser.busy && !export.model.busy }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let configurations: [(NSWindowController, String, String, () -> String, (String) -> Void)] = [
            (rename, "New name", "file", { rename.model.name }, { rename.model.name = $0 }),
            (clone, "Destination directory", root.path + "/file", { clone.model.directory }, { clone.model.directory = $0 }),
            (worktree, "Worktree directory", root.path + "/file", { worktree.model.directory }, { worktree.model.directory = $0 }),
            (export, "ZIP file", root.path + "/file", { export.model.destination }, { export.model.destination = $0 })]
        for (owner, label, prefix, value, set) in configurations {
            set(prefix); owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
            var field: PathEntryField.Field?
            try await wait { field = descendants(owner.window?.contentView).compactMap { $0 as? PathEntryField.Field }.first { $0.accessibilityLabel() == label }; return field?.isEnabled == true && field?.stringValue == prefix }
            let control = field!, coordinator = control.coordinator!
            owner.window?.makeFirstResponder(control)
            guard let editor = control.currentEditor() as? PathEntryField.Editor else { throw Failure(description: "Native editor absent") }
            coordinator.present = { _ in }
            try require(!editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticSpellingCorrectionEnabled && !editor.isAutomaticTextCompletionEnabled && !editor.smartInsertDeleteEnabled, "Path editor inherited prose transformations")
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            for piece in ["literal", "-", "-", "'", "\"", " ", "雪"] { editor.insertText(piece, replacementRange: editor.selectedRange()) }
            let literal = "literal--'\" 雪"
            try await wait { value() == literal && PathEntryField.Coordinator.activeReads == 0 }
            set(prefix); try await wait { editor.string == prefix && value() == prefix }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)); editor.undoManager?.removeAllActions(); editor.breakUndoCoalescing()
            var reads = 0, presentations = 0
            let originalRead = coordinator.read
            coordinator.read = { query, token in reads += 1; return try await originalRead(query, token) }
            coordinator.present = { _ in presentations += 1 }
            coordinator.cancel(); prefs.set(false, forKey: "ShowAppContextMenuIcons")
            try require(editor.completionItem().image == nil, "Path menu ignored owning icon preference")
            prefs.set(true, forKey: "ShowAppContextMenuIcons")
            let item = editor.completionItem()
            try require(item.image != nil && item.title == "Complete Path" && item.isEnabled, "Complete Path action/artwork unavailable")
            invoke(item); invoke(item)
            try await wait { !coordinator.choices.isEmpty && PathEntryField.Coordinator.activeReads == 0 }
            try require(reads == 1 && presentations == 1, "Retained completion action dispatched twice")
            let stale = editor.completionItem(), before = reads
            editor.setSelectedRange(NSRange(location: 0, length: 0)); invoke(stale)
            try require(reads == before && value() == prefix, "Changed caret accepted old context action")
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            let chosen = coordinator.choices[0]
            editor.insertCompletion(chosen, forPartialWordRange: editor.rangeForUserCompletion, movement: NSDownTextMovement, isFinal: false)
            try require(editor.string == chosen, "Native completion preview absent")
            editor.insertCompletion(prefix, forPartialWordRange: editor.rangeForUserCompletion, movement: NSCancelTextMovement, isFinal: true)
            try await wait { value() == prefix && editor.string == prefix }
            editor.insertCompletion(chosen, forPartialWordRange: editor.rangeForUserCompletion, movement: NSReturnTextMovement, isFinal: true)
            try await wait { value() == chosen }
            editor.breakUndoCoalescing(); try require(editor.undoManager?.canUndo == true, "Completion has no native Undo")
            editor.undoManager?.undo();
            try require(value() == prefix, "Undo mismatch in \(label): editor=\(editor.string.debugDescription), model=\(value().debugDescription), expected=\(prefix.debugDescription)")
            editor.undoManager?.redo(); try await wait { value() == chosen }
            try await wait { PathEntryField.Coordinator.activeReads == 0 }
            set(prefix); try await wait { editor.string == prefix }; editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            var reply: CheckedContinuation<[String], Error>?
            coordinator.read = { _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
            presentations = 0; coordinator.request(); try await wait { reply != nil }
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            reply?.resume(returning: [chosen]); reply = nil; try await wait { PathEntryField.Coordinator.activeReads == 0 }
            try require(coordinator.choices.isEmpty && presentations == 0 && value() == prefix, "Delayed result survived caret movement")
            let blocked = editor.completionItem(); control.isEnabled = false; invoke(blocked)
            try require(value() == prefix && PathEntryField.Coordinator.activeReads == 0, "Disabled action changed path")
            let retired = editor.completionItem(); owner.close(); invoke(retired)
            try require(coordinator.retired && value() == prefix && PathEntryField.Coordinator.activeReads == 0, "Retired menu changed a closed path owner")
        }
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Path interaction mutated Git")
        print("PASS: four native path editors preserve literal input, completion preview/cancel and Undo/Redo, owner icons/one-use menu actions, caret/disabled/retired guards; unchanged HEAD/index")
    }
}
