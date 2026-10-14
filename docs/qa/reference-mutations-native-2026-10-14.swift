import AppKit
import TurtleGitCore

@main struct ReferenceMutationsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reference mutation timeout")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Reference mutation QA failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "References QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["commit", "--allow-empty", "-m", "base"])
        _ = try await repo.run(["branch", "topic"])
        _ = try await repo.run(["remote", "add", "origin", root.path])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        _ = try await repo.run(["config", "branch.topic.remote", "origin"])
        _ = try await repo.run(["config", "branch.topic.merge", "refs/heads/main"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let helper = root.appendingPathComponent("gated-reference"), marker = root.appendingPathComponent(".git/reference-ready"), pause = root.appendingPathComponent(".git/reference-pause")
        let script = #"""
        #!/bin/sh
        if [ -f "$3/.git/reference-pause" ]; then
          case "$*" in
            *--unset-all*|*'branch -D'*)
              printf 'Reference: 10%%\rReference: 65%%\r\n'
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\n' "$$" "$task_child" > "$3/.git/reference-ready.pending"
              /bin/mv "$3/.git/reference-ready.pending" "$3/.git/reference-ready"
              wait "$task_child"
              ;;
          esac
        fi
        exec "$TG_REFERENCE_GIT" "$@"
        """#
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_REFERENCE_GIT", git.path, 1); defer { unsetenv("TG_REFERENCE_GIT") }
        let suite = "TurtleGit.ReferenceMutations." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(true, forKey: "ConfirmKillProcess"); defer { prefs.removePersistentDomain(forName: suite) }
        ProgressActionLog.install(store: ActionLogStore(storageURL: root.appendingPathComponent("actions.log")), preferences: prefs)
        for dropping in [true, false] {
            let owner = ReferenceBrowserWindowController(repository: GitRepository(root: root, executable: helper), access: nil, initial: "refs/heads/topic", preferences: prefs) { _ in }
            var pids: [Int32] = []
            defer { owner.close(); for pid in pids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            owner.model.load(); try await wait { !owner.model.busy && owner.model.chosen != nil }
            var refreshes = 0; owner.model.onReferencesChanged = { refreshes += 1 }
            owner.model.confirmDeletion = { _ in true }
            try Data().write(to: pause)
            if dropping { owner.model.unsetTracking() } else { owner.model.deleteChosen() }
            try await wait { FileManager.default.fileExists(atPath: marker.path) && owner.model.renameOutput.contains("Reference: 65%") }
            pids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            try require(pids.count == 2 && pids.allSatisfy { kill($0, 0) == 0 }, "Actual owned reference processes missing")
            try require(!owner.model.renameOutput.contains("Reference: 10%") && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Reference stream/Quit lost")
            var reply: CheckedContinuation<Bool, Never>?
            owner.model.confirmCancellation = { await withCheckedContinuation { reply = $0 } }
            owner.model.cancelRenameOperation(); try await wait { reply != nil }
            reply?.resume(returning: false); reply = nil; try await wait { !owner.model.confirmingCancellation }
            try require(owner.model.busy && pids.allSatisfy { kill($0, 0) == 0 }, "Declined kill cancelled process")
            owner.model.cancelRenameOperation(); try await wait { reply != nil }
            reply?.resume(returning: true); reply = nil
            try await wait { !owner.model.busy && ReferenceBrowserWindowModel.activeMutations == 0 && pids.allSatisfy { kill($0, 0) != 0 } }
            try require(owner.model.mutationCancelled && !owner.model.mutationFailed && refreshes == 1 && owner.model.chosen?.name == "refs/heads/topic", "Cancelled reference operation lost final state/refresh")
            try require(config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Gated cancellation changed config")
            try FileManager.default.removeItem(at: pause); try FileManager.default.removeItem(at: marker)
            owner.close()
        }
        // The real owned deletion confirmation is settled exactly once on forced closure.
        let question = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/topic", preferences: prefs) { _ in }
        defer { question.close() }
        question.model.load(); try await wait { !question.model.busy && question.model.chosen != nil }
        question.model.deleteChosen(); try await wait { question.window?.attachedSheet != nil && question.model.awaitingConfirmation }
        question.close(); try await wait { ReferenceBrowserWindowModel.activeMutations == 0 }
        let refs = try await repo.referenceBrowser()
        try require(question.model.closed && refs.references.contains { $0.name == "refs/heads/topic" }, "Retired confirmation deleted branch or leaked lifetime")
        print("PASS reference mutations: real tracking/deletion streams, carriage returns, declined/accepted cancellation, final refresh, unchanged config/refs, helper cleanup and owned confirmation retirement")
    }
}
