import AppKit
import TurtleGitCore

@main struct ComparisonLaunchVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "Comparison launch timeout at fixture line \(line), active launches \(FileListComparisonSession.activeOperations)")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Comparison launch failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verifyFinderChoices(executable:URL,prefs:UserDefaults) async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitFinderChoice-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer {try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,executable:executable),path="literal 雪\n&?.txt",other="other.txt"
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Finder tool QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        for name in [path,other] {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))};try await repo.stage([path,other]);_ = try await repo.commit(message:"base")
        try Data("second\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"second")
        try Data("working\n".utf8).write(to:root.appendingPathComponent(path))
        let enabled=root.appendingPathComponent(".git/choice-enabled"),ready=root.appendingPathComponent(".git/choice-ready"),release=root.appendingPathComponent(".git/choice-release"),helper=root.appendingPathComponent(".git/choice-git")
        let script="""
        #!/bin/sh
        if [ -f \(quote(enabled.path)) ] && [ ! -f \(quote(release.path)) ]; then
          for argument in "$@"; do
            if [ "$argument" = --show-toplevel ]; then
              : > \(quote(ready.path))
              while [ ! -f \(quote(release.path)) ]; do /bin/sleep 0.02; done
            fi
          done
        fi
        exec \(quote(executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:helper)})
        workspace.fileComparisonPreferences=prefs;workspace.fileComparisonQuestion={_ in true};workspace.open(root)
        try await wait {!workspace.busy};try require(workspace.error==nil,"Private Finder context adoption failed")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        var observed:[Bool]=[],opened:[String]=[]
        workspace.fileComparisonPresentation={_,file in observed.append(ComparisonToolInvocation.capture);opened.append(file.path)}
        for action in [RepositoryAction.diff,.previousDiff] {
            for choice in [false,true] {
                try? FileManager.default.removeItem(at:ready);try? FileManager.default.removeItem(at:release);try Data().write(to:enabled)
                let request=FinderRequest(action:action,paths:[root.appendingPathComponent(path)],alternateTool:choice)
                observed=[];opened=[]
                ComparisonToolInvocation.$alternate.withValue(!choice) {workspace.handle(request.url!)}
                try await wait {FileManager.default.fileExists(atPath:ready.path)}
                try require(ComparisonToolInvocation.alternate==nil,"Finder handoff leaked tool state into later UI actions")
                workspace.selection=[other];try Data().write(to:release)
                try await wait {!workspace.busy && (observed.count==1 || workspace.error != nil) && FileListComparisonSession.activeOperations==0}
                try require(workspace.error==nil && observed==[choice] && opened==[path],"Finder URL lost explicit tool/path across repository discovery: "+(workspace.error ?? ""))
            }
        }
        try? FileManager.default.removeItem(at:enabled)
        for choice in [false,true] {
            let before=Set(NSApp.windows.map {ObjectIdentifier($0)})
            ComparisonToolInvocation.$alternate.withValue(!choice) {workspace.handle(FinderRequest(action:.diff,paths:[root.appendingPathComponent(path),root.appendingPathComponent(other)],alternateTool:choice).url!)}
            let owned=NSApp.windows.filter {!before.contains(ObjectIdentifier($0))}.compactMap {$0.windowController as? FileComparisonWindowController}
            try require(owned.count==1 && owned[0].model.alternateTool==choice,"Finder file-pair viewer lost explicit tool choice")
            try await wait {owned.allSatisfy {!$0.model.busy && !$0.model.filtering}}
            try require(owned[0].model.error==nil,"Private Finder pair did not load")
            owned.forEach {$0.close()}
        }
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(path))==Data("working\n".utf8),"Finder tool handoffs changed repository bytes")
    }
    @MainActor static func verifyTools(repo: GitRepository, prefs: UserDefaults, snapshot: RevisionComparisonSnapshot) async throws {
        // Capture Shift before a delayed confirmation, then create and load the
        // child outside the initiating task to model SwiftUI's later .task.
        let session = ComparisonToolInvocation.$alternate.withValue(true) {
            FileListComparisonSession(window: nil, preferences: prefs)
        }
        var reply: CheckedContinuation<Bool, Never>?, captured: FileComparisonWindowModel?
        session.confirmation = { _ in await withCheckedContinuation { reply = $0 } }
        let launch = Task { @MainActor in
            try await session.run(selectedCount: 4) { _ in
                await Task.yield()
                captured = FileComparisonWindowModel(repository: repo, access: nil, snapshot: snapshot, path: snapshot.files[0].path)
            }
        }
        try await wait { reply != nil }
        try require(ComparisonToolInvocation.alternate == nil, "Pending launch leaked its Shift choice")
        reply?.resume(returning: true); try await launch.value
        guard let captured else { throw Failure(message: "Approved comparison was not captured") }
        captured.comparisonDefaults = prefs
        var observed: [Bool] = []
        captured.openExternalComparison = { _, _, _, alternate in observed.append(alternate); return false }
        captured.load(); try await wait { !captured.busy && !captured.filtering }
        try require(observed == [true] && captured.document != nil, "Delayed viewer lost initiating Shift")
        captured.retireImageLoader()
        // A failed application launch must remain retryable, without changing
        // this window's captured choice when the user releases Shift.
        let retry = ComparisonToolInvocation.$alternate.withValue(true) {
            FileComparisonWindowModel(repository: repo, access: nil, snapshot: snapshot, path: snapshot.files[0].path)
        }
        retry.comparisonDefaults = prefs; var attempts = 0
        retry.openExternalComparison = { _, _, _, alternate in
            try require(alternate, "Retry changed tool choice"); attempts += 1
            if attempts == 1 { throw Failure(message: "Injected application launch failure") }; return false
        }
        retry.load(); try await wait { !retry.busy }
        try require(retry.error != nil && retry.document == nil, "Failed launch was hidden")
        retry.load(); try await wait { !retry.busy && !retry.filtering }
        try require(attempts == 2 && retry.error == nil && retry.document != nil, "External failure could not retry")
        retry.retireImageLoader()
        // Exercise the real configured-program selection, temporary snapshots,
        // expanded arguments and launch boundary without starting another app.
        var tools = DiffToolPreferences(); tools.program.applicationPath = "/Applications/TurtleGit-QA.app"
        tools.program.arguments = "\"%base\" \"%mine\" \"%brev\""; try tools.save(to: prefs)
        defer { prefs.removeObject(forKey: "TurtleGit.DiffTools"); DiffToolApplication.discardAll() }
        let document = try await repo.comparisonFile(snapshot, path: snapshot.files[0].path)
        var launches = 0, failedSnapshot: URL?
        let opener: (URL, NSWorkspace.OpenConfiguration) async throws -> Void = { application, configuration in
            launches += 1
            try require(application.path == tools.program.applicationPath, "Wrong selected application")
            let args = configuration.arguments
            try require(args.count == 3 && args[2] == snapshot.from.label, "Tool placeholders changed")
            let base = URL(fileURLWithPath: args[0]), mine = URL(fileURLWithPath: args[1])
            try require(try Data(contentsOf: base) == document.base.bytes && Data(contentsOf: mine) == document.destination.bytes, "External tool did not receive exact files")
            let mode = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as! NSNumber
            try require(mode.intValue & 0o222 == 0, "Historical external snapshot is writable")
            try require(DiffToolApplication.activeRequests == 1, "Launch lost its owned lifetime")
            failedSnapshot = base
        }
        let ordinary = try await DiffToolApplication.open(document, root: snapshot.root, permissions: [], alternate: false, preferences: prefs, launch: opener)
        let alternate = try await DiffToolApplication.open(document, root: snapshot.root, permissions: [], alternate: true, preferences: prefs, launch: opener)
        try require(!ordinary && alternate && launches == 1, "Disabled default/Shift inversion failed")
        tools.program.enabled = true; try tools.save(to: prefs)
        let internalChoice = try await DiffToolApplication.open(document, root: snapshot.root, permissions: [], alternate: true, preferences: prefs, launch: opener)
        try require(!internalChoice && launches == 1, "Enabled default/Shift inversion failed")
        do {
            _ = try await DiffToolApplication.open(document, root: snapshot.root, permissions: [], alternate: false, preferences: prefs, launch: { app, config in
                try await opener(app, config); throw Failure(message: "Injected launcher rejection")
            })
            throw Failure(message: "Launch failure was swallowed")
        } catch let failure as Failure { try require(failure.message == "Injected launcher rejection", "Unexpected launch failure") }
        try require(failedSnapshot != nil && !FileManager.default.fileExists(atPath: failedSnapshot!.path) && DiffToolApplication.activeRequests == 0, "Failed launch leaked files or lifetime")
        let cancelled = OperationCancellation(); cancelled.cancel()
        do {
            _ = try await DiffToolApplication.open(document, root: snapshot.root, permissions: [], alternate: false, preferences: prefs, cancellation: cancelled, launch: opener)
            throw Failure(message: "Cancelled external request launched")
        } catch is OperationCancellationFailure { }
        try require(launches == 2, "Cancelled external request reached launcher")
        prefs.removeObject(forKey: "TurtleGit.DiffTools")
        // Cached default and alternate viewers for one file remain independent.
        let changed = RevisionComparisonWindowModel(repository: repo, access: nil, from: snapshot.from, to: snapshot.to, preferences: prefs)
        changed.snapshot = snapshot; let ids = Set([snapshot.files[0].path])
        defer { changed.invalidate(); Array(changed.comparisonWindows.values).forEach { $0.close() } }
        ComparisonToolInvocation.$alternate.withValue(false) { changed.compare(ids) }
        try await wait { !changed.busy && changed.comparisonWindows.values.allSatisfy { !$0.model.busy && !$0.model.filtering } }
        ComparisonToolInvocation.$alternate.withValue(true) { changed.compare(ids) }
        try await wait { !changed.busy && changed.comparisonWindows.count == 2 && changed.comparisonWindows.values.allSatisfy { !$0.model.busy && !$0.model.filtering } }
        try require(Set(changed.comparisonWindows.values.map { $0.model.alternateTool }) == Set([true,false]), "Alternate comparison reused the default viewer")
        // Sync captures its choice before format-patch suspends, and supplies
        // the same private tool preferences to its Changed Files children.
        let syncRoot = snapshot.root.appendingPathComponent("sync-tool-fixture")
        try FileManager.default.createDirectory(at: syncRoot, withIntermediateDirectories: true)
        let syncRepo = GitRepository(root: syncRoot, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await syncRepo.run(["init","-b","main"])
        for (key,value) in [("user.name","QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await syncRepo.run(["config",key,value]) }
        for n in 0...2 { try Data("value \(n)\n".utf8).write(to: syncRoot.appendingPathComponent("file.txt")); try await syncRepo.stage(["file.txt"]); _ = try await syncRepo.commit(message: "revision \(n)") }
        let sync = SynchronizationWindowModel(repository: syncRepo, access: nil, preferences: prefs)
        defer { sync.invalidate(); Array(sync.comparison.comparisonWindows.values).forEach { $0.close() } }
        ComparisonToolInvocation.$alternate.withValue(true) { sync.compareHistoryChangeSets(first: "HEAD", second: "HEAD~1") }
        try await wait { !sync.busy && sync.comparison.comparisonWindows.values.first?.model.busy == false }
        guard let syncViewer = sync.comparison.comparisonWindows.values.first else { throw Failure(message: "Sync did not open changesets") }
        try require(syncViewer.model.alternateTool && syncViewer.model.comparisonDefaults === prefs, "Sync changesets lost Shift/preferences")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let paths = ["one", "two", "three", "four 雪\nfile"]
        for path in paths { try Data("base\n".utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(paths); _ = try await repo.commit(message: "base")
        for path in paths { try Data("changed\n".utf8).write(to: root.appendingPathComponent(path)) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.ComparisonLaunch." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(3, forKey: "NumDiffWarning")
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        var questions: [Int] = [], opened: [(RevisionComparisonSnapshot, CommitFile)] = []
        workspace.fileComparisonPresentation = { opened.append(($0, $1)) }
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        workspace.fileComparisonQuestion = { questions.append($0); return false }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4] && opened.isEmpty && workspace.error == nil, "Working/Commit decline launched viewers or failed")
        workspace.fileComparisonQuestion = { questions.append($0); return true }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        workspace.selection = ["not selected"]
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4, 4] && Set(opened.map { $0.1.path }) == Set(paths), "Working/Commit approval retargeted selected paths")
        opened = []
        workspace.showGroupedHistoricalFiles(repository: repo, access: nil, requests: [(.revision("HEAD"), .workingTree, Array(paths.prefix(2))), (.emptyTree, .revision("HEAD"), Array(paths.suffix(2)))], owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions == [4, 4, 4] && opened.count == 4 && opened.prefix(2).allSatisfy { $0.0.to == .workingTree } && opened.suffix(2).allSatisfy { $0.0.from == .emptyTree }, "Log groups prompted separately or lost endpoints")
        opened = []; prefs.set(4, forKey: "NumDiffWarning")
        workspace.showHistoricalFiles(repository: repo, access: nil, from: .revision("HEAD"), to: .workingTree, paths: paths, owner: owner)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(questions.count == 3 && opened.count == 4, "Historical threshold equality warned")
        opened = []; prefs.set(3, forKey: "NumDiffWarning")
        var reply: CheckedContinuation<Bool, Never>?
        workspace.fileComparisonQuestion = { _ in await withCheckedContinuation { reply = $0 } }
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: owner)
        try await wait { reply != nil }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Pending question did not own Quit")
        owner.close(); reply?.resume(returning: true)
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(opened.isEmpty && workspace.error == nil, "Retired approval launched viewers")
        // A real owned alert ends on forced source-window close, independently of injection.
        let sheetOwner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        sheetOwner.isReleasedWhenClosed = false; defer { sheetOwner.close() }
        workspace.fileComparisonQuestion = nil
        workspace.showWorkingFiles(repository: repo, access: nil, paths: paths, owner: sheetOwner)
        try await wait { sheetOwner.attachedSheet != nil }
        sheetOwner.close()
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 && sheetOwner.attachedSheet == nil }
        try require(opened.isEmpty, "Closing owned question launched comparisons")
        // Cancellation after an owned Git child really starts, with no receiver restart.
        let marker = root.appendingPathComponent("read-started"), wrapper = root.appendingPathComponent("slow-git")
        let script = "#!/bin/sh\nif [ \"$4\" = rev-parse ]; then\n /usr/bin/touch " + quote(marker.path) + "\n while :; do /bin/sleep 1; done\nfi\nexec " + quote(executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let readOwner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        readOwner.isReleasedWhenClosed = false; defer { readOwner.close() }
        workspace.showWorkingFiles(repository: GitRepository(root: root, executable: wrapper), access: nil, paths: [paths[0]], owner: readOwner)
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        readOwner.close()
        try await wait { !workspace.busy && FileListComparisonSession.activeOperations == 0 }
        try require(opened.isEmpty && workspace.error == nil, "Closed source read published a viewer/error")
        // A child viewer also owns and cancels its historical blob read.
        try FileManager.default.removeItem(at: marker)
        let blobScript = "#!/bin/sh\nif [ \"$4\" = ls-tree ]; then\n /usr/bin/touch " + quote(marker.path) + "\n while :; do /bin/sleep 1; done\nfi\nexec " + quote(executable.path) + " \"$@\"\n"
        try Data(blobScript.utf8).write(to: wrapper)
        let snapshot = try await repo.revisionFileComparison(from: .revision("HEAD"), to: .workingTree, paths: [paths[0]])
        let viewer = FileComparisonWindowModel(repository: GitRepository(root: root, executable: wrapper), access: nil, snapshot: snapshot, path: paths[0])
        viewer.comparisonDefaults = prefs; viewer.load()
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        viewer.retireImageLoader()
        try await wait { !viewer.busy && FileListComparisonSession.activeOperations == 0 }
        try require(viewer.document == nil && viewer.error == nil, "Retired blob read published a document/error")
        try await verifyRevisionControls(repo: repo, prefs: prefs)
        try await verifyFileActions(executable:executable,prefs:prefs)
        try await verifyFinderChoices(executable:executable,prefs:prefs)
        try await verifyTools(repo: repo, prefs: prefs, snapshot: snapshot)
        // Aggregated status-list GNU patches stay one captured patch, without a many-viewer warning.
        let commit = CommitWindowModel(repository: repo, access: nil, unversionedDefaults: prefs, dialogDefaults: prefs)
        defer { commit.invalidateForClose() }
        commit.entries = try await repo.status(refreshIndex: false)
        var commitPatch = Data(); commit.onUnifiedDiff = { bytes, alternate in try require(alternate, "Commit lost Shift choice"); commitPatch = bytes }
        commit.diff(paths: Set(paths), staged: false, alternate: true)
        try await wait { !commit.busy && FileListComparisonSession.activeOperations == 0 }
        try require(commit.error == nil && commitPatch.range(of: Data("+changed".utf8)) != nil, "Commit patch route failed")
        let status = StatusWindowModel(repository: repo, access: nil, defaults: prefs)
        defer { status.invalidate() }
        status.files = try await repo.workingTreeStatus(refreshIndex: false)
        var statusPatch = Data(); status.onUnifiedDiff = { bytes, _ in statusPatch = bytes }
        status.unifiedDiff(Set(paths), alternate: false)
        try await wait { !status.busy && StatusWindowModel.activeOperations == 0 && FileListComparisonSession.activeOperations == 0 }
        try require(status.error == nil && statusPatch == commitPatch, "Working Tree aggregated patch diverged")
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { log.invalidate() }
        let entries = try await repo.history(); log.entries = entries; log.selected = [entries[0].hash]
        log.files = try await repo.files(in: entries[0]); var logPatch = Data()
        log.onUnifiedDiff = { bytes, _ in logPatch = bytes }
        log.selectedFileDiff(Set(log.files.map(\.id)))
        try await wait { !log.busy && FileListComparisonSession.activeOperations == 0 }
        try require(log.error == nil && logPatch.range(of: Data("+base".utf8)) != nil, "Log selected-file patch route failed")
        try require(try Data(contentsOf: root.appendingPathComponent(".git/index")) == index, "Comparison routes modified index")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head, "Comparison routes modified HEAD")
        for path in paths { try require(try Data(contentsOf: root.appendingPathComponent(path)) == Data("changed\n".utf8), "Comparison routes modified working bytes") }
        print("Comparison launch: captured working/historical/grouped targets, No/Yes/equality, pending question/Quit, late approval refusal, actual owned sheet teardown and started Git cancellation; Commit/Working Tree/Log patch routes and repository preservation passed. Owners closed; no external viewers launched.")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func verifyRevisionControls(repo: GitRepository, prefs: UserDefaults) async throws {
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let controller = RevisionComparisonWindowController(repository: repo, access: nil, from: .revision("HEAD"), to: .workingTree, preferences: prefs, historyRegexExecutable: helper)
        defer { controller.close() }; controller.window!.alphaValue = 0; controller.showWindow(nil)
        let model = controller.model; model.load()
        try await wait { !model.busy && model.snapshot != nil }
        try await wait { descendants(controller.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let probe = descendants(controller.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        try require(probe.leadingColumnCount == 0 && !probe.keyboardDeleteEnabled && probe.rows.allSatisfy { $0.group == nil }, "Changed Files native list used checkbox/group/Delete semantics")
        if ProcessInfo.processInfo.environment["TURTLEGIT_COMPARISON_CAPTURE"] == "1" {
            let window = controller.window!; window.alphaValue = 1
            defer { window.alphaValue = 0 }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance); window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                try await Task.sleep(nanoseconds: 200_000_000)
                let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/changed-files-controls-" + name + ".png")
                let capture = Process(); capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
                try capture.run(); capture.waitUntilExit()
                try require(capture.terminationStatus == 0, "Owned Changed Files compositor capture failed")
            }
            window.appearance = NSAppearance(named: .aqua)
        }
        try require(model.completionNames.contains("main") && model.completionNames.contains("HEAD"), "Comparison revision completion omitted branch/HEAD")
        model.filter = "one +two"
        try require(Set(model.visibleFiles.map(\.path)) == ["one", "two"], "Comparison filter did not use source OR grammar")
        model.filter = ""
        model.setFileColumn(.removed, visible: false)
        try require(model.saveFileLayout(order: [.status, .path], widths: [.path: 420, .status: 180]), "Changed Files layout refused idle update")
        let restored = RevisionComparisonWindowModel(repository: repo, access: nil, from: .revision("HEAD"), to: .workingTree, preferences: prefs)
        defer { restored.invalidate() }
        try require(!restored.fileColumns.visible.contains(.removed) && restored.fileColumns.order.first == .status && restored.fileColumns.widths[.path] == 420 && restored.fileColumns.widths[.status] == 180, "Changed Files layout did not restore from private preferences")
        try await wait {
            probe.configureColumns()
            return descendants(controller.window!.contentView!).compactMap { $0 as? NSTableView }.first?.tableColumns.first(where: { $0.title == "Action" })?.width == 180
        }
        var accepted = 0
        model.resetFileColumns(choose: { false }, accepted: { accepted += 1 })
        try await wait { !model.resettingColumns }
        try require(!model.fileColumns.visible.contains(.removed) && accepted == 0, "Declined columns reset changed layout")
        model.resetFileColumns(choose: { true }, accepted: { accepted += 1 })
        try await wait { !model.resettingColumns }
        try require(model.fileColumns == StatusListColumnSettings() && accepted == 1, "Accepted columns reset did not restore default five columns")
        model.editRevision("definitely-invalid-turtlegit-ref", side: .base)
        try require(model.snapshot == nil && !model.inputMessage.isEmpty && !model.busy, "Typed revision retained stale file actions or skipped input delay")
        try await wait { !model.busy && model.inputMessage.hasPrefix("Invalid reference:") }
        try require(model.snapshot == nil && model.error == nil && controller.window!.attachedSheet == nil, "Typed invalid revision opened a modal error or retained rows")
        model.editRevision("another-invalid-ref", side: .base)
        model.editRevision("HEAD", side: .base)
        try await wait { !model.busy && model.snapshot != nil }
        try require(model.from == "HEAD" && model.inputMessage.isEmpty, "Superseded delayed input published stale invalid result")
        var referenceConfigured = false, logConfigured = false
        model.configureReferencePicker = { referenceConfigured = $0.preferences === prefs }
        model.configureLogPicker = { logConfigured = $0.colorPreferences === prefs }
        controller.showReferencePicker(side: .base)
        try await wait { controller.referencePicker?.model.busy == false }
        guard let picker = controller.referencePicker else { throw Failure(message: "Shared reference picker was not retained") }
        try require(referenceConfigured && controller.window!.attachedSheet === picker.window && picker.window!.alphaValue == 0, "Comparison picker lost owner/preferences/hidden alpha")
        controller.showHistoryPicker(side: .base, reflog: false)
        try require(controller.logPicker == nil, "Blocked comparison presented a second picker")
        picker.model.select(["refs/heads/main"], last: "refs/heads/main"); picker.model.accept()
        try await wait { controller.referencePicker == nil && controller.window!.attachedSheet == nil && !model.busy && model.from == "refs/heads/main" }
        try require(model.snapshot != nil, "Reference selection did not reload comparison")
        controller.showHistoryPicker(side: .base, reflog: false)
        try await wait { controller.logPicker?.model.busy == false }
        guard let log = controller.logPicker else { throw Failure(message: "Comparison Log picker missing") }
        try require(logConfigured && log.model.endRevision == "refs/heads/main", "Log picker lost current typed revision/private routing")
        guard let entry = log.model.entries.first(where: { !$0.hash.isEmpty }) else { throw Failure(message: "Comparison Log picker did not load: " + (log.model.error ?? "")) }
        log.model.finishSelection(entry)
        try await wait { controller.logPicker == nil && controller.window!.attachedSheet == nil && !model.busy && model.from == entry.hash }
        controller.showHistoryPicker(side: .base, reflog: true)
        try await wait { controller.reflogPicker?.model.commandSurfaceAvailable == true && controller.reflogPicker?.model.entries.isEmpty == false }
        guard let reflog = controller.reflogPicker else { throw Failure(message: "Comparison RefLog picker missing") }
        try require(reflog.model.selecting && reflog.window!.alphaValue == 0, "RefLog selection owner/alpha lost")
        let before = model.from; reflog.model.close()
        try await wait { controller.reflogPicker == nil && controller.window!.attachedSheet == nil }
        try require(model.from == before, "Cancelled RefLog changed revision")
        controller.showReferencePicker(side: .destination)
        try await wait { controller.referencePicker?.model.busy == false }
        controller.close()
        try await wait { model.closed && controller.window?.attachedSheet == nil && RevisionComparisonWindowModel.activeFileOperations == 0 }
        try require(controller.referencePicker == nil && model.from == before, "Forced close retained picker or applied late choice")
        restored.editRevision("HEAD~9", side: .base); restored.invalidate()
        print("Changed Files revision/list controls: delayed invalid/corrected input, source path filter, completion catalog, private layout/reset, shared reference acceptance, Log acceptance, RefLog cancel, blocked/forced picker ownership passed.")
    }

    @MainActor static func verifyFileActions(executable:URL,prefs:UserDefaults) async throws {
        DialogGeometry.install(preferences:prefs)
        let oldRecycle=prefs.object(forKey:"RevertWithRecycleBin");prefs.set(false,forKey:"RevertWithRecycleBin")
        defer{if let oldRecycle{prefs.set(oldRecycle,forKey:"RevertWithRecycleBin")}else{prefs.removeObject(forKey:"RevertWithRecycleBin")}}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitChangedActions-"+UUID().uuidString),folder=root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let repo=GitRepository(root:root,executable:executable)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Changed Files QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        for path in ["modified","deleted","old-name","dir/nested"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(path).deletingLastPathComponent(),withIntermediateDirectories:true);try Data((path=="modified" ? "base\n" : "base "+path+"\n").utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(["modified","deleted","old-name","dir/nested"]);_ = try await repo.commit(message:"base")
        let base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _ = try await repo.run(["mv","old-name","renamed"]);_ = try await repo.run(["rm","deleted"])
        for path in ["modified","dir/nested","added"] {try Data("new\n".utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage(["modified","dir/nested","added"]);_ = try await repo.commit(message:"changes")
        let tip=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let owner=RevisionComparisonWindowController(repository:repo,access:RepositoryAccessLease(url:root),from:.revision(base),to:.revision(tip),preferences:prefs),model=owner.model
        owner.window!.alphaValue=0;model.confirmManyDiffs={_ in true};owner.showWindow(nil);model.load();try await wait{!model.busy && model.snapshot != nil};defer{owner.close()}
        let stale=model.captureFileMenu(["modified"]);model.from="HEAD~1"
        try require(!model.claimFileMenu(stale),"Old file menu accepted changed revision input");model.from=base
        let fresh=model.captureFileMenu(["modified"]);try require(model.claimFileMenu(fresh) && !model.claimFileMenu(fresh),"File popup action repeated")
        var blame:[(String,String)]=[],notices:[String]=[],changed=0
        model.onBlame={blame.append(($0,$1))};model.blameFiles(Set(model.visibleFiles.map(\.path)));try await wait{!model.busy}
        try require(blame.contains{$0.0=="deleted" && $0.1==base} && blame.contains{$0.0=="renamed" && $0.1==tip},"Changed Files Blame lost deleted/new side")
        let originalNotice=model.fileActionNotice,originalFailure=model.fileActionFailure,originalFolder=model.chooseExportFolder
        model.fileActionNotice={notices.append($0)};model.onFilesChanged={changed += 1}
        model.revertFiles(["modified"],base:true);try await wait{!model.busy && RevisionComparisonWindowModel.activeFileOperations==0}
        try require(try Data(contentsOf:root.appendingPathComponent("modified"))==Data("base\n".utf8),"Revert to Base did not restore working bytes")
        try require(changed==1 && notices.count==1,"Revert result/refresh handoff missing")
        model.fileActionNotice=originalNotice;model.revertFiles(["modified"],base:false);try await wait{owner.window?.attachedSheet != nil}
        try require(model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Revert result lacks operation ownership")
        func button(_ title:String,in window:NSWindow)->NSButton? {func all(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(all)};return window.contentView.flatMap{all($0).compactMap{$0 as? NSButton}.first{$0.title==title}}}
        button("OK",in:owner.window!.attachedSheet!)!.performClick(nil);try await wait{!model.busy && owner.window?.attachedSheet==nil}
        try require(try Data(contentsOf:root.appendingPathComponent("modified"))==Data("new\n".utf8),"Revert to Version 2 failed")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);model.chooseExportFolder={folder}
        model.exportFiles(Set(model.visibleFiles.map(\.path)));try await wait{!model.busy}
        try require(try Data(contentsOf:folder.appendingPathComponent("renamed"))==Data("base old-name\n".utf8),"Historical rename export lost bytes")
        try require(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("deleted").path),"Deleted entry exported")
        // Exercise source Ignore/Abort with a real unwritable nested destination.
        try FileManager.default.removeItem(at:folder.appendingPathComponent("dir"));try Data("blocker".utf8).write(to:folder.appendingPathComponent("dir"))
        model.fileActionFailure=originalFailure;model.exportFiles(["dir/nested","modified"]);try await wait{owner.window?.attachedSheet != nil}
        let failure=owner.window!.attachedSheet!;try require(!owner.windowShouldClose(owner.window!) && failure.defaultButtonCell?.title=="Abort","Export error lacks owned Abort default")
        button("Ignore",in:failure)!.performClick(nil);try await wait{!model.busy && owner.window?.attachedSheet==nil}
        try Data("sentinel".utf8).write(to:folder.appendingPathComponent("modified"));model.exportFiles(["dir/nested","modified"]);try await wait{owner.window?.attachedSheet != nil}
        button("Abort",in:owner.window!.attachedSheet!)!.performClick(nil);try await wait{!model.busy}
        try require(try Data(contentsOf:folder.appendingPathComponent("modified"))==Data("sentinel".utf8),"Abort continued exporting later files")
        model.chooseExportFolder=originalFolder;model.exportFiles(["modified"]);try await wait{owner.window?.attachedSheet is NSOpenPanel}
        model.cancelFileAction();try await wait{!model.busy && owner.window?.attachedSheet==nil}
        try require(model.error==nil,"Folder cancellation produced an error")
        // A paused protected checkout must settle before requested or forced close
        // drops ownership; cancel does not kill a checkout after recycling starts.
        let gate=root.appendingPathComponent(".git/action-gate"),ready=root.appendingPathComponent(".git/action-ready"),release=root.appendingPathComponent(".git/action-release"),helper=root.appendingPathComponent(".git/action-git")
        let script="""
        #!/bin/sh
        if [ "$4" = checkout ] && [ -f \(quote(gate.path)) ];then
          : > \(quote(ready.path))
          while [ ! -f \(quote(release.path)) ];do /bin/sleep 0.02;done
        fi
        exec \(quote(executable.path)) "$@"
        """
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        for forced in [false,true] {
            for file in [gate,ready,release]{try? FileManager.default.removeItem(at:file)}
            let child=RevisionComparisonWindowController(repository:GitRepository(root:root,executable:helper),access:RepositoryAccessLease(url:root),from:.revision(base),to:.revision(tip),preferences:prefs)
            child.window!.alphaValue=0;child.showWindow(nil);child.model.load();try await wait{!child.model.busy && child.model.snapshot != nil};defer{child.close()}
            var results=0;child.model.fileActionNotice={_ in results += 1}
            try Data().write(to:gate);child.model.revertFiles(["modified"],base:true);try await wait{FileManager.default.fileExists(atPath:ready.path)}
            if forced {child.close()}else{child.window!.performClose(nil)}
            try require(RevisionComparisonWindowModel.activeFileOperations>0 && (forced || !child.model.closed),"Close dropped protected file operation")
            try Data().write(to:release);try await wait{RevisionComparisonWindowModel.activeFileOperations==0 && child.model.closed}
            try require(results==0 && child.window?.isVisible==false,"Closed source published a late result")
        }
        let abort=MergeAbortWindowController(repository:repo,access:RepositoryAccessLease(url:root),preferences:prefs)
        defer{abort.close()};abort.window!.alphaValue=0;abort.showWindow(nil)
        var configured=false,abortBlame=false
        abort.configureModifiedComparison={child in configured=true;child.confirmManyDiffs={_ in true};child.onBlame={path,revision in abortBlame=path=="modified" && revision=="HEAD"}}
        abort.model.showModified();try await wait{abort.modifiedFiles != nil && abort.modifiedFiles?.model.busy==false}
        try require(configured && abort.model.hasChild,"Abort Merge did not configure/own Changed Files")
        abort.modifiedFiles!.model.blameFiles(["modified"]);try await wait{abort.modifiedFiles?.model.busy==false};try require(abortBlame,"Abort-owned Changed Files lost action routing")
        abort.modifiedFiles!.close();try await wait{!abort.model.hasChild};abort.close()
        let parentURL=root.appendingPathComponent("module-parent"),childURL=parentURL.appendingPathComponent("module")
        try FileManager.default.createDirectory(at:childURL,withIntermediateDirectories:true)
        let parent=GitRepository(root:parentURL,executable:executable),module=GitRepository(root:childURL,executable:executable)
        for repository in [parent,module] {
            _ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Module QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
        }
        try Data("base\n".utf8).write(to:childURL.appendingPathComponent("file"));try await module.stage(["file"]);_ = try await module.commit(message:"module base")
        try Data("[submodule \"fixture\"]\npath = module\nurl = ./module\n".utf8).write(to:parentURL.appendingPathComponent(".gitmodules"));try await parent.stage([".gitmodules","module"]);_ = try await parent.commit(message:"pointer base")
        let oldPointer=try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("new\n".utf8).write(to:childURL.appendingPathComponent("file"));try await module.stage(["file"]);_ = try await module.commit(message:"module next");try await parent.stage(["module"]);_ = try await parent.commit(message:"pointer next")
        let newPointer=try await parent.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),childTip=try await module.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let moduleModel=RevisionComparisonWindowModel(repository:parent,access:nil,from:.revision(oldPointer),to:.revision(newPointer),preferences:prefs);defer{moduleModel.invalidate()};moduleModel.confirmManyDiffs={_ in true}
        moduleModel.load();try await wait{!moduleModel.busy && moduleModel.snapshot != nil}
        var moduleLogs:[(URL,String?)]=[];moduleModel.onSubmoduleLog={moduleLogs.append(($0,$1))}
        moduleModel.logSubmodules(["module"]);try await wait{!moduleModel.busy}
        print("Changed Files module route:",moduleLogs.map{($0.0.absoluteString,$0.1 ?? "none")},"expected:",childURL.absoluteString,childTip,"error:",moduleModel.error ?? "none")
        try require(moduleLogs.count==1 && moduleLogs[0].0.standardizedFileURL.path==childURL.standardizedFileURL.path && moduleLogs[0].1==childTip,"Changed Files submodule Log lost child repository/tip: \(moduleModel.error ?? "none")")
        let oldPin=prefs.object(forKey:"LogSubmoduleShowRevision");prefs.set(false,forKey:"LogSubmoduleShowRevision")
        moduleModel.logSubmodules(["module"]);try await wait{!moduleModel.busy}
        if let oldPin{prefs.set(oldPin,forKey:"LogSubmoduleShowRevision")}else{prefs.removeObject(forKey:"LogSubmoduleShowRevision")}
        try require(moduleLogs.count==2 && moduleLogs[1].1==nil,"Unpinned submodule Log forced a revision")
        let final=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);try require(final==tip,"File actions moved HEAD")
        print("Changed Files actions: deleted/rename Blame routing, both version reverts and owned results/refresh, historical export/deleted skip, Ignore/Abort/folder cancel, protected checkout requested/forced-close ownership passed; private preferences/files, owned windows closed.")
    }

}
