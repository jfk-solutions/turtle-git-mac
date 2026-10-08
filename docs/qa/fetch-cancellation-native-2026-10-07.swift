import AppKit
import SwiftUI
import Darwin
import TurtleGitCore

@main struct TransportCancellationVerification {
    @MainActor static func wait(_ model: FetchWindowModel, allowError: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && (allowError || model.error == nil), model.error ?? "Transport timed out")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = root.appendingPathComponent("producer"), client = root.appendingPathComponent("client")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let producer = GitRepository(root: source, executable: git)
        _ = try await producer.run(["init", "-b", "main"])
        _ = try await producer.run(["config", "user.name", "Cancel QA"]); _ = try await producer.run(["config", "user.email", "qa@example.invalid"])
        _ = try await producer.run(["config", "commit.gpgsign", "false"]); _ = try await producer.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base".utf8).write(to: source.appendingPathComponent("file")); try await producer.stage(["file"]); _ = try await producer.commit(message: "base")
        _ = try await producer.run(["clone", source.path, client.path])
        let helper = root.appendingPathComponent("slow-git"), marker = URL(fileURLWithPath: helper.path + ".started")
        let script = """
        #!/bin/sh
        case "${4-}" in
          fetch|pull)
            /bin/sleep 30 &
            task_transport_child=$!
            trap 'kill "$task_transport_child" 2>/dev/null; wait "$task_transport_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_transport_child" > "$0.started"
            wait "$task_transport_child"
            ;;
        esac
        exec \(quote(git.path)) "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let repo = GitRepository(root: client, executable: helper)
        let suite = "TurtleGit.TransportCancellation.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let decoy = Process(); decoy.executableURL = URL(fileURLWithPath: "/bin/sleep"); decoy.arguments = ["30"]; try decoy.run()
        defer { if decoy.isRunning { decoy.terminate() }; decoy.waitUntilExit() }
        for mode in 0..<5 {
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            preferences.set(mode == 1 || mode == 4, forKey: "ConfirmKillProcess")
            let model = FetchWindowModel(repository: repo, access: nil, isPull: mode == 1 || mode == 3, preferences: preferences)
            model.load(); try await wait(model); model.launchRebase = mode == 2
            var callbacks = 0, closes = 0, confirmations = 0
            model.onFetched = { _ in callbacks += 1 }; model.onRebase = { _, _, _ in callbacks += 1 }; model.close = { closes += 1 }
            let index = try Data(contentsOf: client.appendingPathComponent(".git/index"))
            let direct = GitRepository(root: client, executable: git), head = try await direct.run(["rev-parse", "HEAD"]).stdout
            if mode == 3 { model.onProgress = { $0.closeAfterCancellation = true } }
            if mode == 4 { model.onFetchProgress = { $0.closeAfterCancellation = true } }
            model.fetch()
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: marker.path) && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(FileManager.default.fileExists(atPath: marker.path) && model.transportRunning && model.canCancel)
            let pids = try String(contentsOf: marker).split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            precondition(pids.count == 2)
            if mode == 1 || mode == 4 {
                model.confirmCancellation = { choose in confirmations += 1; choose(false) }
                model.cancel(); precondition(model.busy && !model.cancelling && model.canCancel && kill(pids[0], 0) == 0)
                model.confirmCancellation = { choose in confirmations += 1; choose(true) }
            }
            model.cancel(); precondition(model.cancelling && !model.canCancel)
            try await wait(model, allowError: true)
            precondition(!model.transportRunning && model.canCancel && callbacks == 0)
            if mode >= 3 { precondition(model.error == nil && model.progress == nil && model.fetchProgress == nil && closes == 1, "Owned Pull cancellation must finish and close its owner") }
            else { precondition(model.error == "Operation cancelled." && closes == 0) }
            precondition(model.options.remote == "origin" && model.options.branch == "main" && confirmations == (mode == 1 || mode == 4 ? 2 : 0))
            let afterHead = try await direct.run(["rev-parse", "HEAD"]).stdout, afterIndex = try Data(contentsOf: client.appendingPathComponent(".git/index"))
            precondition(head == afterHead && index == afterIndex && decoy.isRunning)
            let stopped = Date().addingTimeInterval(3)
            while kill(pids[1], 0) == 0 && Date() < stopped { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(kill(pids[0], 0) != 0 && kill(pids[1], 0) != 0, "Owned Git/helper process survived")
            if mode < 3 { model.cancel(); precondition(closes == 1) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = NSHostingController(rootView: LogDialogSettings().defaultAppStorage(preferences)); window.contentView?.layoutSubtreeIfNeeded(); window.close()
        print("Pull/Fetch cancellation: actual owned Git/helper stopped for Fetch, Pull and Fetch-before-Rebase; optional confirmation No/Yes; unchanged pre-transport HEAD/index and retained inputs; no success/Rebase callback; unrelated process retained; idle Cancel closes; owned Pull/Fetch policies close result/owner after process cleanup; hidden settings layout passed")
    }
}
