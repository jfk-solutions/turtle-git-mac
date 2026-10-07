import AppKit
import TurtleGitCore

@main struct MessageEncodingVerification {
    @MainActor static func wait(_ model: CommitWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Commit timed out")
    }
    static func body(_ repo: GitRepository) async throws -> Data {
        let object = try await repo.run(["cat-file", "commit", "HEAD"]).stdout
        let separator = object.range(of: Data([10,10]))!
        return object.subdata(in: separator.upperBound..<object.count)
    }
    static func configure(_ repo: GitRepository) async throws {
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Encoding QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["config", "commit.cleanup", "verbatim"])
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: executable); try await configure(repo)
        try Data("base".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let suite = "TurtleGit.MessageEncoding.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        let rows: [(String, String, [UInt8])] = [
            ("windows-1252", "café €", [0x63,0x61,0x66,0xe9,0x20,0x80,0x0a]),
            ("iso-8859-1", "café", [0x63,0x61,0x66,0xe9,0x0a]),
            ("cp1251", "Привет", [0xcf,0xf0,0xe8,0xe2,0xe5,0xf2,0x0a]),
            ("shift_jis", "日本", [0x93,0xfa,0x96,0x7b,0x0a]),
            ("UTF-8", "雪", Array("雪\n".utf8))
        ]
        for (index, row) in rows.enumerated() {
            _ = try await repo.run(["config", "i18n.commitencoding", row.0])
            try Data("change \(index)".utf8).write(to: root.appendingPathComponent("file"))
            model.reload(paths: ["."]); try await wait(model); model.checked = ["file"]; model.message = row.1
            model.commit(); try await wait(model)
            let bytes = try await body(repo), history = try await repo.history()
            precondition(bytes == Data(row.2), "Commit message byte mismatch for " + row.0)
            precondition(history.first?.subject == row.1 && model.messageHistory?.entries.first == row.1)
        }
        // The full-index and separate-index amendment engines share the transport.
        _ = try await repo.run(["config", "i18n.commitencoding", "cp1251"])
        try Data("staged".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        model.reload(); try await wait(model); model.stagingEnabled = true; model.message = "Привет"
        model.commit(); try await wait(model)
        let stagedBody = try await body(repo); precondition(stagedBody == Data(rows[2].2))
        _ = try await repo.run(["config", "i18n.commitencoding", "windows-1252"])
        var amend = CommitOptions(); amend.amend = true; amend.amendDiffToLastCommit = false
        _ = try await repo.commitSelected(message: "café €", paths: ["file"], options: amend)
        let amendedBody = try await body(repo); precondition(amendedBody == Data(rows[0].2))
        model.stagingEnabled = false
        // Encoding refusal must precede real index and branch mutation.
        _ = try await repo.run(["config", "i18n.commitencoding", "utf-16"])
        try Data("refused change".utf8).write(to: root.appendingPathComponent("file"))
        model.reload(); try await wait(model); model.checked = ["file"]; model.message = "refused"; model.createBranch = true; model.newBranch = "must-not-exist"
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        model.commit(); try await wait(model, allowError: true); precondition(model.error != nil)
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(index == afterIndex && head == afterHead)
        let branch = try await repo.run(["show-ref", "--verify", "refs/heads/must-not-exist"], successfulExitCodes: 0...128)
        precondition(branch.exitCode != 0)
        // Exercise the native Rebase reader and writer with a real legacy edit pause.
        let rebaseRoot = root.appendingPathComponent("rebase-fixture"); try FileManager.default.createDirectory(at: rebaseRoot, withIntermediateDirectories: true)
        let rebaseRepo = GitRepository(root: rebaseRoot, executable: executable); try await configure(rebaseRepo)
        _ = try await rebaseRepo.run(["config", "i18n.commitencoding", "windows-1252"])
        try Data("base".utf8).write(to: rebaseRoot.appendingPathComponent("base")); try await rebaseRepo.stage(["base"]); _ = try await rebaseRepo.commit(message: "base")
        _ = try await rebaseRepo.run(["branch", "upstream"]); _ = try await rebaseRepo.run(["checkout", "-b", "topic"])
        try Data("edit".utf8).write(to: rebaseRoot.appendingPathComponent("edit")); try await rebaseRepo.stage(["edit"]); _ = try await rebaseRepo.commit(message: "café")
        var options = RebaseOptions(); options.branch = "topic"; options.upstream = "upstream"; options.force = true
        var plan = try await rebaseRepo.rebasePlan(options); plan.entries[0].action = .edit
        let editor = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/TurtleGitMac")
        let stopped = try await rebaseRepo.startRebase(plan, editorExecutable: editor)
        let rawPause = try Data(contentsOf: rebaseRoot.appendingPathComponent(".git/rebase-merge/message"))
        let expectedPause = try CommitMessageEncoding.decode(rawPause, name: "windows-1252")
        precondition(stopped.state.message == expectedPause && expectedPause.trimmingCharacters(in: .newlines) == "café")
        let rebase = RebaseWindowModel(repository: rebaseRepo, access: nil, messageDefaults: defaults); rebase.editorExecutable = editor; rebase.load()
        var deadline = Date().addingTimeInterval(30)
        while rebase.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!rebase.busy && rebase.error == nil && rebase.amendMessage == expectedPause)
        rebase.amendMessage = "café edited"; rebase.request("continue")
        deadline = Date().addingTimeInterval(30)
        while rebase.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!rebase.busy && rebase.error == nil && rebase.finished)
        let edited = try await body(rebaseRepo)
        precondition(edited == Data([0x63,0x61,0x66,0xe9,0x20,0x65,0x64,0x69,0x74,0x65,0x64,0x0a]))
        print("Native Commit: five encoding byte vectors and Unicode history; full-index and separate-index amendment; unsupported encoding preserves index/HEAD and refuses new branch; native Rebase legacy message reader and real edit continuation passed")
    }
}
