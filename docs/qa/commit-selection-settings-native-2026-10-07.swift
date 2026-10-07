import AppKit
import SwiftUI
import TurtleGitCore

@main struct CommitSettingsVerification {
    @MainActor static func wait(_ model: CommitWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History did not finish")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Commit Settings QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
        let tracked = ["modified", "missing", "staged-delete", "dir/modified"]
        for path in tracked { try Data("base".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(tracked); _ = try await repo.commit(message: "base")
        try Data("modified".utf8).write(to: root.appendingPathComponent("modified")); try Data("dir change".utf8).write(to: root.appendingPathComponent("dir/modified"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("missing")); try FileManager.default.removeItem(at: root.appendingPathComponent("staged-delete")); try await repo.stage(["staged-delete"])
        try Data("unknown".utf8).write(to: root.appendingPathComponent("unknown")); try Data("unknown".utf8).write(to: root.appendingPathComponent("dir/unknown"))
        let suite = "TurtleGit.CommitSettings.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func model() -> CommitWindowModel { CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults) }
        let standard = model(); standard.reload(paths: ["."]); try await wait(standard)
        precondition(standard.checked == Set(tracked), "Defaults must check tracked/missing/staged deletion, exclude untracked")
        let preservedPaths = [".git/index", ".git/config", ".git/HEAD", ".git/refs/heads/main", "modified", "dir/modified", "unknown", "dir/unknown"]
        let before = try preservedPaths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        defaults.set(true, forKey: "AutoselectMissingFiles")
        defaults.set(2, forKey: "Commit.MaxHistoryItems")
        let noMissing = model(); noMissing.reload(paths: ["."]); try await wait(noMissing)
        precondition(noMissing.checked == ["modified", "staged-delete", "dir/modified"], "Missing means worktree deletion, not staged deletion")
        precondition(noMissing.messageHistory?.limit == 2)
        for message in ["one", "two", "three"] { noMissing.messageHistory?.add(message) }
        precondition(noMissing.messageHistory?.entries == ["three", "two"])
        defaults.set(false, forKey: "SelectFilesForCommit")
        let off = model(); off.reload(paths: ["."]); try await wait(off); precondition(off.checked.isEmpty)
        off.reload(paths: ["dir"]); try await wait(off); precondition(off.checked.isEmpty, "Directory descendants are not direct selections")
        off.reload(paths: ["missing", "unknown"]); try await wait(off)
        precondition(off.checked == ["missing", "unknown"], "Explicit files override automatic and missing preferences")
        off.checked = ["unknown"]; off.reload(); try await wait(off); precondition(off.checked == ["unknown"], "Refresh must preserve manual choices")
        // Settings are captured when the dialog opens, as upstream registry readers are.
        standard.reload(paths: ["dir"]); try await wait(standard)
        precondition(standard.checked == ["dir/modified"], "Existing dialog should retain original automatic preference")
        let folder = model(); folder.reload(paths: ["dir"]); try await wait(folder); precondition(folder.checked.isEmpty)
        defaults.set(true, forKey: "SelectFilesForCommit")
        let enabledFolder = model(); enabledFolder.reload(paths: ["dir"]); try await wait(enabledFolder)
        precondition(enabledFolder.checked == ["dir/modified"], "Untracked descendants are never automatically checked")
        let after = try preservedPaths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        // ReCommit reopens with automatic selection enabled regardless of saved off.
        defaults.set(false, forKey: "SelectFilesForCommit")
        let again = model(); again.reload(paths: ["."]); try await wait(again); again.checked = ["modified"]; again.message = "commit modified"
        precondition(again.canCommit); again.commit(.recommit); try await wait(again)
        precondition(again.checked == ["staged-delete", "dir/modified"], "ReCommit enables ordinary selection, still excludes missing/untracked")
        precondition(!defaults.bool(forKey: "SelectFilesForCommit"), "ReCommit must not change global preference")
        let paths = try await repo.run(["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(paths == "modified")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: CommitEditorSettings().defaultAppStorage(defaults))
        window.contentView?.layoutSubtreeIfNeeded(); window.close()
        print("Commit settings: defaults, missing/staged deletion distinction, automatic off, direct files versus folder descendants, manual Refresh, captured preferences, two-item history, actual ReCommit selection and hidden settings layout passed")
    }
}
