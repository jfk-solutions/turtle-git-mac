import AppKit
import TurtleGitCore

@main struct PathEntryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Scope: RepositoryBookmarkProvider {
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
        func startAccessing(_ url: URL) -> Bool { true }
        func stopAccessing(_ url: URL) {}
    }
    @MainActor static var owners: [NSWindowController] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Path entry timeout at \(line)")
    }
    @MainActor static func descendants(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.close() }; owners = [] }
        catch { owners.forEach { $0.close() }; owners = []; fputs("Path entry failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Path QA"), ("user.email", "path@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("source\n".utf8).write(to: root.appendingPathComponent("source.txt")); try await repo.stage(["source.txt"]); _ = try await repo.commit(message: "baseline")
        let folder = root.appendingPathComponent("folder with space"), outside = root.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for name in ["file 雪\n.patch", "file [literal].zip", ".hidden", "FileCase.txt"] { try Data("fixture\n".utf8).write(to: root.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let scope = RepositoryAccessLease(url: root, provider: Scope()), token = OperationCancellation()
        func query(_ text: String, base: URL? = nil, restricted: Bool = false, grants: [RepositoryAccessLease]? = nil) throws -> [String] {
            try PathEntryQuery(text: text, base: base ?? root, permissions: grants ?? [scope], requiresScopes: restricted).results(cancellation: token)
        }
        try require(try query("fo") == ["folder with space/"], "Relative folder completion lost slash/space")
        try require(try query("fi").contains("file 雪\n.patch") && query("fi").contains("file [literal].zip"), "Literal Unicode/newline/glob file names lost")
        try require(try query("../fo", base: folder) == ["../folder with space/"], "Parent-relative prefix changed")
        try require(try query(".").contains(".hidden") && !query("f").contains(".hidden"), "Explicit hidden-prefix completion lost")
        try require(try query("https://example.invalid/path").isEmpty, "URL entered filesystem lookup")
        try require(try query("fo", restricted: true) == ["folder with space/"] && query(outside.path + "/", restricted: true).isEmpty && query("escape/", restricted: true).isEmpty && query("fo", restricted: true, grants: []).isEmpty, "Grant or symlink boundary lost")
        let stopped = OperationCancellation(); stopped.cancel()
        do { _ = try PathEntryQuery(text: "fo", base: root, permissions: [], requiresScopes: false).results(cancellation: stopped); throw Failure(description: "Cancelled completion ran") } catch is OperationCancellationFailure {}
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        var index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.PathEntry." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let rename = RenameWindowController(repository: repo, access: nil, source: "source.txt", preferences: prefs)
        let clone = CloneWindowController(directory: root, access: nil, preferences: prefs, executable: repo.executable)
        let worktree = WorktreeCreateWindowController(repository: repo, access: nil, preferences: prefs)
        let export = ExportWindowController(repository: repo, access: nil, revision: "HEAD", preferences: prefs)
        owners = [rename, clone, worktree, export]
        worktree.model.load(); export.model.load(revision: "HEAD")
        try await wait { !worktree.model.busy && !worktree.model.chooser.busy && !export.model.busy }
        index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let configurations: [(NSWindowController, String, String, () -> String, (String) -> Void)] = [
            (rename, "New name", "fo", { rename.model.name }, { rename.model.name = $0 }),
            (clone, "Destination directory", root.path + "/fo", { clone.model.directory }, { clone.model.directory = $0 }),
            (worktree, "Worktree directory", root.path + "/fo", { worktree.model.directory }, { worktree.model.directory = $0 }),
            (export, "ZIP file", root.path + "/fi", { export.model.destination }, { export.model.destination = $0 })]
        var firstField: PathEntryField.Field?, firstEditor: PathEntryField.Editor?, firstCoordinator: PathEntryField.Coordinator?
        for (owner, label, prefix, value, set) in configurations {
            set(prefix); owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
            var field: PathEntryField.Field?
            try await wait { field = descendants(owner.window?.contentView).compactMap { $0 as? PathEntryField.Field }.first { $0.accessibilityLabel() == label }; return field?.isEnabled == true && field?.stringValue == prefix }
            let control = field!, coordinator = control.coordinator!
            coordinator.present = { _ in } // Test actual TextKit completion without physical popup tracking.
            owner.window?.makeFirstResponder(control)
            guard let editor = control.currentEditor() as? PathEntryField.Editor else { throw Failure(description: "Custom path field editor absent: " + label) }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("l", replacementRange: editor.selectedRange())
            try await wait { value() == prefix + "l" && !coordinator.choices.isEmpty }
            var selected = 0
            let choices = editor.completions(forPartialWordRange: editor.rangeForUserCompletion, indexOfSelectedItem: &selected) ?? []
            try require(!choices.isEmpty && selected == -1 && editor.rangeForUserCompletion.length == editor.string.utf16.count, "Native completion split a path word or selected it prematurely")
            let chosen = choices[0]
            editor.insertCompletion(chosen, forPartialWordRange: editor.rangeForUserCompletion, movement: NSReturnTextMovement, isFinal: true)
            try await wait { value() == chosen }
            try require(control.stringValue == chosen, "Native choice did not bind exactly: " + label)
            if label == "New name" { firstField = control; firstEditor = editor; firstCoordinator = coordinator }
            else { owner.close() }
        }
        // Held reads are cancelled/retained through retirement, and cannot reopen
        // a popup or replace a changed draft once they return successfully.
        let field = firstField!, coordinator = firstCoordinator!
        rename.model.name = "fo"; try await wait { field.stringValue == "fo" }
        rename.window?.makeFirstResponder(field)
        let editor = field.currentEditor() as? PathEntryField.Editor ?? firstEditor!
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        var reply: CheckedContinuation<[String], Error>?, captured: OperationCancellation?, presented = 0
        coordinator.read = { _, token in captured = token; return try await withCheckedThrowingContinuation { reply = $0 } }
        coordinator.present = { _ in presented += 1 }
        coordinator.request(); try await wait { reply != nil }
        rename.model.name = "different"; try await wait { field.stringValue == "different" }
        reply?.resume(returning: ["folder with space/"]); reply = nil; try await wait { PathEntryField.Coordinator.activeReads == 0 }
        try require(captured?.isCancelled == true && presented == 0 && rename.model.name == "different", "Changed input accepted old completion")
        rename.model.name = "fo"; try await wait { field.stringValue == "fo" }; rename.window?.makeFirstResponder(field)
        let active = field.currentEditor() as! PathEntryField.Editor; active.setSelectedRange(NSRange(location: active.string.utf16.count, length: 0))
        coordinator.request(); try await wait { reply != nil }; rename.close()
        try require(captured?.isCancelled == true && PathEntryField.Coordinator.activeReads > 0, "Closed field released pending reader")
        reply?.resume(returning: ["late"]); reply = nil; try await wait { PathEntryField.Coordinator.activeReads == 0 }
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try require(coordinator.retired && presented == 0 && rename.model.name == "fo", "Retired delegate/popup changed the model")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Completion changed Git state")
        print("PASS: source filesystem completion in four native dialog fields, literal paths/scopes, real TextKit binding/selection, cancellation and retired reply guards; unchanged HEAD/index")
    }
}
