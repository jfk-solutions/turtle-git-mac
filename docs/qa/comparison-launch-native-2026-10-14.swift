import AppKit
import TurtleGitCore

@main struct ComparisonLaunchVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Comparison launch timeout at fixture line \(line), active launches \(FileListComparisonSession.activeOperations)")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Comparison launch failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let paths = ["one", "two", "three", "four 雪\nfile"]
        for path in paths { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "base")
        for path in paths { try Data("changed\n".utf8).write(to: root.appendingPathComponent(path)) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.ComparisonLaunch." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(3, forKey: "NumDiffWarning")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        var questions: [Int] = [], opened: [(RevisionComparisonSnapshot, CommitFile)] = []
        workspace.fileComparisonPresentation = { opened.append(($0, $1)) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        workspace.fileComparisonQuestion = { questions.append($0); return false }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4] && opened.isEmpty && workspace.error == nil, "Working/Commit decline launched viewers or failed")
        workspace.fileComparisonQuestion = { questions.append($0); return true }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        workspace.selection = ["not selected"]
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4, 4] && Set(opened.map { $0.1.path }) == Set(paths), "Working/Commit approval retargeted selected paths")
        opened = []
        workspace.showGroupedHistoricalFiles(repository: repo, access: nil, requests: [(.revision("HEAD"), .workingTree, Array(paths.prefix(2))), (.emptyTree, .revision("HEAD"), Array(paths.suffix(2)))], owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4, 4, 4] && opened.count == 4 && opened.prefix(2).allSatisfy { $0.0.to == .workingTree } && opened.suffix(2).allSatisfy { $0.0.from == .emptyTree }, "Log groups prompted separately or lost endpoints")
        opened = []; prefs.set(4, forKey: "NumDiffWarning")
        workspace.showHistoricalFiles(repository: repo, access: nil, from: .revision("HEAD"), to: .workingTree, paths: paths, owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions.count == 3 && opened.count == 4, "Historical threshold equality warned")
        opened = []; prefs.set(3, forKey: "NumDiffWarning")
        var reply: CheckedContinuation<Bool, Never>?
        workspace.fileComparisonQuestion = { _ in await withCheckedContinuation { reply = $0 } }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        try await wait { reply != nil }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Pending question did not own Quit")
        owner.close(); reply?.resume(returning: true)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(opened.isEmpty && workspace.error == nil, "Retired approval launched viewers")
        // A real owned alert ends on forced source-window close, independently of injection.
        let sheetOwner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheetOwner.isReleasedWhenClosed = false; defer { sheetOwner.close() }
        workspace.fileComparisonQuestion = nil
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: sheetOwner)
        try await wait { sheetOwner.attachedSheet != nil }
        sheetOwner.close()
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 && sheetOwner.attachedSheet == nil }
        try require(opened.isEmpty, "Closing owned question launched comparisons")
        // Cancellation after an owned Git child really starts, with no receiver restart.
        let marker = root.appendingPathComponent("read-started"), wrapper = root.appendingPathComponent("slow-git")
        let script = "#!/bin/sh\nif [ \"$4\" = rev-parse ]; then\n /usr/bin/touch " + quote(marker.path) + "\n while :; do /bin/sleep 1; done\nfi\nexec " + quote(executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let readOwner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        readOwner.isReleasedWhenClosed = false; defer { readOwner.close() }
        workspace.showWorkingFiles(repository: GitRepository(root: root, executable: wrapper), access: nil, paths: [paths[0]], owner: readOwner)
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        readOwner.close()
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(opened.isEmpty && workspace.error == nil, "Closed source read published a viewer/error")
        // A child viewer also owns and cancels its historical blob read.
        try FileManager.default.removeItem(at: marker)
        let blobScript = "#!/bin/sh\nif [ \"$4\" = ls-tree ]; then\n /usr/bin/touch " + quote(marker.path) + "\n while :; do /bin/sleep 1; done\nfi\nexec " + quote(executable.path) + " \"$@\"\n"
        try Data(blobScript.utf8).write(to: wrapper)
        let snapshot = try await repo.revisionFileComparison(from: .revision("HEAD"), to: .workingTree, paths: [paths[0]])
        let viewer = FileComparisonWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, snapshot: snapshot, path: paths[0])
        viewer.comparisonDefaults = prefs; viewer.load()
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        viewer.retireImageLoader()
        try await wait { !viewer.busy && FileListComparisonSession.activeOperations == 0 }
        try require(viewer.document == nil && viewer.error == nil, "Retired blob read published a document/error")
        // Aggregated status-list GNU patches stay one captured patch, without a many-viewer warning.
        let commit = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        defer { commit.invalidateForClose() }
        commit.entries = try await repo.status(refreshIndex: false)
        var commitPatch = Data(); commit.onUnifiedDiff = { bytes, alternate in try require(alternate, "Commit lost Shift choice"); commitPatch = bytes }
        commit.diff(paths: Set(paths), staged: false, alternate: true)
        try await wait { !commit.busy && FileListComparisonSession.activeOperations == 0 }
        try require(commit.error == nil && commitPatch.range(of: Data("+changed".utf8)) != nil, "Commit patch route failed")
        let status = StatusWindowModel(repository: repo, access: nil, defaults: prefs)
        defer { status.invalidate() }
        status.files = try await repo.workingTreeStatus(refreshIndex: false)
        var statusPatch = Data(); status.onUnifiedDiff = { bytes, _ in statusPatch = bytes }
        status.unifiedDiff(Set(paths), alternate: false)
        try await wait { !status.busy && StatusWindowModel.activeOperations == 0 && FileListComparisonSession.activeOperations == 0 }
        try require(status.error == nil && statusPatch == commitPatch, "Working Tree aggregated patch diverged")
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { log.invalidate() }
        let entries = try await repo.history(); log.entries = entries; log.selected = [entries[0].hash]
        log.files = try await repo.files(in: entries[0]); var logPatch = Data()
        log.onUnifiedDiff = { bytes, _ in logPatch = bytes }
        log.selectedFileDiff(Set(log.files.map(\.id)))
        try await wait { !log.busy && FileListComparisonSession.activeOperations == 0 }
        try require(log.error == nil && logPatch.range(of: Data("+base".utf8)) != nil, "Log selected-file patch route failed")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Comparison routes modified index")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head, "Comparison routes modified HEAD")
        for path in paths { try require(try Data(contentsOf: root.appendingPathComponent(path)) == Data("changed\n".utf8), "Comparison routes modified working bytes") }
        print("Comparison launch: captured working/historical/grouped targets, No/Yes/equality, pending question/Quit, late approval refusal, actual owned sheet teardown and started Git cancellation; Commit/Working Tree/Log patch routes and repository preservation passed. Owners closed; no external viewers launched.")
    }
}
