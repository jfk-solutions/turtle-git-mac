import AppKit
import TurtleGitCore

@main struct MergeConflictHintVerification {
    @MainActor static func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Native hint timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if CommandLine.arguments[1] == "--probe-suppression" {
            precondition(UserDefaults(suiteName: CommandLine.arguments[2])!.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
            print("Fresh process read saved conflict-hint suppression")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        let suite = "TurtleGitMergeHintQA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); preferences.synchronize() }
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Hint QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours")
        var options = MergeOptions(); options.revision = "refs/heads/feature"
        let model = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false, preferences: preferences)
        var acknowledgement: CheckedContinuation<Bool, Never>?, hints = 0, finished = 0
        model.presentConflictHint = { hints += 1; return await withCheckedContinuation { acknowledgement = $0 } }
        model.onChanged = { _ in finished += 1 }
        let operation = Task { await model.run() }
        try await waitUntil { model.confirmingConflictHint && acknowledgement != nil }
        precondition(model.busy && hints == 1 && finished == 0 && model.postActions.isEmpty)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        model.perform(.resolve); model.cancel(); acknowledgement?.resume(returning: false); await operation.value
        precondition(!model.confirmingConflictHint && !model.busy && !model.cancelled && finished == 1 && model.postActions == [.resolve, .commit, .stash])
        precondition(preferences.object(forKey: MergeProgressWindowModel.conflictHintPreference) == nil)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && file == afterFile)
        let second = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false, preferences: preferences)
        second.presentConflictHint = { hints += 1; return true }
        await second.run(); preferences.synchronize(); precondition(hints == 2 && preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
        let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = ["--probe-suppression", suite]
        try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
        let reloaded = UserDefaults(suiteName: suite)!
        let third = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false, preferences: reloaded)
        third.presentConflictHint = { preconditionFailure("Suppressed hint presented") }
        await third.run(); precondition(third.postActions == [.resolve, .commit, .stash])
        _ = try await repo.abortMerge()
        for mode in [MergeAbortMode.mixed, .hard] {
            _ = try await repo.run(["reset", "--hard"])
            do { _ = try await repo.merge(options); preconditionFailure("Expected repeated conflict") } catch is GitFailure {}
            let conflictFile = try Data(contentsOf: root.appendingPathComponent("file"))
            _ = try await repo.abortMerge(mode: mode)
            let resetFile = try Data(contentsOf: root.appendingPathComponent("file")), conflicts = try await repo.conflicts()
            let resetHead = try await repo.run(["rev-parse", "HEAD"]).stdout
            precondition(conflicts.isEmpty && resetHead == head && resetFile == (mode == .mixed ? conflictFile : Data("ours\n".utf8)))
        }
        preferences.removePersistentDomain(forName: suite); preferences.synchronize()
        options.revision = "missing"
        let ordinaryFailure = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .commit, showStashPop: false, preferences: preferences)
        ordinaryFailure.presentConflictHint = { preconditionFailure("Non-conflict failure showed hint") }
        await ordinaryFailure.run(); precondition(!ordinaryFailure.success && !ordinaryFailure.confirmingConflictHint)
        precondition(MergeProgressWindowModel.conflictHint.contains("After resolving all files, you need to perform a commit") && MergeProgressWindowModel.conflictHintPreference == "MergeConflictsNeedsCommit")
        print("Merge conflict hint: real conflict blocks completion/actions until acknowledged, unchecked acknowledgement does not persist suppression or change HEAD/refs/index/working bytes; checked acknowledgement persists to fresh process and suppresses next model; no-conflict failure skips hint; three abort reset modes clear conflicts with source working-tree effects; isolated preferences removed, no windows or standard preferences/clipboard writes")
    }
}
