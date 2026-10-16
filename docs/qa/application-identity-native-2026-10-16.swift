import AppKit
import TurtleGitCore

@main struct ApplicationIdentityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [PatchWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "File document timeout at \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.close() }; owners = [] }
        catch { owners.forEach { $0.close() }; owners = []; fputs("Application identity failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Identity QA"), ("user.email", "identity@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try await repo.run(["write-tree"]).stdout
        let folder = root.deletingLastPathComponent().appendingPathComponent("standalone-" + UUID().uuidString); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("patch 雪\n.PATCH"), bytes = Data("--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n".utf8)
        try bytes.write(to: file)
        let suite = "TurtleGit.ApplicationIdentity." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        defer { workspace.stopMonitoringForTermination() }
        workspace.reviewPatchPreferences = preferences; workspace.root = root; workspace.busy = true
        var presentations = 0
        workspace.patchDocumentPresentation = { owner in
            presentations += 1
            if !owners.contains(where: { $0 === owner }) { owners.append(owner) }
            owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
        }
        workspace.handle(file)
        try await wait { workspace.patchDocumentWindows.count == 1 && PatchDocumentSession.activeOperations == 0 }
        let owner = workspace.patchDocumentWindows.values.first!, model = owner.model, session = owner.documentSession!
        try require(model.exportDocument.bytes == bytes && model.readOnly && model.allowsDocumentEditing && !model.canApplyLines && !model.canApplyHunks && session.fileURL == file && owner.window?.representedURL == file, "File URL did not open scoped standalone document")
        try require(workspace.root == root && workspace.busy && workspace.error == nil, "File-open adopted or disrupted active workspace")
        try await wait { descendants(owner.window!.contentView!).contains { ($0 as? PatchTextView.PatchText)?.isEditable == true } }
        let text = descendants(owner.window!.contentView!).compactMap { $0 as? PatchTextView.PatchText }.first!
        owner.window?.makeFirstResponder(text)
        text.insertText("+edited\n", replacementRange: NSRange(location: text.string.utf16.count, length: 0))
        try await wait { model.documentDirty }
        let edited = model.document.text
        workspace.handle(file)
        try require(workspace.patchDocumentWindows.count == 1 && presentations == 2 && model.document.text == edited && model.documentDirty, "Repeated file-open replaced dirty document")
        session.saveDocument(); try await wait { PatchDocumentSession.activeOperations == 0 && !model.documentDirty }
        try require(try Data(contentsOf: file) == Data(edited.utf8), "Opened patch Save did not target the original file")
        // As in the retained document fixture, Save's counters settle before
        // SwiftUI re-enables NSTextView; wait for real native input readiness.
        try await wait { model.canEditText && text.isEditable && text.string == model.document.text }
        text.breakUndoCoalescing()
        try require(text.undoManager?.canUndo == true, "Opened document lost native Undo")
        text.undoManager?.undo(); try await wait { model.documentDirty }
        text.undoManager?.redo(); try await wait { !model.documentDirty }
        // Save As changes the document's file identity without losing its owner.
        // Opening the old path must create a distinct window; the new path must
        // focus this same edited document, rather than opening a second copy.
        let renamed = folder.appendingPathComponent("saved-as.diff")
        session.chooseSave = { _, _, reply in reply(renamed) }
        session.saveDocument(as: true); try await wait { PatchDocumentSession.activeOperations == 0 && session.fileURL == renamed }
        let beforeReopen = presentations
        workspace.handle(renamed)
        try require(presentations == beforeReopen + 1 && workspace.patchDocumentWindows.count == 1 && workspace.patchDocumentWindows.values.first === owner, "Save As new filename did not reuse its document")
        workspace.handle(file)
        try await wait { workspace.patchDocumentWindows.count == 2 && PatchDocumentSession.activeOperations == 0 }
        let reopened = workspace.patchDocumentWindows.values.first { $0 !== owner }!
        try require(reopened.documentSession.fileURL == file && session.fileURL == renamed && reopened.model.exportDocument.bytes == Data(edited.utf8), "Save As old filename redirected the renamed document")
        reopened.close(); try require(workspace.patchDocumentWindows.count == 1, "Reopened old path leaked owner")
        let second = folder.appendingPathComponent("other.diff"), utf16 = Data([0xff, 0xfe]) + "--- a/a\r\n+++ b/a\r\n".data(using: .utf16LittleEndian)!
        try utf16.write(to: second); workspace.handle(second)
        try await wait { workspace.patchDocumentWindows.count == 2 && PatchDocumentSession.activeOperations == 0 }
        let secondOwner = workspace.patchDocumentWindows.values.first { $0.documentSession.fileURL == second }!
        try require(secondOwner.model.exportDocument.bytes == utf16 && secondOwner.documentSession.fileURL == second, "Multiple file opens lost exact encoded bytes")
        workspace.confirmingQuit = true; workspace.handle(folder.appendingPathComponent("refused.patch")); workspace.confirmingQuit = false
        try require(workspace.patchDocumentWindows.count == 2, "File open bypassed pending Quit")
        workspace.handle(folder.appendingPathComponent("unsupported.bin")); try require(workspace.patchDocumentWindows.count == 2 && workspace.error != nil, "Unsupported file entered patch editor"); workspace.error = nil
        // Hold a successful read reply, then force-close its actual owner. Its
        // security lease and global read count remain owned until real settlement.
        var reply: CheckedContinuation<Data, Error>?, token: OperationCancellation?
        workspace.configurePatchDocument = { controller in
            controller.documentSession.readFile = { _, cancellation in token = cancellation; return try await withCheckedThrowingContinuation { reply = $0 } }
        }
        let slow = folder.appendingPathComponent("slow.patch"); try bytes.write(to: slow); workspace.handle(slow)
        try await wait { reply != nil }
        let slowOwner = workspace.patchDocumentWindows.values.first { $0.model.comparisonTitle == slow.lastPathComponent }!
        try require(PatchDocumentSession.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "File read lacks Quit ownership")
        slowOwner.close()
        try require(token?.isCancelled == true && PatchDocumentSession.activeOperations > 0 && workspace.patchDocumentWindows.count == 2, "Closing document released pending read or registration incorrectly")
        reply?.resume(returning: bytes); reply = nil; try await wait { PatchDocumentSession.activeOperations == 0 }
        try require(slowOwner.model.retired && slowOwner.model.exportDocument.bytes.isEmpty && slowOwner.model.error == nil, "Retired file read published late contents")
        owner.close(); secondOwner.close(); try require(workspace.patchDocumentWindows.isEmpty, "Closed documents retained workspace ownership")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try await repo.run(["write-tree"]).stdout
        try require(after == head && afterIndex == index, "Patch file opening/editing changed Git state")
        print("PASS: native file-URL patch/diff routing, independent workspace, duplicate dirty preservation, scoped Save/Undo/UTF16 documents, Quit/read ownership and forced-close late-result refusal")
    }
}
