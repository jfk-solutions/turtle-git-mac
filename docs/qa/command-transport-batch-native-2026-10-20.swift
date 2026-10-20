// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

private struct CommandTransportScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
@main struct CommandTransportBatchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: UInt = #line) throws { if !value { throw Failure(description: "\(line): \(message)") } }
    @MainActor static var diagnostic: () -> String = { "" }
    @MainActor static func wait(_ message: String, line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "\(line): \(message); \(diagnostic())")
    }
    @MainActor static func pending(_ value: NSWindowController) -> Bool {
        switch value {
        case let child as FetchWindowController: return child.serviceWorkPending || child.model.preparing || child.model.busy
        case let child as PushWindowController: return child.serviceWorkPending || child.model.preparing || child.model.busy
        case let child as SwitchWindowController: return child.model.busy
        case let child as RebaseWindowController: return child.model.busy || child.model.loadingPlan || child.model.loadingColumnMetadata
        default: return false
        }
    }
    @MainActor static func ready(_ value: NSWindowController) -> Bool {
        switch value {
        case let child as FetchWindowController: return !child.model.busy && !child.model.preparing
        case let child as PushWindowController: return !child.model.busy && !child.model.preparing
        case let child as SwitchWindowController: return !child.model.busy
        default: return !pending(value)
        }
    }
    @MainActor static func cancel(_ value: NSWindowController) {
        if let child = value as? FetchWindowController { child.model.cancel() }
        else if let child = value as? PushWindowController { child.model.cancel() }
        else { value.window?.performClose(nil) }
    }
    @MainActor final class Context {
        let directory: URL, git: URL, suite: String, defaults: UserDefaults, store: RepositoryAccessStore, workspace: RepositoryModel, host: NSWindow
        let delegate = TurtleGitApplicationDelegate()
        var shown: [(RepositoryAction, NSWindowController, GitRepository, RepositoryAccessLease?)] = []
        init(directory: URL, git: URL, executable: ((URL) -> URL)? = nil) throws {
            self.directory = directory; self.git = git; suite = "TurtleGit.CommandTransport.QA." + UUID().uuidString; defaults = UserDefaults(suiteName: suite)!
            store = try RepositoryAccessStore(storageURL: directory.appendingPathComponent("access.json"), provider: CommandTransportScopes())
            workspace = RepositoryModel(startMonitoring: false, initializePreferences: false, repositoryFactory: { GitRepository(root: $0, executable: executable?($0) ?? git) }, snapshotWriter: { _ in false }, savedAccessStore: store, comparisonMarks: WorkingComparisonMarkStore(storageURL: directory.appendingPathComponent("marks.json")))
            workspace.repositoryBookmarkProvider = CommandTransportScopes(); workspace.requiresRepositoryScope = true; workspace.fileComparisonPreferences = defaults; workspace.transportClipboardText = { nil }; defaults.set(0, forKey: "AutoCloseGitProgress")
            host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false; host.alphaValue = 0; host.orderFront(nil); workspace.workspaceWindow = host
            workspace.commandTransportWorkflowPresentation = { [weak self] action, controller, repository, access in
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000))
                self?.shown.append((action, controller, repository, access))
            }
            delegate.startupArguments = []; delegate.startupCommandHandler = { _, _, _ in }; delegate.repositoryModel = workspace; delegate.startupDidFinishLaunching()
        }
        func finish() {
            delegate.retireFinderServices(); workspace.stopMonitoringForTermination()
            shown.forEach { $0.1.close() }
            // This receiver is a private process. A routing defect may create a
            // real form before its capture hook; retire those windows too.
            for window in NSApp.windows {
                if let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
                if let parent = window.sheetParent { parent.endSheet(window, returnCode: .abort) }
                window.close(); window.orderOut(nil)
            }
            host.close(); defaults.removePersistentDomain(forName: suite)
        }
        func invoke(_ command: String, _ paths: [URL]) throws {
            var args = ["/command:" + command, "/path:" + paths.map(\.path).joined(separator: "*")]
            if command == "fetch" { args.append("/remote:mirror") }
            if command == "push" { args.append("/branch:topic") }
            guard let parsed = try PrimaryCommandInvocation.parse(arguments: args, currentDirectory: directory.path) else { throw Failure(description: "CLI parse failed") }
            try require(parsed.transportPaths.map(\.path) == paths.map(\.path), "CLI rewrote raw path order/duplicates")
            workspace.handleCommandLine(arguments: args, currentDirectory: directory.path)
        }
        func child(_ index: Int, action: RepositoryAction, root: URL) async throws -> NSWindowController {
            try await wait("child \(index) \(action)") { self.shown.count > index && ready(self.shown[index].1) }
            let capture = shown[index]
            let actionMatches = capture.0 == action, rootMatches = capture.2.root.path == root.path
            let containsRoot = capture.3?.contains(root) == true, scoped = capture.3?.hasSecurityScope == true
            try require(actionMatches && rootMatches && containsRoot && scoped,
                "CLI child action/root/scoped ownership changed: index=\(index), actualAction=\(capture.0.rawValue), expectedAction=\(action.rawValue), actualRoot=\(capture.2.root.absoluteString), expectedRoot=\(root.absoluteString), lease=\(String(describing: capture.3?.url.absoluteString)), hasScope=\(scoped), containsExpectedRoot=\(containsRoot), actionMatches=\(actionMatches), rootMatches=\(rootMatches)")
            try require(capture.1.window?.alphaValue == 0, "CLI child became visible")
            return capture.1
        }
        func drain() async throws { try await wait("CLI batch drain") { !self.workspace.busy && !self.workspace.hasPendingRepositoryWork && RepositoryModel.activeCommandFileOperations == 0 } }
    }
    static func configure(_ repo: GitRepository) async throws {
        for (key, value) in [("user.name", "CLI Transport QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("branch.main.remote", "mirror"), ("branch.main.merge", "refs/heads/main"), ("remote.pushDefault", "mirror")] { _ = try await repo.run(["config", key, value]) }
    }
    static func make(_ root: URL, git: URL) async throws -> GitRepository {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let repo = GitRepository(root: root, executable: git); _ = try await repo.run(["init", "-b", "main"]); try await configure(repo)
        try Data("base\n".utf8).write(to: root.appendingPathComponent("nested/file")); try await repo.stage(["nested/file"]); _ = try await repo.commit(message: "base")
        try Data("next\n".utf8).write(to: root.appendingPathComponent("nested/file")); try await repo.stage(["nested/file"]); _ = try await repo.commit(message: "next")
        _ = try await repo.run(["branch", "topic"]); _ = try await repo.run(["remote", "add", "mirror", root.path])
        return repo
    }
    static func snapshot(_ repo: GitRepository, bare: Bool = false) async throws -> [Data] {
        let refs = try await repo.run(["for-each-ref", "--format=%(refname) %(objectname)"]).stdout
        let files = bare ? ["HEAD", "config"] : [".git/HEAD", ".git/index", ".git/config", "nested/file"]
        return try [refs] + files.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
    }
    @MainActor static func dialogs() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let a = try await make(directory.appendingPathComponent("A 雪"), git: git), b = try await make(directory.appendingPathComponent("B space"), git: git)
        _ = try await a.run(["bisect", "start", "HEAD", "HEAD~1"])
        let bareRoot = directory.appendingPathComponent("bare.git"); _ = try await a.run(["clone", "--bare", b.root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git); _ = try await bare.run(["remote", "add", "mirror", b.root.path])
        let invalid = directory.appendingPathComponent("not-a-repository"); try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        let context = try Context(directory: directory, git: git); defer { context.finish(); diagnostic = { "" } }
        for root in [a.root, b.root, bareRoot, invalid] { try context.store.remember(root) }
        diagnostic = { "CLI roots=\(context.shown.map { $0.2.root.path }), busy=\(context.workspace.busy), pending=\(context.workspace.hasPendingRepositoryWork), error=\(String(describing: context.workspace.error))" }
        let beforeA = try await snapshot(a), beforeB = try await snapshot(b), beforeBare = try await snapshot(bare, bare: true)
        for command in ["fetch", "pull", "push"] {
            let start = context.shown.count
            try context.invoke(command, [b.root, b.root.appendingPathComponent("nested"), invalid, bareRoot, a.root, b.root])
            for (offset, root) in [b.root, bareRoot, a.root, b.root].enumerated() {
                let action = RepositoryAction(rawValue: command)!
                let child = try await context.child(start + offset, action: action, root: root)
                try require(context.shown.count == start + offset + 1, "CLI overlapped repository dialogs")
                let other = root.path == a.root.path ? b.root : a.root
                try require(context.shown[start + offset].3?.contains(other) == false, "CLI reused another separately saved root grant")
                if let fetch = child as? FetchWindowController {
                    try require(fetch.model.isPull == (command == "pull"), "CLI Pull/Fetch mode changed")
                    if command == "fetch" { try require(fetch.model.options.remote == "mirror", "Fetch /remote preset lost") }
                } else { try require((child as? PushWindowController)?.model.options.source == "topic", "Push /branch preset lost") }
                cancel(child)
                try await wait("cancelled child/read drain") { child.window?.isVisible == false && !pending(child) }
            }
            try await context.drain()
        }
        let prior = context.shown.count
        try context.invoke("fetch", [a.root.appendingPathComponent("nested"), a.root.appendingPathComponent("nested")])
        try await context.drain()
        try require(context.shown.count == prior && context.workspace.error != nil, "duplicate nonroot paths widened to a single containing repository")
        let afterA = try await snapshot(a), afterB = try await snapshot(b), afterBare = try await snapshot(bare, bare: true)
        try require(afterA == beforeA && afterB == beforeB && afterBare == beforeBare, "cancelled CLI forms mutated Git/index/worktree")
        print("PASS: ordered CLI Fetch/Pull/Push roots/duplicates, skip invalid and nonroot, bare accepted including Pull, bisect source CLI opening, remote/branch presets and Cancel continuation without mutation")
    }
    @MainActor static func effects() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let seed = try await make(directory.appendingPathComponent("seed"), git: git)
        let originRoot = directory.appendingPathComponent("origin.git"); _ = try await seed.run(["clone", "--bare", seed.root.path, originRoot.path])
        let origin = GitRepository(root: originRoot, executable: git)
        func clone(_ name: String) async throws -> GitRepository {
            let root = directory.appendingPathComponent(name); _ = try await seed.run(["clone", originRoot.path, root.path])
            let repo = GitRepository(root: root, executable: git); try await configure(repo)
            _ = try await repo.run(["remote", "add", "mirror", originRoot.path]); return repo
        }
        let a = try await clone("A"), b = try await clone("B")
        _ = try await a.run(["switch", "topic"])
        try Data("topic publication\n".utf8).write(to: a.root.appendingPathComponent("nested/file")); try await a.stage(["nested/file"]); _ = try await a.commit(message: "topic update")
        let topic = try await a.run(["rev-parse", "topic"]).stdout
        _ = try await a.run(["switch", "main"])
        try Data("remote advance\n".utf8).write(to: seed.root.appendingPathComponent("nested/file")); try await seed.stage(["nested/file"]); _ = try await seed.commit(message: "remote advance")
        _ = try await seed.run(["push", originRoot.path, "main"])
        let remoteTip = try await seed.run(["rev-parse", "main"]).stdout, beforeB = try await snapshot(b)
        let context = try Context(directory: directory, git: git); defer { context.finish(); diagnostic = { "" } }
        try context.store.remember(a.root); try context.store.remember(b.root)
        diagnostic = { "effect action/root=\(context.shown.map { $0.0.rawValue + ":" + $0.2.root.path }), pending=\(context.workspace.hasPendingRepositoryWork), error=\(String(describing: context.workspace.error))" }
        // Real Fetch completion must retain the first root until its progress
        // and then its source-modal Switch successor have both been dismissed.
        try context.invoke("fetch", [a.root, b.root])
        let fetch = try await context.child(0, action: .fetch, root: a.root) as! FetchWindowController
        fetch.model.options.branch = "main"; fetch.model.fetch()
        try await wait("actual Fetch result") { fetch.model.fetchProgress?.busy == false }
        guard let fetched = fetch.model.fetchProgress else { throw Failure(description: "Fetch progress disappeared before acknowledgement") }
        let fetchedTip = try await a.run(["rev-parse", "refs/remotes/mirror/main"]).stdout
        try require(fetched.success && fetchedTip == remoteTip && context.shown.count == 1 && context.workspace.hasPendingRepositoryWork, "actual Fetch effect/order failed")
        try require(fetched.postActions.contains(.switchBranch), "Fetch lost source Switch postaction")
        fetched.perform(.switchBranch)
        let switched = try await context.child(1, action: .switchBranch, root: a.root)
        try require(switched is SwitchWindowController && context.shown.count == 2 && context.workspace.hasPendingRepositoryWork, "Fetch modal successor was skipped or next root overlapped")
        cancel(switched)
        let fetchB = try await context.child(2, action: .fetch, root: b.root); cancel(fetchB)
        try await context.drain()
        let pullStart = context.shown.count
        try context.invoke("pull", [a.root, b.root])
        let pull = try await context.child(pullStart, action: .pull, root: a.root) as! FetchWindowController
        pull.model.fastForwardOnly = true; pull.model.fetch()
        try await wait("actual Pull result") { pull.model.progress?.busy == false }
        guard let pulled = pull.model.progress else { throw Failure(description: "Pull progress disappeared before acknowledgement") }
        let pulledTip = try await a.run(["rev-parse", "HEAD"]).stdout, pulledFile = try Data(contentsOf: a.root.appendingPathComponent("nested/file"))
        try require(pulled.success && pulledTip == remoteTip && pulledFile == Data("remote advance\n".utf8) && context.shown.count == pullStart + 1, "actual Pull effect/order failed")
        pulled.close()
        let pullB = try await context.child(pullStart + 1, action: .pull, root: b.root); cancel(pullB)
        try await context.drain()
        let pushStart = context.shown.count
        try context.invoke("push", [a.root, b.root])
        let push = try await context.child(pushStart, action: .push, root: a.root) as! PushWindowController
        try require(push.model.options.source == "topic", "accepted Push lost CLI branch")
        push.model.options.remote = "mirror"; push.model.options.destination = "published"; push.model.options.setUpstream = false; push.model.push()
        try await wait("actual Push result") { push.model.progress?.busy == false }
        guard let pushed = push.model.progress else { throw Failure(description: "Push progress disappeared before acknowledgement") }
        let published = try await origin.run(["rev-parse", "refs/heads/published"]).stdout
        try require(pushed.success && published == topic && context.shown.count == pushStart + 1, "actual Push effect/order failed")
        pushed.close()
        let pushB = try await context.child(pushStart + 1, action: .push, root: b.root); cancel(pushB)
        try await context.drain()
        // Actual Git rejection must still return to the ordered coordinator.
        _ = try await origin.run(["config", "core.hooksPath", originRoot.appendingPathComponent("hooks").path])
        let hook = originRoot.appendingPathComponent("hooks/pre-receive")
        try Data("#!/bin/sh\necho private-rejection >&2\nexit 1\n".utf8).write(to: hook); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        let failureStart = context.shown.count
        try context.invoke("push", [a.root, b.root])
        let rejected = try await context.child(failureStart, action: .push, root: a.root) as! PushWindowController
        rejected.model.options.remote = "mirror"; rejected.model.options.destination = "rejected"; rejected.model.options.setUpstream = false; rejected.model.push()
        try await wait("actual rejected Push result") { rejected.model.progress?.busy == false }
        guard let failed = rejected.model.progress else { throw Failure(description: "Rejected Push lost result") }
        let absent = try await origin.run(["show-ref", "--verify", "--quiet", "refs/heads/rejected"], successfulExitCodes: 0...1)
        try require(!failed.success && absent.exitCode == 1 && context.shown.count == failureStart + 1, "Git rejection published or advanced batch before acknowledgement")
        failed.close()
        let afterFailure = try await context.child(failureStart + 1, action: .push, root: b.root); cancel(afterFailure)
        try await context.drain()
        let afterB = try await snapshot(b)
        try require(afterB == beforeB, "A accepted operations or failure changed cancelled root B")
        print("PASS: actual private Fetch/Pull/Push Git effects, retained progress acknowledgement, Fetch→Switch modal chain ordering and actual rejected Push→next-root continuation")
    }
    @MainActor static func lifetime() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let a = try await make(directory.appendingPathComponent("A"), git: git), b = try await make(directory.appendingPathComponent("B"), git: git)
        let beforeA = try await snapshot(a), beforeB = try await snapshot(b)
        let hold = directory.appendingPathComponent("hold-fetch"), released = directory.appendingPathComponent("release-read"), pidFile = directory.appendingPathComponent("held-fetch.pid"), wrapper = directory.appendingPathComponent("held-git")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/sh\ncase \" $* \" in\n*\" fetch \"*) if [ -f \(quote(hold.path)) ]; then /bin/echo $$ > \(quote(pidFile.path)); while [ ! -f \(quote(released.path)) ]; do /bin/sleep 0.1; done; fi ;;\nesac\nexec \(quote(git.path)) \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let context = try Context(directory: directory, git: git, executable: { $0.path == a.root.path ? wrapper : git })
        defer { try? Data().write(to: released); context.finish(); diagnostic = { "" } }
        diagnostic = { "lifetime count=\(context.shown.count), pending=\(context.workspace.hasPendingRepositoryWork), operations=\(RepositoryModel.activeCommandFileOperations), fetch=\(FetchProgressWindowModel.activeOperations), error=\(String(describing: context.workspace.error))" }
        var panels: [NSOpenPanel] = [], reply: ((NSApplication.ModalResponse) -> Void)?
        context.workspace.presentCommandTransportFolderPanel = { panel, parent, completion in
            panel.alphaValue = 0; panel.setFrameOrigin(NSPoint(x: -20000, y: -20000)); panels.append(panel); reply = completion; parent?.beginSheet(panel, completionHandler: nil)
        }
        context.workspace.selectedCommandTransportFolderURL = { _ in directory }
        defer { reply?(.cancel); panels.forEach { panel in if let parent = panel.sheetParent { parent.endSheet(panel, returnCode: .cancel) }; panel.close() } }
        try context.invoke("fetch", [a.root, b.root])
        try await wait("owned first-use common folder") { reply != nil && context.host.attachedSheet === panels.last }
        try require(context.shown.isEmpty && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "CLI folder grant lacks owned Quit boundary")
        let late = reply; reply?(.cancel); reply = nil
        try await context.drain()
        late?(.OK)
        try require(context.shown.isEmpty && context.host.attachedSheet == nil, "late cancelled CLI grant started batch")
        try context.invoke("fetch", [a.root, b.root])
        try await wait("retry common folder") { reply != nil }; reply?(.OK); reply = nil
        let first = try await context.child(0, action: .fetch, root: a.root)
        try require(panels.count == 2 && context.host.attachedSheet == nil, "CLI first-use retry lost owned panel detachment")
        cancel(first)
        let second = try await context.child(1, action: .fetch, root: b.root); cancel(second)
        try await context.drain()
        // Ordinary mail-form Cancel closes synchronously while the actual
        // preview reader still owns its MainActor completion/decrement. Mail
        // cancellation must not release a source-modal parent before that drain.
        let patch = directory.appendingPathComponent("private-preview.patch")
        let patchBytes = Data("Subject: Private preview\n\nPrivate patch body\n".utf8)
        try patchBytes.write(to: patch); context.defaults.set(false, forKey: "SendMail.Combine")
        let mailAccess = RepositoryAccessLease(url: directory, provider: CommandTransportScopes())
        var mailForm: SendPatchWindowController?, mailCompletions = 0
        let mail = SendMailWorkflow(files: [patch], repository: a, access: mailAccess, fileAccess: [mailAccess], preferences: context.defaults,
            presentation: { controller in
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); controller.showWindow(nil)
                mailForm = controller as? SendPatchWindowController
            }, customSubject: false, completion: { _ in mailCompletions += 1 })
        defer { mail.invalidate() }
        do {
            mail.start()
            guard let form = mailForm else { throw Failure(description: "Private mail form did not present") }
            try require(form.model.pendingLoads > 0, "actual mail preview did not begin synchronously")
            form.model.cancel()
            try require(mailCompletions == 0 && mail.transportBatchWorkPending, "mail Cancel completed before its closed form reader drained")
            try await wait("normal mail Cancel preview drain") { form.model.pendingLoads == 0 && !mail.transportBatchWorkPending && mailCompletions == 1 }
            await Task.yield()
            try require(mailCompletions == 1 && form.window?.isVisible == false, "mail Cancel completion duplicated or left its form open")
        } catch {
            mail.invalidate()
            for _ in 0..<3000 { if !mail.transportBatchWorkPending { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        // Forced retirement uses the same actual pending reader but must never
        // deliver the normal source-modal completion callback.
        var forcedForm: SendPatchWindowController?, forcedCompletions = 0
        let forced = SendMailWorkflow(files: [patch], repository: a, access: mailAccess, fileAccess: [mailAccess], preferences: context.defaults,
            presentation: { controller in
                controller.window?.alphaValue = 0; controller.window?.setFrameOrigin(NSPoint(x: -20000, y: -20000)); controller.showWindow(nil)
                forcedForm = controller as? SendPatchWindowController
            }, customSubject: false, completion: { _ in forcedCompletions += 1 })
        defer { forced.invalidate() }
        do {
            forced.start()
            guard let form = forcedForm else { throw Failure(description: "Forced private mail form did not present") }
            try require(form.model.pendingLoads > 0, "forced mail preview did not begin synchronously")
            forced.invalidate()
            try require(forcedCompletions == 0 && forced.transportBatchWorkPending, "forced mail retirement dropped pending reader accounting")
            try await wait("forced mail preview drain") { form.model.pendingLoads == 0 && !forced.transportBatchWorkPending }
            await Task.yield()
            try require(forcedCompletions == 0 && form.window?.isVisible == false, "forced mail retirement delivered ordinary completion")
        } catch {
            forced.invalidate()
            for _ in 0..<3000 { if !forced.transportBatchWorkPending { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
            throw error
        }
        let afterPatch = try Data(contentsOf: patch)
        try require(afterPatch == patchBytes, "Cancel-only mail workflows changed private patch bytes")
        // Actual progress owns a private subprocess; force-retiring the initial
        // workspace cancels it, retains Quit until drain and never presents B.
        try Data().write(to: hold)
        let start = context.shown.count
        try context.invoke("fetch", [a.root, b.root])
        let fetch = try await context.child(start, action: .fetch, root: a.root) as! FetchWindowController
        fetch.model.options.branch = "main"; fetch.model.fetch()
        var heldPID: Int32?
        try await wait("held actual Fetch subprocess") {
            if let value = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                heldPID = pid
            }
            return heldPID != nil && FetchProgressWindowModel.activeOperations > 0
        }
        guard let pid = heldPID else { throw Failure(description: "Held Fetch subprocess did not publish a valid PID") }
        try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel && context.workspace.hasPendingRepositoryWork, "held progress lost batch/Quit accounting")
        context.host.close()
        try await context.drain()
        try require(context.shown.count == start + 1 && fetch.window?.isVisible == false && FetchProgressWindowModel.activeOperations == 0 && Darwin.kill(pid, 0) != 0, "retired CLI batch advanced or leaked actual progress/subprocess")
        let afterA = try await snapshot(a), afterB = try await snapshot(b)
        try require(afterA == beforeA && afterB == beforeB, "cancelled first-use/progress mutated repositories")
        print("PASS: owned CLI common grant Cancel/late/retry, accepted root sequence, normal/forced mail preview cancellation drain, held actual Fetch progress owner-close cancellation, Quit accounting, subprocess and batch drain")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let ordered = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)))!
        let hidden = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.turtleGitCommandTransportOrder(_:relativeTo:)))!
        method_exchangeImplementations(ordered, hidden)
        defer { method_exchangeImplementations(ordered, hidden) }
        switch ProcessInfo.processInfo.environment["TURTLEGIT_COMMAND_TRANSPORT_BATCH_CASE"] {
        case "dialogs": try await dialogs()
        case "effects": try await effects()
        case "lifetime": try await lifetime()
        default: throw Failure(description: "Unknown command transport case")
        }
        print("PASS: command transport batch case completed")
    }
}

private extension NSWindow {
    @objc func turtleGitCommandTransportOrder(_ place: NSWindow.OrderingMode, relativeTo otherWindowNumber: Int) {
        alphaValue = 0
        turtleGitCommandTransportOrder(place, relativeTo: otherWindowNumber)
    }
}
