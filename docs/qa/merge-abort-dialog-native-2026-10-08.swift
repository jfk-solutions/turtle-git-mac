import AppKit
import TurtleGitCore

@main struct MergeAbortVerification {
    @MainActor static func waitUntil(_ predicate: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "Native Abort timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Abort QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["switch", "-c", "feature"])
        try Data("theirs\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["switch", "main"])
        try Data("ours\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "ours")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        var options = MergeOptions(); options.revision = "refs/heads/feature"
        let idle = MergeAbortWindowModel(repository: repo, access: nil)
        var comparisons = 0, idleClosed = 0
        idle.onShowModified = { comparisons += 1 }; idle.close = { idleClosed += 1 }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(idle.mode == .merge && !idle.busy && !idle.showingProgress)
        idle.showModified(); idle.close(); idle.invalidate(); idle.showModified(); idle.abort()
        precondition(comparisons == 1 && idleClosed == 1 && !idle.showingProgress)
        let idleIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")); precondition(idleIndex == index)
        var closes = 0, aborts = 0
        let progress = MergeProgressWindowModel(repository: repo, access: nil, options: options, target: .branch, showStashPop: false)
        progress.close = { closes += 1 }; progress.onAbortRequested = { aborts += 1 }
        await progress.run(); precondition(!progress.success && progress.postActions.contains(.resolve))
        let conflict = try Data(contentsOf: root.appendingPathComponent("file"))
        progress.close(); precondition(closes == 1 && aborts == 0)
        let closedFile = try Data(contentsOf: root.appendingPathComponent("file")); precondition(closedFile == conflict)
        progress.cancelResult(); progress.cancelResult(); progress.perform(.stash)
        try await waitUntil { !progress.checkingDismissal }
        precondition(closes == 2 && aborts == 1)
        try Data("resolved\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        progress.cancelResult(); try await waitUntil { !progress.checkingDismissal }
        precondition(closes == 3 && aborts == 1, "Cancel must freshly check resolved conflicts")
        _ = try await repo.run(["reset", "--hard"])
        for mode in MergeAbortMode.allCases {
            do { _ = try await repo.merge(options); preconditionFailure("Expected conflict") } catch is GitFailure {}
            let before = try Data(contentsOf: root.appendingPathComponent("file"))
            try Data("untracked\n".utf8).write(to: root.appendingPathComponent("untracked"))
            let model = MergeAbortWindowModel(repository: repo, access: nil)
            model.mode = mode; var changed = 0, resize: [Bool] = [], action: MergeAbortPostAction?
            model.onChanged = { _ in changed += 1 }; model.onResize = { resize.append($0) }; model.onPostAction = { action = $0 }
            model.abort(); model.mode = mode == .mixed ? .hard : .mixed; model.abort(); model.showModified()
            try await waitUntil { !model.busy }
            precondition(model.success && model.showingProgress && changed == 1 && resize == [true])
            let actualHead = try await repo.run(["rev-parse", "HEAD"]).stdout, conflicts = try await repo.conflicts()
            let after = try Data(contentsOf: root.appendingPathComponent("file"))
            precondition(actualHead == head && conflicts.isEmpty && after == (mode == .mixed ? before : Data("ours\n".utf8)))
            let untracked = try Data(contentsOf: root.appendingPathComponent("untracked")); precondition(untracked == Data("untracked\n".utf8))
            precondition(model.postActions == (mode == .hard ? [.clean] : []))
            if mode == .hard { model.perform(.clean); precondition(action == .clean) }
            _ = try await repo.run(["reset", "--hard"])
        }
        for mode in MergeAbortMode.allCases {
            let lock = root.appendingPathComponent(".git/index.lock")
            try Data().write(to: lock)
            let model = MergeAbortWindowModel(repository: repo, access: nil); model.mode = mode; model.abort()
            try await waitUntil { !model.busy }
            precondition(!model.success && model.postActions == [.retry])
            try FileManager.default.removeItem(at: lock)
            model.perform(.retry)
            if mode == .merge {
                precondition(!model.showingProgress && model.mode == .merge && !model.busy)
                model.abort()
            } else { precondition(model.showingProgress && model.busy) }
            try await waitUntil { !model.busy }; precondition(model.success)
        }
        // Source mixed/hard reset success adds all four Bisect actions when active.
        _ = try await repo.run(["bisect", "start"])
        let mixed = MergeAbortWindowModel(repository: repo, access: nil); mixed.mode = .mixed; mixed.abort()
        try await waitUntil { !mixed.busy }; precondition(mixed.success && mixed.postActions == [.good, .bad, .skip, .reset])
        _ = try await repo.run(["bisect", "reset"])
        precondition(MergeAbortPostAction.good.bisectOperation == .good && MergeAbortPostAction.retry.bisectOperation == nil)
        print("Abort Merge: defaults/comparison/idle nonmutation/invalidation; Cancel vs Close, duplicate dismissal and fresh conflict resolution; all three real reset modes and captured selection; untracked/HEAD preservation; lock failures and mode-specific Retry; active Bisect post-actions. No windows, standard preferences or clipboard writes.")
    }
}
