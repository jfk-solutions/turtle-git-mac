import AppKit
import TurtleGitCore

@main struct LogProgressiveRowsVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Progressive rows timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Progressive rows failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let tree = try await repo.run(["mktree"], input: Data()).text.trimmingCharacters(in: .newlines)
        var hashes: [String] = []
        for i in 0..<130 {
            var args = ["commit-tree", tree]; if let parent = hashes.last { args += ["-p", parent] }
            hashes.append(try await repo.run(args, input: Data("row \(i) 雪\n".utf8)).text.trimmingCharacters(in: .newlines))
        }
        _ = try await repo.run(["update-ref", "refs/heads/main", hashes.last!]); _ = try await repo.run(["notes", "add", "-m", "older note", hashes[0]])
        let wrapper = root.appendingPathComponent("progress-git")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        notes=no
        for arg in "$@"; do if [ "$arg" = --log-size ]; then notes=yes; fi; done
        if [ "$notes" = yes ] && [ -f "$3/slow" ]; then
          if [ -f "$3/first-notes" ]; then : > "$3/waiting"; /bin/sleep 30; else : > "$3/first-notes"; fi
        fi
        exec \(quote(git.path)) "$@"
        """
        try script.write(to: wrapper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slow = GitRepository(root: root, executable: wrapper), suite = "TurtleGit.ProgressiveRows." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = LogWindowController(repository: slow, access: nil, labelDefaults: prefs, savesGeometry: false), model = owner.model
        defer { model.invalidate(); owner.close() }
        model.showWorkingTree = false
        model.reload(); try await wait { !model.busy && model.entries.count == 130 && LogWindowModel.activeHistoryLoads == 0 }
        let baseline = model.entries.map(\.hash), oldGraph = model.graph.count
        try Data().write(to: root.appendingPathComponent("slow")); model.reload()
        try await wait { model.entries.count == 128 && model.loadingHistory && FileManager.default.fileExists(atPath: root.appendingPathComponent("waiting").path) }
        try require(model.busy && model.entries.first?.isHead == true && model.graph.count == 128 && model.entries.last?.hash == hashes[2], "Published prefix lacks metadata/order/graph")
        model.invalidate()
        try await wait { LogWindowModel.activeHistoryLoads == 0 }
        try require(model.entries.map(\.hash) == baseline && model.graph.count == oldGraph && !model.loadingHistory, "Cancelled partial publication did not restore stable snapshot")
        try FileManager.default.removeItem(at: root.appendingPathComponent("slow"))
        model.reload(); try await wait { !model.busy && model.entries.count == 130 && LogWindowModel.activeHistoryLoads == 0 }
        try require(model.entries.map(\.hash) == baseline && model.entries.last?.notes == "older note", "Completed publication lost final metadata/rows")
        model.invalidate(); owner.close()
        print("Progressive Log rows: 128 complete metadata/graph rows visible while older notes still run, actual cancellation and stable-snapshot rollback, complete final ordering/notes and owned cleanup passed. Private repo/preferences.")
    }
}
