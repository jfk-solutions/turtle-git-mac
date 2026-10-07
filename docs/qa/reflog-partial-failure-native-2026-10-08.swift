import AppKit
import TurtleGitCore

@main struct ReferenceLogPartialFailureVerification {
    @MainActor static func wait(_ model: ReferenceLogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy)
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), direct = GitRepository(root: root, executable: git)
        _ = try await direct.run(["init", "-b", "main"])
        _ = try await direct.run(["config", "user.name", "Failure QA"]); _ = try await direct.run(["config", "user.email", "qa@example.invalid"])
        _ = try await direct.run(["config", "commit.gpgsign", "false"]); _ = try await direct.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<4 { try Data("commit \(n)".utf8).write(to: root.appendingPathComponent("file")); try await direct.stage(["file"]); _ = try await direct.commit(message: "commit \(n)") }
        let wrapper = root.appendingPathComponent("fail-delete.sh"), calls = root.appendingPathComponent("calls"), mode = root.appendingPathComponent("mode")
        let script = """
        #!/bin/sh
        if { [ "$4" = reflog ] && [ "$5" = delete ]; } || { [ "$4" = stash ] && [ "$5" = drop ]; }; then
          printf '%s\\n' "$7" >> \(quote(calls.path))
          if [ -f \(quote(mode.path)) ]; then
            if [ "$(cat \(quote(mode.path)))" = all ] || [ "$7" = 'HEAD@{2}' ] || [ "$7" = 'refs/stash@{2}' ]; then echo 'injected failure: 雪' >&2; exit 77; fi
          fi
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let model = ReferenceLogWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, reference: "HEAD")
        model.confirmDelete = { _, _, proceed in proceed() }; model.reload(); try await wait(model); let rows = model.entries
        let head = try await direct.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        var refreshed = 0, failures: [String] = []
        model.onChanged = { _ in refreshed += 1 }
        model.presentDeletionFailure = { issue in
            await MainActor.run { precondition(model.busy && issue.details.contains("雪")); failures.append(issue.selector) }
            // Async per-error acknowledgement completes before the next deletion starts.
            try? await Task.sleep(nanoseconds: 10_000_000)
            let attempted = try! String(contentsOf: calls).split(separator: "\n").map(String.init)
            precondition(attempted == ["HEAD@{3}", "HEAD@{2}"])
        }
        try "middle".write(to: mode, atomically: true, encoding: .utf8)
        model.delete(Set(rows.map(\.id))); try await wait(model)
        precondition(model.error == nil && model.deletionReport?.contains("Deleted entries: 3. Failed entries: 1.") == true && failures == [rows[2].id] && refreshed == 1)
        precondition(model.entries.map(\.subject) == [rows[2].subject])
        let attempts = try String(contentsOf: calls).split(separator: "\n").map(String.init); precondition(attempts == rows.reversed().map(\.id))
        try FileManager.default.removeItem(at: mode); model.delete(Set(model.entries.map(\.id))); try await wait(model)
        precondition(model.error == nil && model.deletionReport == nil && model.entries.isEmpty && refreshed == 2)
        // All-failed batches still refresh and retain all rows; headless callers get the summary error.
        _ = try await direct.run(["reset", "--soft", "HEAD"]); _ = try await direct.run(["reset", "--soft", "HEAD"])
        model.reload(); try await wait(model); let allRows = model.entries
        model.presentDeletionFailure = nil; try "all".write(to: mode, atomically: true, encoding: .utf8)
        model.delete(Set(allRows.map(\.id))); try await wait(model)
        precondition(model.entries == allRows && model.error?.contains("Deleted entries: 0. Failed entries: 2.") == true && refreshed == 3)
        let afterHead = try await direct.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && index == afterIndex && config == afterConfig && file == afterFile)
        try FileManager.default.removeItem(at: mode)
        for n in 0..<4 { try Data("stash \(n)".utf8).write(to: root.appendingPathComponent("file")); _ = try await direct.saveStash(StashSaveOptions()) }
        model.reference = "refs/stash"; model.reload(); try await wait(model); let stashes = model.entries
        try "middle".write(to: mode, atomically: true, encoding: .utf8); model.delete(Set(stashes.map(\.id))); try await wait(model)
        precondition(model.entries.map(\.hash) == [stashes[2].hash] && model.error?.contains("Deleted entries: 3. Failed entries: 1.") == true && refreshed == 4)
        try FileManager.default.removeItem(at: mode); model.delete(Set(model.entries.map(\.id))); try await wait(model)
        precondition(model.entries.isEmpty && model.error == nil && model.deletionReport == nil && refreshed == 5)
        print("RefLog partial failure: real HEAD/stash batches continue after middle command failure, async per-error acknowledgement precedes next command, complete/failed selectors and Unicode diagnostics retained, partial/all-failed refresh and retry reset, ordinary HEAD/index/config/worktree preserved passed; no displayed UI")
    }
}
