import AppKit
import TurtleGitCore

@main struct LogHistoryStreamVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Log stream timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch {
            for _ in 0..<500 { if LogWindowModel.activeHistoryLoads==0 { break };try? await Task.sleep(nanoseconds:10_000_000) }
            fputs("Log stream failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Stream QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for index in 0..<3 { _ = try await repo.run(["commit", "--allow-empty", "-m", "row \(index) 雪"]) }
        let wrapper = root.appendingPathComponent("stream-git")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        if [ "$4" = log ] && [ -f "$3/slow" ]; then
          \(quote(git.path)) "$@"
          : > "$3/started"
          /bin/sleep 30
          exit 0
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        try Data().write(to: root.appendingPathComponent("slow"))
        let slow = GitRepository(root: root, executable: wrapper), suite = "TurtleGit.LogStream." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = LogWindowController(repository: slow, access: nil, labelDefaults: prefs, savesGeometry: false), model = owner.model
        model.showWorkingTree = false
        defer { model.invalidate(); owner.close() }
        model.reload()
        try await wait { model.loadedRevisionCount == 3 && model.loadingHistory && model.entries.count==3 }
        try require(model.busy && LogWindowModel.activeHistoryLoads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Incremental walk has no live rows/progress/Quit ownership")
        try require(model.graph.count==3 && model.entries.first?.isHead==true && model.entries.map(\.subject)==["row 2 雪","row 1 雪","row 0 雪"],"Live prefix lacks graph/labels/order")
        model.invalidate()
        try await wait { LogWindowModel.activeHistoryLoads == 0 }
        try require(model.entries.isEmpty && !model.loadingHistory, "Cancelled stream published incomplete rows")
        try FileManager.default.removeItem(at: root.appendingPathComponent("slow"))
        let final = LogWindowController(repository: slow, access: nil, labelDefaults: prefs, savesGeometry: false), next = final.model
        defer { next.invalidate(); final.close() }
        next.showWorkingTree = false; next.reload()
        try await wait { !next.busy && !next.loadingHistory && next.entries.count == 3 && LogWindowModel.activeHistoryLoads == 0 }
        try require(next.error == nil && next.loadedRevisionCount == 3 && next.entries.map(\.subject) == ["row 2 雪", "row 1 雪", "row 0 雪"], "Finished streamed history changed final row order/text")
        owner.close(); final.close()
        print("Log stream: live complete rows/graph/labels and count before Git exit, actual owned process cancellation/retirement/Quit, cancelled prefix rollback and final UTF-8 row/order preserved. Private repo/preferences; owned windows closed.")
    }
}
