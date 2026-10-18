import AppKit
import TurtleGitCore

private struct MailCommandScope: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}

extension PrimaryCommandsVerification {
    @MainActor static func verifyMailCommands() async throws {
        let container = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), root = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Mail command QA"), ("user.email", "sender@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.rebaseCommit("HEAD")
        try Data("next\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "next")
        _ = try await repo.run(["branch", "topic"])
        let remote = container.appendingPathComponent("remote.git"); _ = try await repo.run(["clone", "--bare", "--", root.path, remote.path])
        let head = try await repo.rebaseCommit("HEAD"), index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let patchBytes = try await repo.run(["format-patch", "-1", "--stdout", "HEAD"]).stdout
        let first = root.appendingPathComponent("first 雪[*]\n.patch"), second = root.appendingPathComponent("second.patch")
        try patchBytes.write(to: first); try patchBytes.write(to: second)
        let suite = "TurtleGit.MailCommands." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(base.hash, forKey: "History.RequestPull." + root.path + ".startrevision")
        prefs.set(true, forKey: "SendMail.Attach"); prefs.set(true, forKey: "SendMail.Combine")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true }, comparisonMarks: WorkingComparisonMarkStore(storageURL: container.appendingPathComponent("marks")))
        workspace.requiresRepositoryScope = false; workspace.fileComparisonPreferences = prefs
        workspace.commandLineRepositoryPermission = { _ in RepositoryAccessLease(url: root) }
        workspace.commandLinePathListPermission = { _, _ in RepositoryAccessLease(url: container) }
        var requests: [RequestPullWindowController] = [], composers: [SendPatchWindowController] = []
        workspace.requestPullPresentation = { requests.append($0) }
        workspace.finderMailPresentation = { if let controller = $0 as? SendPatchWindowController { composers.append(controller) } }
        defer { workspace.stopMonitoringForTermination(); for window in NSApp.windows { window.close() } }
        func invoke(_ args: [String]) { workspace.handleCommandLine(arguments: args, currentDirectory: root.path) }
        let list = container.appendingPathComponent("request-selection"); try Data((root.path + "\0").utf8).write(to: list)
        invoke(["--command=requestpull", "--endrev=topic", "--url", remote.path, "--pathfile", list.path, "--pathfile0", "--deletepathfile"])
        try await wait { !workspace.busy && requests.count == 1 && !requests[0].model.busy }
        let request = requests[0]
        try require(request.model.start == base.hash && request.model.end == "topic" && request.model.repositoryURL == remote.path && !FileManager.default.fileExists(atPath: list.path), "Request Pull lost private history/presets or path-file deletion")
        request.model.end = "edited unresolved"; request.model.repositoryURL = "edited URL"
        invoke(["--command=requestpull", "--endrev=HEAD", "--url=other"])
        try await wait { !workspace.busy }
        try require(requests.count == 1 && request.model.end == "edited unresolved" && request.model.repositoryURL == "edited URL", "Competing Request Pull erased native draft")
        request.model.end = "topic"; request.model.repositoryURL = remote.path
        var generated: URL?
        request.model.presentDocument = { file, mail in generated = file }
        request.model.create(); try await wait { !request.model.busy && generated != nil }
        defer { if let generated { try? FileManager.default.removeItem(at: generated.deletingLastPathComponent()) } }
        let bytes = try Data(contentsOf: generated!)
        try require(String(decoding: bytes, as: UTF8.self).contains("next") && request.model.error == nil, "Request Pull did not generate actual local-remote request")
        request.close()
        let adopted = workspace.root
        let mailList = container.appendingPathComponent("mail-selection")
        try Data((first.path + "\0" + second.path + "\0" + first.path + "\0").utf8).write(to: mailList)
        invoke(["--command=sendmail", "--pathfile", mailList.path, "--pathfile0", "--deletepathfile"])
        try await wait { !workspace.busy && composers.count == 1 && SendPatchWindowModel.activeLoads == 0 }
        let composer = composers[0]
        try require(composer.model.rows.map(\.file.path) == [first.path, second.path, first.path] && composer.model.checked.count == 3, "Send Mail lost orgPathList ordering/duplicates")
        try require(composer.model.attachment && composer.model.combine && workspace.root == adopted && !FileManager.default.fileExists(atPath: mailList.path), "Send Mail lost private preferences, changed checkout or retained deleted list")
        try require(workspace.finderMailWorkflows.count == 1 && workspace.finderMailWorkflows.values.first?.repository.root.path == root.path && workspace.finderMailWorkflows.values.first?.preferences === prefs, "Local sender/presentation context was not captured")
        composer.close(); try await wait { workspace.finderMailWorkflows.isEmpty }
        // No-repository files use an owned private Git-global identity context.
        let outside = container.appendingPathComponent("outside.patch"); try patchBytes.write(to: outside)
        invoke(["--command=sendmail", "--path", outside.path])
        try await wait { !workspace.busy && composers.count == 2 && SendPatchWindowModel.activeLoads == 0 }
        var global: SendMailWorkflow? = workspace.finderMailWorkflows.values.first
        let globalRoot = global!.repository.root
        try require(global!.access == nil && globalRoot.path != root.path && FileManager.default.fileExists(atPath: globalRoot.path) && workspace.root == adopted, "Outside mail borrowed workspace identity or failed private context")
        composers[1].close(); try await wait { workspace.finderMailWorkflows.isEmpty }; global = nil
        try require(!FileManager.default.fileExists(atPath: globalRoot.path), "Completed outside mail retained private context directory")
        // Capture the workspace owner while file inspection waits; ignore an
        // uncooperative reply after close and keep accounting until it drains.
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false; workspace.workspaceWindow = owner
        var inspection: CheckedContinuation<Void, Never>?, inspectionToken: OperationCancellation?
        workspace.mailFileInspection = { _, token in inspectionToken = token; await withCheckedContinuation { inspection = $0 } }
        invoke(["--command=sendmail", "--path", first.path])
        try await wait { inspection != nil && workspace.hasPendingRepositoryWork }
        owner.close(); try await wait { inspectionToken?.isCancelled == true }
        try require(workspace.hasPendingRepositoryWork && workspace.busy, "Owner close dropped mail preflight before drain")
        inspection?.resume(); inspection = nil
        try await wait { !workspace.busy && !workspace.hasPendingRepositoryWork }
        try require(composers.count == 2 && workspace.finderMailWorkflows.isEmpty, "Closed owner accepted late mail inspection")
        workspace.workspaceWindow = nil; workspace.mailFileInspection = nil
        workspace.requiresRepositoryScope = true
        var permission: CheckedContinuation<[RepositoryAccessLease]?, Never>?, permissionToken: OperationCancellation?
        workspace.mailFilePermission = { _, token in permissionToken = token; return await withCheckedContinuation { permission = $0 } }
        invoke(["--command=sendmail", "--path", outside.path])
        try await wait { permission != nil }
        workspace.stopMonitoringForTermination()
        try require(permissionToken?.isCancelled == true && workspace.hasPendingRepositoryWork, "Retirement lost pending mail authorization")
        permission?.resume(returning: [RepositoryAccessLease(url: container, provider: MailCommandScope())]); permission = nil
        try await wait { !workspace.busy && !workspace.hasPendingRepositoryWork }
        try require(composers.count == 2 && workspace.finderMailWorkflows.isEmpty, "Late file grant published mail options after retirement")
        // A linked sender needs its working folder and external common metadata.
        let linked = container.appendingPathComponent("linked")
        var worktreeOptions = WorktreeCreationOptions(); worktreeOptions.detach = true
        _ = try await repo.createWorktree(at: linked, options: worktreeOptions)
        let linkedPatch = linked.appendingPathComponent("linked.patch"); try patchBytes.write(to: linkedPatch)
        let scoped = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true })
        scoped.requiresRepositoryScope = true; scoped.fileComparisonPreferences = prefs
        defer { scoped.stopMonitoringForTermination() }
        var grantRequests: [[URL]] = [], linkedComposer: SendPatchWindowController?
        scoped.mailFilePermission = { targets, _ in
            grantRequests.append(targets)
            return [RepositoryAccessLease(url: grantRequests.count == 1 ? linked : root, provider: MailCommandScope())]
        }
        scoped.finderMailPresentation = { linkedComposer = $0 as? SendPatchWindowController }
        scoped.handleCommandLine(arguments: ["--command=sendmail", "--path", linkedPatch.path], currentDirectory: container.path)
        try await wait { !scoped.busy && linkedComposer != nil && SendPatchWindowModel.activeLoads == 0 }
        let sender = scoped.finderMailWorkflows.values.first!
        try require(grantRequests.count == 2 && sender.access?.contains(linked) == true && sender.access?.permits(root.appendingPathComponent(".git/config")) == true && scoped.root == nil, "Linked sender lost separately authorized metadata or changed checkout")
        linkedComposer?.close(); linkedComposer = nil
        try await wait { scoped.finderMailWorkflows.isEmpty }
        scoped.mailFilePermission = { _, _ in [] }
        scoped.handleCommandLine(arguments: ["--command=sendmail", "--path", outside.path], currentDirectory: container.path)
        try await wait { !scoped.busy }
        try require(scoped.error != nil && scoped.finderMailWorkflows.isEmpty, "Uncovered mail permission accepted")
        scoped.mailFilePermission = { _, _ in nil }
        scoped.handleCommandLine(arguments: ["--command=sendmail", "--path", outside.path], currentDirectory: container.path)
        try await wait { !scoped.busy }
        try require(scoped.finderMailWorkflows.isEmpty, "Cancelled mail permission opened composer")
        // Upstream admits every original list entry before reading checked
        // files. A missing/directory entry can be unchecked to send the valid file.
        let mixed = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in true })
        mixed.requiresRepositoryScope = false; mixed.fileComparisonPreferences = prefs
        defer { mixed.stopMonitoringForTermination() }
        var mixedComposer: SendPatchWindowController?, selectedRequest: SendPatchRequest?
        mixed.finderMailPresentation = { mixedComposer = $0 as? SendPatchWindowController }
        let absent = container.appendingPathComponent("missing.patch")
        mixed.handleCommandLine(arguments: ["--command=sendmail", "--path", root.path, "--path", first.path, "--path", absent.path], currentDirectory: container.path)
        try await wait { !mixed.busy && mixedComposer != nil && SendPatchWindowModel.activeLoads == 0 }
        let mixedOptions = mixedComposer!
        try require(mixedOptions.model.rows.map(\.file.path) == [root.path,first.path,absent.path] && mixedOptions.model.checked.count == 3, "Unusable original entries were rejected or silently filtered")
        try require(mixed.finderMailWorkflows.values.first?.repository.root.path == root.path, "First directory entry failed to supply its repository sender context")
        mixedOptions.model.setChecked([mixedOptions.model.rows[1].id])
        mixedOptions.model.to = "to@example.invalid"; mixedOptions.model.combinedSubject = "Mixed selection"
        mixedOptions.model.onSubmit = { selectedRequest = $0 }
        mixedOptions.model.submit()
        try await wait { selectedRequest != nil && SendPatchWindowModel.activeLoads == 0 && mixed.finderMailWorkflows.isEmpty }
        try require(selectedRequest?.files.map(\.path) == [first.path] && selectedRequest?.messages.count == 1 && mixedOptions.model.error == nil, "Unchecked unusable paths prevented valid checked-file preparation")
        let finalHead = try await repo.rebaseCommit("HEAD")
        try require(finalHead.hash == head.hash && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: root.appendingPathComponent("file"))) == Data("next\n".utf8), "Mail entry changed source HEAD/index/file")
        try await wait { RequestPullWindowModel.activeOperations == 0 && SendPatchWindowModel.activeLoads == 0 }
        print("PASS: Mail command family: Request Pull presets/private history/draft preservation and real local request; ordered duplicate Send Mail path-file inputs; owning settings/local/global sender contexts and cleanup; captured owner/retirement preflight cancellation/drain; linked sender metadata grants; wrong/cancelled permissions; unusable original entries remain selectable and unchecked entries do not block preparation; workspace and source Git state preserved. No delivery, mail client or public service activated.")
    }
}
