import AppKit
import SwiftUI
import TurtleGitCore

@main struct MergeHistoryVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Merge timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeHistory.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["commit", "--allow-empty", "-m", "base"])
        let history = MergeMessageHistory(defaults: prefs)
        let model = MergeWindowModel(repository: repo, access: nil, preferences: prefs)
        let editor = MergeMessageTextView(frame: .init(x: 0, y: 0, width: 600, height: 110))
        editor.isRichText = false; editor.allowsUndo = true; editor.model = model
        let menu = NSMenu(); editor.appendHistoryItems(to: menu); precondition(menu.items.isEmpty)
        history.add("previous 雪\nbody")
        editor.appendHistoryItems(to: menu)
        precondition(menu.items.suffix(2).map(\.title) == ["Paste last message", "Recent messages…"])
        precondition(menu.items.suffix(2).allSatisfy { $0.image != nil && $0.target === editor })
        editor.string = MergeWindowModel.defaultMessage; editor.pasteLastMessage()
        precondition(editor.string == "previous 雪\nbody" && model.message == editor.string)
        editor.string = "before REPLACE after"; editor.setSelectedRange(.init(location: 7, length: 7)); editor.pasteLastMessage()
        precondition(editor.string == "before previous 雪\nbody after")
        model.showMessageHistory = { insert in insert("chosen\nbody") }
        editor.string = "prefix selected suffix"; editor.setSelectedRange(.init(location: 7, length: 8)); editor.recentMessages()
        precondition(editor.string == "prefix chosen\nbody\n suffix" && model.message == editor.string)
        editor.string = MergeWindowModel.defaultMessage; editor.recentMessages(); precondition(editor.string == "chosen\nbody")
        editor.isEditable = false; let disabled = NSMenu(); editor.appendHistoryItems(to: disabled)
        editor.insertHistory("bad", appendNewline: true); precondition(disabled.items.isEmpty && editor.string == "chosen\nbody")
        editor.isEditable = true; model.busy = true; editor.insertHistory("bad", appendNewline: false); precondition(editor.string == "chosen\nbody"); model.busy = false
        SavedDataStore(preferences: prefs).clear(.messageHistory)
        let cancelled = MergeWindowController(repository: repo, access: nil, preferences: prefs)
        cancelled.window?.contentViewController = nil; cancelled.model.message = "cancel draft"; cancelled.close()
        precondition(history.entries == ["cancel draft"])
        let noCommit = MergeWindowController(repository: repo, access: nil, preferences: prefs)
        noCommit.window?.contentViewController = nil; noCommit.model.options.noCommit = true; noCommit.model.message = "excluded"; noCommit.close()
        let sentinel = MergeWindowController(repository: repo, access: nil, preferences: prefs)
        sentinel.window?.contentViewController = nil; sentinel.close(); precondition(history.entries == ["cancel draft"])
        let failed = MergeWindowModel(repository: repo, access: nil, preferences: prefs)
        failed.target = .commit; failed.commitRevision = "refs/heads/missing"; failed.message = "failed attempt"
        failed.merge(); let progress = failed.progress!
        precondition(history.entries.first == "failed attempt")
        try await wait { progress.busy }; precondition(!progress.success)
        // A concurrent dialog must retain its newest position when the operation's owner closes.
        history.add("other dialog"); failed.finish(progress); failed.saveMessageHistoryForClose()
        precondition(history.entries.first == "other dialog")
        let invalid = MergeWindowModel(repository: repo, access: nil, preferences: prefs)
        invalid.target = .commit; invalid.messages = true; invalid.messageCount = "invalid"; invalid.message = "not submitted"
        invalid.merge(); precondition(invalid.progress == nil && !history.entries.contains("not submitted"))
        let host = NSHostingView(rootView: CommitMessageHistoryDialog(history: history) { _ in })
        host.frame = .init(x: 0, y: 0, width: 600, height: 320); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        SavedDataStore(preferences: prefs).clear(.messageHistory); precondition(history.entries.isEmpty)
        history.add("fresh"); precondition(history.entries == ["fresh"])
        print("PASS: native history menu icons, sentinel clearing, selected UTF-16 insertion/newline behavior, edit/busy guards, hidden controller Cancel/No Commit/default close, save before real failed Git merge, no duplicate close reorder, count validation, shared history picker layout and Saved Data clear; no main app")
    }
}
