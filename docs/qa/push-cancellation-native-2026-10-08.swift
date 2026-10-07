import AppKit
import Darwin
import TurtleGitCore

@main struct PushCancellationVerification {
    @MainActor static func wait(_ model: PushWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Push timed out")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.PushCancellation.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let decoy = Process(); decoy.executableURL = URL(fileURLWithPath: "/bin/sleep"); decoy.arguments = ["30"]; try decoy.run()
        defer { if decoy.isRunning { decoy.terminate() }; decoy.waitUntilExit() }
        for mode in 0..<3 {
            let client = root.appendingPathComponent("client-\(mode)"), destination = root.appendingPathComponent("remote-\(mode).git"), second = root.appendingPathComponent("second-\(mode).git")
            for path in [client, destination, second] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
            let direct = GitRepository(root: client, executable: git), remote = GitRepository(root: destination, executable: git), other = GitRepository(root: second, executable: git)
            _ = try await direct.run(["init", "-b", "main"]); _ = try await remote.run(["init", "--bare"]); _ = try await other.run(["init", "--bare"])
            _ = try await direct.run(["config", "user.name", "Push QA"]); _ = try await direct.run(["config", "user.email", "qa@example.invalid"])
            _ = try await direct.run(["config", "commit.gpgsign", "false"]); _ = try await direct.run(["config", "core.hooksPath", "/dev/null"])
            try Data("base".utf8).write(to: client.appendingPathComponent("file")); try await direct.stage(["file"]); _ = try await direct.commit(message: "base")
            _ = try await direct.run(["tag", "selected"])
            _ = try await direct.run(["remote", "add", "a-good", destination.path]); if mode == 1 { _ = try await direct.run(["remote", "add", "z-slow", second.path]) }
            let helper = root.appendingPathComponent("slow-git-\(mode)"), marker = URL(fileURLWithPath: helper.path + ".started"), release = URL(fileURLWithPath: helper.path + ".release")
            let script = """
            #!/bin/sh
            task_delay=no
            if [ "${4-}" = push ] && [ ! -f "$0.release" ]; then
              case \(mode) in
                0) task_delay=yes ;;
                1) for task_arg in "$@"; do [ "$task_arg" = z-slow ] && task_delay=yes; done ;;
                2) for task_arg in "$@"; do [ "$task_arg" = --tags ] && task_delay=yes; done ;;
              esac
            fi
            if [ "$task_delay" = yes ]; then
              /bin/sleep 30 &
              task_transport_child=$!
              trap 'kill "$task_transport_child" 2>/dev/null; wait "$task_transport_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_transport_child" > "$0.started"
              wait "$task_transport_child"
            fi
            exec \(quote(git.path)) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            preferences.set(mode == 1, forKey: "ConfirmKillProcess")
            let model = PushWindowModel(repository: GitRepository(root: client, executable: helper), access: nil, preferences: preferences)
            model.load(); try await wait(model)
            model.options.remote = "a-good"; model.options.setUpstream = false; model.options.allRemotes = mode == 1
            model.options.allBranches = mode == 2; model.options.includeTags = mode == 2
            var callbacks = 0, closes = 0, confirmations = 0
            model.onPushed = { _ in callbacks += 1 }; model.close = { closes += 1 }
            let index = try Data(contentsOf: client.appendingPathComponent(".git/index")), head = try await direct.run(["rev-parse", "HEAD"]).stdout
            model.push(confirmed: true)
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(FileManager.default.fileExists(atPath: marker.path) && model.transportRunning && model.canCancel)
            let pids = try String(contentsOf: marker).split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }; precondition(pids.count == 2)
            if mode == 1 {
                model.confirmCancellation = { choose in confirmations += 1; choose(false) }
                model.cancel(); precondition(model.busy && !model.cancelling && model.canCancel && kill(pids[0], 0) == 0)
                model.confirmCancellation = { choose in confirmations += 1; choose(true) }
            }
            model.cancel(); precondition(model.cancelling && !model.canCancel); try await wait(model, allowError: true)
            precondition(model.error?.contains("Operation cancelled.") == true && callbacks == 0 && closes == 0 && !model.transportRunning && model.canCancel)
            precondition(model.options.remote == "a-good" && model.options.source == "refs/heads/main" && confirmations == (mode == 1 ? 2 : 0))
            let afterHead = try await direct.run(["rev-parse", "HEAD"]).stdout
            let afterIndex = try Data(contentsOf: client.appendingPathComponent(".git/index"))
            precondition(head == afterHead && index == afterIndex && decoy.isRunning)
            let refs = try await remote.checkoutReferences()
            if mode == 0 { precondition(refs.isEmpty && !(model.error?.contains("Completed:") ?? true)) }
            else {
                let received = try await remote.run(["rev-parse", "refs/heads/main"]).stdout; precondition(received == head)
                precondition(model.error?.contains(mode == 1 ? "Completed: a-good." : "Completed: a-good (branches).") == true)
                precondition(!refs.contains { $0.name.hasPrefix("refs/tags/") })
                if mode == 1 { let otherRefs = try await other.checkoutReferences(); precondition(otherRefs.isEmpty && model.error?.contains("Push to z-slow failed.") == true) }
            }
            let stopped = Date().addingTimeInterval(3)
            while kill(pids[1], 0) == 0 && Date() < stopped { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(kill(pids[0], 0) != 0 && kill(pids[1], 0) != 0, "Owned push/helper survived")
            // Retry the same model with the delay released: a new token must execute.
            try Data().write(to: release); model.push(confirmed: true); try await wait(model)
            precondition(model.error == nil && callbacks == 1 && closes == 1 && !model.transportRunning)
            let received = try await remote.run(["rev-parse", "refs/heads/main"]).stdout; precondition(received == head)
            if mode == 1 { let received = try await other.run(["rev-parse", "refs/heads/main"]).stdout; precondition(received == head) }
            if mode == 2 { let tag = try await remote.run(["rev-parse", "refs/tags/selected"]).stdout; precondition(tag == head) }
            model.cancel(); precondition(closes == 2)
        }
        print("Push cancellation: owned transport/helper stopped, unrelated process retained; optional No/Yes; partial remotes and branches-before-tags reported without rollback; HEAD/index and inputs retained; no success callback after cancellation; same-model retries publish expected refs with fresh tokens; idle Cancel closes")
    }
}
