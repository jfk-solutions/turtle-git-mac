import AppKit
import TurtleGitCore

@main struct InputHostsVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Timed out at \(line)")
    }
    @MainActor static func main() async {
        do { try await run(); print("PASS Input hosts: Synchronization shared form/real saves/Cancel, Rebase owned sheet/captured revision/menu gates, source project language/minimum, read-error/retirement cancellation/Quit accounting, legacy synchronous save gates and unchanged HEAD/index") }
        catch { fputs("FAIL Input hosts: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.InputHosts.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set("Menlo", forKey: "LogFontName"); preferences.set(16, forKey: "LogFontSize")
        _ = try await repository.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Input Hosts QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.projectlanguage","-1"),("tgit.logminsize","3"),("tgit.logwidthmarker","72")] { _ = try await repository.run(["config",key,value]) }
        for message in ["first","second","third"] { _ = try await repository.run(["commit","--allow-empty","-m",message]) }
        let revisions = try await repository.history(), head = try await repository.run(["rev-parse","HEAD"]).stdout
        let index = root.appendingPathComponent(".git/index"), beforeIndex = try? Data(contentsOf: index)
        let note = try await repository.editableCommitNote(revision: revisions[1].hash), settings = try await repository.projectDialogSettings(source: .effective)
        try require(settings.minimumLength == 3 && settings.borderColumn == 72, "Effective project fixture")
        let sync = HistoryNotesWindowController(repository: repository, access: nil, revision: note.revision, preferences: preferences)
        defer { sync.close() }
        var closed = 0, changed = 0
        sync.onClosed = { closed += 1 }; sync.model.onChanged = { _ in changed += 1 }
        try require(!sync.canAccept && !sync.editor.isEditable && sync.window?.title == "Edit Notes", "Shared form loading gate")
        sync.model.load(); try await wait { !sync.model.loading && sync.model.snapshot != nil && HistoryNotesWindowModel.activeReads == 0 }
        try require(sync.checkbox.isHidden && sync.editor.font?.pointSize == 16 && !sync.canAccept && !sync.editor.isContinuousSpellCheckingEnabled, "Source checkbox/font/language/minimum")
        sync.editor.string = "🐢"; sync.textDidChange(Notification(name: NSText.didChangeNotification)); try require(!sync.canAccept, "UTF-16 minimum")
        sync.editor.string = "sync note 🐢\nexact text"; sync.textDidChange(Notification(name: NSText.didChangeNotification)); sync.save()
        try await wait { closed == 1 && InputWindowController.activeSaves == 0 && HistoryNotesWindowModel.activeMutations == 0 }
        let saved = try await repository.editableCommitNote(revision: note.revision)
        try require(saved.text == "sync note 🐢\nexact text" && changed == 1, "Shared form real note write")
        let cancel = HistoryNotesWindowController(repository: repository, access: nil, revision: note.revision, preferences: preferences)
        cancel.model.load(); try await wait { cancel.model.snapshot != nil && !cancel.model.loading }; cancel.editor.string = "cancelled"; cancel.cancel()
        let afterCancel = try await repository.editableCommitNote(revision: note.revision)
        try require(afterCancel.text == saved.text, "Cancel does not write")

        let legacy = HistoryNotesWindowController(repository: repository, access: nil, revision: note.revision, preferences: preferences)
        legacy.model.load(); try await wait { !legacy.model.loading && legacy.model.snapshot != nil }
        legacy.model.text = "legacy captured"; legacy.model.save(); legacy.model.text = "later draft"
        try require(legacy.model.saving && HistoryNotesWindowModel.activeMutations == 1, "Synchronous legacy save gate")
        try await wait { !legacy.model.saving && HistoryNotesWindowModel.activeMutations == 0 }
        let legacySaved = try await repository.editableCommitNote(revision: note.revision)
        try require(legacySaved.text == "legacy captured", "Legacy captures draft before task")
        legacy.close()

        let failure = HistoryNotesWindowController(repository: repository, access: nil, revision: note.revision, preferences: preferences)
        failure.model.read = { _ in throw Failure(message: "Injected read failure") }
        failure.model.load(); try await wait { !failure.model.loading && failure.model.error != nil }
        try require(!failure.canAccept && !failure.editor.isEditable && !failure.errorLabel.stringValue.isEmpty, "Failed read cannot accept empty draft")
        failure.cancel()

        var continuation: CheckedContinuation<Void,Never>?, ownedToken: OperationCancellation?
        let held = HistoryNotesWindowController(repository: repository, access: nil, revision: note.revision, preferences: preferences)
        held.model.read = { token in ownedToken = token; await withCheckedContinuation { continuation = $0 }; return (saved, settings) }
        held.model.load(); try await wait { continuation != nil }
        held.close(); try require(ownedToken?.isCancelled == true && HistoryNotesWindowModel.activeReads == 1, "Closed history read remains counted")
        continuation?.resume(); continuation = nil; try await wait { HistoryNotesWindowModel.activeReads == 0 }
        try require(held.model.snapshot == nil && !held.canAccept, "Late history read cannot repopulate retired editor")

        let plan = try await repository.cherryPickPlan(revisions: [revisions[0].hash, revisions[1].hash])
        let rebase = RebaseWindowController(repository: repository, access: nil, preferences: preferences)
        defer { rebase.close() }
        rebase.model.plan = plan
        let chosen = plan.entries[1], ids: Set<String> = [chosen.id]
        rebase.model.performRevisionMenu(.notes, ids: ids); try await wait { rebase.noteEditor != nil }
        guard let editor = rebase.noteEditor else { throw Failure(message: "Owned Rebase note editor missing") }
        try require(editor.window?.sheetParent === rebase.window && editor.editor.font?.pointSize == 16 && !editor.editor.isContinuousSpellCheckingEnabled && !rebase.model.revisionMenuAvailable, "Owned Rebase source settings/menu gate")
        editor.editor.string = "rebase captured\nnotes"; editor.textDidChange(Notification(name: NSText.didChangeNotification))
        rebase.model.revisionMenuLog.selected = [revisions[0].hash]; editor.save()
        try await wait { rebase.noteEditor == nil && !rebase.model.revisionMenuLog.savingNote && InputWindowController.activeSaves == 0 }
        let rebaseSaved = try await repository.editableCommitNote(revision: chosen.commit.hash)
        try require(rebaseSaved.text == "rebase captured\nnotes" && rebase.window?.attachedSheet == nil && rebase.model.revisionMenuAvailable, "Captured revision / released parent")
        rebase.model.performRevisionMenu(.notes, ids: ids); try await wait { rebase.noteEditor != nil }; rebase.noteEditor?.cancel(); try await wait { rebase.noteEditor == nil }

        let legacyLog = LogWindowModel(repository: repository, access: nil, labelDefaults: preferences)
        legacyLog.entries = revisions; legacyLog.selected = [chosen.commit.hash]; legacyLog.editNotes()
        try await wait { legacyLog.noteRequest != nil && !legacyLog.loadingNote }
        legacyLog.noteText = "legacy log captured"; legacyLog.saveNote(); legacyLog.noteText = "later log draft"
        try require(legacyLog.savingNote && LogWindowModel.activeNoteSaves == 1, "Synchronous legacy Log save gate")
        try await wait { !legacyLog.savingNote && legacyLog.noteRequest == nil && LogWindowModel.activeNoteSaves == 0 }
        let legacyLogSaved = try await repository.editableCommitNote(revision: chosen.commit.hash)
        try require(legacyLogSaved.text == "legacy log captured", "Legacy Log captures draft before task")
        legacyLog.invalidate()

        let retired = RebaseWindowController(repository: repository, access: nil, preferences: preferences)
        retired.model.plan = plan
        retired.model.revisionMenuLog.readNote = { _, token in ownedToken = token; await withCheckedContinuation { continuation = $0 }; return (rebaseSaved, settings) }
        retired.model.performRevisionMenu(.notes, ids: ids); try await wait { continuation != nil }
        retired.close(); try require(ownedToken?.isCancelled == true && LogWindowModel.activeNoteReads == 1, "Retired Rebase read cancellation/count")
        continuation?.resume(); continuation = nil; try await wait { LogWindowModel.activeNoteReads == 0 }
        try require(retired.noteEditor == nil && retired.model.revisionMenuLog.isInvalidated && retired.model.revisionMenuLog.noteRequest == nil, "Retired Rebase read fence")
        let finalHead = try await repository.run(["rev-parse","HEAD"]).stdout
        try require(finalHead == head && (try? Data(contentsOf: index)) == beforeIndex && LogWindowModel.activeNoteSaves == 0 && HistoryNotesWindowModel.activeReads == 0, "No owned work / HEAD or index changes")
    }
}
