import AppKit
import TurtleGitCore
import Darwin

@main struct CommitReferencesVerification {
    struct Failure: Error { let line: UInt }
    static func require(_ value: @autoclosure () -> Bool, line: UInt = #line) throws { if !value() { throw Failure(line: line) } }
    @MainActor static func wait(_ ready: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(line: line)
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await verify(); print("PASS: Native commit-containing references, source menus/pickers/filtering, Log route, stale replies and owned close; repository bytes unchanged. No physical gestures, installed Finder or signed acceptance."); fflush(stdout); exit(0) }
            catch { print("FAIL: \(error)"); fflush(stdout); exit(1) }
        }; NSApp.run()
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git), suite = "TurtleGit.CommitRefs.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!; defer { prefs.removePersistentDomain(forName: suite) }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "References QA"), ("user.email", "refs@example.invalid"), ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file.txt")
        try Data("root\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Root subject")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "old", base]); _ = try await repo.run(["tag", "-a", "root-tag", "-m", "Annotation", base])
        try Data("next\n".utf8).write(to: file); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "Next subject")
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), bytes = try Data(contentsOf: file), refs = try await repo.run(["show-ref"]).stdout
        let controller = CommitContainingReferencesWindowController(repository: repo, access: nil, revision: base, preferences: prefs), window = controller.window!
        window.alphaValue = 0; window.orderFront(nil); defer { window.close() }
        var copied = "", logs: [(String?, Bool, HistoryRevisionRange?)] = [], browsed: [String] = [], comparisons: [(ComparisonRevision, ComparisonRevision)] = []
        controller.copyText = { copied = $0 }; controller.onLog = { logs.append(($0, $1, $2)) }; controller.onBrowse = { browsed.append($0) }; controller.onCompare = { comparisons.append(($0, $1)) }
        controller.refresh(); try await wait { !controller.busy }
        if controller.snapshot?.hash != base || controller.rows.count != 4 || !controller.showLog.isEnabled { print("Initial refs diagnostic:", controller.snapshot?.hash ?? "nil", base, controller.rows.map(\.rawValue), controller.showLog.isEnabled, controller.status.stringValue) }
        try require(controller.snapshot?.hash == base && controller.rows.count == 4 && controller.showLog.isEnabled)
        try require(controller.subject.stringValue.hasSuffix("Root subject") && controller.subject.toolTip!.contains("References QA"))
        try require(controller.table.headerView == nil && controller.table.allowsMultipleSelection && MenuIcon.showBranches.image() != nil)
        let cell = controller.tableView(controller.table, viewFor: controller.table.tableColumns[0], row: 0) as! NSTableCellView
        try require(cell.imageView?.image?.size == NSSize(width: 16, height: 16))
        window.contentView!.layoutSubtreeIfNeeded(); try require(controller.revision.frame.width > 300 && controller.table.enclosingScrollView!.frame.height > 200)
        let buttonRect = controller.showLog.convert(controller.showLog.bounds, to: window.contentView!)
        try require(abs(buttonRect.maxX - (window.contentView!.bounds.width - 14)) < 1)
        if CommandLine.arguments.count > 3 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[3])
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                try await Task.sleep(nanoseconds: 100_000_000)
                let view = window.contentView!, bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.layoutSubtreeIfNeeded()
                views(view).forEach { $0.needsDisplay = true; $0.displayIfNeeded() }
                window.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("commit-containing-refs-" + name + ".png"))
            }
            window.appearance = NSAppearance(named: .aqua)
        }
        func menu() -> NSMenu { let menu = controller.table.menu!; controller.menuNeedsUpdate(menu); return menu }
        func action(_ title: String) throws {
            let item = menu().items.first { $0.title == title }!; try require(item.isEnabled && NSApp.sendAction(item.action!, to: item.target, from: item))
        }
        let mainIndex = controller.rows.firstIndex(of: "refs/heads/main")!, oldIndex = controller.rows.firstIndex(of: "refs/heads/old")!
        controller.table.selectRowIndexes(IndexSet(integer: mainIndex), byExtendingSelection: false)
        try require(menu().items.filter { !$0.isSeparatorItem }.map(\.title) == ["Show log", "Browse repository", "Compare with working tree", "Copy"])
        try require(menu().items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image != nil })
        try action("Copy"); try require(copied == "refs/heads/main\n")
        try action("Show log"); try require(logs.last?.0 == "refs/heads/main" && logs.last?.1 == false)
        try action("Browse repository"); try require(browsed == ["refs/heads/main"])
        try action("Compare with working tree"); try require(comparisons.count == 1 && comparisons[0].0 == .revision("refs/heads/main") && comparisons[0].1 == .workingTree)
        controller.showLog.performClick(nil); try require(logs.last?.0 == base && logs.last?.1 == true)
        controller.table.selectRowIndexes(IndexSet(integer: oldIndex), byExtendingSelection: false)
        controller.table.selectRowIndexes(IndexSet(integer: mainIndex), byExtendingSelection: true)
        let rangeItems = menu().items.filter { ($0.representedObject as? String) == "range" || ($0.representedObject as? String) == "symmetric" }
        try require(rangeItems.count == 2 && rangeItems[0].title == "Show log of old..main")
        try action(rangeItems[0].title); try require(logs.last?.2?.from == "refs/heads/old" && logs.last?.2?.to == "refs/heads/main")
        try action(rangeItems[1].title); try require(logs.last?.2?.kind == .symmetricDifference)
        try action("Compare revisions"); try require(comparisons.count == 2 && comparisons[1].0 == .revision("refs/heads/main") && comparisons[1].1 == .revision("refs/heads/old"))
        var unified: Data?, alternate = true
        controller.onUnified = { unified = $0; alternate = $1 }
        try action("Unified diff"); try await wait { !controller.busy && unified != nil }
        try require(!alternate && String(decoding: unified!, as: UTF8.self).contains("-next\n+root"))
        controller.table.selectAll(nil); try require(menu().items.map(\.title) == ["Copy"])
        controller.filter.stringValue = "tags"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.filter))
        try require(controller.rows.count == 4); try await wait { controller.rows.count == 1 }
        try require(controller.rows[0] == "refs/tags/root-tag")
        controller.filter.stringValue = "TAGS"; controller.applyFilter(); try require(controller.rows.isEmpty)
        window.makeFirstResponder(controller.filter)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        try require(window.performKeyEquivalent(with: escape)); try require(controller.filter.stringValue.isEmpty && controller.rows.count == 4)
        controller.revision.stringValue = "missing"; controller.refresh(); try await wait { !controller.busy }
        try require(controller.snapshot == nil && !controller.showLog.isEnabled && !controller.filter.isEnabled && controller.chooser.isEnabled && controller.status.stringValue.contains("Invalid revision"))
        controller.revision.stringValue = ""; controller.refresh(); try require(controller.rows.isEmpty && controller.status.stringValue.isEmpty)
        controller.revision.stringValue = base; controller.refresh(); try await wait { !controller.busy }
        func choose(_ index: Int) throws {
            let item = controller.chooser.itemArray.first { $0.title == ["Browse References", "Log", "Reflog"][index] }!
            try require(NSApp.sendAction(item.action!, to: item.target, from: item))
            print("Chooser dispatch:", item.title, item.tag, String(describing: controller.picker))
        }
        try choose(0); try await wait { (controller.picker as? ReferenceBrowserWindowController)?.model.busy == false }
        let browser = controller.picker as! ReferenceBrowserWindowController
        try require(window.attachedSheet === browser.window && browser.window!.alphaValue == 0 && !controller.windowShouldClose(window))
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        browser.model.finish(nil); try await wait { controller.picker == nil && window.attachedSheet == nil }
        try require(controller.revision.stringValue == base)
        try choose(0); try await wait { (controller.picker as? ReferenceBrowserWindowController)?.model.busy == false }
        let accepted = controller.picker as! ReferenceBrowserWindowController; accepted.model.folder = "refs/heads"; accepted.model.select(["refs/heads/main"], last: "refs/heads/main"); accepted.model.accept()
        try await wait { controller.picker == nil && !controller.busy && window.attachedSheet == nil }
        try require(controller.revision.stringValue == "refs/heads/main" && controller.snapshot?.hash == String(decoding: head, as: UTF8.self).trimmingCharacters(in: .newlines))
        try choose(1); try await wait { (controller.picker as? LogWindowController)?.model.busy == false }
        let logPicker = controller.picker as! LogWindowController; logPicker.model.close(); try await wait { controller.picker == nil && window.attachedSheet == nil }
        try choose(2); try await wait { (controller.picker as? ReferenceLogWindowController)?.model.busy == false }
        let reflog = controller.picker as! ReferenceLogWindowController; reflog.model.close(); try await wait { controller.picker == nil && window.attachedSheet == nil }
        let bareRoot = root.appendingPathExtension("bare")
        _ = try await repo.run(["clone", "--bare", "--", root.path, bareRoot.path])
        let bare = CommitContainingReferencesWindowController(repository: GitRepository(root: bareRoot, executable: git), access: nil, revision: "HEAD", preferences: prefs)
        bare.window!.alphaValue = 0; bare.window!.orderFront(nil); bare.onCompare = controller.onCompare; bare.onLog = controller.onLog
        bare.refresh(); try await wait { !bare.busy }; try require(bare.snapshot?.bare == true)
        bare.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        bare.menuNeedsUpdate(bare.table.menu!); try require(!bare.table.menu!.items.contains { $0.title == "Compare with working tree" })
        bare.close()
        // Supersede an obsolete reply that ignores cancellation.
        let oldSnapshot = try await repo.commitContainingReferences(base)
        var release: CheckedContinuation<CommitContainingReferences, Never>?
        controller.read = { _, _ in await withCheckedContinuation { release = $0 } }
        controller.revision.stringValue = base; controller.refresh(); try await wait { release != nil }
        controller.read = nil; controller.revision.stringValue = "main"; controller.refresh(); try await wait { !controller.busy }
        release!.resume(returning: oldSnapshot); release = nil; try await Task.sleep(nanoseconds: 100_000_000)
        try require(controller.snapshot?.subject == "Next subject" && controller.revision.stringValue == "main")
        controller.read = { _, _ in await withCheckedContinuation { release = $0 } }; controller.refresh(); try await wait { release != nil }
        window.close(); release!.resume(returning: oldSnapshot); release = nil; try await Task.sleep(nanoseconds: 100_000_000)
        try require(controller.closed && !controller.busy && controller.picker == nil)
        // Use the actual parent revision-table menu to open the modeless child.
        let parent = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false)
        parent.window!.alphaValue = 0; parent.window!.orderFront(nil); defer { parent.close() }
        try await wait { !parent.model.busy && !parent.model.entries.isEmpty }
        parent.model.select([base]); parent.window!.contentView!.layoutSubtreeIfNeeded()
        let table = views(parent.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.identifier.rawValue == "graph" } }!
        table.selectRowIndexes(IndexSet(integer: parent.model.entries.firstIndex { $0.hash == base }!), byExtendingSelection: false)
        table.menu!.delegate!.menuNeedsUpdate?(table.menu!)
        let entry = table.menu!.items.first { $0.title == "Show branches this commit is on" }!
        try require(entry.isEnabled && entry.image != nil && NSApp.sendAction(entry.action!, to: entry.target, from: entry))
        try await wait { parent.containingReferences.count == 1 && parent.containingReferences.values.first?.busy == false }
        let owned = parent.containingReferences.values.first!; try require(owned.window!.parent === parent.window && owned.window!.alphaValue == 0 && owned.snapshot?.hash == base)
        parent.close(); try require(owned.closed && parent.containingReferences.isEmpty)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterBytes = try Data(contentsOf: file)
        try require(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && bytes == afterBytes)
    }
}
