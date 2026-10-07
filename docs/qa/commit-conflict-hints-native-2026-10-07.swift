import AppKit
import TurtleGitCore

@main struct ConflictHintVerification {
    @MainActor static func wait(_ model: CommitWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "Commit timed out")
    }
    static func body(_ repo: GitRepository) async throws -> String {
        let object = try await repo.run(["cat-file", "commit", "HEAD"]).text
        return String(object[object.range(of: "\n\n")!.upperBound...])
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Conflict Hint QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["config", "commit.cleanup", "verbatim"])
        let file = root.appendingPathComponent("file")
        try Data("base".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let suite = "TurtleGit.ConflictHints.QA." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        var prompts = 0, commits = 0, events: [String] = [], sequence = 0
        model.onCommitted = { _ in commits += 1 }
        let hint = "Title\n# Conflicts:\n#\tfile"
        @MainActor func prepare(_ message: String, staged: Bool = false) async throws {
            sequence += 1; try Data("change \(sequence)".utf8).write(to: file)
            if staged { try await repo.stage(["file"]) }
            model.reload(); try await wait(model); model.stagingEnabled = staged; model.checked = ["file"]; model.message = message
            model.messageOnly = false; model.createBranch = false
        }
        try await prepare(hint)
        model.issueProperties.warnNoSignedOffBy = true
        model.confirmMissingSignOff = { choose in events.append("sign-off"); choose(.proceed) }
        model.confirmConflictHints = { choose in prompts += 1; events.append("hints"); choose(false, true) }
        model.createBranch = true; model.newBranch = "must-not-exist"
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout, history = model.messageHistory?.entries
        model.commit(); try await wait(model)
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let branch = try await repo.run(["show-ref", "--verify", "refs/heads/must-not-exist"], successfulExitCodes: 0...128)
        precondition(index == afterIndex && head == afterHead && branch.exitCode != 0 && commits == 0)
        precondition(events == ["sign-off", "hints"] && prompts == 1 && model.message == hint && model.messageHistory?.entries == history)
        precondition(!defaults.bool(forKey: "CommitMessageContainsConflictHint"), "Abort must not remember suppression")
        model.confirmMissingSignOff = { choose in choose(.add) }
        model.commit(); try await wait(model)
        let trailer = try await repo.commitSignOffLine()
        let signedDraft = IssueTrackerProperties.addingSignOff(trailer, to: hint)
        let afterSignOffIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterSignOffHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        precondition(model.message == signedDraft && model.messageHistory?.entries == history && commits == 0)
        precondition(afterSignOffIndex == index && afterSignOffHead == head && !defaults.bool(forKey: "CommitMessageContainsConflictHint"))
        model.createBranch = false; model.issueProperties.warnNoSignedOffBy = false
        model.confirmConflictHints = { choose in prompts += 1; choose(true, true) }
        model.commit(); try await wait(model)
        let ignoredBody = try await body(repo)
        precondition(ignoredBody == signedDraft.trimmingCharacters(in: .newlines) + "\n" && prompts == 3 && commits == 1 && defaults.bool(forKey: "CommitMessageContainsConflictHint"))
        try await prepare(hint); model.confirmConflictHints = { _ in preconditionFailure("Remembered Ignore must bypass prompt") }
        model.commit(); try await wait(model); precondition(commits == 2)
        defaults.removeObject(forKey: "CommitMessageContainsConflictHint")
        // Staged commits and message-only amendments must pass the same gate.
        try await prepare(hint, staged: true)
        let stagedIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        model.confirmConflictHints = { choose in prompts += 1; choose(false, false) }
        model.commit(); try await wait(model)
        let cancelledStage = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(stagedIndex == cancelledStage && commits == 2 && prompts == 4)
        model.confirmConflictHints = { choose in prompts += 1; choose(true, false) }
        model.commit(); try await wait(model); precondition(commits == 3 && prompts == 5)
        model.reload(); try await wait(model); model.stagingEnabled = false; model.messageOnly = true; model.amend = true; model.message = hint
        model.confirmConflictHints = { choose in prompts += 1; choose(false, false) }
        model.commit(); try await wait(model); precondition(commits == 3 && prompts == 6)
        model.amend = false; model.messageOnly = false
        // Configured prefix, strip-comments and source core.cleanup exemptions.
        _ = try await repo.run(["config", "core.commentchar", ";"])
        let custom = "Title\n; Conflicts:\n;\tfile"
        try await prepare(custom); model.confirmConflictHints = { choose in prompts += 1; choose(true, false) }
        model.commit(); try await wait(model); precondition(prompts == 7 && commits == 4)
        defaults.set(true, forKey: "StripCommentedLines")
        try await prepare(custom); model.confirmConflictHints = { _ in preconditionFailure("Comment stripping must bypass warning") }
        model.commit(); try await wait(model)
        let stripped = try await body(repo); precondition(stripped == "Title\n" && commits == 5)
        defaults.set(false, forKey: "StripCommentedLines")
        for cleanup in ["verbatim", "whitespace", "scissors"] {
            _ = try await repo.run(["config", "core.cleanup", cleanup]); try await prepare(custom)
            model.commit(); try await wait(model)
            let preserved = try await body(repo); precondition(preserved == custom + "\n")
        }
        precondition(commits == 8 && prompts == 7)
        print("Commit conflict hints: Abort preserves HEAD/index/draft/history and refuses branch; sign-off precedes hints and remains in draft after Abort; Ignore and remembered Ignore; staging and message-only amendment gates; custom prefix, stripping and all cleanup exemptions passed")
    }
}
