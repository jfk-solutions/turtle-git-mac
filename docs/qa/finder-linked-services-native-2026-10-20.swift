// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

// This legacy workflow receiver injects its instrumented action owner through
// makeStandaloneWorkspace. Distinct scene/action ownership is verified by the
// current dialog-launch receiver, rather than inferred from this private host.

@MainActor private func verifyPublicOpenService(_ entries:[[String:Any]])throws {
    guard entries.count==1,let entry=entries.first,
          entry["NSMessage"] as? String=="openInTurtleGit",entry["NSUserData"] as? String=="open",
          entry["NSPortName"] as? String=="TurtleGit",entry["NSSendFileTypes"] as? [String]==["public.item"],
          entry["NSRestricted"] as? Bool==true,(entry["NSRequiredContext"] as? [String:Any])?.isEmpty==true,
          (entry["NSMenuItem"] as? [String:String])?["default"]=="Open in TurtleGit" else {
        throw NSError(domain:"TurtleGit.NativeServicesInventory",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected one restricted Open in TurtleGit item Service"])
    }
}

private struct LinkedServiceScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
private actor LinkedServiceReadGate {
    var token: OperationCancellation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ token: OperationCancellation) async {
        self.token = token
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}
@main struct FinderLinkedServicesVerification {
    static let commands = ["worktreeList", "worktreeCreate", "submoduleAdd", "submoduleUpdate", "submoduleSync", "logSubmodule"]
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
        var configure: ((RepositoryAction, NSWindowController) -> Void)?
        init(root: URL, git: URL) throws {
            self.root = root; self.git = git; suite = "TurtleGit.LinkedServices.QA." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
            defaults.set(0, forKey: "AutoCloseGitProgress"); defaults.set(false, forKey: "ConfirmKillProcess")
            store = try RepositoryAccessStore(storageURL: root.appendingPathComponent("access.json"), provider: LinkedServiceScopes())
            workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("marks.json")))
            workspace.repositoryBookmarkProvider = LinkedServiceScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = defaults
            host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.alphaValue = 0; host.isReleasedWhenClosed = false; host.orderFront(nil); workspace.workspaceWindow = host
            workspace.finderServiceWorkflowPresentation = { [weak self] action, controller, repository, access in
                guard let self else { return }
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                self.configure?(action, controller)
                self.windows.append((action, controller, repository, access))
            }
            workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
                panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                parent?.beginSheet(panel, completionHandler: nil)
                Task { @MainActor in await Task.yield(); completion(.OK) }
            }
            workspace.selectedFinderServiceFolderURL = { _ in root }
            delegate.startupArguments = []; delegate.startupCommandHandler = { _, _, _ in }; delegate.makeStandaloneWorkspace = { workspace }; delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
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
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), directory = root.appendingPathComponent("selected [dir]; 雪")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let selected = board([directory]); defer { selected.releaseGlobally() }
        var received: [FinderRequest] = []
        let provider = TurtleGitFinderServicesProvider { received.append($0) }; defer { provider.retire() }
        let count = selected.changeCount
        for command in commands {
            try require(invoke(provider, selected, command) == nil && received.last?.action.rawValue == command && received.last?.paths.map(\.path) == [directory.path], "linked Services changed captured path/action")
        }
        let multiple = board([directory, root]); defer { multiple.releaseGlobally() }
        for command in ["worktreeList", "worktreeCreate", "submoduleAdd", "logSubmodule"] {
            let total = received.count
            try require(invoke(provider, multiple, command) != nil && received.count == total, "singleton linked Service accepted multiple directories")
        }
        for command in ["submoduleUpdate", "submoduleSync"] {
            try require(invoke(provider, multiple, command) == nil && received.last?.paths.map(\.path) == [directory.path, root.path], "multi-folder linked Service lost selected order")
        }
        try require(selected.changeCount == count, "linked Services changed private pasteboard")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
        let declarations = plist["NSServices"] as? [[String: Any]] ?? []
        try verifyPublicOpenService(declarations)
        provider.retire(); let total = received.count
        try require(invoke(provider, selected, "submoduleSync") != nil && received.count == total, "retired linked Service provider dispatched")
        print("PASS: six linked Services,one public declaration and legacy handlers, literal directory capture, folder UTIs and source cardinality")
    }
    static func bytes(_ repository: GitRepository, _ path: String) throws -> Data { try Data(contentsOf: repository.root.appendingPathComponent(path)) }
    static func value(_ repository: GitRepository, _ args: [String]) async throws -> String { try await repository.run(args).text.trimmingCharacters(in: .newlines) }
    @MainActor static func submodules() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(context.workspace.root?.path ?? "nil"), error=\(context.workspace.error ?? "nil"), windows=\(context.windows.map { $0.0.rawValue })" }
        let a = try await context.make("superprojectA"), b = try await context.make("workspaceB"), first = try await context.make("sourceOne"), second = try await context.make("sourceTwo")
        try context.store.remember(a.root); try context.store.remember(b.root); try await context.open(b)
        let bIndex = try bytes(b, ".git/index"), bHead = try await value(b, ["rev-parse", "HEAD"])
        let names = ["modules/one [u]", "modules/two"]
        let initialHead = try await value(a, ["rev-parse", "HEAD"])
        for (index, source) in [first, second].enumerated() {
            try await context.open(b)
            let input = try await context.launch("submoduleAdd", paths: [a.root]) as? SubmoduleAddWindowController
            try require(input?.model.repository.root.path == a.root.path && input?.model.canApply == true, "Submodule Add captured wrong repository or no submit callback")
            try await context.open(b)
            input?.model.source = source.root.path; input?.model.path = names[index]; input?.model.useKey = false
            let count = context.windows.count
            input?.model.apply()
            try await wait("real Submodule Add progress child") { context.windows.count == count + 1 }
            let progress = context.windows.last?.1 as? SubmoduleAddProgressWindowController
            try await wait("actual local Submodule Add complete") { progress?.model.busy == false && SubmoduleAddProgressWindowModel.activeOperations == 0 }
            try require(progress?.model.success == true && progress?.model.repository.root.path == a.root.path, "Submodule Add failed: \(progress?.model.output ?? "missing")")
            let staged = try await value(a, ["ls-files", "--stage", "--", names[index]])
            let child = GitRepository(root: a.root.appendingPathComponent(names[index]), executable: context.git)
            let sourceHead = try await value(source, ["rev-parse", "HEAD"]), childHead = try await value(child, ["rev-parse", "HEAD"])
            try require(staged.hasPrefix("160000 ") && childHead == sourceHead, "native Add did not clone and stage selected gitlink")
            progress?.close(); input?.close()
        }
        let afterAddsHead = try await value(a, ["rev-parse", "HEAD"])
        try require(afterAddsHead == initialHead, "Submodule Add committed without explicit commit")
        _ = try await a.commit(message: "two gitlinks")
        let child = GitRepository(root: a.root.appendingPathComponent(names[0]), executable: context.git)
        let other = GitRepository(root: a.root.appendingPathComponent(names[1]), executable: context.git)
        let old = try await value(child, ["rev-parse", "HEAD"]), otherHead = try await value(other, ["rev-parse", "HEAD"])
        try Data("next source revision\n".utf8).write(to: first.root.appendingPathComponent("normal.txt")); try await first.stage(["normal.txt"]); _ = try await first.commit(message: "source advance")
        let next = try await value(first, ["rev-parse", "HEAD"])
        _ = try await child.run(["fetch", "origin"]); _ = try await child.run(["checkout", "--detach", next])
        try await a.stage([names[0]]); _ = try await a.commit(message: "record new selected gitlink")
        _ = try await child.run(["checkout", "--detach", old])
        let parentHead = try await value(a, ["rev-parse", "HEAD"])
        try await context.open(b)
        let update = try await context.launch("submoduleUpdate", paths: [child.root]) as? SubmoduleUpdateWindowController
        try await wait("scoped Submodule Update list") { update?.model.busy == false && SubmoduleUpdateWindowModel.activeReads == 0 }
        try require(update?.model.repository.root.path == a.root.path && update?.model.scope == [names[0]] && update?.model.paths == [names[0]] && update?.model.selection == Set([GitReferenceName(names[0])]), "selected gitlink Update widened/narrowed or opened child instead of parent")
        try await context.open(b)
        update?.model.options.noFetch = true
        let count = context.windows.count; update?.model.apply()
        try await wait("scoped Update progress child") { context.windows.count == count + 1 }
        let updateProgress = context.windows.last?.1 as? SubmoduleUpdateProgressWindowController
        try await wait("actual selected Update complete") { updateProgress?.model.busy == false && SubmoduleUpdateProgressWindowModel.activeOperations == 0 }
        let changed = try await value(child, ["rev-parse", "HEAD"]), unchanged = try await value(other, ["rev-parse", "HEAD"])
        try require(updateProgress?.model.success == true && updateProgress?.model.result?.attemptedPaths == [names[0]] && changed == next && unchanged == otherHead, "Update did not honor captured selected gitlink")
        updateProgress?.close(); update?.close()
        // Sync updates precisely the selected child's URL, leaving its sibling's
        // configured URL and working checkout untouched.
        let oldOtherURL = try await value(a, ["config", "--get", "submodule." + names[1] + ".url"])
        for (index, name) in names.enumerated() { _ = try await a.run(["config", "--file", ".gitmodules", "submodule." + name + ".url", index == 0 ? second.root.path : first.root.path]) }
        try await context.open(b)
        let sync = try await context.launch("submoduleSync", paths: [child.root]) as? SubmoduleSyncWindowController
        try await wait("actual selected Submodule Sync complete") { sync?.model.busy == false && SubmoduleSyncWindowModel.activeOperations == 0 }
        let firstURL = try await value(a, ["config", "--get", "submodule." + names[0] + ".url"]), otherURL = try await value(a, ["config", "--get", "submodule." + names[1] + ".url"])
        try require(sync?.model.success == true && sync?.model.result?.entries.map(\.command.scope) == [names[0]] && firstURL == second.root.path && otherURL == oldOtherURL, "Sync did not retain parent/selected child scope")
        sync?.close()
        try await context.open(b)
        let parentLog = try await context.launch("logSubmodule", paths: [child.root]) as? LogWindowController
        try await wait("actual superproject Log read") { parentLog?.model.busy == false && parentLog?.model.entries.isEmpty == false }
        try require(parentLog?.model.repository.root.path == a.root.path && parentLog?.model.historyPaths == [names[0]], "Parent Log opened child history or wrong superproject/path")
        parentLog?.close()
        let finalBHead = try await value(b, ["rev-parse", "HEAD"]), finalAHead = try await value(a, ["rev-parse", "HEAD"])
        try require(try bytes(b, ".git/index") == bIndex && finalBHead == bHead && finalAHead == parentHead, "linked Services changed unrelated B or committed Update/Sync")
        _ = try await context.launch("logSubmodule", paths: [a.root], accepted: false)
        _ = try await context.launch("submoduleAdd", paths: [a.root.appendingPathComponent("normal.txt")], accepted: false)
        for command in ["submoduleUpdate", "submoduleSync"] { _ = try await context.launch(command, paths: [b.root], accepted: false) }
        print("PASS: native local Add→scoped Update/Sync, actual gitlink/checkout/config effects, A forms survive B, proven superproject Log and unchanged unrelated repository")
    }
    @MainActor static func worktrees() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(context.workspace.root?.path ?? "nil"), error=\(context.workspace.error ?? "nil"), windows=\(context.windows.map { String(describing: type(of: $0.1)) })" }
        let a = try await context.make("worktreeA"), b = try await context.make("workspaceB")
        try context.store.remember(a.root); try context.store.remember(b.root); try await context.open(b)
        let bIndex = try bytes(b, ".git/index"), bHead = try await value(b, ["rev-parse", "HEAD"]), aHead = try await value(a, ["rev-parse", "HEAD"])
        let destination = context.root.appendingPathComponent("created checkout [w]")
        let create = try await context.launch("worktreeCreate", paths: [a.root]) as? WorktreeCreateWindowController
        try await wait("actual Worktree Create source reads") { create?.model.busy == false && create?.model.chooser.busy == false }
        try require(create?.model.chooser.repository.root.path == a.root.path && create?.model.currentBranch == "main", "Worktree Create loaded workspace B")
        try await context.open(b)
        var authority: [String] = []
        create?.model.requiresSecurityScope = true
        create?.model.authorizeDestination = { path, token in
            try token.check(); authority.append(path.path)
            try require(!FileManager.default.fileExists(atPath: destination.path), "destination created before authority")
            return RepositoryAccessLease(url: context.root, provider: LinkedServiceScopes())
        }
        create?.model.directory = destination.path; create?.model.useHead = true; create?.model.createBranch = true; create?.model.branchName = "linked-feature"
        create?.model.create()
        try await wait("actual authorized Worktree creation") { create?.model.busy == false && WorktreeCreateWindowModel.activeOperations == 0 }
        let linked = GitRepository(root: destination, executable: context.git)
        let linkedHead = try await value(linked, ["rev-parse", "HEAD"]), linkedBranch = try await value(linked, ["branch", "--show-current"])
        let rows = try await a.worktrees()
        try require(create?.model.success == true && authority == [destination.path] && create?.model.destinationAccess?.contains(destination) == true && linkedHead == aHead && linkedBranch == "linked-feature" && rows.contains(where: { $0.path.path == destination.path }), "Worktree creation lost authority/options/source revision: \(create?.model.output ?? "missing")")
        create?.close()
        try await context.open(b)
        let list = try await context.launch("worktreeList", paths: [a.root]) as? WorktreeListWindowController
        try await wait("actual Worktree List loaded") { list?.model.busy == false && list?.model.rows.count == 2 }
        try require(list?.model.repository.root.path == a.root.path && Set(list?.model.rows.map { $0.path.path } ?? []) == Set([a.root.path, destination.path]), "Worktree List read wrong repository or omitted linked checkout")
        // List's Add is the actual source-shaped child, captured before display
        // and still scoped to its owner after workspace adoption changes.
        try await context.open(b)
        let count = context.windows.count
        list?.model.add()
        try await wait("owned Worktree List Create child") { list?.createWindow != nil && context.windows.count == count + 1 }
        let child = list?.createWindow
        try await wait("owned Worktree Create child reads") { child?.model.busy == false && child?.model.chooser.busy == false }
        try require(child?.model.chooser.repository.root.path == a.root.path && child?.window?.sheetParent === list?.window && child?.window?.alphaValue == 0, "List Create child lost owner/repository/hidden presentation")
        child?.close()
        try await wait("Worktree List child detached and reloaded") { list?.createWindow == nil && list?.model.busy == false && list?.window?.attachedSheet == nil }
        try require(list?.model.rows.count == 2, "cancelled List Create mutated worktree list")
        list?.close()
        let bareRoot = context.root.appendingPathComponent("bare.git")
        _ = try await a.run(["clone", "--bare", a.root.path, bareRoot.path]); try context.store.remember(bareRoot)
        let bareList = try await context.launch("worktreeList", paths: [bareRoot]) as? WorktreeListWindowController
        try await wait("bare Worktree List") { bareList?.model.busy == false && bareList?.model.rows.isEmpty == false }
        try require(bareList?.model.repository.root.path == bareRoot.path && bareList?.model.rows.first?.isBare == true, "source bare Worktree List unavailable")
        bareList?.close()
        let bareCreate = try await context.launch("worktreeCreate", paths: [bareRoot]) as? WorktreeCreateWindowController
        try await wait("bare Worktree Create source reads") { bareCreate?.model.busy == false && bareCreate?.model.chooser.busy == false }
        try require(bareCreate?.model.chooser.repository.root.path == bareRoot.path, "source bare Worktree Create unavailable")
        bareCreate?.close()
        for command in ["submoduleAdd", "submoduleUpdate", "submoduleSync", "logSubmodule"] { _ = try await context.launch(command, paths: [bareRoot], accepted: false) }
        let nested = a.root.appendingPathComponent("nested selection"); try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await context.launch("worktreeCreate", paths: [nested], accepted: false)
        let finalBHead = try await value(b, ["rev-parse", "HEAD"]), finalAHead = try await value(a, ["rev-parse", "HEAD"])
        try require(try bytes(b, ".git/index") == bIndex && finalBHead == bHead && finalAHead == aHead, "worktree workflows changed unrelated B or source HEAD")
        print("PASS: captured Worktree create/list with destination authority, actual branch/checkout, List child ownership, source bare support and nested/bare submodule refusal")
    }
    static func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func ownership() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), actualGit = URL(fileURLWithPath: CommandLine.arguments[2])
        let wrapper = root.appendingPathComponent("held-git"), started = root.appendingPathComponent("started-sync"), release = root.appendingPathComponent("release-sync"), dispatched = root.appendingPathComponent("dispatched-sync"), hold = root.appendingPathComponent("hold-sync")
        let script = """
        #!/bin/bash
        if [[ " $* " == *" submodule sync "* ]] && [[ -f \(quoted(hold.path)) ]]; then
          : > \(quoted(started.path))
          while [[ ! -e \(quoted(release.path)) ]]; do /bin/sleep .02; done
          : > \(quoted(dispatched.path))
        fi
        exec \(quoted(actualGit.path)) "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let context = try Context(root: root, git: wrapper)
        defer { try? Data().write(to: release); context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(context.workspace.root?.path ?? "nil"), error=\(context.workspace.error ?? "nil"), windows=\(context.windows.map { String(describing: type(of: $0.1)) })" }
        let a = try await context.make("authorityA"), b = try await context.make("workspaceB"), c = try await context.make("first-useC"), source = try await context.make("localSource")
        _ = try await a.run(["submodule", "add", "--", source.root.path, "module"]); _ = try await a.commit(message: "module baseline")
        try context.store.remember(a.root); try context.store.remember(b.root); try await context.open(b)
        let beforeC = try bytes(c, ".git/index"), beforeA = try bytes(a, ".git/index")
        var grantReply: ((NSApplication.ModalResponse) -> Void)?, grantPanels: [NSOpenPanel] = []
        context.workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); grantPanels.append(panel); grantReply = completion; parent?.beginSheet(panel, completionHandler: nil)
        }
        context.workspace.selectedFinderServiceFolderURL = { _ in c.root }
        defer { grantReply?(.cancel); grantPanels.forEach { panel in panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.close() } }
        let selected = board([c.root]); defer { selected.releaseGlobally() }
        let count = context.windows.count
        try require(invoke(context.delegate.finderServicesProvider, selected, "submoduleAdd") == nil, "first-use Submodule Add rejected before authority")
        try await wait("actual first-use repository authority") { grantReply != nil && context.host.attachedSheet != nil }
        try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored first-use linked repository authority")
        let lateGrant = grantReply; grantReply?(.cancel); grantReply = nil
        try await wait("first-use linked authority cancelled") { !context.workspace.hasPendingFinderServiceWork && context.host.attachedSheet == nil }
        lateGrant?(.OK)
        try require(context.windows.count == count && context.workspace.root?.path == b.root.path && bytes(c, ".git/index") == beforeC, "late cancelled linked authority opened/adopted/mutated C")
        try require(invoke(context.delegate.finderServicesProvider, selected, "submoduleAdd") == nil, "replacement linked authority rejected")
        try await wait("replacement linked authority") { grantReply != nil }; grantReply?(.OK); grantReply = nil
        try await wait("actual first-use Submodule Add form") { context.windows.count == count + 1 && !context.workspace.busy && !context.workspace.hasPendingFinderServiceWork }
        guard let add = context.windows.last?.1 as? SubmoduleAddWindowController else { throw Failure(description: "Submodule Add form missing") }
        try require(add.model.repository.root.path == c.root.path && context.windows.last?.3?.hasSecurityScope == true, "first-use Add lost captured repository authority")
        var pickerReply: ((NSApplication.ModalResponse) -> Void)?, sourcePanels: [NSOpenPanel] = []
        add.presentOpenPanel = { panel, parent, completion in panel.alphaValue = 0; sourcePanels.append(panel); pickerReply = completion; parent.beginSheet(panel, completionHandler: nil) }
        add.selectedPanelURL = { _ in source.root }
        let oldSource = add.model.source
        add.model.pick(.repository)
        try await wait("actual owned Add source picker") { pickerReply != nil && add.window?.attachedSheet != nil }
        try require(add.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "source picker lost owner/Quit lifetime")
        var addClosed = false; let priorAddClose = add.onClosed
        add.onClosed = { addClosed = true; priorAddClose() }
        let lateSource = pickerReply; add.close()
        try require(!addClosed && add.finderServiceWorkPending, "Submodule Add published close before source picker detached")
        try await wait("Add source picker drained") { addClosed && !add.finderServiceWorkPending }
        lateSource?(.OK); pickerReply = nil
        try require(add.model.source == oldSource && bytes(c, ".git/index") == beforeC && sourcePanels.allSatisfy { $0.sheetParent == nil }, "late source picker edited/started a closed Add form")
        // Worktree creation uses the real owned destination permission panel.
        try await context.open(b)
        guard let create = try await context.launch("worktreeCreate", paths: [a.root]) as? WorktreeCreateWindowController else { throw Failure(description: "Worktree Create missing") }
        try await wait("Worktree Create reads before destination permission") { !create.model.busy && !create.model.chooser.busy }
        create.model.requiresSecurityScope = true; create.directoryBookmarkProvider = LinkedServiceScopes()
        var destinationReply: ((NSApplication.ModalResponse) -> Void)?, destinationPanels: [NSOpenPanel] = [], destinationToken: OperationCancellation?
        create.presentDirectoryPanel = { panel, parent, completion in panel.alphaValue = 0; destinationPanels.append(panel); destinationReply = completion; parent.beginSheet(panel, completionHandler: nil) }
        create.selectedDirectoryURL = { _ in root }
        let realAuthorization = create.model.authorizeDestination
        create.model.authorizeDestination = { path, token in destinationToken = token; return try await realAuthorization(path, token) }
        let destination = root.appendingPathComponent("must-not-create")
        create.model.directory = destination.path; create.model.createBranch = true; create.model.branchName = "must-not-create"
        create.model.create()
        try await wait("actual Worktree destination authority") { destinationReply != nil && create.model.authorizingDestination && create.window?.attachedSheet != nil }
        try require(destinationToken != nil && create.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Worktree destination authority lost token/worker/Quit")
        var createClosed = false; let priorCreateClose = create.onClosed
        create.onClosed = { createClosed = true; priorCreateClose() }
        let lateDestination = destinationReply; create.close()
        try require(destinationToken?.isCancelled == true && !createClosed && create.finderServiceWorkPending, "Worktree close released pending authorization worker")
        try await wait("Worktree destination authorization drained") { createClosed && !create.finderServiceWorkPending && WorktreeCreateWindowModel.activeOperations == 0 }
        lateDestination?(.OK); destinationReply = nil
        let refs = try await value(a, ["for-each-ref", "--format=%(refname)", "refs/heads/must-not-create"])
        try require(!FileManager.default.fileExists(atPath: destination.path) && refs.isEmpty && create.model.destinationAccess == nil && destinationPanels.allSatisfy { $0.sheetParent == nil }, "late Worktree authority created/granted/reopened after owner close")
        // Hold the actual Git child for Sync before exec of the real mutation.
        // Forced close must cancel/reap that process, retain the scoped owner
        // until receipt, and never dispatch the delayed mutation afterward.
        let urlBefore = try await value(a, ["config", "--get", "submodule.module.url"])
        _ = try await a.run(["config", "--file", ".gitmodules", "submodule.module.url", b.root.path])
        try Data().write(to: hold)
        let sync = try await context.launch("submoduleSync", paths: [a.root]) as? SubmoduleSyncWindowController
        try await wait("actual owned Sync child held") { FileManager.default.fileExists(atPath: started.path) && sync?.model.busy == true }
        guard let sync else { throw Failure(description: "Sync missing") }
        try require(sync.finderServiceWorkPending && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Sync worker lost owner/Quit")
        var syncClosed = false; let priorSyncClose = sync.onClosed
        sync.onClosed = { syncClosed = true; priorSyncClose() }
        sync.close()
        try require(!syncClosed && sync.finderServiceWorkPending, "Sync forced close retired before actual Git child receipt")
        try await wait("actual Sync Git process and owner drained") { syncClosed && !sync.finderServiceWorkPending && SubmoduleSyncWindowModel.activeOperations == 0 }
        let urlAfter = try await value(a, ["config", "--get", "submodule.module.url"])
        try require(urlAfter == urlBefore && !FileManager.default.fileExists(atPath: dispatched.path) && bytes(a, ".git/index") == beforeA, "cancelled Sync dispatched a late mutation or changed index")
        try await wait("linked Services own scopes retired") { !context.workspace.hasPendingRepositoryWork && !context.workspace.hasPendingFinderServiceWork }
        print("PASS: first-use linked authority Cancel/replacement/late fence, actual Add source picker and Worktree destination panel drain, forced-close token/Quit ownership, cancelled/reaped real Sync child with no late mutation")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitLinkedServicesOrder(_:relativeTo:)))!
        method_exchangeImplementations(original, hidden); defer { method_exchangeImplementations(original, hidden) }
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_LINKED_SERVICES_CASE"] {
        case "provider": try provider()
        case "submodules": try await submodules()
        case "worktrees": try await worktrees()
        case "ownership": try await ownership()
        default: throw Failure(description: "Unknown linked Services case")
        }
        print("PASS: linked Services case completed")
    }
}
private extension NSWindow {
    @objc func turtleGitLinkedServicesOrder(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        alphaValue = 0; turtleGitLinkedServicesOrder(place, relativeTo: otherWin)
    }
}
