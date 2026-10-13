import AppKit
import TurtleGitCore

actor RefLogNoteGate {
    var continuation: CheckedContinuation<(CommitNoteSnapshot,ProjectDialogSettings),Error>?
    var token: OperationCancellation?
    func read(_ token: OperationCancellation) async throws -> (CommitNoteSnapshot,ProjectDialogSettings) { self.token = token; return try await withCheckedThrowingContinuation { continuation = $0 } }
    func release(_ value: (CommitNoteSnapshot,ProjectDialogSettings)) { continuation?.resume(returning:value); continuation = nil }
}
@main struct RefLogNotesPatchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool,_ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw Failure(description:"RefLog note/patch did not settle") }
    @MainActor static func table(_ view:NSView) -> ReferenceLogTableView? { (view as? ReferenceLogTableView) ?? view.subviews.compactMap(table).first }
    @MainActor static func invoke(_ item:NSMenuItem) throws { guard item.isEnabled,let action=item.action else { throw Failure(description:"Disabled note/patch command") }; try require(NSApp.sendAction(action,to:item.target,from:item),"Note/patch did not dispatch") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("RefLog note/patch failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.RefLogNotes.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set("Menlo",forKey:"LogFontName"); prefs.set(15,forKey:"LogFontSize")
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Note QA"),("user.email","note@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("tgit.logminsize","4")] { _ = try await repo.run(["config",key,value]) }
        let file=root.appendingPathComponent("file")
        try Data("source\n".utf8).write(to:file); try await repo.stage(["file"]); _ = try await repo.commit(message:"First")
        _ = try await repo.run(["commit","--allow-empty","-m","Second"])
        _ = try await repo.run(["checkout","--detach","HEAD"]); _ = try await repo.run(["checkout","main"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:file)
        let owner=ReferenceLogWindowController(repository:repo,access:nil,reference:"HEAD",preferences:prefs); defer { owner.close() }
        var preset:FormatPatchPreset?; owner.model.onFormatPatch = { preset=$0 }; owner.model.reload()
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !owner.model.busy && table(owner.window!.contentView!)?.numberOfRows == owner.model.entries.count && owner.model.entries.count >= 4 }
        let native=table(owner.window!.contentView!)!,model=owner.model
        native.selectRowIndexes(IndexSet([0,1]),byExtendingSelection:false)
        let expected=model.formatPatchPreset(model.selection)
        let patch=native.owner!.menu().item(withTitle:"Create patch…")!
        try require(patch.image != nil,"Patch source icon missing"); try invoke(patch)
        try require(preset==expected && expected != nil,"Repeated-event patch range changed")
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        let selected=model.entries[0], notes=native.owner!.menu().item(withTitle:"Edit Notes…")!
        try require(notes.image != nil,"Note source icon missing"); try invoke(notes)
        try await wait { owner.noteEditor != nil }
        let editor=owner.noteEditor!
        try require(editor.window?.sheetParent === owner.window && editor.editor.font?.pointSize == 15 && !model.commandSurfaceAvailable,"Note sheet ownership/font/parent gates")
        editor.editor.string="a"; editor.textDidChange(Notification(name:NSText.didChangeNotification)); editor.save()
        try require(owner.noteEditor === editor && !editor.busy,"Minimum-length check accepted short note")
        editor.editor.string="captured RefLog\nnotes 雪"; editor.textDidChange(Notification(name:NSText.didChangeNotification))
        model.selection=[model.entries.last!.id]; editor.save()
        try await wait { owner.noteEditor == nil && !model.noteLog.savingNote && InputWindowController.activeSaves == 0 }
        let saved=try await repo.editableCommitNote(revision:selected.hash)
        try require(saved.text=="captured RefLog\nnotes 雪" && owner.window?.attachedSheet == nil && model.commandSurfaceAvailable,"Note did not save captured revision/release parent")
        model.performOperation(.editNotes,ids:[selected.id]); try await wait { owner.noteEditor != nil }
        owner.noteEditor!.editor.string="discarded"; owner.noteEditor!.cancel(); try await wait { owner.noteEditor == nil }
        let unchanged=try await repo.editableCommitNote(revision:selected.hash); try require(unchanged.text==saved.text,"Cancel wrote note")
        let gate=RefLogNoteGate(), settings=try await repo.projectDialogSettings(source:.effective)
        model.noteLog.readNote = { _,token in try await gate.read(token) }
        model.performOperation(.editNotes,ids:[selected.id]); try await wait { model.noteLog.loadingNote }
        while await gate.continuation == nil { try await Task.sleep(nanoseconds:1_000_000) }
        owner.window!.close()
        try require(await gate.token?.isCancelled == true && LogWindowModel.activeNoteReads > 0,"Closed note read lost cancellation/Quit accounting")
        await gate.release((saved,settings)); try await wait { LogWindowModel.activeNoteReads == 0 }
        try require(owner.noteEditor == nil && model.noteLog.isInvalidated,"Retired note read reopened a sheet")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==bytes,"Notes/patch handoff changed HEAD/index/worktree")
        print("RefLog notes/patch: original menu icons, repeated-selector patch range, shared note sheet/font/minimum, captured-revision save, Cancel, parent gates and forced-close late-read cancellation passed. Notes changed only the intended notes ref; review-only patch handoff and owned windows closed.")
    }
}
