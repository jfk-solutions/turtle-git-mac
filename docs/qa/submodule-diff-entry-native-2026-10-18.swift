import AppKit
import TurtleGitCore

@main struct SubmoduleDiffEntryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Diff entry did not settle at \(line)")
    }
    @MainActor static func verify() async throws {
        let container = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = container.appendingPathComponent("parent"), childURL = root.appendingPathComponent("module")
        try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
        let parent = GitRepository(root: root, executable: git), child = GitRepository(root: childURL, executable: git)
        for repo in [parent, child] {
            _ = try await repo.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Diff QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        }
        try Data("child base\n".utf8).write(to: childURL.appendingPathComponent("file")); try await child.stage(["file"]); _ = try await child.commit(message: "child base")
        let childBase = try await child.rebaseCommit("HEAD").hash
        let old = "missing/old [literal]", new = "other missing/new [literal]"
        try FileManager.default.createDirectory(at: root.appendingPathComponent("missing"), withIntermediateDirectories: true)
        try Data("old bytes\n".utf8).write(to: root.appendingPathComponent(old)); try Data("plain base\n".utf8).write(to: root.appendingPathComponent("plain")); try await parent.stage([old, "plain"])
        _ = try await parent.run(["update-index", "--add", "--cacheinfo", "160000," + childBase + ",module"])
        _ = try await parent.commit(message: "attach"); let parentBase = try await parent.rebaseCommit("HEAD").hash
        try Data("child next\n".utf8).write(to: childURL.appendingPathComponent("file")); try await child.stage(["file"]); _ = try await child.commit(message: "child next")
        let childNext = try await child.rebaseCommit("HEAD").hash
        try FileManager.default.createDirectory(at: root.appendingPathComponent("other missing"), withIntermediateDirectories: true)
        _ = try await parent.run(["mv", "--", old, new]); try Data("new bytes\n".utf8).write(to: root.appendingPathComponent(new)); try await parent.stage([new])
        _ = try await parent.run(["update-index", "--cacheinfo", "160000," + childNext + ",module"])
        _ = try await parent.commit(message: "advance"); let parentNext = try await parent.rebaseCommit("HEAD").hash
        try FileManager.default.removeItem(at: root.appendingPathComponent("missing")); try FileManager.default.removeItem(at: root.appendingPathComponent("other missing"))
        try Data("dirty child\n".utf8).write(to: childURL.appendingPathComponent("file"))
        try Data("plain dirty\n".utf8).write(to: root.appendingPathComponent("plain"))
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), childIndex = try Data(contentsOf: childURL.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.DiffEntry." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let changedSuite = suite + ".changed", changedPrefs = UserDefaults(suiteName: changedSuite)!
        defer { prefs.removePersistentDomain(forName: suite); changedPrefs.removePersistentDomain(forName: changedSuite) }
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true }, comparisonMarks: WorkingComparisonMarkStore(storageURL: container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = prefs
        workspace.commandLineRepositoryPermission = { _ in workspace.fileComparisonPreferences = changedPrefs; return RepositoryAccessLease(url: root) }
        var shown: [SubmoduleDiffWindowController] = [], comparisons: [RevisionComparisonSnapshot] = [], unified: [Data] = []
        workspace.submoduleDiffPresentation = { shown.append($0) }
        workspace.fileComparisonPresentation = { snapshot, _ in comparisons.append(snapshot) }
        workspace.commandUnifiedPresentation = { unified.append($0) }
        defer { workspace.stopMonitoringForTermination(); for controller in shown { controller.close() }; for window in NSApp.windows { window.close() } }
        func invoke(_ args: [String], cwd: URL? = nil) { workspace.handleCommandLine(arguments: args, currentDirectory: (cwd ?? root).path) }
        invoke(["--command=diff", "--path", childURL.path, "--submodule"])
        try await wait { shown.count == 1 && !workspace.busy && !shown[0].model.busy }
        let initial = shown[0].model
        let initialContext = "root=\(initial.repository.root.path), rootURL=\(initial.repository.root.absoluteString), expected=\(root.path), expectedURL=\(root.absoluteString), path=\(initial.path), from=\(initial.from), to=\(String(describing: initial.to)), dirty=\(String(describing: initial.details?.dirty)), error=\(String(describing: initial.error))"
        try require(GitReferenceName.equal(initial.repository.root.standardizedFileURL.path, root.standardizedFileURL.path), "Submodule Diff chose the wrong repository: " + initialContext)
        try require(initial.to == nil, "Submodule Diff lost the working-checkout endpoint: " + initialContext)
        try require(initial.details != nil, "Submodule Diff did not load comparison details: " + initialContext)
        try require(initial.details?.dirty == true, "Submodule Diff lost the dirty checkout state: " + initialContext)
        shown[0].model.onLog(child, childBase)
        try await wait { NSApp.windows.contains { ($0.delegate as? LogWindowController)?.model.busy == false } }
        let childLog = NSApp.windows.compactMap { $0.delegate as? LogWindowController }.first!
        try require(childLog.model.colorPreferences === prefs, "Submodule child Log replaced captured command preferences after permission callback")
        childLog.close()
        shown[0].close()
        invoke(["--command=diff", "--path", childURL.path, "--submodule", "--startrev=" + parentBase, "--endrev=" + parentNext])
        try await wait { shown.count == 2 && !workspace.busy && !shown[1].model.busy }
        try require(shown[1].model.details?.from.revision == childBase && shown[1].model.details?.to.revision == childNext && shown[1].model.to == parentNext, "Historical gitlink endpoints lost")
        shown[1].close()
        let zero = String(repeating: "0", count: 40)
        invoke(["--command=diff", "--path", childURL.path, "--submodule", "--startrev=" + zero, "--endrev=" + parentBase])
        try await wait { shown.count == 3 && !workspace.busy && !shown[2].model.busy }
        try require(shown[2].model.from == parentBase && shown[2].model.to == nil && shown[2].model.details?.to.revision == childNext, "Working sentinel did not normalize to child checkout")
        shown[2].close()
        invoke(["--command=diff", "--path", childURL.path, "--submodule", "--startrev=" + zero, "--endrev=" + zero])
        try await wait { shown.count == 4 && !workspace.busy && !shown[3].model.busy }
        try require(shown[3].model.fromIndex && shown[3].model.details?.from.revision == childNext, "Two working sides did not use index gitlink")
        shown[3].close()
        invoke(["--command=diff", "--path", childURL.path, "--submodule", "--unified", "--startrev=" + parentBase, "--endrev=" + parentNext])
        try await wait { unified.count == 1 && !workspace.busy }
        try require(String(decoding: unified[0], as: UTF8.self).contains("Subproject commit " + childNext) && shown.count == 4, "Unified submodule Diff did not use unified patch route")
        invoke(["--command=diff", "--path", root.appendingPathComponent(old).path, "--path2", root.appendingPathComponent(new).path, "--startrev=" + parentBase, "--endrev=" + parentNext, "--unified"])
        try await wait { comparisons.count == 1 && !workspace.busy }
        let snapshot = comparisons[0]
        try require(GitReferenceName.equal(snapshot.root.standardizedFileURL.path, root.standardizedFileURL.path), "Historical path2 chose the wrong snapshot repository: actual=\(snapshot.root.absoluteString), expected=\(root.absoluteString), from=\(snapshot.from.label), to=\(snapshot.to.label)")
        let document: FileComparisonDocument
        do { document = try await GitRepository(root: snapshot.root, executable: git).comparisonFile(snapshot, path: new) }
        catch { throw Failure(description: "Historical path2 snapshot content read failed: root=\(snapshot.root.absoluteString), expected=\(root.absoluteString), from=\(snapshot.from.label), to=\(snapshot.to.label), oldPath=\(String(describing: snapshot.files.first?.oldPath)), path=\(String(describing: snapshot.files.first?.path)), error=\(error)") }
        try require(snapshot.files[0].oldPath == old && snapshot.files[0].path == new && document.base.bytes == Data("old bytes\n".utf8) && document.destination.bytes == Data("new bytes\n".utf8) && unified.count == 1, "Historical path2 endpoint order, missing parent discovery or unified precedence changed")
        invoke(["--command=diff", "--path", root.appendingPathComponent(new).path, "--path2", root.appendingPathComponent(new).path, "--startrev=" + parentNext, "--endrev=" + parentNext])
        try await wait { comparisons.count == 2 && !workspace.busy }
        try require(comparisons[1].files.count == 1, "Identical historical endpoint was discarded")
        invoke(["--command=diff", "--path", childURL.path, "--startrev=" + parentBase, "--endrev=" + parentNext, "--unified"])
        try await wait { !workspace.busy && NSApp.windows.contains { ($0.delegate as? StatusWindowController)?.model.busy == false } }
        try require(shown.count == 4 && unified.count == 1, "Ordinary directory lost ChangedDlg precedence")
        for window in NSApp.windows where window.delegate is StatusWindowController { window.close() }
        let bareURL = container.appendingPathComponent("bare.git"); _ = try await parent.run(["clone", "--bare", root.path, bareURL.path])
        workspace.commandLineRepositoryPermission = { _ in RepositoryAccessLease(url: bareURL) }
        invoke(["--command=diff", "--path", bareURL.appendingPathComponent(old).path, "--path2", bareURL.appendingPathComponent(new).path, "--startrev=" + parentBase, "--endrev=" + parentNext], cwd: bareURL)
        try await wait { comparisons.count == 3 && !workspace.busy }
        try require(GitReferenceName.equal(comparisons[2].root.standardizedFileURL.path, bareURL.standardizedFileURL.path), "Bare historical pair chose the wrong repository: actual=\(comparisons[2].root.absoluteString), expected=\(bareURL.absoluteString), from=\(comparisons[2].from.label), to=\(comparisons[2].to.label), error=\(String(describing: workspace.error))")
        try require(workspace.error == nil, "Bare historical pair reported an error: " + String(describing: workspace.error))
        invoke(["--command=diff", "--path", bareURL.appendingPathComponent(old).path, "--startrev=" + parentBase, "--endrev=" + zero], cwd: bareURL)
        try await wait { !workspace.busy && workspace.error != nil }
        try require(comparisons.count == 3, "Bare working sentinel opened editor")
        workspace.error = nil; workspace.commandLineRepositoryPermission = nil
        invoke(["--command=diff", "--path", root.appendingPathComponent("plain").path, "--submodule"])
        try await wait { comparisons.count == 4 && !workspace.busy }
        try require(shown.count == 4 && comparisons[3].files.first?.path == "plain" && workspace.error == nil, "Submodule flag forced a regular file into gitlink UI")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: childURL.appendingPathComponent(".git/index")) == childIndex, "Comparison changed parent or child index")
        let finalParent = try await parent.rebaseCommit("HEAD").hash, finalChild = try await child.rebaseCommit("HEAD").hash
        try require(finalParent == parentNext && finalChild == childNext, "Comparison changed repository HEAD")
        workspace.stopMonitoringForTermination()
        try await wait { !workspace.hasPendingRepositoryWork && SubmoduleDiffWindowModel.activeReads == 0 && FileListComparisonSession.activeOperations == 0 }
        print("PASS: Submodule Diff entry family: source switches, gitlink ownership, dirty checkout, paired revisions, working/index sentinels, unified precedence, missing historical path2 and identical paths, directory status precedence, bare historical eligibility, read-only HEAD/index and owned cleanup")
    }
    static func main() async {
        do { await MainActor.run { _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited) }; try await verify() }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}
