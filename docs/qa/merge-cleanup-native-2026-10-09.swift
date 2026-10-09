import AppKit
import TurtleGitCore

@main struct MergeCleanupVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(predicate(), "Timed out")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Merge cleanup failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeCleanup.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        prefs.set(0, forKey: "AutoCloseGitProgress")
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let producer = GitRepository(root: source, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Cleanup QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await producer.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["switch", "-c", "feature"])
        try Data("feature\n".utf8).write(to: source.appendingPathComponent("feature")); try await producer.stage(["feature"]); _ = try await producer.commit(message: "feature")
        _ = try await producer.run(["switch", "main"])
        for stage in ["remote", "config", "validation", "merge", "inspection", "dismissal", "deletion"] {
            let client = root.appendingPathComponent(stage)
            _ = try await producer.run(["clone", source.path, client.path])
            let actual = GitRepository(root: client, executable: git)
            _ = try await actual.run(["branch", "feature", "refs/remotes/origin/feature"])
            let before = try await actual.run(["rev-parse", "HEAD"]).stdout
            let helper = root.appendingPathComponent("slow-" + stage), marker = URL(fileURLWithPath: helper.path + ".started")
            let command = ["validation":"rev-parse", "inspection":"status", "dismissal":"status", "deletion":"branch"][stage] ?? stage
            let quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = """
            #!/bin/sh
            if [ "\(stage)" = inspection ] && [ "${4-}" = merge ]; then exit 1; fi
            if [ "${4-}" = '\(command)' ]; then
              printf 'owned cleanup work\\n'
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            var ids: [Int32] = []
            defer { for pid in ids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            let wrapped = GitRepository(root: client, executable: helper)
            if stage == "remote" || stage == "config" {
                let owner = MergeWindowController(repository: wrapped, access: nil, preferences: prefs)
                defer { owner.close() }
                owner.model.load(revision: "refs/heads/feature")
                try await wait { FileManager.default.fileExists(atPath: marker.path) }
                ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                try require(ids.count == 2 && ids.allSatisfy { kill($0,0) == 0 }, "Metadata process not live")
                owner.close(); try await wait { ids.allSatisfy { kill($0,0) != 0 } }
                try require(owner.model.closed && !owner.model.busy && owner.model.references.isEmpty && owner.model.error == nil, "Closed metadata published")
            } else {
                var options = MergeOptions(); options.revision = "refs/heads/feature"; options.fastForwardOnly = true
                let model = MergeProgressWindowModel(repository: wrapped, access: nil, options: options, target: .branch, showStashPop: false, preferences: prefs)
                let controller = MergeProgressWindowController(model: model)
                defer { controller.close(); model.invalidate() }
                var changes = 0, dispatches = 0, aborts = 0
                model.onChanged = { _ in changes += 1 }; model.onPostAction = { _,_ in dispatches += 1 }; model.onAbortRequested = { aborts += 1 }
                model.start()
                var lateAnswer: ((Bool) -> Void)?
                if stage == "dismissal" || stage == "deletion" {
                    try await wait { !model.busy }
                    try require(model.success, "Setup merge failed")
                    if stage == "dismissal" { model.cancelResult() }
                    else { model.confirmDeletion = { _, answer in lateAnswer = answer }; model.perform(.removeBranch); lateAnswer?(true) }
                } else if stage == "merge" {
                    prefs.set(true, forKey: "ConfirmKillProcess")
                    model.confirmCancellation = { lateAnswer = $0 }
                }
                try await wait { FileManager.default.fileExists(atPath: marker.path) }
                ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                try require(ids.count == 2 && ids.allSatisfy { kill($0,0) == 0 }, "Progress process not live")
                if stage == "merge" { model.cancel(); try require(model.confirmingCancellation, "Missing confirmation") }
                controller.close()
                let frozen = (model.output, model.rawOutput, model.postActions, changes)
                lateAnswer?(true); model.perform(.push); model.cancelResult(); model.start()
                try await wait { ids.allSatisfy { kill($0,0) != 0 } }
                try await Task.sleep(nanoseconds: 100_000_000)
                try require(!model.busy && !model.confirmingCancellation && !model.confirmingDeletion && !model.checkingDismissal, "Closed progress still busy")
                try require(model.output == frozen.0 && model.rawOutput == frozen.1 && model.postActions == frozen.2 && changes == frozen.3 && dispatches == 0 && aborts == 0, "Late completion changed closed progress")
                prefs.set(false, forKey: "ConfirmKillProcess")
            }
            let after = try await actual.run(["rev-parse", "HEAD"]).stdout
            if stage == "dismissal" || stage == "deletion" { try require(after != before, "Completed merge unexpectedly rolled back") }
            else { try require(after == before, "Cancelled pre-merge operation mutated HEAD") }
            let feature = try await actual.run(["show-ref", "--verify", "refs/heads/feature"]).stdout
            try require(!feature.isEmpty, "Cancelled deletion removed branch")
            print("PASS forced Merge cleanup: " + stage)
        }
    }
}
