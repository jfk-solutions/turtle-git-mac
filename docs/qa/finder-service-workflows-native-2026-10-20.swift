// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

private struct FinderWorkflowScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
@main struct FinderServiceWorkflowsVerification {
    static let commands = ["fetch", "pull", "push", "synchronize", "branch", "tag", "switchBranch", "merge", "rebase", "stash", "stashApply", "stashPop", "stashList"]
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var diagnostic: () -> String = { "" }
    static func require(_ value: Bool, _ message: String, line: UInt = #line) throws { if !value { throw Failure(description: "\(line): \(message)") } }
    @MainActor static func wait(_ message: String, line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "\(line): \(message): \(diagnostic())")
    }
    @MainActor static func board(_ urls: [URL]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.writeObjects(urls.map { url -> NSPasteboardItem in let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item })
        return board
    }
    @MainActor static func invoke(_ provider: TurtleGitFinderServicesProvider, _ board: NSPasteboard, _ command: String) -> NSString? {
        var error: NSString?; provider.performFinderAction(board, userData: command, error: &error); return error
    }
    @MainActor static func provider() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), selection = board([root])
        defer { selection.releaseGlobally() }
        var packets: [FinderRequest] = []
        let provider = TurtleGitFinderServicesProvider { packets.append($0) }
        defer { provider.retire() }
        let initial = selection.changeCount
        for command in commands {
            try require(invoke(provider, selection, command) == nil, "provider rejected \(command)")
            try require(packets.last?.action.rawValue == command && packets.last?.paths.map(\.path) == [root.path], "provider changed \(command) selected repository")
        }
        try require(packets.count == commands.count && selection.changeCount == initial, "provider mutated pasteboard or duplicated dispatch")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
        let services = plist["NSServices"] as? [[String: Any]] ?? []
        try require(services.count == FinderServiceCommand.allCases.count && Set(services.compactMap { $0["NSUserData"] as? String }) == Set(FinderServiceCommand.allCases.map(\.rawValue)), "plist/provider commands differ")
        for command in commands {
            let matching = services.filter { $0["NSUserData"] as? String == command }
            try require(matching.count == 1 && matching[0]["NSMessage"] as? String == "performFinderAction", "missing/duplicate ObjC Services selector for \(command)")
            try require((matching[0]["NSMenuItem"] as? [String: String])?["default"]?.contains("TurtleGit") == true, "unbranded Service \(command)")
        }
        for command in ["fetch", "branch", "stashList"] {
            let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, snapshotWriter: { _ in false })
            let delegate = TurtleGitApplicationDelegate(); delegate.startupArguments = []
            var sequence: [String] = []
            delegate.startupCommandHandler = { _, _, _ in sequence.append("startup") }
            delegate.workspaceServiceHandler = { model, request in if model === workspace { sequence.append(request.action.rawValue) }; return true }
            defer { delegate.retireFinderServices(); workspace.stopMonitoringForTermination() }
            try require(invoke(delegate.finderServicesProvider, selection, command) == nil && sequence.isEmpty, "cold \(command) escaped queue")
            delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
            try require(sequence == ["startup", command] && delegate.pendingFinderServiceRequest == nil, "cold \(command) was not delivered exactly once after startup")
            workspace.busy = true
            try require(invoke(delegate.finderServicesProvider, selection, command) != nil && sequence == ["startup", command], "busy \(command) queued unexpectedly")
        }
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        try Data("base\n".utf8).write(to: base); try Data("mine\n".utf8).write(to: mine)
        let tool = TurtleGitApplicationDelegate(); tool.startupArguments = ["--merge-tool", "--base", base.path, "--mine", mine.path, "--readonly"]; tool.startupDirectory = root.path
        var handed: [URL] = [], completion: ((Error?) -> Void)?
        tool.workspaceOpenHandoff.launch = { urls, _, configuration, reply in
            handed = urls; completion = reply
            precondition(configuration.createsNewApplicationInstance && configuration.arguments.isEmpty)
        }
        defer { tool.retireFinderServices(); tool.workspaceOpenHandoff.retire(); completion?(nil) }
        try require(invoke(tool.finderServicesProvider, selection, "push") == nil && handed.count == 1, "standalone tool lost Push handoff")
        let request = try FinderServiceCommand.request(serviceURL: handed[0])
        try require(request.action == .push && request.paths.map(\.path) == [root.path] && tool.workspaceOpenHandoff.hasPendingWork, "standalone envelope changed Push selection")
        try require(tool.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored pending Push handoff")
        completion?(nil); completion = nil
        try require(!tool.workspaceOpenHandoff.hasPendingWork, "Push handoff receipt did not drain")
        print("PASS: all13 new private-pasteboard commands/plist, cold transport/reference/stash dispatch, busy rejection and standalone Push receipt")
    }
    @MainActor static func busy(_ controller: NSWindowController) -> Bool {
        switch controller {
        case let value as FetchWindowController: return value.model.busy || value.model.preparing
        case let value as PushWindowController: return value.model.busy || value.model.preparing
        case let value as SynchronizationWindowController: return value.model.busy
        case let value as BranchTagWindowController: return value.model.busy
        case let value as SwitchWindowController: return value.model.busy
        case let value as MergeWindowController: return value.model.busy
        case let value as RebaseWindowController: return value.model.busy || value.model.loadingPlan || value.model.loadingColumnMetadata
        case let value as StashWindowController: return value.model.busy || value.model.preparing
        case let value as StashRestoreWindowController: return value.model.busy
        case let value as ReferenceLogWindowController: return value.model.busy
        default: return false
        }
    }
    @MainActor static func routing() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        func repository(_ name: String, populated: Bool = true) async throws -> GitRepository {
            let root = directory.appendingPathComponent(name); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let repo = GitRepository(root: root, executable: git); _ = try await repo.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Services Workflow QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            if populated { try Data("base\n".utf8).write(to: root.appendingPathComponent("file 雪.txt")); try await repo.stage(["file 雪.txt"]); _ = try await repo.commit(message: "baseline") }
            return repo
        }
        func snapshot(_ repo: GitRepository, bare: Bool = false) async throws -> [Data] {
            let refs = try await repo.run(["for-each-ref", "--format=%(refname) %(objectname)"]).stdout
            var data = [refs]
            let paths = bare ? ["HEAD", "config"] : [".git/HEAD", ".git/config", ".git/index", "file 雪.txt"]
            for path in paths {
                let file = repo.root.appendingPathComponent(path)
                if FileManager.default.fileExists(atPath: file.path) { data.append(try Data(contentsOf: file)) }
                else { data.append(Data()) }
            }
            return data
        }
        let a = try await repository("repoA"), b = try await repository("repoB")
        try Data("stashed\n".utf8).write(to: a.root.appendingPathComponent("file 雪.txt")); _ = try await a.run(["stash", "push", "-m", "workflow fixture"])
        let beforeA = try await snapshot(a), beforeB = try await snapshot(b)
        let suite = "TurtleGit.FinderService.Workflows.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "StashShowChanges")
        let store = try RepositoryAccessStore(storageURL: directory.appendingPathComponent("access.json"), provider: FinderWorkflowScopes())
        try store.remember(a.root); try store.remember(b.root)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: directory.appendingPathComponent("marks.json")))
        workspace.repositoryBookmarkProvider = FinderWorkflowScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = prefs
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.alphaValue = 0; host.isReleasedWhenClosed = false; host.orderFront(nil); workspace.workspaceWindow = host
        var opened: [(RepositoryAction, NSWindowController, GitRepository, RepositoryAccessLease?)] = []
        workspace.finderServiceWorkflowPresentation = { action, controller, repository, access in
            controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            opened.append((action, controller, repository, access))
        }
        diagnostic = { "root=\(String(describing: workspace.root)), busy=\(workspace.busy), pending=\(workspace.hasPendingFinderServiceWork), error=\(String(describing: workspace.error)), opened=\(opened.map { $0.0.rawValue })" }
        defer { opened.forEach { $0.1.close() }; host.close(); workspace.stopMonitoringForTermination(); diagnostic = { "" } }
        workspace.open(b.root); try await wait("open initial B") { !workspace.busy && workspace.root?.path == b.root.path }
        let delegate = TurtleGitApplicationDelegate(); delegate.startupArguments = []; delegate.startupCommandHandler = { _, _, _ in }; delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
        defer { delegate.retireFinderServices() }
        func launch(_ name: String, path: URL, accepted: Bool = true) async throws -> NSWindowController? {
            try await wait("workspace idle before \(name)") { !workspace.busy && !workspace.hasPendingFinderServiceWork }
            let old = opened.count, selection = board([path]); defer { selection.releaseGlobally() }
            workspace.error = nil
            try require(invoke(delegate.finderServicesProvider, selection, name) == nil, "provider synchronous rejection \(name)")
            try await wait("\(name) routing") { !workspace.busy && !workspace.hasPendingFinderServiceWork && (opened.count > old || workspace.error != nil) }
            if !accepted { try require(opened.count == old && workspace.error != nil, "ineligible \(name) presented dialog"); return nil }
            try require(opened.count == old + 1, "\(name) did not present exactly once: \(workspace.error ?? "")")
            let captured = opened[old]
            try require(captured.0.rawValue == name && captured.2.root.path == workspace.root?.path && captured.3?.contains(path) == true && captured.3?.hasSecurityScope == true, "\(name) lost selected repository/scoped access")
            try require(captured.1.window?.alphaValue == 0, "\(name) was visible")
            try await wait("\(name) native read") { !busy(captured.1) }
            return captured.1
        }
        for name in commands where !["stashApply", "stashPop"].contains(name) {
            workspace.open(b.root); try await wait("restore B before \(name)") { !workspace.busy && workspace.root?.path == b.root.path }
            let controller = try await launch(name, path: name == "stash" ? a.root.appendingPathComponent("file 雪.txt") : a.root)
            try require(workspace.root?.path == a.root.path, "\(name) used workspace B")
            switch name {
            case "fetch", "pull": try require((controller as? FetchWindowController)?.model.isPull == (name == "pull"), "Fetch/Pull mode changed")
            case "push": try require(controller is PushWindowController, "Push controller missing")
            case "synchronize": try require(controller is SynchronizationWindowController, "Sync controller missing")
            case "branch", "tag": try require((controller as? BranchTagWindowController)?.model.isTag == (name == "tag"), "Branch/Tag mode changed")
            case "switchBranch": try require(controller is SwitchWindowController, "Switch controller missing")
            case "merge": try require(controller is MergeWindowController, "Merge controller missing")
            case "rebase": try require(controller is RebaseWindowController, "Rebase controller missing")
            case "stash": try require(controller is StashWindowController, "Stash Save dialog missing")
            case "stashList": try require((controller as? ReferenceLogWindowController)?.model.reference == "refs/stash", "Stash List did not scope refs/stash")
            default: break
            }
            controller?.close()
            let after = try await snapshot(a)
            try require(after == beforeA, "\(name) mutated Git/worktree merely opening")
        }
        // Explicit Services Apply/Pop is source-faithful authorization to execute
        // the operation. The other workspace must remain untouched.
        let applied = try await launch("stashApply", path: a.root) as? StashRestoreWindowController
        try require(applied?.model.result != nil && applied?.model.error == nil && applied?.model.success == true, "actual Services stash apply failed")
        let appliedBytes = try Data(contentsOf: a.root.appendingPathComponent("file 雪.txt"))
        try require(appliedBytes == Data("stashed\n".utf8), "Services Apply missed selected worktree")
        let stashAfterApply = try await a.run(["stash", "list", "--format=%H"]).stdout
        try require(stashAfterApply.split(separator: 10).count == 1, "Apply dropped or duplicated stash")
        applied?.close(); _ = try await a.run(["restore", "--worktree", "--", "file 雪.txt"])
        let popped = try await launch("stashPop", path: a.root) as? StashRestoreWindowController
        try require(popped?.model.result != nil && popped?.model.success == true, "actual Services stash pop failed")
        let stashAfterPop = try await a.run(["stash", "list", "--format=%H"]).stdout
        let poppedBytes = try Data(contentsOf: a.root.appendingPathComponent("file 雪.txt"))
        try require(stashAfterPop.isEmpty && poppedBytes == Data("stashed\n".utf8), "Pop did not restore once/drop selected stash")
        popped?.close()
        // Bare repositories expose source transport clauses, but never a
        // working-tree dialog merely because another worktree is already open.
        let bareRoot = directory.appendingPathComponent("bare.git")
        _ = try await a.run(["clone", "--bare", a.root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git); try store.remember(bareRoot)
        let beforeBare = try await snapshot(bare, bare: true)
        for name in commands {
            let allowed = ["fetch", "push"].contains(name)
            let controller = try await launch(name, path: bareRoot, accepted: allowed)
            controller?.close()
        }
        let afterBare = try await snapshot(bare, bare: true)
        try require(afterBare == beforeBare, "bare service reads mutated refs/config")
        let unborn = try await repository("unborn", populated: false); try store.remember(unborn.root)
        let beforeUnborn = try await snapshot(unborn)
        // Source has no HEAD eligibility bit: these dialogs may open and must
        // handle missing HEAD themselves. No-stash operations remain refused.
        for name in ["fetch", "branch"] { let controller = try await launch(name, path: unborn.root); controller?.close() }
        for name in ["stashApply", "stashPop", "stashList"] { _ = try await launch(name, path: unborn.root, accepted: false) }
        let afterUnborn = try await snapshot(unborn)
        try require(afterUnborn == beforeUnborn, "unborn service created HEAD/index/refs")
        let conflict = try await repository("merging"); try store.remember(conflict.root)
        _ = try await conflict.run(["switch", "-c", "side"])
        try Data("side\n".utf8).write(to: conflict.root.appendingPathComponent("file 雪.txt")); try await conflict.stage(["file 雪.txt"]); _ = try await conflict.commit(message: "side")
        _ = try await conflict.run(["switch", "main"])
        try Data("main\n".utf8).write(to: conflict.root.appendingPathComponent("file 雪.txt")); try await conflict.stage(["file 雪.txt"]); _ = try await conflict.commit(message: "main")
        _ = try await conflict.run(["merge", "side"], successfulExitCodes: 0...1)
        let mergeHead = conflict.root.appendingPathComponent(".git/MERGE_HEAD")
        try require(FileManager.default.fileExists(atPath: mergeHead.path), "private actual merge did not conflict")
        let beforeConflict = try await snapshot(conflict), mergeBytes = try Data(contentsOf: mergeHead)
        for name in ["pull", "synchronize", "merge", "rebase", "stash"] { _ = try await launch(name, path: name == "stash" ? conflict.root.appendingPathComponent("file 雪.txt") : conflict.root, accepted: false) }
        let conflictFetch = try await launch("fetch", path: conflict.root); conflictFetch?.close()
        let afterConflict = try await snapshot(conflict)
        try require(afterConflict == beforeConflict, "in-progress service mutated conflict/index/refs")
        let afterMergeBytes = try Data(contentsOf: mergeHead)
        try require(afterMergeBytes == mergeBytes, "in-progress service cleared MERGE_HEAD")
        // New Services requests retain the existing owned folder-grant contract.
        let c = try await repository("unsavedC")
        workspace.open(b.root); try await wait("B before Fetch permission") { !workspace.busy && workspace.root?.path == b.root.path }
        var reply: ((NSApplication.ModalResponse) -> Void)?, panels: [NSOpenPanel] = []
        workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panels.append(panel); reply = completion
            parent?.beginSheet(panel, completionHandler: nil)
        }
        workspace.selectedFinderServiceFolderURL = { _ in c.root }
        defer { reply?(.cancel); panels.forEach { panel in if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }; panel.close() } }
        let cBoard = board([c.root]); defer { cBoard.releaseGlobally() }
        let old = opened.count
        try require(invoke(delegate.finderServicesProvider, cBoard, "fetch") == nil, "first-use Fetch grant rejected")
        try await wait("owned Fetch folder grant") { reply != nil && host.attachedSheet === panels.last }
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && workspace.hasPendingFinderServiceWork, "Fetch permission lost Quit ownership")
        let late = reply; reply?(.cancel); reply = nil
        try await wait("cancelled Fetch permission detached") { !workspace.hasPendingFinderServiceWork && host.attachedSheet == nil }
        late?(.OK)
        try require(opened.count == old && workspace.root?.path == b.root.path, "late cancelled Fetch grant adopted C")
        try require(invoke(delegate.finderServicesProvider, cBoard, "fetch") == nil, "Fetch grant retry rejected")
        try await wait("second Fetch permission") { reply != nil }
        reply?(.OK); reply = nil
        try await wait("permission-captured Fetch C") { !workspace.busy && !workspace.hasPendingFinderServiceWork && opened.count == old + 1 && !busy(opened.last!.1) }
        try require(opened.last?.2.root.path == c.root.path && opened.last?.3?.contains(c.root) == true, "Fetch grant lost selected C authority")
        opened.last?.1.close()
        let afterB = try await snapshot(b)
        try require(afterB == beforeB, "Services changed unrelated workspace B HEAD/index/config/refs/worktree")
        opened.forEach { $0.1.close() }
        workspace.stopMonitoringForTermination(); host.close()
        try await wait("owned workflow workers drained") { !workspace.busy && !workspace.hasPendingFinderServiceWork && StashWindowController.activeChildReleases == 0 }
        print("PASS: actual discovered scoped13 Services workflows, review-dialog no-mutation snapshots, selected-repo Apply/Pop, bare/unborn/merge-state eligibility, owned Fetch grant cancel/late/retry and unrelated repository preservation")
    }
    @MainActor static func batch() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        func make(_ name: String) async throws -> GitRepository {
            let root = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            let repo = GitRepository(root: root, executable: git)
            _ = try await repo.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "Services Batch QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            try Data("base\n".utf8).write(to: root.appendingPathComponent("nested/file")); try await repo.stage(["nested/file"]); _ = try await repo.commit(message: "batch baseline")
            return repo
        }
        func snapshot(_ repo: GitRepository) async throws -> [Data] {
            let refs = try await repo.run(["for-each-ref", "--format=%(refname) %(objectname)"]).stdout
            return try [refs] + [".git/HEAD", ".git/index", ".git/config", "nested/file"].map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        }
        let a = try await make("batchA"), b = try await make("batchB")
        let beforeA = try await snapshot(a), beforeB = try await snapshot(b)
        let hold = directory.appendingPathComponent("hold-read"), released = directory.appendingPathComponent("release-read"), pidFile = directory.appendingPathComponent("held-read.pid")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let wrapper = directory.appendingPathComponent("held-git")
        let script = "#!/bin/sh\ncase \" $* \" in\n*\" remote \"*) if [ -f \(quote(hold.path)) ]; then /bin/echo $$ > \(quote(pidFile.path)); while [ ! -f \(quote(released.path)) ]; do /bin/sleep 0.1; done; fi ;;\nesac\nexec \(quote(git.path)) \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        defer { try? Data().write(to: released) }
        let suite = "TurtleGit.FinderServices.Batch.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = try RepositoryAccessStore(storageURL: directory.appendingPathComponent("batch-access.json"), provider: FinderWorkflowScopes()); try store.remember(a.root); try store.remember(b.root)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: $0.path == a.root.path ? wrapper : git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: directory.appendingPathComponent("batch-marks.json")))
        workspace.repositoryBookmarkProvider = FinderWorkflowScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = prefs
        let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.alphaValue = 0; host.isReleasedWhenClosed = false; host.orderFront(nil); workspace.workspaceWindow = host
        var children: [FetchWindowController] = [], roots: [String] = [], leases: [RepositoryAccessLease?] = [], overlap = false
        workspace.finderServiceWorkflowPresentation = { action, child, repository, access in
            guard action == .fetch, let child = child as? FetchWindowController else { return }
            if children.contains(where: { $0.window?.isVisible == true || $0.model.preparing || $0.model.busy }) { overlap = true }
            child.window?.alphaValue = 0; child.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            children.append(child); roots.append(repository.root.path); leases.append(access)
        }
        var panels: [NSOpenPanel] = [], reply: ((NSApplication.ModalResponse) -> Void)?
        workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
            panels.append(panel); reply = completion; panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); parent?.beginSheet(panel, completionHandler: nil)
        }
        workspace.selectedFinderServiceFolderURL = { _ in b.root }
        let delegate = TurtleGitApplicationDelegate(); delegate.startupArguments = []; delegate.startupCommandHandler = { _, _, _ in }; delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
        diagnostic = { "batch roots=\(roots), busy=\(workspace.busy), pending=\(workspace.hasPendingFinderServiceWork), reads=\(FetchWindowModel.activePreparationReads), error=\(String(describing: workspace.error)), panels=\(panels.count)" }
        defer {
            try? Data().write(to: released); reply?(.cancel)
            children.forEach { $0.close() }; panels.forEach { panel in if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }; panel.close() }
            delegate.retireFinderServices(); workspace.stopMonitoringForTermination(); host.close(); diagnostic = { "" }
        }
        let selection = board([a.root, a.root.appendingPathComponent("nested"), b.root]); defer { selection.releaseGlobally() }
        try require(invoke(delegate.finderServicesProvider, selection, "fetch") == nil, "multi-root Fetch rejected")
        try await wait("first ordered batch child") { children.count == 1 && !busy(children[0]) }
        try require(roots == [a.root.path] && panels.isEmpty && workspace.hasPendingFinderServiceWork, "batch advanced before first dialog closed")
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored retained batch dialog")
        children[0].model.cancel()
        try await wait("second ordered batch child") { children.count == 2 && !busy(children[1]) }
        try require(roots == [a.root.path, b.root.path] && !overlap && panels.isEmpty, "batch root order/one-child ownership or separately saved grants changed")
        try require(leases[0]?.contains(a.root) == true && leases[0]?.contains(b.root) == false && leases[1]?.contains(b.root) == true && leases[1]?.contains(a.root) == false && leases[1]?.hasSecurityScope == true, "batch reused A authority for B")
        children[1].model.cancel()
        try await wait("completed batch drained") { !workspace.hasPendingFinderServiceWork && !workspace.busy && FetchWindowModel.activePreparationReads == 0 }
        let afterA = try await snapshot(a), afterB = try await snapshot(b)
        try require(afterA == beforeA && afterB == beforeB, "batch Fetch dialogs mutated repositories")
        // Hold a real owned Git metadata read. Closing the batch owner must
        // cancel/drain it and prevent the later root from opening.
        try Data().write(to: hold)
        let second = board([a.root, b.root]); defer { second.releaseGlobally() }
        let old = children.count
        try require(invoke(delegate.finderServicesProvider, second, "fetch") == nil, "second batch rejected")
        var heldPID: Int32?
        try await wait("actual held metadata subprocess") {
            guard children.count == old + 1, FetchWindowModel.activePreparationReads > 0,
                  let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return false }
            heldPID = value; return true
        }
        guard let pid = heldPID else { throw Failure(description: "Held metadata subprocess did not publish its PID") }
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored held batch read")
        host.close()
        try await wait("owner-closed batch worker drain") { !workspace.hasPendingFinderServiceWork && !workspace.busy && FetchWindowModel.activePreparationReads == 0 }
        try require(children.count == old + 1 && roots.last == a.root.path && children[old].window?.isVisible == false && Darwin.kill(pid, 0) != 0, "owner close opened B or leaked held Git child")
        let finalA = try await snapshot(a), finalB = try await snapshot(b)
        try require(finalA == beforeA && finalB == beforeB, "cancelled batch changed Git/index/worktree")
        print("PASS: ordered multi-root Fetch skips nonroot, independent grants, Cancel continues after child/read drain, owner close stops next and reaps held Git metadata worker")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_SERVICE_WORKFLOWS_CASE"] {
        case "provider": try await provider()
        case "routing": try await routing()
        case "batch": try await batch()
        default: throw Failure(description: "Unknown workflow case")
        }
        print("PASS: Finder Services workflow case completed")
    }
}
