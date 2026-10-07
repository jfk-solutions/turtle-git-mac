import AppKit
import TurtleGitCore

@main struct PushSourcePickersVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Picker load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let client = root.appendingPathComponent("client"), bare = root.appendingPathComponent("remote.git")
        for path in [client, bare] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let repo = GitRepository(root: client, executable: git), remote = GitRepository(root: bare, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await remote.run(["init", "--bare"])
        _ = try await repo.run(["config", "user.name", "Picker QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("first".utf8).write(to: client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "first")
        let first = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try Data("second".utf8).write(to: client.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "second")
        _ = try await repo.run(["remote", "add", "origin", bare.path])
        let suite = "TurtleGit.PushSourcePickers.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let push = PushWindowModel(repository: repo, access: nil, preferences: preferences); push.load(); try await wait { push.busy }; precondition(push.error == nil)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: client.appendingPathComponent(".git/index")), config = try Data(contentsOf: client.appendingPathComponent(".git/config"))
        var logs = 0, reflogs = 0
        push.pickSourceLog = { logs += 1 }; push.pickSourceRefLog = { reflogs += 1 }
        push.browseSourceHistory(referenceLog: false); push.browseSourceHistory(referenceLog: true); precondition(logs == 1 && reflogs == 1)
        push.busy = true; push.browseSourceHistory(referenceLog: false); push.busy = false
        push.options.allBranches = true; push.browseSourceHistory(referenceLog: true); push.options.allBranches = false
        push.confirmation = "pending"; push.browseSourceHistory(referenceLog: false); push.confirmation = nil; precondition(logs == 1 && reflogs == 1)
        let source = push.options.source; push.chooseSourceRevision(nil); push.chooseSourceRevision(""); precondition(push.options.source == source)
        let log = LogWindowModel(repository: repo, access: nil, selecting: true, labelDefaults: preferences)
        defer { log.invalidate() }
        push.configureSourceLog(log); try await wait { log.busy || log.loadingActions }
        precondition(log.error == nil && log.endRevision == "main" && !log.allBranches && !log.showWorkingTree && log.historyPaths.isEmpty)
        precondition(log.entries.contains { $0.hash == first } && !log.entries.contains { $0.hash.isEmpty })
        var chosen = 0; log.finishSelection = { entry in chosen += 1; push.chooseSourceRevision(entry?.hash) }
        log.selected = [first]; precondition(log.canAcceptSelection); log.accept(); precondition(chosen == 1 && push.options.source == first)
        // A cancelled picker retains the source and histories, as controller callbacks pass nil.
        push.chooseSourceRevision(nil); precondition(push.options.source == first)
        let reflog = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        reflog.reload(); try await wait { reflog.busy }; precondition(reflog.error == nil)
        guard let entry = reflog.entries.first(where: { $0.hash == first }) else { preconditionFailure("Fixture old HEAD missing") }
        reflog.onChoose = { selected in chosen += 1; push.chooseSourceRevision(selected.hash) }
        reflog.selection = [entry.id]; reflog.accept(); precondition(chosen == 2 && push.options.source == first)
        let deadline = Date().addingTimeInterval(10)
        while push.localBranch != nil && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(push.localBranch == nil && !push.canTrack && !push.canSave && !push.options.setUpstream)
        precondition(preferences.stringArray(forKey: push.urlHistoryKey) == nil && preferences.stringArray(forKey: push.destinationHistoryKey) == nil)
        let beforePush = try await remote.checkoutReferences(); precondition(beforePush.isEmpty)
        let afterSelectionHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterSelectionIndex = try Data(contentsOf: client.appendingPathComponent(".git/index")), afterSelectionConfig = try Data(contentsOf: client.appendingPathComponent(".git/config"))
        precondition(head == afterSelectionHead && index == afterSelectionIndex && config == afterSelectionConfig)
        // Only explicit OK sends the chosen immutable historical commit.
        push.options.destination = "selected-old"; push.options.remote = "origin"; push.push(); try await wait { push.busy }; precondition(push.error == nil)
        let published = try await remote.run(["rev-parse", "refs/heads/selected-old"]).text.trimmingCharacters(in: .newlines)
        precondition(published == first)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: client.appendingPathComponent(".git/index"))
        precondition(afterHead == head && afterIndex == index)
        print("Push source pickers: guarded Log/RefLog menu dispatch, source-scoped selection-only Log without working tree, real historical Log and HEAD RefLog accept callbacks, cancelled selection retention, hash metadata/controls, no history/config/HEAD/index mutation or remote push before OK; explicit OK publishes chosen old commit passed")
    }
}
