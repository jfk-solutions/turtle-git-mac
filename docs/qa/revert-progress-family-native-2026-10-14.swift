import AppKit
import TurtleGitCore

@main struct RevertProgressFamilyVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "Revert timeout at line \(line)") }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Revert progress family failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); for (key, value) in [("user.name", "Revert QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let path = "file 雪.txt", file = root.appendingPathComponent(path); try Data("base".utf8).write(to: file); try await repo.stage([path]); _ = try await repo.commit(message: "base"); try Data("changed".utf8).write(to: file)
        let entries = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }, head = try await repo.run(["rev-parse", "HEAD"]).text
        let suite = "TurtleGit.RevertFamily." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!; prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(false, forKey: "ConfirmKillProcess"); defer { prefs.removePersistentDomain(forName: suite) }
        ProgressActionLog.install(store: ActionLogStore(storageURL: root.appendingPathComponent("actions.log")), preferences: prefs)
        let retry = RevertProgressWindowController(repository: repo, access: nil, entries: entries, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { retry.close(); for copy in retry.model.trashedFiles { try? FileManager.default.removeItem(at: copy) } }
        let lock = root.appendingPathComponent(".git/index.lock"); try Data("foreign lock".utf8).write(to: lock)
        retry.model.start(); try await wait { !retry.model.busy }; try require(retry.model.failed && !retry.model.retired && retry.model.trashedFiles.isEmpty, "Lock failure did not retain recoverable result")
        try FileManager.default.removeItem(at: lock); try Data("updated draft".utf8).write(to: file); try await repo.stage([path]); retry.model.retry(); try await wait { !retry.model.busy }
        try require(!retry.model.failed && !retry.model.cancelled && String(contentsOf: file) == "base" && retry.model.trashedFiles.count == 1 && retry.model.clipboardOutput.contains(path), "Fresh Retry lost current status, recovery or output"); retry.close()
        // Captured no-errors policy closes a successful result, without an extra validation run.
        try Data("again".utf8).write(to: file); let again = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }; prefs.set(2, forKey: "AutoCloseGitProgress")
        let automatic = RevertProgressWindowController(repository: repo, access: nil, entries: again, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { automatic.close(); for copy in automatic.model.trashedFiles { try? FileManager.default.removeItem(at: copy) } }
        prefs.set(0, forKey: "AutoCloseGitProgress"); automatic.model.start(); try await wait { RevertProgressWindowModel.activeOperations == 0 }; try require(automatic.model.retired && String(contentsOf: file) == "base", "Captured auto-close preference lost")
        // Real running restore remains protected until its current step finishes.
        try FileManager.default.removeItem(at: file); let missing = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }
        let helper = root.appendingPathComponent("gated-revert"), marker = root.appendingPathComponent(".git/revert-ready"), release = root.appendingPathComponent(".git/revert-release")
        let script = #"""
        #!/bin/sh
        if [ "$4" = restore ];then
          printf 'Restore: 10%%\rRestore: 80%%\r\n'
          : > "$3/.git/revert-ready"
          while [ ! -f "$3/.git/revert-release" ];do /bin/sleep 0.05;done
        fi
        exec "$TG_REVERT_GIT" "$@"
        """#
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path); setenv("TG_REVERT_GIT", git.path, 1); defer { unsetenv("TG_REVERT_GIT") }
        prefs.set(true, forKey: "ConfirmKillProcess")
        let slow = RevertProgressWindowController(repository: GitRepository(root: root, executable: helper), access: nil, entries: missing, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { try? Data().write(to: release); slow.close() }
        var answer: CheckedContinuation<Bool, Never>?, finished = 0
        slow.model.confirmCancellation = { await withCheckedContinuation { answer = $0 } }; slow.model.onFinished = { _, _ in finished += 1 }
        slow.model.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && slow.model.commandOutput.contains("Restore: 80%") }
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")); slow.model.cancel(); try await wait { answer != nil }; answer?.resume(returning: false); answer = nil; try await wait { !slow.model.confirmingCancellation }; try require(slow.model.busy && !slow.model.cancelRequested, "No cancelled protected step")
        slow.model.cancel(); try await wait { answer != nil }; answer?.resume(returning: true); answer = nil; try await wait { slow.model.cancelRequested }
        try require(slow.model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Queued cancellation lost lifetime")
        try Data().write(to: release); try await wait { !slow.model.busy }; try require(slow.model.cancelled && !slow.model.failed && finished == 1 && Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Cancelled protected step published index or lost completion"); slow.close()
        // Forced retirement retains a pending operation and rejects late result callbacks.
        try FileManager.default.removeItem(at: marker); try FileManager.default.removeItem(at: release); try FileManager.default.removeItem(at: file)
        let lateEntries = try await repo.status().filter { ![FileState.untracked, .ignored].contains($0.state) }, late = RevertProgressWindowController(repository: GitRepository(root: root, executable: helper), access: nil, entries: lateEntries, amend: false, againstHead: false, autoCloseSuccess: false, preferences: prefs); defer { try? Data().write(to: release); late.close() }; var lateFinished = 0; late.model.onFinished = { _, _ in lateFinished += 1 }; late.model.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) }; late.close(); let frozen = late.model.commandOutput
        try require(late.model.retired && RevertProgressWindowModel.activeOperations > 0, "Forced closure lost protected lifetime"); try Data().write(to: release); try await wait { RevertProgressWindowModel.activeOperations == 0 }; try require(lateFinished == 0 && late.model.commandOutput == frozen, "Retired result published")
        let after = try await repo.run(["rev-parse", "HEAD"]).text; try require(head == after, "Revert changed HEAD")
        print("PASS Revert family: foreign-lock failure/fresh Retry/Trash recovery, captured auto-close, real CR stream, declined/queued cancellation and protected index, forced-retirement counter/Quit and late-result suppression")
    }
}
