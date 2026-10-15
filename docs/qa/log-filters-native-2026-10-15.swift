import AppKit
import Combine
import ScreenCaptureKit
import TurtleGitCore

@main struct LogFiltersVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Log filter timeout at \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func capture(_ owner: NSWindowController, directory: URL?) async throws {
        guard let directory, let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        NSApp.setActivationPolicy(.regular); owner.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Owned Log window missing") }
            let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("log-native-filters-" + suffix + ".png"))
        }
        window.orderOut(nil)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Log filters failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        let repo = GitRepository(root: root, executable: git), suite = "TurtleGit.LogFilters." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "TurtleGit Team"), ("user.email", "demo@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for (path, value) in [("README.md", "# Harbor\n"), ("Repository.swift", "struct Repository {}\n")] { try Data(value.utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["."]); _ = try await repo.commit(message: "Create the Harbor project")
        _ = try await repo.run(["switch", "-c", "feature/colorful-status"])
        try Data("struct StatusBadge {}\n".utf8).write(to: root.appendingPathComponent("Badge.swift")); try await repo.stage(["."]); _ = try await repo.commit(message: "Add colorful status badges")
        _ = try await repo.run(["switch", "main"])
        try Data("# Harbor\n\nBlue status palette\n".utf8).write(to: root.appendingPathComponent("README.md")); try Data("struct Repository { let blue = true }\n".utf8).write(to: root.appendingPathComponent("Repository.swift")); try await repo.stage(["."]); _ = try await repo.commit(message: "Use blue status colors")
        _ = try await repo.run(["merge", "--no-ff", "--no-edit", "feature/colorful-status"])
        _ = try await repo.run(["tag", "v0.1-preview"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), status = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        let keys: Set<String> = ["UseRegexFilter", "FilterCaseSensitively", "SelectedLogFilters"]
        let global = UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) }
        prefs.set(true, forKey: "ShowAppContextMenuIcons"); prefs.set(false, forKey: "EnableLogCache"); prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        prefs.set(HistorySearchFields.subject.rawValue, forKey: "SelectedLogFilters"); prefs.set(true, forKey: "FilterCaseSensitively"); prefs.set(false, forKey: "UseRegexFilter")
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false, historyRegexExecutable: helper)
        defer { owner.close() }; let model = owner.model; model.reload()
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !model.busy && model.entries.count == 4 }
        let baseline = model.entries.map(\.hash)
        try require(model.searchFields == .subject && model.searchCaseSensitive && !model.searchRegex, "Log ignored private filter settings")
        let fields = descendants(owner.window!.contentView!).compactMap { $0 as? NSSearchField }
        guard let history = fields.first(where: { $0.accessibilityLabel() == "Filter revisions" }), let paths = fields.first(where: { $0.accessibilityLabel() == "Filter changed paths" }), let coordinator = history.delegate as? LogFilterField.Coordinator, let pathCoordinator = paths.delegate as? LogFilterField.Coordinator else { throw Failure(description: "Native filter fields missing") }
        let menu = coordinator.makeMenu()
        try require(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == ["Subject", "Messages", "Paths", "Authors", "Emails", "Revisions", "Refname", "Tag Info", "Notes", "Toggle filters", "All", "Use regular expression", "Case-sensitive"], "Filter menu source order changed")
        let authors = menu.item(withTitle: "Authors")!, regex = menu.item(withTitle: "Use regular expression")!
        try require(authors.image != nil, "Original filter menu artwork missing")
        _ = NSApp.sendAction(authors.action!, to: authors.target, from: authors)
        _ = NSApp.sendAction(regex.action!, to: regex.target, from: regex)
        try require(model.searchFields == [.subject, .authors] && !model.searchRegex && prefs.integer(forKey: "SelectedLogFilters") == model.searchFields.rawValue, "Private or one-use filter menu failed")
        model.selectSearchFields(.subject)
        prefs.set(false, forKey: "ShowAppContextMenuIcons"); try require(coordinator.makeMenu().items.allSatisfy { $0.image == nil }, "Filter menu ignored icon preference"); prefs.removeObject(forKey: "ShowAppContextMenuIcons")
        var loads = 0
        let observation = model.$busy.dropFirst().sink { if $0 && model.loadingHistory { loads += 1 } }; defer { observation.cancel() }
        func type(_ value: String) { history.stringValue = value; coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: history)) }
        type("bl"); type("blue")
        try await Task.sleep(nanoseconds: 200_000_000); try require(loads == 0 && model.entries.map(\.hash) == baseline, "Typing refreshed before the source delay")
        try await wait { !model.busy && model.entries.count == 1 && model.entries.first?.subject == "Use blue status colors" }
        try require(loads == 1, "Typing did not coalesce into one history reload")
        history.stringValue = ""; coordinator.searchAction(history)
        try await wait { !model.busy && model.entries.count == 4 }
        let blue = model.entries.first { $0.subject == "Use blue status colors" }!; model.select([blue.hash]); try await wait { !model.busy && model.files.count == 2 }
        paths.stringValue = "README"; pathCoordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: paths))
        try await Task.sleep(nanoseconds: 200_000_000); try require(model.filterPaths.isEmpty, "Path filter ignored the source delay")
        try await wait { model.visibleFiles.count == 1 && model.visibleFiles.first?.path == "README.md" }
        let editor = NSTextView()
        try require(pathCoordinator.control(paths, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) && model.filterPaths.isEmpty && model.visibleFiles.count == 2, "Escape did not clear the path filter immediately")
        model.setSearchRegex(true); type("("); let beforeInvalid = loads
        try await wait { model.searchFilterError != nil }
        try require(loads == beforeInvalid && model.entries.count == 4, "Invalid ECMAScript changed the displayed history")
        try require(coordinator.control(history, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Invalid-pattern Return was not consumed")
        try await wait { !model.busy && model.searchFilterError == nil && loads > beforeInvalid }
        try require(model.entries.count == 4, "Explicit Return lost source inactive-filter fallback")
        type("blue|snow")
        try require(coordinator.control(history, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Native Return was not consumed")
        try await wait { !model.busy && model.searchFilterError == nil && model.entries.count == 1 }
        history.stringValue = ""; coordinator.searchAction(history); try await wait { !model.busy && model.entries.count == 4 }
        let gate = LogFilterValidationGate()
        model.readSearchValidation = { text, sensitive, token in try await gate.read(token) }
        model.editSearch("blue"); try await wait { LogWindowModel.activeFilterValidations == 1 }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Quit lost validation ownership")
        history.stringValue = ""; coordinator.searchAction(history)
        try await wait { !model.busy && model.entries.count == 4 }
        try require(await gate.cancelled, "Replacement query did not cancel validation")
        await gate.release(true); try await wait { LogWindowModel.activeFilterValidations == 0 }
        model.readSearchValidation = nil; model.setSearchRegex(false)
        // An independent retiring owner retains the started read through settlement.
        let late = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false, historyRegexExecutable: helper); defer { late.close() }
        late.model.reload(); try await wait { !late.model.busy && late.model.entries.count == 4 }
        let closeGate = LogFilterValidationGate(); late.model.setSearchRegex(true); late.model.readSearchValidation = { _, _, token in try await closeGate.read(token) }
        late.model.editSearch("blue"); try await wait { LogWindowModel.activeFilterValidations == 1 }
        late.close(); try require(await closeGate.cancelled && late.model.isInvalidated && LogWindowModel.activeFilterValidations == 1, "Close lost started validation lifetime")
        await closeGate.release(true); try await wait { LogWindowModel.activeFilterValidations == 0 }
        try require(late.model.entries.count == 4 && late.model.searchFilterError == nil, "Closed validation published a late result")
        model.select([blue.hash]); try await wait { !model.busy && model.files.count == 2 }
        owner.window!.setContentSize(NSSize(width: 1080, height: 740)); owner.window!.contentView!.layoutSubtreeIfNeeded()
        for field in [history, paths] { try require(field.bounds.width >= 140 && owner.window!.contentView!.bounds.contains(field.convert(field.bounds, to: owner.window!.contentView!)), "Filter clipped at native minimum size") }
        try await capture(owner, directory: output)
        let held = coordinator.makeMenu().item(withTitle: "Case-sensitive")!, sensitive = model.searchCaseSensitive
        model.editSearch("closed draft"); model.editPathFilter("closed path"); owner.close()
        _ = NSApp.sendAction(held.action!, to: held.target, from: held)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try require(model.isInvalidated && model.searchCaseSensitive == sensitive && model.filterPaths.isEmpty && LogWindowModel.activeHistoryLoads == 0, "Closed timer/menu restarted work")
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterStatus = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        try require(afterHead == head && afterStatus == status && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Filter UI changed repository state")
        try require(NSDictionary(dictionary: global).isEqual(to: UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) }), "Private Log changed global filters")
        print("PASS: Log filters completed: source menu/order/private preferences and icons, one-use/closed actions, coalesced one-second typing, immediate clear/Return/Escape, actual ECMAScript validation, query replacement and forced-close/Quit lifetime, minimum geometry and unchanged HEAD/index/status. All owned windows closed.")
    }
}
actor LogFilterValidationGate {
    private var continuation: CheckedContinuation<Bool, Error>?
    private var token: OperationCancellation?
    var cancelled: Bool { token?.isCancelled == true }
    func read(_ token: OperationCancellation) async throws -> Bool { self.token = token; return try await withCheckedThrowingContinuation { continuation = $0 } }
    func release(_ valid: Bool) { continuation?.resume(returning: valid); continuation = nil }
}
