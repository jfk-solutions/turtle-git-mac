// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private struct FileServiceScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
private actor FileServiceReadGate {
    var token: OperationCancellation?
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func hold(_ token: OperationCancellation) async {
        self.token = token
        if !released { await withCheckedContinuation { continuation = $0 } }
    }
    func finish() { released = true; continuation?.resume(); continuation = nil }
}
@main struct FinderFileServicesVerification {
    static let commands = ["add", "revert", "resolve", "resolveCurrent", "resolveMine", "resolveTheirs", "blame", "previousDiff", "editConflict", "ignore", "ignoreMask", "ignoreDelete", "ignoreDeleteMask"]
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
    @MainActor static func provider() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = root.appendingPathComponent(literal)
        try Data("unchanged\n".utf8).write(to: file)
        let selected = board([file]); defer { selected.releaseGlobally() }
        var received: [FinderRequest] = []
        let provider = TurtleGitFinderServicesProvider { received.append($0) }; defer { provider.retire() }
        let count = selected.changeCount
        for command in commands {
            try require(invoke(provider, selected, command) == nil, "provider rejected \(command)")
            try require(received.last?.action.rawValue == command && received.last?.paths.map(\.path) == [file.path], "provider rewrote selected literal path")
        }
        try require(selected.changeCount == count && received.count == 13, "provider changed pasteboard or duplicated dispatch")
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])), format: nil) as! [String: Any]
        let services = plist["NSServices"] as? [[String: Any]] ?? []
        try require(services.count == 56 && Set(services.compactMap { $0["NSUserData"] as? String }) == Set(FinderServiceCommand.allCases.map(\.rawValue)), "56 service declarations differ from Core")
        for command in commands {
            let matches = services.filter { $0["NSUserData"] as? String == command }
            try require(matches.count == 1 && matches[0]["NSMessage"] as? String == "performFinderAction" && matches[0]["NSSendFileTypes"] as? [String] == ["public.item"], "selected-file declaration invalid: \(command)")
        }
        provider.retire(); try require(invoke(provider, selected, "add") != nil && received.count == 13, "retired provider accepted file mutation")
        print("PASS: all13 selected-file private-pasteboard commands and47 native Services declarations preserve literal selection")
    }
    @MainActor static func busy(_ controller: NSWindowController) -> Bool {
        switch controller {
        case let value as AddProgressWindowController: return value.model.busy
        case let value as AddWindowController: return value.model.busy
        case let value as RevertWindowController: return value.model.busy
        case let value as ResolveWindowController: return value.model.busy || (!value.model.showingProgress && value.model.entries.isEmpty && value.model.error == nil)
        case let value as IgnoreWindowController: return value.model.busy
        case let value as BlameWindowController: return value.model.busy || value.model.loadingParents || (value.model.snapshot == nil && value.model.error == nil)
        case let value as FileComparisonWindowController: return value.model.busy || value.model.filtering || (value.model.document == nil && value.model.error == nil)
        case let value as TextConflictWindowController: return value.model.busy || value.model.preparing || (value.model.document == nil && value.model.error == nil)
        default: return false
        }
    }
    @MainActor final class Context {
        let root: URL, git: URL, defaults: UserDefaults, suite: String
        let store: RepositoryAccessStore
        let workspace: RepositoryModel
        let host: NSWindow
        let delegate = TurtleGitApplicationDelegate()
        var windows: [(RepositoryAction, NSWindowController, GitRepository, RepositoryAccessLease?)] = []
        var questions: [String] = []
        var keepLocal = true
        init(root: URL, git: URL) throws {
            self.root = root; self.git = git; suite = "TurtleGit.FileServices.QA." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
            store = try RepositoryAccessStore(storageURL: root.appendingPathComponent("access.json"), provider: FileServiceScopes())
            workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: root.appendingPathComponent("marks.json")))
            workspace.repositoryBookmarkProvider = FileServiceScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = defaults
            host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.alphaValue = 0; host.isReleasedWhenClosed = false; host.orderFront(nil); workspace.workspaceWindow = host
            workspace.finderServiceWorkflowPresentation = { [weak self] action, controller, repository, access in
                guard let self else { return }
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                if let value = controller as? ResolveWindowController {
                    value.presentQuestion = { [weak self] owner, alert, completion in
                        self?.questions.append(alert.messageText); alert.window.alphaValue = 0
                        alert.beginSheetModal(for: owner, completionHandler: completion)
                        Task { @MainActor in await Task.yield(); alert.buttons[0].performClick(nil) }
                        return true
                    }
                }
                if let value = controller as? IgnoreWindowController {
                    value.presentQuestion = { [weak self] owner, alert, completion in
                        self?.questions.append(alert.messageText); alert.window.alphaValue = 0
                        let answer = alert.messageText == "Keep file locally?" && self?.keepLocal == false ? 1 : 0
                        alert.beginSheetModal(for: owner, completionHandler: completion)
                        Task { @MainActor in await Task.yield(); alert.buttons[answer].performClick(nil) }
                        return true
                    }
                }
                self.windows.append((action, controller, repository, access))
            }
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
            try await wait("\(command) native read/action") { !busy(captured.1) && !self.workspace.busy }
            return captured.1
        }
    }
    @MainActor static func paths() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "root=\(String(describing: context.workspace.root)), busy=\(context.workspace.busy), pending=\(context.workspace.hasPendingRepositoryWork), error=\(String(describing: context.workspace.error)), windows=\(context.windows.map { $0.0.rawValue })" }
        let a = try await context.make("repoA"), b = try await context.make("repoB")
        try context.store.remember(a.root); try context.store.remember(b.root)
        func stable(_ repo: GitRepository) async throws -> [Data] {
            let refs = try await repo.run(["for-each-ref", "--format=%(refname) %(objectname)"]).stdout
            return try [refs] + [".git/HEAD", ".git/config", ".git/index", literal, "normal.txt"].map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        }
        let beforeB = try await stable(b), headA = try await a.run(["rev-parse", "HEAD"]).stdout
        try Data("working\n".utf8).write(to: a.root.appendingPathComponent(literal))
        for command in ["revert", "blame", "previousDiff"] {
            try await context.open(b)
            let beforeIndex = try Data(contentsOf: a.root.appendingPathComponent(".git/index"))
            let controller = try await context.launch(command, paths: [a.root.appendingPathComponent(literal)])
            try require(context.workspace.root?.path == a.root.path, "\(command) used workspace B")
            switch command {
            case "revert":
                let model = (controller as? RevertWindowController)?.model
                try require(model?.entries.map(\.path) == [literal], "Revert lost selected literal scope")
            case "blame": try require((controller as? BlameWindowController)?.model.path == literal && (controller as? BlameWindowController)?.model.snapshot != nil && (controller as? BlameWindowController)?.model.error == nil, "Blame lost selected literal path")
            default: try require((controller as? FileComparisonWindowController)?.model.path == literal && (controller as? FileComparisonWindowController)?.model.document != nil && (controller as? FileComparisonWindowController)?.model.error == nil, "PreviousDiff lost selected literal path")
            }
            controller?.close()
            let afterIndex = try Data(contentsOf: a.root.appendingPathComponent(".git/index")), working = try Data(contentsOf: a.root.appendingPathComponent(literal))
            try require(afterIndex == beforeIndex && working == Data("working\n".utf8), "review/view mutated selected working/index bytes")
        }
        // Ordinary file Add is an explicit source action: stage exactly the
        // selected path, including punctuation and a literal symlink leaf.
        let new = "new [n]; 雪\n.txt", other = "other-untracked.txt", link = "external link"
        try Data("new\n".utf8).write(to: a.root.appendingPathComponent(new)); try Data("other\n".utf8).write(to: a.root.appendingPathComponent(other))
        try FileManager.default.createSymbolicLink(at: a.root.appendingPathComponent(link), withDestinationURL: b.root.appendingPathComponent("normal.txt"))
        try await context.open(b)
        let add = try await context.launch("add", paths: [a.root.appendingPathComponent(new), a.root.appendingPathComponent(link)]) as? AddProgressWindowController
        try require(add?.model.success == true && add?.model.paths == [new, link], "Add did not stage exact captured file order")
        let added = try await a.run(["ls-files", "--stage", "--", new]).stdout
        let symlink = try await a.run(["ls-files", "--stage", "--", link]).stdout
        let untouched = try await a.run(["ls-files", "--", other]).stdout
        try require(!added.isEmpty && String(decoding: symlink, as: UTF8.self).hasPrefix("120000 ") && untouched.isEmpty, "Add followed symlink or staged unrelated selection")
        add?.close()
        let folder = a.root.appendingPathComponent("scope"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside\n".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        let folderIndex = try Data(contentsOf: a.root.appendingPathComponent(".git/index"))
        let addFolder = try await context.launch("add", paths: [folder]) as? AddWindowController
        try require(addFolder?.model.entries.map(\.path) == ["scope/inside.txt"], "folder Add review expanded outside selected directory")
        addFolder?.close()
        let afterFolderIndex = try Data(contentsOf: a.root.appendingPathComponent(".git/index"))
        try require(afterFolderIndex == folderIndex, "folder Add staged before review acceptance")
        // Native Ignore mode dialogs retain source filename/mask/delete choices.
        for (command, name, drop) in [("ignore", "ignore [i].tmp", false), ("ignoreMask", "mask.log", false), ("ignoreMask", ".profile", false), ("ignoreDelete", "delete.keep", false), ("ignoreDeleteMask", "delete.drop", true)] {
            if !command.contains("Delete") { try Data("untracked\n".utf8).write(to: a.root.appendingPathComponent(name)) }
            try await context.open(b)
            let controller = try await context.launch(command, paths: [a.root.appendingPathComponent(name)]) as? IgnoreWindowController
            try require(controller?.model.options.paths == [name] && controller?.model.options.mask == command.hasSuffix("Mask"), "Ignore mode/scope changed: \(command)")
            context.keepLocal = !drop
            controller?.model.apply()
            try await wait("actual \(command) completion") { IgnoreWindowModel.activeOperations == 0 && !context.workspace.busy }
            try require(controller?.model.error == nil, "Ignore operation failed")
            let checked = try await a.run(["check-ignore", "--no-index", "--", name], literalPathspecs: false, successfulExitCodes: 0...1).stdout
            try require(!checked.isEmpty, "Ignore did not write matching rule for \(command)")
            if command.contains("Delete") {
                let tracked = try await a.run(["ls-files", "--", name]).stdout
                try require(tracked.isEmpty && FileManager.default.fileExists(atPath: a.root.appendingPathComponent(name).path) == !drop, "Ignore delete/keep-local effects changed")
            }
            controller?.close()
        }
        try require(context.questions.contains("Keep file locally?"), "Ignore deletion bypassed source keep-local question")
        // Live eligibility must distinguish normal, added and untracked paths.
        for command in ["add", "revert", "ignore", "resolve", "resolveCurrent", "editConflict"] { _ = try await context.launch(command, paths: [a.root.appendingPathComponent("normal.txt")], accepted: false) }
        for command in ["blame", "previousDiff"] { _ = try await context.launch(command, paths: [a.root.appendingPathComponent(new)], accepted: false) }
        for command in ["revert", "blame", "previousDiff"] { _ = try await context.launch(command, paths: [a.root.appendingPathComponent(other)], accepted: false) }
        let bareRoot = context.root.appendingPathComponent("bare.git")
        _ = try await a.run(["clone", "--bare", a.root.path, bareRoot.path]); try context.store.remember(bareRoot)
        for command in commands { _ = try await context.launch(command, paths: [bareRoot], accepted: false) }
        // First-use Add needs owned folder authority before it may stage.
        let c = try await context.make("unsavedC"), pending = c.root.appendingPathComponent("first-use [p].txt")
        try Data("pending\n".utf8).write(to: pending); try await context.open(b)
        var reply: ((NSApplication.ModalResponse) -> Void)?, panels: [NSOpenPanel] = []
        context.workspace.presentFinderServiceFolderPanel = { panel, parent, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panels.append(panel); reply = completion; parent?.beginSheet(panel, completionHandler: nil)
        }
        context.workspace.selectedFinderServiceFolderURL = { _ in c.root }
        defer { reply?(.cancel); panels.forEach { panel in if let owner = panel.sheetParent { owner.endSheet(panel, returnCode: .cancel) }; panel.close() } }
        let selected = board([pending]); defer { selected.releaseGlobally() }
        let initialWindows = context.windows.count, cIndex = try Data(contentsOf: c.root.appendingPathComponent(".git/index"))
        try require(invoke(context.delegate.finderServicesProvider, selected, "add") == nil, "first-use Add rejected before permission")
        try await wait("owned Add folder grant") { reply != nil && context.host.attachedSheet === panels.last }
        try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored pending Add permission")
        let late = reply; reply?(.cancel); reply = nil
        try await wait("cancelled Add grant detached") { !context.workspace.hasPendingFinderServiceWork && context.host.attachedSheet == nil }
        late?(.OK)
        let cancelledIndex = try Data(contentsOf: c.root.appendingPathComponent(".git/index"))
        try require(context.windows.count == initialWindows && cancelledIndex == cIndex && context.workspace.root?.path == b.root.path, "cancelled/late Add permission mutated or adopted C")
        // Mixed repositories are not a transport batch. Grant the private common
        // parent explicitly, then verify discovery refuses the mixed file scope.
        context.workspace.selectedFinderServiceFolderURL = { _ in context.root }
        let mixed = board([a.root.appendingPathComponent(literal), b.root.appendingPathComponent(literal)]); defer { mixed.releaseGlobally() }
        context.workspace.error = nil
        let mixedStart = context.windows.count
        try require(invoke(context.delegate.finderServicesProvider, mixed, "revert") == nil, "mixed request did not reach owned validation")
        try await wait("mixed scope folder grant or early refusal") { reply != nil || (!context.workspace.hasPendingFinderServiceWork && context.workspace.error != nil) }
        reply?(.OK); reply = nil
        try await wait("mixed repository rejection") { !context.workspace.busy && !context.workspace.hasPendingFinderServiceWork && context.workspace.error != nil }
        try require(context.windows.count == mixedStart, "mixed repositories opened one narrowed file dialog")
        // An accepted first-use Add retains its selected scope and Quit owner
        // through asynchronous preflight, even after the workspace closes.
        let gate = FileServiceReadGate()
        context.workspace.addSelectionPreflight = { repository, paths, token in
            await gate.hold(token)
            try token.check()
            return try await repository.addSelectionIsFiles(paths, cancellation: token)
        }
        context.workspace.selectedFinderServiceFolderURL = { _ in c.root }
        let heldStart = context.windows.count
        do {
            try require(invoke(context.delegate.finderServicesProvider, selected, "add") == nil, "held first-use Add rejected")
            for _ in 0..<3000 {
                let started = await gate.token != nil
                if reply != nil || started { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            reply?(.OK); reply = nil
            for _ in 0..<3000 { if await gate.token != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            let token = await gate.token
            try require(token != nil && context.workspace.hasPendingRepositoryWork && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Add preflight lost scope/worker/Quit ownership")
            context.host.close()
            try require(token?.isCancelled == true && context.workspace.hasPendingRepositoryWork, "owner close released held Add before worker drain")
            await gate.finish()
            try await wait("retired Add preflight drain") { !context.workspace.hasPendingRepositoryWork && !context.workspace.busy }
            let retiredIndex = try Data(contentsOf: c.root.appendingPathComponent(".git/index"))
            try require(retiredIndex == cIndex && context.windows.count == heldStart, "late retired Add preflight staged/presented")
        } catch {
            context.host.close(); await gate.finish()
            for _ in 0..<3000 { if !context.workspace.hasPendingRepositoryWork { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        let afterB = try await stable(b), finalHead = try await a.run(["rev-parse", "HEAD"]).stdout
        try require(afterB == beforeB && finalHead == headA, "file Services changed unrelated B or committed A")
        print("PASS: literal selected-path views/reviews, direct file Add/symlink, four Ignore modes and actual keep/delete effects, live bare/normal/added/untracked/mixed eligibility, owned Add permission Cancel/late fence")
    }
    @MainActor static func conflicts() async throws {
        let context = try Context(root: URL(fileURLWithPath: CommandLine.arguments[1]), git: URL(fileURLWithPath: CommandLine.arguments[2]))
        defer { context.finish(); diagnostic = { "" } }
        diagnostic = { "conflict root=\(String(describing: context.workspace.root)), error=\(String(describing: context.workspace.error)), busy=\(context.workspace.busy), windows=\(context.windows.map { $0.0.rawValue })" }
        let a = try await context.make("conflictA"), b = try await context.make("workspaceB")
        try context.store.remember(a.root); try context.store.remember(b.root)
        let names = ["current; 雪.txt", "mine [m].txt", "theirs\n.txt"]
        for name in names { try Data("base\n".utf8).write(to: a.root.appendingPathComponent(name)) }
        try await a.stage(names); _ = try await a.commit(message: "three bases")
        _ = try await a.run(["switch", "-c", "side"])
        for (index, name) in names.enumerated() { try Data("theirs \(index)\n".utf8).write(to: a.root.appendingPathComponent(name)) }
        try await a.stage(names); _ = try await a.commit(message: "side")
        _ = try await a.run(["switch", "main"])
        for (index, name) in names.enumerated() { try Data("mine \(index)\n".utf8).write(to: a.root.appendingPathComponent(name)) }
        try await a.stage(names); _ = try await a.commit(message: "main")
        _ = try await a.run(["merge", "side"], successfulExitCodes: 0...1)
        let head = try await a.run(["rev-parse", "HEAD"]).stdout, merge = try Data(contentsOf: a.root.appendingPathComponent(".git/MERGE_HEAD"))
        let bIndex = try Data(contentsOf: b.root.appendingPathComponent(".git/index")), bHead = try await b.run(["rev-parse", "HEAD"]).stdout
        try await context.open(b)
        let beforeReview = try Data(contentsOf: a.root.appendingPathComponent(".git/index"))
        let review = try await context.launch("resolve", paths: names.prefix(2).map { a.root.appendingPathComponent($0) }) as? ResolveWindowController
        try require(review?.model.paths == Array(names.prefix(2)) && review?.model.quick == nil && Set(review?.model.entries.map(\.path) ?? []) == Set(names.prefix(2)), "Resolve review scope changed")
        review?.close()
        let editor = try await context.launch("editConflict", paths: names.prefix(2).map { a.root.appendingPathComponent($0) }) as? TextConflictWindowController
        try require(editor?.model.path == names[0] && editor?.model.document != nil && editor?.model.error == nil, "multi-selection EditConflict did not consume first captured path")
        editor?.close()
        let afterReview = try Data(contentsOf: a.root.appendingPathComponent(".git/index"))
        try require(afterReview == beforeReview, "Resolve/EditConflict mutated before explicit resolution")
        let currentBytes = try Data(contentsOf: a.root.appendingPathComponent(names[0]))
        for (index, command) in ["resolveCurrent", "resolveMine", "resolveTheirs"].enumerated() {
            try await context.open(b)
            let controller = try await context.launch(command, paths: [a.root.appendingPathComponent(names[index])]) as? ResolveWindowController
            try await wait("actual source quick-resolution question/action") { controller?.model.success == true && controller?.model.busy == false && controller?.model.hasQuestion == false && !context.workspace.busy }
            try require(controller?.model.paths == [names[index]], "quick resolution changed path scope")
            let working = try Data(contentsOf: a.root.appendingPathComponent(names[index]))
            let expected = index == 0 ? currentBytes : Data((index == 1 ? "mine 1\n" : "theirs 2\n").utf8)
            let staged = try await a.run(["show", ":" + names[index]]).stdout
            try require(working == expected && staged == expected, "\(command) staged wrong source side/current bytes")
            let unmerged = try await a.run(["diff", "--name-only", "--diff-filter=U", "-z"]).stdout
            let remaining = Set(unmerged.split(separator: 0).map { Data($0) }), expectedRemaining = Set(names.dropFirst(index + 1).map { Data($0.utf8) })
            try require(remaining == expectedRemaining, "quick resolution narrowed/expanded other conflicts")
            controller?.close()
        }
        try require(context.questions.filter { $0.contains("mark the conflicted") }.count == 3, "quick resolve bypassed/duplicated source questions")
        let afterHead = try await a.run(["rev-parse", "HEAD"]).stdout, afterMerge = try Data(contentsOf: a.root.appendingPathComponent(".git/MERGE_HEAD"))
        let afterBHead = try await b.run(["rev-parse", "HEAD"]).stdout, afterBIndex = try Data(contentsOf: b.root.appendingPathComponent(".git/index"))
        try require(afterHead == head && afterMerge == merge && afterBHead == bHead && afterBIndex == bIndex, "quick resolve committed/cleared merge state or mutated workspace B")
        try await wait("selected conflict workers drained") { ResolveWindowModel.activeOperations == 0 && !context.workspace.hasPendingRepositoryWork }
        print("PASS: selected Resolve/EditConflict review, first-selected multi editor, real source questions and Current/Mine/Theirs index/worktree effects, preserved other conflicts/HEAD/merge state/workspace B")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_FILE_SERVICES_CASE"] {
        case "provider": try provider()
        case "paths": try await paths()
        case "conflicts": try await conflicts()
        default: throw Failure(description: "Unknown selected-file Services case")
        }
        print("PASS: selected-file Services case completed")
    }
}
