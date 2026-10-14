import AppKit
import TurtleGitCore

@main struct AdvancedListConsumersVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Advanced list consumer timeout")
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Advanced list consumers failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for i in 0..<4 { try Data("base\n".utf8).write(to: root.appendingPathComponent("file-\(i)")) }
        try await repo.stage((0..<4).map { "file-\($0)" }); _ = try await repo.commit(message: "base")
        for i in 0..<4 { try Data("changed\n".utf8).write(to: root.appendingPathComponent("file-\(i)")) }
        let suite = "TurtleGit.AdvancedList." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(3, forKey: "LogTooManyItemsThreshold"); prefs.set(3, forKey: "NumDiffWarning")
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { log.invalidate() }
        log.files = try await repo.workingTreeFiles()
        try require(log.hidesTooManyFiles && log.visibleFiles.isEmpty && log.fileTableRows.isEmpty && log.files.count == 4, "Large-list threshold did not suppress rows while retaining metadata")
        prefs.set(4, forKey: "LogTooManyItemsThreshold")
        try require(!log.hidesTooManyFiles && log.visibleFiles.count == 4, "Threshold equality should display files")
        let owner = RevisionComparisonWindowController(repository: repo, access: nil, from: .revision("HEAD"), to: .workingTree, preferences: prefs), model = owner.model
        defer { model.invalidate(); owner.close() }
        model.load(); try await wait { !model.busy && model.snapshot?.files.count == 4 }
        let ids = Set(model.visibleFiles.map(\.path)); var questions = 0, opened: [String] = []
        model.confirmManyDiffs = { count in questions += 1; try! require(count == 4, "Warning lost captured count"); return false }
        model.openComparedFile = { _, file in opened.append(file.path) }
        model.compare(ids); try await wait { !model.busy && RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(questions == 1 && opened.isEmpty, "No opened comparison windows")
        model.confirmManyDiffs = { _ in questions += 1; return true }
        model.compare(ids); try await wait { !model.busy && RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(questions == 2 && Set(opened) == ids, "Yes lost selected comparison targets")
        prefs.set(4, forKey: "NumDiffWarning"); model.compare(ids)
        try await wait { !model.busy && RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(questions == 2 && opened.count == 8, "Threshold equality unexpectedly warned")
        prefs.set(3, forKey: "NumDiffWarning"); var reply: CheckedContinuation<Bool, Never>?
        model.confirmManyDiffs = { _ in await withCheckedContinuation { reply = $0 } }; model.compare(ids)
        try await wait { reply != nil }
        try require(model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Pending warning lost Quit ownership")
        model.invalidate(); reply?.resume(returning: true)
        try await wait { RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(opened.count == 8, "Late Yes opened retired comparisons")
        owner.close()
        print("Advanced list consumers: strict large-file cutoff/equality, captured multi-diff No/Yes/equality, no retargeted launch after retirement and pending question/Quit lifetime passed. Private settings/repository; native owner closed.")
    }
}
