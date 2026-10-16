import AppKit
import Darwin
import TurtleGitCore

@main struct ChangedFilesRecoveryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<3000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Changed Files recovery timeout at \(line)")
    }
    @MainActor static func views(_ view: NSView?) -> [NSView] { guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) } }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Changed Files recovery failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        func configure(_ repository: GitRepository) async throws {
            _ = try await repository.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Changed Recovery QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        }
        try await configure(repo)
        let original = Data((1...32).map { "copy context \($0)\n" }.joined().utf8)
        try original.write(to: root.appendingPathComponent("source")); try Data("good base\n".utf8).write(to: root.appendingPathComponent("z-good"))
        try await repo.stage(["source", "z-good"]); _ = try await repo.commit(message: "base")
        let base = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try original.write(to: root.appendingPathComponent("a-copy")); try (original + Data("source changed\n".utf8)).write(to: root.appendingPathComponent("source")); try Data("good new\n".utf8).write(to: root.appendingPathComponent("z-good"))
        try await repo.stage(["a-copy", "source", "z-good"]); _ = try await repo.commit(message: "changes")
        let tip = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let suite = "TurtleGit.ChangedRecovery.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "RevertWithRecycleBin"); defer { prefs.removePersistentDomain(forName: suite) }
        var owners: [RevisionComparisonWindowController] = []; defer { owners.forEach { $0.close() } }
        func make(_ repository: GitRepository, from: ComparisonRevision, to: ComparisonRevision) -> RevisionComparisonWindowController {
            let owner = RevisionComparisonWindowController(repository: repository, access: nil, from: from, to: to, preferences: prefs)
            owners.append(owner); owner.window?.alphaValue = 0; owner.window?.orderFront(nil); owner.model.load(); return owner
        }
        func ready(_ model: RevisionComparisonWindowModel) async throws { try await wait { !model.busy && RevisionComparisonWindowModel.activeFileOperations == 0 } }
        func buttons(_ window: NSWindow) -> [NSButton] { views(window.contentView).compactMap { $0 as? NSButton } }
        func text(_ window: NSWindow) -> String { views(window.contentView).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n") }
        func question(_ owner: RevisionComparisonWindowController) async throws -> NSWindow {
            try await wait { owner.window?.attachedSheet != nil }
            let sheet = owner.window!.attachedSheet!
            try require(buttons(sheet).contains { $0.title == "Ignore" } && sheet.defaultButtonCell?.title == "Abort", "Per-file question lost source Ignore/Abort/default")
            try require(text(sheet).contains("a-copy"), "Preparation failure omitted copied path")
            return sheet
        }
        let owner = make(repo, from: .revision(base), to: .revision(tip)), model = owner.model
        try await ready(model); try require(model.error == nil && model.visibleFiles.first { $0.path == "a-copy" }?.action.hasPrefix("C") == true, "Real copy comparison missing")
        var changed = 0; model.onFilesChanged = { changed += 1 }
        // Preparation failure is a source per-file question. Ignore continues
        // to the next selected row; the real result sheet holds its own lifetime.
        model.revertFiles(["a-copy", "z-good"], base: true)
        let first = try await question(owner); buttons(first).first { $0.title == "Ignore" }!.performClick(nil)
        try await wait { owner.window?.attachedSheet != nil && owner.window?.attachedSheet !== first }
        let result = owner.window!.attachedSheet!
        try require(text(result).contains("1 file(s) reverted to " + base) && changed == 1 && model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Partial result/count/Quit ownership missing")
        buttons(result).first { $0.title == "OK" }!.performClick(nil); try await ready(model)
        try require(model.error == nil && Data(contentsOf: root.appendingPathComponent("z-good")) == Data("good base\n".utf8) && Data(contentsOf: root.appendingPathComponent("a-copy")) == original, "Ignore failed to restore only the valid file")
        _ = try await repo.run(["checkout", tip, "--", "z-good"])
        var notices: [String] = []; model.fileActionNotice = { notices.append($0) }
        model.revertFiles(["a-copy", "z-good"], base: true)
        let abort = try await question(owner); buttons(abort).first { $0.title == "Abort" }!.performClick(nil); try await ready(model)
        try require(notices.last == "0 file(s) reverted to \(base)." && changed == 1 && Data(contentsOf: root.appendingPathComponent("z-good")) == Data("good new\n".utf8), "Abort continued to a later file or lost zero-count result")
        // Requested close cancels the pending question and stops before the next
        // file; no late success notice or repeated mutation follows.
        let noticeCount = notices.count; model.revertFiles(["a-copy", "z-good"], base: true); _ = try await question(owner)
        try require(model.cancelFileAction(closeAfter: true), "Owner cancellation bypassed pending operation")
        try await wait { !owner.window!.isVisible && RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(notices.count == noticeCount && Data(contentsOf: root.appendingPathComponent("z-good")) == Data("good new\n".utf8), "Closed question continued mutation/result")
        // Destination export reads only Version 2. Missing Base bytes cannot
        // block an otherwise valid destination file.
        let exportOwner = make(repo, from: .revision(base), to: .revision(tip)); try await ready(exportOwner.model)
        let object = String(decoding: try await repo.run(["rev-parse", base + ":z-good"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let blob = root.appendingPathComponent(".git/objects/" + object.prefix(2) + "/" + object.dropFirst(2)), saved = try Data(contentsOf: blob)
        try FileManager.default.removeItem(at: blob); defer { try? saved.write(to: blob) }
        let folder = root.appendingPathComponent("export"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        exportOwner.model.chooseExportFolder = { folder }; exportOwner.model.exportFiles(["z-good"]); try await ready(exportOwner.model)
        try require(exportOwner.model.error == nil && Data(contentsOf: folder.appendingPathComponent("z-good")) == Data("good new\n".utf8) && !FileManager.default.fileExists(atPath: blob.path), "Version 2 export read the missing Base blob")
        try saved.write(to: blob); exportOwner.close()
        // Root comparisons expose the empty-tree Revert entry. Historical
        // removal clears the selected index entry and retains the working copy.
        let initialRoot = root.appendingPathComponent("initial-repo"); try FileManager.default.createDirectory(at: initialRoot, withIntermediateDirectories: true)
        let initial = GitRepository(root: initialRoot, executable: git); try await configure(initial)
        try Data("initial\n".utf8).write(to: initialRoot.appendingPathComponent("initial")); try await initial.stage(["initial"]); _ = try await initial.commit(message: "root")
        let initialHead = try await initial.run(["rev-parse", "HEAD"]).stdout
        let rootOwner = make(initial, from: .emptyTree, to: .revision("HEAD")); try await ready(rootOwner.model)
        var rootNotices: [String] = []; rootOwner.model.fileActionNotice = { rootNotices.append($0) }
        try require(rootOwner.model.canRevertFiles(["initial"], base: true) && rootOwner.model.revertTitle(base: true) == "Revert to empty tree", "Root empty-tree action absent")
        rootOwner.model.revertFiles(["initial"], base: true); try await ready(rootOwner.model)
        let empty = try await initial.run(["ls-files"]).stdout, afterRootHead = try await initial.run(["rev-parse", "HEAD"]).stdout
        try require(empty.isEmpty && afterRootHead == initialHead && Data(contentsOf: initialRoot.appendingPathComponent("initial")) == Data("initial\n".utf8) && rootNotices.count == 1 && rootNotices[0].hasPrefix("1 file(s) reverted to "), "Root restore changed HEAD/working contents or omitted result")
        rootOwner.close()
        let finalHead = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try require(finalHead == tip && Data(contentsOf: root.appendingPathComponent("a-copy")) == original, "Historical operations moved HEAD or changed copied working file")
        print("PASS: Changed Files per-file preparation Ignore/Abort, ordered counts and owned result/Close, copy Base failure, destination-only missing-Base export and empty-tree root Revert; owned windows closed")
    }
}
