import AppKit
import SwiftUI
import TurtleGitCore

@main struct MessageFileVerification {
    @MainActor static func wait(_ model: CommitWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Commit timed out")
    }
    static func body(_ repo: GitRepository) async throws -> String {
        let object = try await repo.run(["cat-file", "commit", "HEAD"]).text
        return String(object[object.range(of: "\n\n")!.upperBound...])
    }
    static func configure(_ repo: GitRepository) async throws {
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Message QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["config", "commit.cleanup", "verbatim"])
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: executable); try await configure(repo)
        try Data("base".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let suite = "TurtleGit.MessageFile.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        var sequence = 0
        @MainActor func attempt(_ raw: String, expected: String, draft: String) async throws {
            sequence += 1; try Data("change \(sequence)".utf8).write(to: root.appendingPathComponent("file"))
            model.reload(paths: ["."]); try await wait(model); model.checked = ["file"]; model.message = raw
            model.commit(); try await wait(model)
            let actual = try await body(repo)
            precondition(Data(actual.utf8) == Data(expected.utf8), "Commit bytes differ: " + actual.debugDescription)
            precondition(model.message == draft && model.messageHistory?.entries.first == draft)
        }
        try await attempt(" \nTitle \r\n\r\n\r\n# keep \r\nBody \t \n", expected: "Title\n\n# keep\nBody \t\n", draft: "Title \r\n\r\n\r\n# keep \r\nBody \t")
        defaults.set(true, forKey: "StripCommentedLines")
        try await attempt("Message\n# drop\n", expected: "Message\n", draft: "Message\n# drop")
        _ = try await repo.run(["config", "core.commentchar", ";"])
        try await attempt("Custom\n; drop\n# keep", expected: "Custom\n# keep\n", draft: "Custom\n; drop\n# keep")
        defaults.set(false, forKey: "StripCommentedLines"); defaults.set(false, forKey: "SanitizeCommitMsg")
        let loose = " \n\nLoose  \r\n\n\nTail  \n\n"
        try await attempt(loose, expected: "\n\nLoose\n\n\nTail\n\n", draft: loose)
        defaults.set(true, forKey: "StripCommentedLines"); defaults.set(true, forKey: "SanitizeCommitMsg")
        try Data("not committed".utf8).write(to: root.appendingPathComponent("file"))
        model.reload(); try await wait(model); model.checked = ["file"]; model.message = "; only comment"
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout, history = model.messageHistory?.entries
        model.commit(); try await wait(model, allowError: true); precondition(model.error != nil)
        let refusedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), refusedHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(index == refusedIndex && head == refusedHead && model.messageHistory?.entries == history)
        // A real edit pause proves the Rebase model consumes the same formatter.
        let rebaseRoot = root.appendingPathComponent("rebase-fixture"); try FileManager.default.createDirectory(at: rebaseRoot, withIntermediateDirectories: true)
        let rebaseRepo = GitRepository(root: rebaseRoot, executable: executable); try await configure(rebaseRepo)
        _ = try await rebaseRepo.run(["config", "core.commentchar", ";"])
        try Data("base".utf8).write(to: rebaseRoot.appendingPathComponent("base")); try await rebaseRepo.stage(["base"]); _ = try await rebaseRepo.commit(message: "base")
        _ = try await rebaseRepo.run(["branch", "upstream"]); _ = try await rebaseRepo.run(["checkout", "-b", "topic"])
        try Data("edit contents".utf8).write(to: rebaseRoot.appendingPathComponent("edit")); try await rebaseRepo.stage(["edit"]); _ = try await rebaseRepo.commit(message: "edit me")
        var options = RebaseOptions(); options.branch = "topic"; options.upstream = "upstream"; options.force = true
        var plan = try await rebaseRepo.rebasePlan(options); plan.entries[0].action = .edit
        let editor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")
        let stopped = try await rebaseRepo.startRebase(plan, editorExecutable: editor); precondition(stopped.state.isEditPause)
        let rebase = RebaseWindowModel(repository: rebaseRepo, access: nil, messageDefaults: defaults); rebase.editorExecutable = editor; rebase.load()
        var deadline = Date().addingTimeInterval(30)
        while rebase.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!rebase.busy && rebase.error == nil && rebase.state?.isEditPause == true)
        rebase.amendMessage = "Edited summary\n; drop\n# keep"; rebase.request("continue")
        deadline = Date().addingTimeInterval(30)
        while rebase.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!rebase.busy && rebase.error == nil && rebase.finished)
        let edited = try await body(rebaseRepo); precondition(edited == "Edited summary\n# keep\n")
        let file = try Data(contentsOf: rebaseRoot.appendingPathComponent("edit")); precondition(file == Data("edit contents".utf8))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: CommitEditorSettings().defaultAppStorage(defaults)); window.contentView?.layoutSubtreeIfNeeded(); window.close()
        print("Commit message file: real commit bytes with verbatim Git cleanup, retained draft/history, default/custom comment stripping, sanitize on/off and comment-only refusal; actual Rebase edit continuation and hidden settings layout passed")
    }
}
