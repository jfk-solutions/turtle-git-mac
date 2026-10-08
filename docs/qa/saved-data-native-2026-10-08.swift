import AppKit
import SwiftUI
import TurtleGitCore

@main struct SavedDataVerification {
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Saved Data receiver timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.SavedData.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Saved Data QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let beforeHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let beforeIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let history = CommitMessageHistory(repositoryIdentity: repo.root.path, defaults: prefs); history.add("saved message")
        prefs.set(["https://example.invalid/repo"], forKey: "Clone.URLHistory")
        prefs.set(["ssh://example.invalid/push"], forKey: "History.PushURLS." + repo.root.path)
        prefs.set(["/output"], forKey: "FormatPatchDirectories")
        prefs.set(false, forKey: "StashPop.ShowChanges"); prefs.set(7, forKey: "OpenRebaseRemoteBranchEqualsHEAD")
        prefs.set(true, forKey: "MergeConflictsNeedsCommit"); prefs.set(true, forKey: "Commit.SkipCancelConfirmation")
        prefs.set(2, forKey: "AutoCloseGitProgress"); prefs.set(["private-key-path"], forKey: "Clone.KeyHistory")
        let store = ActionLogStore(storageURL: root.appendingPathComponent("private/logfile.txt"))
        try store.append(repository: root, output: "keep log", cancelled: false)
        let settings = SavedDataSettingsModel(store: store, preferences: prefs, showFile: { _ in true })
        precondition(settings.summaries[.urlHistory]?.entries == 3 && settings.summaries[.messageHistory]?.entries == 1)
        let beforeClone = CloneWindowModel(directory: root, access: nil, preferences: prefs, executable: git)
        precondition(beforeClone.urls.count == 1)
        settings.clear(.urlHistory); precondition(settings.summaries[.urlHistory]?.available == false)
        let clone = CloneWindowModel(directory: root, access: nil, preferences: prefs, executable: git)
        precondition(clone.urls.isEmpty && clone.keys == ["private-key-path"] && !history.entries.isEmpty)
        let push = PushWindowModel(repository: repo, access: nil, preferences: prefs); push.load(); try await wait { !push.busy }
        precondition(push.urls.isEmpty)
        let patch = FormatPatchWindowModel(repository: repo, access: nil, preferences: prefs); precondition(patch.dirs.isEmpty)
        settings.clear(.messageHistory); precondition(history.entries.isEmpty && settings.summaries[.messageHistory]?.available == false)
        history.add("new after clear"); settings.refresh(); precondition(settings.summaries[.messageHistory]?.entries == 1)
        settings.clear(.storedDecisions)
        for key in ["StashPop.ShowChanges", "OpenRebaseRemoteBranchEqualsHEAD", "MergeConflictsNeedsCommit", "Commit.SkipCancelConfirmation"] { precondition(prefs.object(forKey: key) == nil) }
        precondition(prefs.integer(forKey: "AutoCloseGitProgress") == 2 && store.exists)
        let clearedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(clearedIndex == beforeIndex)
        let originalTree = try await repo.run(["write-tree"]).stdout
        // Stash Pop must ask again after clearing its remembered false answer.
        _ = try await repo.run(["config", "user.name", "Saved Data QA"])
        try Data("stash content".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.run(["stash", "push", "-m", "saved-data-check"])
        let stash = StashRestoreWindowModel(repository: repo, access: nil, pop: true, showChanges: 1, preferences: prefs)
        var questions = 0
        stash.onPresent = { prompt, choose in questions += 1; precondition(prompt.rememberKey == "StashPop.ShowChanges"); choose(false, false) }
        stash.start(); try await wait { !stash.busy && questions == 1 }
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try await repo.run(["write-tree"]).stdout
        precondition(beforeHead == afterHead && originalTree == afterIndex)
        let host = NSHostingView(rootView: SavedDataSettingsPage()); host.frame = NSRect(x: 0, y: 0, width: 760, height: 700); host.layoutSubtreeIfNeeded(); precondition(host.fittingSize.width > 0)
        print("PASS: Saved Data clears real Clone/Push/Format Patch histories, live Commit history and remembered Stash decision; action log, keys, options and HEAD/index preserved; hidden native host")
    }
}
