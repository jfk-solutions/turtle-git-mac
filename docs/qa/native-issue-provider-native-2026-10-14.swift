import AppKit
import SwiftUI
import TurtleGitCore

@main struct NativeIssueProviderVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "Native issue provider timeout at line \(line)") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Native issue provider failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); for (key, value) in [("user.name", "Provider QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "file.txt"; try Data("base".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "base"); try Data("changes".utf8).write(to: root.appendingPathComponent(path))
        let suite = "TurtleGit.NativeIssueProvider." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!; prefs.set(true, forKey: "Commit.SkipCancelConfirmation"); prefs.set(false, forKey: "Commit.AutoSelectSubmodules"); defer { prefs.removePersistentDomain(forName: suite) }
        let parameters = #"{"linkText":"Select tickets","messageTemplate":"Ticket: %BUGID%","requireIssue":true,"issues":[{"id":"2","summary":"Second"},{"id":"1","summary":"First 雪"}]}"#
        // Real native association editor validates, returns only on OK, then Apply persists.
        let settings = IssueProviderSettingsModel(preferences: prefs), parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false); parent.isReleasedWhenClosed = false; settings.window = parent; defer { settings.suspend(); parent.close() }
        parent.contentViewController = NSHostingController(rootView: IssueProviderSettingsPage(workspace: RepositoryModel(), preferences: prefs, model: settings)); parent.contentView?.layoutSubtreeIfNeeded()
        settings.add(root: root); guard let editor = settings.editor else { throw Failure(description: "Association editor absent") }
        editor.model.row.path = "/nonexistent-turtlegit-provider-qa"; editor.model.accept(); try require(settings.editor === editor && editor.model.error != nil && settings.rows.isEmpty, "Invalid association closed/wrote parent")
        editor.model.row.path = root.path; editor.model.row.parameters = parameters; editor.model.accept(); try require(!settings.hasChild && settings.modified && prefs.data(forKey: NativeIssueAssociations.key) == nil, "Editor accepted directly to persistent settings")
        try require(settings.apply() && (try NativeIssueAssociations.load(from: prefs)).count == 1, "Association Apply failed")
        settings.edit(copy: true); settings.editor?.model.cancel(); try require(settings.rows.count == 1 && !settings.modified, "Copy Cancel changed rows")
        settings.edit(copy: true); settings.editor?.model.row.enabled = false; settings.editor?.model.accept(); try require(settings.rows.count == 2 && settings.rows[0].id != settings.rows[1].id, "Copy lost new identity")
        settings.cancel(); try require(settings.rows.count == 1, "Parent Cancel retained copied association")
        let originalArchive = prefs.data(forKey: NativeIssueAssociations.key); settings.selection = [settings.rows[0].id]; settings.remove(); try require(settings.rows.isEmpty && settings.modified, "Remove did not edit draft"); settings.cancel(); try require(prefs.data(forKey: NativeIssueAssociations.key) == originalArchive, "Remove draft persisted before Apply")
        settings.edit(); guard let retiredEditor = settings.editor else { throw Failure(description: "Parent retirement editor absent") }; parent.close(); try await wait { !settings.hasChild }; let frozenRows = settings.rows
        retiredEditor.model.row.parameters = NativeIssueCatalogProvider.exampleParameters; retiredEditor.model.accept(); try require(settings.rows == frozenRows && !settings.modified, "Retired settings editor wrote parent draft")
        // The actual Commit button/model uses a captured provider and owned native picker.
        let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs); defer { owner.close() }; owner.model.reload(); try await wait { !owner.model.busy && owner.model.nativeIssueProvider != nil }
        owner.model.message = "body"; owner.model.checked = [path]; let head = try await repo.run(["rev-parse", "HEAD"]).text, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        owner.model.commit(); try await wait { !owner.model.busy }; try require(owner.model.error != nil && index == Data(contentsOf: root.appendingPathComponent(".git/index")), "Required provider check staged or committed without an issue")
        owner.model.error = nil; try await wait { owner.window?.attachedSheet == nil }
        owner.model.selectProviderIssues(); try await wait { owner.issueProviderOwner?.picker != nil }; guard let cancelled = owner.issueProviderOwner?.picker else { throw Failure(description: "Owned issue picker missing") }
        cancelled.model.selected = ["1"]; cancelled.model.cancel(); try await wait { !owner.model.issueProviderBusy }; try require(owner.model.message == "body" && owner.model.issueID.isEmpty, "Picker Cancel changed draft")
        owner.model.selectProviderIssues(); try await wait { owner.issueProviderOwner?.picker != nil }; guard let picker = owner.issueProviderOwner?.picker else { throw Failure(description: "Second issue picker absent") }
        try require(owner.model.inputsBlocked && !owner.model.canCommit && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Picker escaped Commit/Quit gates")
        picker.model.selected = ["1", "2"]; picker.model.query = "First"; try require(picker.model.rows.count == 1 && picker.model.selected.count == 2, "Filter lost hidden selected issue")
        picker.model.accept(); try await wait { !owner.model.issueProviderBusy }; try require(owner.model.issueID == "2,1" && owner.model.message == "body\nTicket: 2,1\n", "Provider result lost catalog order/message")
        owner.model.onCommitProgress = nil; var committed = 0, closes = 0; owner.model.onCommitted = { _ in committed += 1 }; owner.model.close = { closes += 1 }; owner.model.commit(); try await wait { !owner.model.busy }
        let body = try await repo.run(["log", "-1", "--format=%B"]).text, newHead = try await repo.run(["rev-parse", "HEAD"]).text
        try require(newHead != head && committed == 1 && closes == 1 && body.contains("Ticket: 2,1") && body.components(separatedBy: "Ticket:").count == 2, "Actual provider commit/callback failed or duplicated template")
        owner.close()
        // A delayed provider reply retains its captured permission/lifetime and cannot edit a retired draft.
        try Data("later".utf8).write(to: root.appendingPathComponent(path)); let late = CommitWindowController(repository: repo, access: nil, defaults: prefs); defer { late.close() }; late.model.reload(); try await wait { !late.model.busy && late.model.nativeIssueProvider != nil }; late.model.message = "retired draft"
        var reply: CheckedContinuation<NativeIssueProviderResult?, Never>?
        late.model.chooseProviderIssues = { _, _ in await withCheckedContinuation { reply = $0 } }; late.model.selectProviderIssues(); try await wait { reply != nil }; late.close()
        try require(CommitWindowModel.activeIssueProviderOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired provider lost operation lifetime")
        reply?.resume(returning: NativeIssueProviderResult(message: "late overwrite", issueID: "1")); reply = nil; try await wait { CommitWindowModel.activeIssueProviderOperations == 0 }; try require(late.model.message == "retired draft", "Retired provider reply changed message")
        print("PASS native issue providers: real association editor/validation/Apply/Copy/Remove/Cancel, Commit provider required check before Git, owned filtered multi-selection/Cancel, actual message/ID commit and completion, retained retired reply/Quit and window cleanup")
    }
}
