// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private struct FilesystemServiceScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
private actor FilesystemServiceReadGate {
    var token: OperationCancellation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ token: OperationCancellation) async {
        self.token = token
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}
@main struct FinderFilesystemServicesVerification {
    static let commands = ["rename", "remove", "removeKeep", "clean"]
    static let literal = "literal [a]; 雪\n.txt"
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: UInt = #line) throws { if !value { throw Failure(description: "\(line): \(message)") } }
    @MainActor static var diagnostic: () -> String = { "" }
    @MainActor static func wait(_ message: String, line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "\(line): \(message); \(diagnostic())")
    }
    @MainActor static func board(_ paths: [URL]) -> NSPasteboard {
        let value = NSPasteboard.withUniqueName()
        value.writeObjects(paths.map { path -> NSPasteboardItem in let item = NSPasteboardItem(); item.setString(path.absoluteString, forType: .fileURL); return item })
        return value
    }
    @MainActor static func invoke(_ provider: TurtleGitFinderServicesProvider, _ value: NSPasteboard, _ command: String) -> NSString? {
        var error: NSString?; provider.performFinderAction(value, userData: command, error: &error); return error
    }
    @MainActor final class Context {
        let root: URL, git: URL, defaults: UserDefaults, suite: String
        let store: RepositoryAccessStore
        let workspace: RepositoryModel
        let host: NSWindow
        let delegate = TurtleGitApplicationDelegate()
        var windows: [(RepositoryAction, NSWindowController, GitRepository, RepositoryAccessLease?)] = []
        var questions: [String] = []
        var acceptRemoval = true
        var configure: ((RepositoryAction, NSWindowController) -> Void)?
        init(root: URL, git: URL) throws {
            self.root = root; self.git = git; suite = "TurtleGit.FilesystemServices.QA." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
            store = try RepositoryAccessStore(storageURL: root.appendingPathComponent("access.json"), provider: FilesystemServiceScopes())
            workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("marks.json")))
            workspace.repositoryBookmarkProvider = FilesystemServiceScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = defaults
            host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.alphaValue = 0; host.isReleasedWhenClosed = false; host.orderFront(nil); workspace.workspaceWindow = host
            workspace.finderServiceWorkflowPresentation = { [weak self] action, controller, repository, access in
                guard let self else { return }
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                if let value = controller as? RemoveWindowController {
                    value.presentQuestion = { [weak self] owner, alert, completion in
                        self?.questions.append(alert.messageText); alert.window.alphaValue = 0
                        alert.beginSheetModal(for: owner, completionHandler: completion)
                        Task { @MainActor in await Task.yield(); alert.buttons[self?.acceptRemoval == false ? 1 : 0].performClick(nil) }
                        return true
                    }
                }
                self.configure?(action, controller)
                self.windows.append((action, controller, repository, access))
            }
            workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
                panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                parent?.beginSheet(panel, completionHandler: nil)
                Task { @MainActor in await Task.yield(); completion(.OK) }
            }
            workspace.selectedFinderServiceFolderURL = { _ in root }
            delegate.startupArguments = []; delegate.startupCommandHandler = { _, _, _ in }; delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
        }
        func finish() {
            windows.forEach { $0.1.close() }; delegate.retireFinderServices(); workspace.stopMonitoringForTermination(); host.close(); defaults.removePersistentDomain(forName: suite)
        }
        func make(_ name: String) async throws -> GitRepository {
            let directory = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repo = GitRepository(root: directory, executable: git); _ = try await repo.run(["init", "-b", "main"])
            for (key, value) in [("user.name", "File Services QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            for (path, text) in [(literal, "base\n"), ("normal.txt", "normal\n"), ("delete.keep", "keep\n"), ("delete.drop", "drop\n")] { try Data(text.utf8).write(to: directory.appendingPathComponent(path)) }
            try await repo.stage([literal, "normal.txt", "delete.keep", "delete.drop"]); _ = try await repo.commit(message: "baseline")
            try Data("committed\n".utf8).write(to: directory.appendingPathComponent(literal)); try await repo.stage([literal]); _ = try await repo.commit(message: "second")
            return repo
        }
        func open(_ repo: GitRepository) async throws {
            // Mutation callbacks enqueue a real workspace refresh. Opening
            // while that refresh owns busy is intentionally refused by Model;
            // wait for its accepted-command boundary before issuing Open.
            try await wait("workspace ready to open \(repo.root.lastPathComponent)") {
                !self.workspace.busy && !self.workspace.hasPendingRepositoryWork
            }
            var accepted = false
            workspace.open(repo.root, onOpened: { accepted = true })
            try await wait("accepted open \(repo.root.lastPathComponent)") {
                accepted && !self.workspace.busy && self.workspace.root?.path == repo.root.path
            }
        }
        func launch(_ command: String, paths: [URL], accepted: Bool = true) async throws -> NSWindowController? {
            try await wait("idle before \(command)") { !self.workspace.busy && !self.workspace.hasPendingRepositoryWork }
            let prior = windows.count, selected = board(paths); defer { selected.releaseGlobally() }
            workspace.error = nil
            let result = invoke(delegate.finderServicesProvider, selected, command)
            if !accepted, result != nil { try require(windows.count == prior, "rejected command still presented"); return nil }
            try require(result == nil, "synchronous \(command) rejection: \(result ?? "")")
            try await wait("\(command) dispatch") { !self.workspace.busy && !self.workspace.hasPendingFinderServiceWork && (self.windows.count > prior || self.workspace.error != nil) }
            if !accepted { try require(windows.count == prior && workspace.error != nil, "ineligible \(command) presented"); return nil }
            try require(windows.count == prior + 1, "\(command) actual controller missing: \(workspace.error ?? "")")
            let captured = windows[prior]
            try require(captured.0.rawValue == command && captured.1.window?.alphaValue == 0 && captured.3?.hasSecurityScope == true, "\(command) lost action, hidden window or scope")
            try require(captured.2.root.path == workspace.root?.path && captured.3?.contains(captured.2.root) == true, "\(command) captured wrong repository or scope")
            return captured.1
        }
    }
    @MainActor static func provider() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), path = directory.appendingPathComponent(literal)
        try Data("private selection\n".utf8).write(to: path)
        let selection = board([path]); defer { selection.releaseGlobally() }
        var received: [FinderRequest] = []
        let provider = TurtleGitFinderServicesProvider { received.append($0) }; defer { provider.retire() }
        let count = selection.changeCount
        for command in commands {
            try require(invoke(provider, selection, command) == nil, "provider rejected \(command)")
            try require(received.last?.action.rawValue == command && received.last?.paths.map(\.path) == [path.path], "provider altered captured \(command) selection")
        }
        let multiple = board([path, directory.appendingPathComponent("second.txt")]); defer { multiple.releaseGlobally() }
        try require(invoke(provider, multiple, "rename") != nil && received.count == commands.count, "Rename accepted multiple selected paths")
        for command in ["remove", "removeKeep", "clean"] {
            try require(invoke(provider, multiple, command) == nil && received.last?.paths.count == 2, "multi-path service dropped selected paths")
        }
        try require(selection.changeCount == count, "Services altered private pasteboard")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
        let services = plist["NSServices"] as? [[String: Any]] ?? []
        try require(services.count == 56 && Set(services.compactMap { $0["NSUserData"] as? String }) == Set(FinderServiceCommand.allCases.map(\.rawValue)), "56 registered Services differ from Core commands")
        for command in commands {
            let entries = services.filter { $0["NSUserData"] as? String == command }
            try require(entries.count == 1 && entries[0]["NSMessage"] as? String == "performFinderAction" && entries[0]["NSSendFileTypes"] as? [String] == [command == "clean" ? "public.folder":"public.item"], "filesystem service declaration invalid")
        }
        provider.retire(); let total = received.count
        try require(invoke(provider, selection, "remove") != nil && received.count == total, "retired provider dispatched filesystem mutation")
        print("PASS: filesystem Services registration, private literal-path envelopes, source cardinality and retired-provider refusal")
    }
    static func bytes(_ repository: GitRepository, _ path: String) throws -> Data { try Data(contentsOf: repository.root.appendingPathComponent(path)) }
    @MainActor static func effects() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(String(describing: context.workspace.root)), error=\(String(describing: context.workspace.error)), windows=\(context.windows.map { $0.0.rawValue })" }
        let a = try await context.make("selectionA"), b = try await context.make("workspaceB")
        try context.store.remember(a.root); try context.store.remember(b.root)
        try await context.open(b)
        let symlink = "symlink [leaf]", renamedSymlink = "renamed symlink"
        try FileManager.default.createSymbolicLink(at: a.root.appendingPathComponent(symlink), withDestinationURL: b.root.appendingPathComponent("normal.txt"))
        try await a.stage([symlink]); _ = try await a.commit(message: "symlink baseline")
        let bIndex = try bytes(b, ".git/index"), bHead = try await b.run(["rev-parse", "HEAD"]).stdout
        let aHead = try await a.run(["rev-parse", "HEAD"]).stdout
        let original = try bytes(a, literal), beforeRename = try bytes(a, ".git/index")
        let rename = try await context.launch("rename", paths: [a.root.appendingPathComponent(literal)]) as? RenameWindowController
        try require(rename?.model.source == literal && rename?.model.name == literal && context.workspace.root?.path == a.root.path, "Rename did not present source filename from A")
        try require(try bytes(a, ".git/index") == beforeRename && bytes(a, literal) == original, "Rename mutated before user submission")
        let renamed = "renamed [r]; 雪\n.txt"
        try await context.open(b)
        rename?.model.name = renamed; rename?.model.rename()
        try await wait("real Rename settled") { rename?.model.busy == false && RenameWindowModel.activeOperations == 0 }
        let renamedIndex = try await a.run(["ls-files", "-z", "--", renamed]).stdout
        try require(rename?.model.error == nil && rename?.model.failed == false && !FileManager.default.fileExists(atPath: a.root.appendingPathComponent(literal).path) && bytes(a, renamed) == original && renamedIndex == Data((renamed + "\0").utf8), "Rename did not stage exact literal destination")
        rename?.close()
        let linkRename = try await context.launch("rename", paths: [a.root.appendingPathComponent(symlink)]) as? RenameWindowController
        try require(linkRename?.model.source == symlink && linkRename?.model.repository.root.path == a.root.path, "Rename followed symlink target into B")
        linkRename?.model.name = renamedSymlink; linkRename?.model.rename()
        try await wait("literal symlink Rename settled") { linkRename?.model.busy == false && RenameWindowModel.activeOperations == 0 }
        let linkEntry = try await a.run(["ls-files", "--stage", "--", renamedSymlink]).stdout
        let linkTarget = try FileManager.default.destinationOfSymbolicLink(atPath: a.root.appendingPathComponent(renamedSymlink).path)
        try require(String(decoding: linkEntry, as: UTF8.self).hasPrefix("120000 ") && linkTarget == b.root.appendingPathComponent("normal.txt").path, "Rename changed symlink type or target")
        linkRename?.close()
        // Delete captures multiple paths, asks once, and preserves unstaged bytes
        // when the source keep-local variant is selected.
        for (command, names, keep) in [("remove", [renamed, "delete.drop"], false), ("removeKeep", ["normal.txt", "delete.keep"], true)] {
            try await context.open(b)
            if keep { for name in names { try Data("private unstaged \(name)\n".utf8).write(to: a.root.appendingPathComponent(name)) } }
            let before = try names.map { try bytes(a, $0) }, questions = context.questions.count
            let controller = try await context.launch(command, paths: names.map { a.root.appendingPathComponent($0) }) as? RemoveWindowController
            try require(controller?.request.paths == names && controller?.request.keepLocal == keep, "Delete source file-list/keep-local flag changed")
            try await wait("actual \(command) completion") { controller?.model.busy == false && RemoveWindowModel.activeOperations == 0 }
            try require(controller?.model.failed == false && controller?.model.removed == names.count && context.questions.count == questions + 1, "Delete did not obtain one source confirmation or finish all paths")
            for (index, name) in names.enumerated() {
                let entry = try await a.run(["ls-files", "-z", "--", name]).stdout
                try require(entry.isEmpty && FileManager.default.fileExists(atPath: a.root.appendingPathComponent(name).path) == keep, "Delete/keep-local index or disk effects incorrect")
                if keep { try require(try bytes(a, name) == before[index], "keep-local changed unstaged bytes") }
            }
            controller?.close()
        }
        // Cleanup accepts the source folder selection; its preview and explicit
        // destructive post-action operate only in that captured directory.
        let folder = a.root.appendingPathComponent("cleanup scope")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let selected = folder.appendingPathComponent("selected.tmp"), sibling = folder.appendingPathComponent("sibling.tmp"), outside = a.root.appendingPathComponent("outside.tmp")
        for url in [selected, sibling, outside] { try Data("untracked\n".utf8).write(to: url) }
        try await context.open(b)
        let clean = try await context.launch("clean", paths: [folder]) as? CleanWindowController
        try require(clean?.model.scopePaths == ["cleanup scope"] && (try clean?.model.directoryScopes()) == ["cleanup scope"], "Cleanup lost source folder scope")
        clean?.model.dryRun = true; clean?.model.permanently = true
        let oldWindows = context.windows.count
        clean?.model.accept()
        try await wait("actual Cleanup progress child") { context.windows.count == oldWindows + 1 }
        let progress = context.windows.last?.1 as? CleanProgressWindowController
        try await wait("Cleanup dry-run completion") { progress?.model.busy == false && CleanProgressWindowModel.activeOperations == 0 }
        try require(progress?.model.previewSucceeded == true && progress?.model.failed == false && [selected, sibling, outside].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Cleanup dry run deleted files or failed")
        progress?.model.remove(permanently: true)
        try await wait("explicit Cleanup deletion") { progress?.model.busy == false && CleanProgressWindowModel.activeOperations == 0 }
        try require(progress?.model.failed == false && !FileManager.default.fileExists(atPath: selected.path) && !FileManager.default.fileExists(atPath: sibling.path) && FileManager.default.fileExists(atPath: outside.path), "Cleanup widened scope or did not execute explicit deletion")
        progress?.close()
        let finalBHead = try await b.run(["rev-parse", "HEAD"]).stdout, finalAHead = try await a.run(["rev-parse", "HEAD"]).stdout
        try require(try bytes(b, ".git/index") == bIndex && finalBHead == bHead && finalAHead == aHead, "filesystem Services committed or modified unrelated workspace B")
        _ = try await context.launch("clean", paths: [outside], accepted: false)
        let mixed = board([a.root.appendingPathComponent(renamedSymlink), b.root.appendingPathComponent("normal.txt")]); defer { mixed.releaseGlobally() }
        let mixedWindows = context.windows.count
        context.workspace.error = nil
        try require(invoke(context.delegate.finderServicesProvider, mixed, "remove") == nil, "mixed selection did not reach captured validation")
        try await wait("mixed repositories rejected") { !context.workspace.hasPendingFinderServiceWork && !context.workspace.busy && context.workspace.error != nil }
        try require(context.windows.count == mixedWindows, "mixed Delete narrowed to one repository")
        // Normal root and untracked targets are source-ineligible for Rename and
        // Delete; mixed repositories must never narrow to the first repository.
        for command in ["rename", "remove", "removeKeep"] {
            _ = try await context.launch(command, paths: [a.root], accepted: false)
            _ = try await context.launch(command, paths: [outside], accepted: false)
        }
        print("PASS: captured A/B Rename, ordered Delete/keep-local questions and Git effects, Cleanup dry-run/explicit deletion with exact folder scope, unchanged HEAD and unrelated workspace")
    }
    @MainActor static func ownership() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(String(describing: context.workspace.root)), pending=\(context.workspace.hasPendingRepositoryWork), error=\(String(describing: context.workspace.error)), windows=\(context.windows.map { $0.0.rawValue })" }
        let a = try await context.make("savedA"), b = try await context.make("workspaceB"), c = try await context.make("first-useC")
        try context.store.remember(a.root); try context.store.remember(b.root); try await context.open(b)
        var reply: ((NSApplication.ModalResponse) -> Void)?, panels: [NSOpenPanel] = []
        context.workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panels.append(panel); reply = completion; parent?.beginSheet(panel, completionHandler: nil)
        }
        context.workspace.selectedFinderServiceFolderURL = { _ in c.root }
        defer { reply?(.cancel); panels.forEach { panel in if let owner = panel.sheetParent { owner.endSheet(panel, returnCode: .cancel) }; panel.close() } }
        let selection = board([c.root.appendingPathComponent(literal)]); defer { selection.releaseGlobally() }
        let initial = context.windows.count, before = try bytes(c, ".git/index"), working = try bytes(c, literal)
        try require(invoke(context.delegate.finderServicesProvider, selection, "rename") == nil, "first-use Rename rejected before owned grant")
        try await wait("first-use folder authority sheet") { reply != nil && context.host.attachedSheet === panels.last }
        try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel && invoke(context.delegate.finderServicesProvider, selection, "remove") != nil, "pending authority lost Quit/busy ownership")
        let late = reply; reply?(.cancel); reply = nil
        try await wait("cancelled folder authority drain") { !context.workspace.hasPendingFinderServiceWork && context.host.attachedSheet == nil }
        late?(.OK)
        try require(context.windows.count == initial && context.workspace.root?.path == b.root.path && bytes(c, ".git/index") == before && bytes(c, literal) == working, "late cancelled grant adopted or mutated C")
        try require(invoke(context.delegate.finderServicesProvider, selection, "rename") == nil, "second first-use Rename rejected")
        try await wait("replacement owned grant") { reply != nil }
        reply?(.OK); reply = nil
        try await wait("accepted first-use captured Rename") { context.windows.count == initial + 1 && !context.workspace.busy && !context.workspace.hasPendingFinderServiceWork }
        let granted = context.windows.last?.1 as? RenameWindowController
        try require(granted?.model.source == literal && granted?.model.repository.root.path == c.root.path && context.windows.last?.3?.hasSecurityScope == true && context.windows.last?.1.window?.alphaValue == 0, "first-use Rename lost captured path/scope/hidden child")
        granted?.close()
        _ = try await a.run(["-c", "protocol.file.allow=always", "submodule", "add", "--", b.root.path, "child module"])
        _ = try await a.commit(message: "gitlink baseline")
        let child = a.root.appendingPathComponent("child module")
        let gitlinkRename = try await context.launch("rename", paths: [child]) as? RenameWindowController
        try require(gitlinkRename?.model.repository.root.path == a.root.path && gitlinkRename?.model.source == "child module", "gitlink Rename did not retain containing repository/source root exception")
        gitlinkRename?.close()
        _ = try await context.launch("removeKeep", paths: [child], accepted: false)
        context.acceptRemoval = false
        let gitlinkRemove = try await context.launch("remove", paths: [child]) as? RemoveWindowController
        try await wait("cancelled gitlink Delete confirmation") { gitlinkRemove?.model.busy == false && RemoveWindowModel.activeOperations == 0 }
        try require(gitlinkRemove?.model.repository.root.path == a.root.path && gitlinkRemove?.request.paths == ["child module"] && FileManager.default.fileExists(atPath: child.path), "gitlink Delete omitted source root exception or Cancel removed it")
        gitlinkRemove?.close(); context.acceptRemoval = true
        // Source forms remain tied to A after the workspace adopts B. Hold a real
        // destination-preparation worker, then forcibly close its owner. Neither
        // scope nor onClosed may retire before the cancelled producer returns.
        try await context.open(b)
        let gate = FilesystemServiceReadGate()
        let rename = try await context.launch("rename", paths: [a.root.appendingPathComponent(literal)]) as? RenameWindowController
        guard let rename else { throw Failure(description: "Rename controller missing") }
        try await context.open(b)
        let aIndex = try bytes(a, ".git/index"), aBytes = try bytes(a, literal)
        rename.model.resolveDestination = { target, token in
            await gate.hold(token); try token.check()
            return try await a.renameDestination(target, source: literal, cancellation: token)
        }
        var renamedClosed = false
        let previousClose = rename.onClosed
        rename.onClosed = { renamedClosed = true; previousClose() }
        rename.model.chooseDestination(a.root.appendingPathComponent("late destination.txt"))
        for _ in 0..<3000 { if await gate.token != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let token = await gate.token
        do {
            try require(token != nil && rename.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Rename preparation lost per-owner pending/Quit")
            rename.close()
            try require(token?.isCancelled == true && !renamedClosed && rename.finderServiceWorkPending, "forced Rename close released active producer")
            await gate.finish()
            try await wait("forced Rename worker and callback drained") { renamedClosed && !rename.finderServiceWorkPending && RenameWindowModel.activeOperations == 0 }
            try require(rename.model.name == literal && bytes(a, ".git/index") == aIndex && bytes(a, literal) == aBytes && context.workspace.root?.path == b.root.path, "late destination result published or changed captured repository")
        } catch { rename.close(); await gate.finish(); throw error }
        // Removal preflight likewise owns its captured ordered list and the grant
        // until actual worker receipt. A late cancelled producer must not open a
        // confirmation or enter Git rm.
        let removalGate = FilesystemServiceReadGate(), startQuestions = context.questions.count
        context.configure = { _, controller in
            if let remove = controller as? RemoveWindowController {
                remove.model.prepare = { path, token in
                    await removalGate.hold(token); try token.check()
                    return try await a.prepareRemoval(path, keepLocal: false, cancellation: token)
                }
            }
        }
        let remove = try await context.launch("remove", paths: [a.root.appendingPathComponent(literal), a.root.appendingPathComponent("normal.txt")]) as? RemoveWindowController
        guard let remove else { throw Failure(description: "Remove controller missing") }
        for _ in 0..<3000 { if await removalGate.token != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let removalToken = await removalGate.token
        var removedClosed = false; let previousRemovalClose = remove.onClosed
        remove.onClosed = { removedClosed = true; previousRemovalClose() }
        do {
            try require(removalToken != nil && remove.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Remove preparation lost per-owner pending/Quit")
            remove.close()
            try require(removalToken?.isCancelled == true && !removedClosed && remove.finderServiceWorkPending, "forced Remove close released active producer")
            await removalGate.finish()
            try await wait("forced Remove worker and callback drained") { removedClosed && !remove.finderServiceWorkPending && RemoveWindowModel.activeOperations == 0 }
            try require(context.questions.count == startQuestions && bytes(a, ".git/index") == aIndex && bytes(a, literal) == aBytes, "late Remove prepared/confirmed/mutated after owner close")
        } catch { remove.close(); await removalGate.finish(); throw error }
        // Real linked-worktree cleanup reaches an external Git metadata folder.
        // Keep only the worktree authority, so its actual native permission child
        // owns the running preview and must settle before onClosed is published.
        let linked = context.root.appendingPathComponent("linked-cleanup")
        _ = try await a.run(["worktree", "add", "-b", "cleanup-branch", linked.path])
        let linkedRepository = GitRepository(root: linked, executable: context.git)
        let loose = linked.appendingPathComponent("private-untracked.tmp")
        try Data("private cleanup candidate\n".utf8).write(to: loose)
        let linkedIndex = try await linkedRepository.run(["ls-files", "--stage", "-z"]).stdout
        let cleanRequest = CleanDialogRequest(options: CleanOptions(), paths: [], dryRun: true, submodules: false, permanently: true)
        let cleanup = CleanProgressWindowController(repository: linkedRepository, access: RepositoryAccessLease(url: linked, provider: FilesystemServiceScopes()), request: cleanRequest, preferences: context.defaults)
        cleanup.window?.alphaValue = 0; cleanup.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        cleanup.model.requiresSecurityScope = true; cleanup.model.bookmarkProvider = FilesystemServiceScopes()
        var metadataReply: ((NSApplication.ModalResponse) -> Void)?, metadataPanels: [NSOpenPanel] = [], metadataToken: OperationCancellation?
        let realMetadataChoice = cleanup.model.chooseMetadataFolder
        cleanup.model.chooseMetadataFolder = { requirement, token in metadataToken = token; return try await realMetadataChoice?(requirement, token) }
        cleanup.presentAuthorization = { panel, owner, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); metadataPanels.append(panel); metadataReply = completion
            owner.beginSheet(panel, completionHandler: nil)
        }
        cleanup.selectedAuthorizationURL = { _ in a.root }
        var cleanupClosed = false; cleanup.onClosed = { cleanupClosed = true }
        defer { cleanup.close(); metadataReply?(.cancel); metadataPanels.forEach { panel in panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.close() } }
        cleanup.showWindow(nil); cleanup.model.start()
        try await wait("actual linked-worktree metadata authority") { metadataReply != nil && cleanup.model.authorizing && cleanup.window?.attachedSheet != nil }
        try require(metadataToken != nil && cleanup.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Cleanup lost metadata permission worker/Quit ownership")
        let lateMetadata = metadataReply
        cleanup.close()
        try require(metadataToken?.isCancelled == true && !cleanupClosed && cleanup.finderServiceWorkPending, "forced Cleanup close retired before metadata worker drain")
        try await wait("Cleanup metadata child and preview worker drained") { cleanupClosed && !cleanup.finderServiceWorkPending && CleanProgressWindowModel.activeOperations == 0 }
        lateMetadata?(.OK); metadataReply = nil
        let afterLinkedIndex = try await linkedRepository.run(["ls-files", "--stage", "-z"]).stdout
        try require(afterLinkedIndex == linkedIndex && FileManager.default.fileExists(atPath: loose.path) && cleanup.model.additionalAccess.isEmpty && metadataPanels.allSatisfy { $0.sheetParent == nil }, "late Cleanup metadata answer granted/mutated/reopened after close")
        try await wait("filesystem Services owned work released") { !context.workspace.hasPendingRepositoryWork && !context.workspace.hasPendingFinderServiceWork }
        print("PASS: first-use authority Cancel/replacement/late callback fence, immutable A/B forms, Rename and Remove forced-close cancellation, deferred onClosed and Quit until actual worker drain")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitFilesystemServicesOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_FILESYSTEM_SERVICES_CASE"] {
        case "provider": try provider()
        case "effects": try await effects()
        case "ownership": try await ownership()
        default: throw Failure(description: "Unknown filesystem Services case")
        }
        print("PASS: filesystem Services case completed")
    }
}

private extension NSWindow {
    @objc func turtleGitFilesystemServicesOrder(_ place:NSWindow.OrderingMode,relativeTo otherWin:Int){
        alphaValue=0
        turtleGitFilesystemServicesOrder(place,relativeTo:otherWin)
    }
}
