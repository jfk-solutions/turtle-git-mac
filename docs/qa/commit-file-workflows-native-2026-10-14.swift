import AppKit
import TurtleGitCore

@main struct CommitFileWorkflowsVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Commit file workflows timeout at fixture line \(line)")
    }
    @MainActor static func settled(_ model: CommitWindowModel) async throws { try await wait { !model.busy && CommitWindowModel.activeFileOperations == 0 } }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Commit file workflows failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for path in ["one", "two", "old"] { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["one", "two", "old"]); _ = try await repo.commit(message: "base")
        let renamed = "renamed 雪\nfile", unknown = "unversioned 🦎"
        _ = try await repo.run(["mv", "old", renamed])
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("one"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("two"))
        try Data("new\n".utf8).write(to: root.appendingPathComponent(unknown))
        let suite = "TurtleGit.CommitFileWorkflows." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs), model = owner.model
        defer { model.invalidateForClose(); owner.close() }
        model.reload(); try await settled(model)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let single = model.fileMenu(["one"]), missing = model.fileMenu(["two"]), rename = model.fileMenu([renamed])
        try require(single.commands.contains(.openWith) && missing.commands.contains(.blame) && !missing.commands.contains(.open), "Source tracked/missing gates diverged")
        var logs: [String] = []; model.onFileLog = { logs.append($0) }; model.fileAction(.oldNameLog, snapshot: rename)
        try require(logs == ["old"], "Renamed history lost original name")
        model.selection = ["one"]; model.fileAction(.log, snapshot: single)
        try require(logs == ["old"], "Stale menu dispatched after selection change")
        model.selection = []
        var appReply: CheckedContinuation<URL?, Never>?, launched: [String] = []
        let application = root.appendingPathComponent("QA.app")
        model.chooseApplication = { _ in await withCheckedContinuation { appReply = $0 } }
        model.openWorkingFile = { url, app in try require(app == application, "Open With lost captured application"); launched.append(url.lastPathComponent) }
        model.fileAction(.openWith, snapshot: model.fileMenu(["one"]))
        try await wait { appReply != nil }
        try require(model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Pending Open With lost operation/Quit ownership")
        model.selection = ["two"]; appReply?.resume(returning: application)
        try await settled(model); try require(launched.isEmpty, "Late panel retargeted source selection")
        appReply = nil; model.selection = []
        model.fileAction(.openWith, snapshot: model.fileMenu(["one"]))
        try await wait { appReply != nil }; appReply?.resume(returning: application); try await settled(model)
        try require(launched == ["one"], "Valid captured Open With was not delivered")
        let export = root.appendingPathComponent("exported"); try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        model.chooseExportFolder = { _ in export }
        model.fileAction(.export, snapshot: model.fileMenu(["one", renamed])); try await settled(model)
        try require(try Data(contentsOf: export.appendingPathComponent("one")) == Data("changed\n".utf8) && Data(contentsOf: export.appendingPathComponent(renamed)) == Data("base\n".utf8), "Export did not retain captured working bytes/names")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Read-only menu actions changed index")
        model.withFileMenu(model.fileMenu(["one"])) { model.markForRestore(["one"]) }; try await settled(model)
        try require(model.restoreCopies["one"] != nil, "Restoration copy missing")
        try Data("later\n".utf8).write(to: root.appendingPathComponent("one"))
        model.confirmFileRestore = { false }; model.restoreNow(["one"]); try await settled(model)
        try require(try Data(contentsOf: root.appendingPathComponent("one")) == Data("later\n".utf8), "Declined restoration changed data")
        model.confirmFileRestore = { true }; model.restoreNow(["one"]); try await settled(model)
        try require(model.restoreCopies["one"] == nil && Data(contentsOf: root.appendingPathComponent("one")) == Data("changed\n".utf8), "Approved restoration failed")
        model.confirmFileDeletion = { _, _ in false }; model.fileAction(.delete, snapshot: model.fileMenu([unknown]), permanently: true); try await settled(model)
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent(unknown).path), "Declined deletion removed file")
        model.confirmFileDeletion = { _, _ in true }; model.fileAction(.delete, snapshot: model.fileMenu([unknown]), permanently: true); try await settled(model)
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(unknown).path), "Approved permanent deletion failed")
        let versioned = try requireEntry(model, "one")
        model.withFileMenu(model.fileMenu(["one"])) { model.newChangelist([versioned]) }
        model.changelistName = "obsolete"; model.selection = [renamed]; model.createChangelist()
        try require(!model.creatingChangelist, "Stale changelist draft remained open")
        let beforeLists = try await repo.changelists(); try require(beforeLists.assignments["one"] == nil, "Stale name reply changed metadata")
        model.selection = []; model.withFileMenu(model.fileMenu(["one"])) { model.moveToChangelist(["one"], name: "review") }; try await settled(model)
        try require(model.changelists.assignments["one"] == "review", "Captured changelist assignment failed")
        // A real started Git operation cancels and does not release its new refresh early.
        let wrapper = root.appendingPathComponent("slow-git"), marker = root.appendingPathComponent("add-started")
        let script = "#!/bin/sh\nif [ \"$4\" = add ]; then\n /usr/bin/touch " + quote(marker.path) + "\n while :; do /bin/sleep 1; done\nfi\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let delayed = CommitWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        defer { delayed.invalidateForClose() }
        delayed.reload(); try await settled(delayed)
        try require(delayed.commitIdentityPrepared && delayed.error == nil, "Delayed staging owner did not initialize")
        delayed.entries = model.entries
        let refreshedEntries = try await repo.status(refreshIndex: false)
        var refreshReply: CheckedContinuation<[StatusEntry], Never>?
        delayed.queryCommitStatus = { _, _ in await withCheckedContinuation { refreshReply = $0 } }
        delayed.moveToStage(["one"], staged: true); try await wait { FileManager.default.fileExists(atPath: marker.path) }
        try require(delayed.cancelFileOperation(), "Started staging operation could not cancel")
        try await wait { refreshReply != nil && CommitWindowModel.activeFileOperations == 0 }
        try require(delayed.busy, "Completed operation cleared the new refresh's busy state")
        refreshReply?.resume(returning: refreshedEntries)
        try await settled(delayed)
        try require(delayed.error?.contains("cancelled") == true, "Cancellation diagnostic was lost to refresh")
        // Force retirement with a pending panel; its eventual Yes must not launch.
        appReply = nil; model.selection = []
        model.fileAction(.openWith, snapshot: model.fileMenu(["one"]))
        try await wait { appReply != nil }; model.invalidateForClose(); owner.close()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Removed owner released pending reply's Quit guard")
        appReply?.resume(returning: application)
        try await wait { CommitWindowModel.activeFileOperations == 0 }
        try require(launched == ["one"], "Retired panel opened a file")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout; try require(finalHead == head, "File workflows moved HEAD")
        print("Commit file workflows: source marked/missing/rename gates, stale selection/name refusal, captured Open With/export, restore No/Yes, permanent deletion No/Yes, real started stage cancellation, retained diagnostics and late panel/retired Quit ownership passed. Private inputs; owners closed; no external apps launched.")
    }
    @MainActor static func requireEntry(_ model: CommitWindowModel, _ path: String) throws -> StatusEntry {
        guard let entry = model.entries.first(where: { $0.path == path }) else { throw Failure(message: "Missing entry " + path) }; return entry
    }
}
