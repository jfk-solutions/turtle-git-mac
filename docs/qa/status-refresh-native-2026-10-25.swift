// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func statusRefreshOrder(_ mode: NSWindow.OrderingMode, relativeTo number: Int) {
        alphaValue = 0; setFrameOrigin(.init(x: -24000, y: -24000)); statusRefreshOrder(mode, relativeTo: number)
    }
    @objc func statusRefreshConstrain(_ frame: NSRect, to screen: NSScreen?) -> NSRect { frame }
}
@MainActor @main enum StatusRefreshVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Status refresh timeout at \(line)")
    }
    static func drained() -> Bool {
        StatusWindowModel.activeOperations == 0 && CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeMetadataOperations == 0 && CommitWindowModel.activeFileOperations == 0 && CommitWindowModel.activePreferenceOperations == 0
    }
    @MainActor final class Context {
        let base: URL, git: URL, folder: URL, prefs: UserDefaults, suite = "TurtleGit.StatusRefresh." + UUID().uuidString
        var repo: GitRepository!, workspace: RepositoryModel?, owners: [NSWindowController] = []
        var held: CheckedContinuation<[WorkingTreeFile], Error>?
        var head = Data(), index = Data(), config = Data(), indexDate: Date?
        init() {
            base = URL(fileURLWithPath: CommandLine.arguments[1]); git = URL(fileURLWithPath: CommandLine.arguments[2])
            // The production repository factory receives a canonical directory
            // URL. Preserve that form before creation as well as its path bytes.
            folder = URL(fileURLWithPath: base.appendingPathComponent("repository").path, isDirectory: true).resolvingSymlinksInPath(); prefs = UserDefaults(suiteName: suite)!
            prefs.set(false, forKey: "UseLibgit2"); prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "Autocompletion")
            prefs.set(true, forKey: "HintStagingMode"); prefs.set(true, forKey: "Commit.SkipCancelConfirmation")
            prefs.set(true, forKey: "AddBeforeCommit")
        }
        func prepare() async throws {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder"), withIntermediateDirectories: true)
            repo = GitRepository(root: folder, executable: git, askpass: nil, libgit2Configuration: .init(enabled: false))
            _ = try await repo.run(["init", "--template=", "-b", "main"])
            for (key, value) in [("user.name", "Status Refresh QA"), ("user.email", "status@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            for path in ["file", "folder/one", "steady"] { try Data("base\n".utf8).write(to: folder.appendingPathComponent(path)) }
            try await repo.stage(["."]); _ = try await repo.commit(message: "base")
            for path in ["file", "folder/one"] { try Data("working\n".utf8).write(to: folder.appendingPathComponent(path)) }
            // An unchanged tracked file with stale stat data exposes optional
            // index refresh writes, even when its displayed content is clean.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(4)], ofItemAtPath: folder.appendingPathComponent("steady").path)
            head = try await repo.run(["rev-parse", "HEAD"]).stdout
            index = try Data(contentsOf: folder.appendingPathComponent(".git/index")); config = try Data(contentsOf: folder.appendingPathComponent(".git/config"))
            indexDate = try folder.appendingPathComponent(".git/index").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        func own<T: NSWindowController>(_ owner: T) -> T {
            owners.append(owner); owner.window?.isReleasedWhenClosed = false; owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(.init(x: -24000, y: -24000)); owner.showWindow(nil); return owner
        }
        func status() async throws -> StatusWindowController {
            let owner = own(StatusWindowController(repository: repo, access: nil, defaults: prefs))
            owner.model.setScope(["."]); try await StatusRefreshVerification.wait { !owner.model.busy && StatusWindowModel.activeOperations == 0 }
            try StatusRefreshVerification.require(owner.model.error == nil && owner.model.hasStatusSnapshot, "Initial real Status acquisition failed: \(owner.model.error ?? "none")")
            return owner
        }
        func preserved() async throws {
            let actualHead = try await repo.run(["rev-parse", "HEAD"]).stdout
            try StatusRefreshVerification.require(actualHead == head && (try Data(contentsOf: folder.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: folder.appendingPathComponent(".git/config"))) == config, "Display refresh changed HEAD/index/config bytes")
            let actualDate = try folder.appendingPathComponent(".git/index").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            try StatusRefreshVerification.require(actualDate == indexDate, "Display refresh republished Git index stat cache")
        }
        func clean() async {
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            workspace?.stopMonitoringForTermination()
            for owner in owners {
                if let window = owner.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }
                owner.close()
            }
            owners = []
            await workspace?.shutdownFinderPublication(); workspace = nil
            for _ in 0..<3000 { if StatusRefreshVerification.drained() { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            prefs.removePersistentDomain(forName: suite)
        }
    }
    /// A real watcher must remain idle for two full seconds, not merely pass a
    /// predicate in the gap between recurring reads. Bound total settling time.
    static func quiescent(_ workspace: RepositoryModel, _ status: StatusWindowModel, reads: () -> Int) async throws {
        var count = reads(), stable = 0
        for _ in 0..<750 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if reads() == count && !workspace.busy && !status.busy { stable += 1 } else { count = reads(); stable = 0 }
            if stable >= 100 { return }
        }
        throw Failure(description: "Status/Commit display reads kept retriggering real filesystem refresh: \(reads()) Status acquisitions")
    }
    static func monitor(_ c: Context) async throws {
        let snapshot = c.base.appendingPathComponent("private-snapshot.json")
        let workspace = RepositoryModel(startMonitoring: true, initializePreferences: false, repositoryFactory: { _ in c.repo }, snapshotWriter: { value in try JSONEncoder().encode(value).write(to: snapshot, options: .atomic); return true }, snapshotStore: FinderSnapshotStore(url: snapshot), cachePersistenceDefaults: c.prefs)
        c.workspace = workspace; workspace.fileComparisonPreferences = c.prefs; workspace.notifyFinder = {}
        workspace.open(c.folder)
        try await wait { !workspace.busy && workspace.root?.path == c.folder.path }
        try require(workspace.error == nil, "Actual monitored repository adoption failed")
        workspace.activate(.status)
        var owner: StatusWindowController?
        try await wait {
            owner = NSApp.windows.compactMap { $0.delegate as? StatusWindowController }.first { $0.model.repository.root.path == c.folder.path && !$0.model.retired }
            return owner?.model.hasStatusSnapshot == true && owner?.model.busy == false
        }
        guard let owner else { throw Failure(description: "Actual workspace Status controller unavailable") }
        c.owners.append(owner)
        var reads = 0; let productionRead = owner.model.readStatus
        owner.model.readStatus = { token in reads += 1; return try await productionRead(token) }
        owner.model.reload(); try await wait { reads > 0 && !owner.model.busy }
        try await quiescent(workspace, owner.model, reads: { reads })
        let before = reads
        try Data("external mutation\n".utf8).write(to: c.folder.appendingPathComponent("external.txt"))
        do {
            try await wait { !workspace.busy && !owner.model.busy && workspace.entries.contains { $0.path == "external.txt" } && owner.model.files.contains { $0.id == "external.txt" } }
        } catch {
            let workspaceRows = workspace.entries.prefix(20).map { "\($0.path):\($0.index)\($0.worktree)" }.joined(separator: ", ")
            let statusRows = owner.model.files.prefix(20).map { "\($0.id):\($0.entry.index)\($0.entry.worktree)" }.joined(separator: ", ")
            let diagnostic = "External-change diagnostic: root=\(workspace.root?.path ?? "nil") expected=\(c.folder.path) workspaceURL=\(workspace.root?.absoluteString ?? "nil") workspaceDirectory=\(workspace.root?.hasDirectoryPath.description ?? "nil") ownerRoot=\(owner.model.repository.root.path) ownerURL=\(owner.model.repository.root.absoluteString) ownerDirectory=\(owner.model.repository.root.hasDirectoryPath) workspaceBusy=\(workspace.busy) workspaceError=\(workspace.error ?? "nil") finder=\(workspace.finderStatus) workspacePending=\(workspace.hasPendingRepositoryWork) workspaceQuit=\(workspace.confirmingQuit) workspaceRows=[\(workspaceRows)] statusReads=\(reads) before=\(before) statusBusy=\(owner.model.busy) refreshing=\(owner.model.refreshing) statusError=\(owner.model.error ?? "nil") refreshFailure=\(owner.model.refreshFailure ?? "nil") cancelled=\(owner.model.refreshCancelled) retired=\(owner.model.retired) statusScope=\(owner.model.filter.paths) statusRows=[\(statusRows)] externalExists=\(FileManager.default.fileExists(atPath:c.folder.appendingPathComponent("external.txt").path))"
            fputs(diagnostic + "\n", stderr)
            throw error
        }
        try require(reads > before, "Real external file mutation did not refresh Status")
        try await quiescent(workspace, owner.model, reads: { reads })
        // Commit's initial/repeated display reads share this monitored repository;
        // they must not re-seed Status via index-stat writes either.
        workspace.activate(.commit)
        var commit: CommitWindowController?
        try await wait {
            commit = NSApp.windows.compactMap { $0.delegate as? CommitWindowController }.first { $0.model.repository.root.path == c.folder.path && $0.canReuse }
            return commit?.model.hasHead == true && commit?.model.busy == false && CommitWindowModel.activeReloads == 0
        }
        guard let commit else { throw Failure(description: "Actual workspace Commit unavailable") }
        c.owners.append(commit)
        commit.model.reload(paths: ["."]); try await wait { !commit.model.busy && CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeMetadataOperations == 0 }
        try await quiescent(workspace, owner.model, reads: { reads })
        try await c.preserved()
        commit.close(); owner.window?.performClose(nil)
        try await wait { owner.model.retired && !owner.window!.isVisible }
        print("Actual monitor quiescent; external mutation refreshed; Commit display did not feed index writes; idle Status closed")
    }
    static func cancel(_ c: Context) async throws {
        let owner = try await c.status(), model = owner.model, previous = model.files
        model.selection = ["file"]; let selection = model.selection
        var reads = 0
        model.readStatus = { _ in reads += 1; return try await withCheckedThrowingContinuation { c.held = $0 } }
        model.reload(); try await wait { c.held != nil }
        model.requestReload(); model.requestReload()
        try require(!owner.windowShouldClose(owner.window!) && model.cancelling && !model.retired && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Busy close did not cancel and retain the actual worker")
        c.held?.resume(returning: []); c.held = nil
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(reads == 1 && model.files.map(\.entry) == previous.map(\.entry) && model.selection == selection && model.refreshCancelled && !model.retired, "Cancelled read published partial data, restarted its pre-cancel passive queue or auto-closed")
        model.readStatus = { token in reads += 1; return try await c.repo.workingTreeStatus(readPolicy: .automatic, cancellation: token) }
        try Data("later external\n".utf8).write(to: c.folder.appendingPathComponent("later.txt"))
        model.requestReload(); try await wait { !model.busy && model.files.contains { $0.id == "later.txt" } }
        try require(reads == 2 && !model.refreshCancelled, "Later meaningful external refresh was permanently paused")
        try await c.preserved()
        try require(owner.windowShouldClose(owner.window!), "Idle second close was refused")
        owner.window?.performClose(nil); try await wait { model.retired }
    }
    static func scope(_ c: Context) async throws {
        let owner = try await c.status(), model = owner.model, previous = model.files
        var reads = 0
        model.readStatus = { token in
            reads += 1
            if reads == 1 { return try await withCheckedThrowingContinuation { c.held = $0 } }
            return try await c.repo.workingTreeStatus(readPolicy: .automatic, cancellation: token)
        }
        model.reload(); try await wait { c.held != nil }
        model.requestReload(); model.setScope(["folder"])
        try require(model.filter.paths.isEmpty && model.busy && model.cancelOperation(), "Scope was applied to an in-flight snapshot or cancellation unavailable")
        c.held?.resume(returning: previous); c.held = nil
        try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(reads == 2 && model.filter.paths == ["folder"] && model.visibleFiles.map(\.id) == ["folder/one"], "Cancellation lost or duplicated accepted pending scope")
        model.confirmingQuit = true; model.setScope(["file"]); model.requestReload()
        try require(model.filter.paths == ["folder"], "Quit confirmation adopted pending scope early")
        model.confirmingQuit = false; try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try require(reads == 3 && model.filter.paths == ["file"] && model.visibleFiles.map(\.id) == ["file"], "Declining Quit lost accepted scope/refresh")
        model.readStatus = { _ in reads += 1; return try await withCheckedThrowingContinuation { c.held = $0 } }
        model.reload(); try await wait { c.held != nil }; model.requestReload(); owner.close()
        try require(model.retired && StatusWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retired read released ownership before worker drained")
        c.held?.resume(returning: previous); c.held = nil
        try await wait { StatusWindowModel.activeOperations == 0 }
        try require(reads == 4 && model.filter.paths == ["file"], "Retired source launched a queued refresh or replaced scope")
        try await c.preserved()
    }
    static func main() async {
        NSApplication.shared.setActivationPolicy(.accessory)
        method_exchangeImplementations(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!, class_getInstanceMethod(NSWindow.self, #selector(NSWindow.statusRefreshOrder(_:relativeTo:)))!)
        method_exchangeImplementations(class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)))!, class_getInstanceMethod(NSWindow.self, #selector(NSWindow.statusRefreshConstrain(_:to:)))!)
        let c = Context()
        do {
            try await c.prepare()
            switch CommandLine.arguments[3] { case "monitor": try await monitor(c); case "cancel": try await cancel(c); case "scope": try await scope(c); default: throw Failure(description: "Unknown Status refresh case") }
            await c.clean(); try require(drained() && NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil }, "Status refresh owners did not drain/close")
            print("PASS: status refresh " + CommandLine.arguments[3])
        } catch { await c.clean(); fputs("Status refresh failed: \(error)\n", stderr); exit(1) }
    }
}
