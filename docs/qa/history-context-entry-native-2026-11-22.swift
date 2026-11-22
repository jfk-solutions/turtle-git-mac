// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum HistoryContextEntryVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String, line: Int = #line) throws {
        if !value { throw Failure(description: "Context entry \(line): \(message)") }
    }
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(description: message) }; return value
    }
    static func views(_ view: NSView?) -> [NSView] {
        guard let view else { return [] }; return [view] + view.subviews.flatMap { views($0) }
    }
    static func wait(_ message: String, window: NSWindow? = nil, line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2400 {
            window?.contentView?.layoutSubtreeIfNeeded()
            if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(description: "Context entry timeout \(line): \(message)")
    }
    static func key(_ window: NSWindow, flags: NSEvent.ModifierFlags = .shift) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 109)!
    }
    static func mouse(_ table: NSTableView, row: Int, column: Int = 0) -> NSEvent {
        let cell = table.frameOfCell(atColumn: column, row: row)
        return NSEvent.mouseEvent(with: .rightMouseDown, location: table.convert(.init(x: cell.midX, y: cell.midY), to: nil), modifierFlags: [], timestamp: 0,
                                  windowNumber: table.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func find(_ menu: NSMenu, title: String? = nil, id: String? = nil) -> NSMenuItem? {
        for item in menu.items {
            if title.map({ item.title == $0 }) == true || id.map({ item.identifier?.rawValue == $0 }) == true { return item }
            if let child = item.submenu, let found = find(child, title: title, id: id) { return found }
        }
        return nil
    }
    static func invoke(_ item: NSMenuItem) throws {
        try require(item.isEnabled && !item.isHidden, "Native item unavailable: " + item.title)
        let action = try unwrap(item.action, "Missing selector: " + item.title)
        _ = NSApp.sendAction(action, to: item.target, from: item)
    }
    static func hiddenWindow(_ content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: -24000, y: -24000, width: 980, height: 340), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0; window.contentView = content; window.orderFront(nil); return window
    }
    static func withSheet(_ window: NSWindow, check: () throws -> Void) async throws {
        let sheet = NSWindow(contentRect: .init(x: -24000, y: -24000, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.alphaValue = 0
        defer { if sheet.sheetParent != nil { window.endSheet(sheet, returnCode: .abort) }; sheet.close() }
        window.beginSheet(sheet) { _ in }
        try await wait("attached private sheet") { window.attachedSheet === sheet }
        try check()
        window.endSheet(sheet, returnCode: .abort); sheet.close()
        try await wait("detached private sheet") { sheet.sheetParent == nil }
    }
    @MainActor final class Context {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ContextEntry." + UUID().uuidString
        let prefs: UserDefaults, board = NSPasteboard.withUniqueName()
        var repo: GitRepository!, first = "", head = "", index = Data(), original = Data()
        let path = "source 雪.swift"
        var owners: [NSWindowController] = [], windows: [NSWindow] = []
        var addModel: AddWindowModel?, addCoordinator: AddFileTable.Coordinator?
        init() {
            prefs = UserDefaults(suiteName: suite)!
            for key in ["UseLibgit2", "EnableGravatar", "Gravatar", "EnableLogCache", "Blame.EnableLexer", "LogIncludeWorkingTreeChanges"] { prefs.set(false, forKey: key) }
            prefs.set(true, forKey: "ShowAppContextMenuIcons")
        }
        func prepare() async throws {
            let root = base.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            repo = GitRepository(root: root, executable: git, askpass: nil, libgit2Configuration: .init(enabled: false))
            _ = try await repo.run(["init", "--template=", "-b", "main"])
            for (key, value) in [("user.name", "Context Entry QA"), ("user.email", "context@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
            var lines = (0..<90).map { "let line\($0) = \($0)" }
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent(path))
            try await repo.stage([path]); _ = try await repo.commit(message: "Context baseline")
            first = try await repo.rebaseCommit("HEAD").hash
            _ = try await repo.run(["tag", "baseline", first])
            let remote = base.appendingPathComponent("origin.git")
            _ = try await repo.run(["clone", "--bare", "--template=", "--", root.path, remote.path])
            _ = try await repo.run(["remote", "add", "origin", remote.path]); _ = try await repo.run(["fetch", "origin"])
            _ = try await repo.run(["branch", "--set-upstream-to=origin/main", "main"])
            for n in 1...2 {
                lines[n * 20] = "let changed\(n) = \(n)"
                try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: root.appendingPathComponent(path))
                try Data("Changed \(n)\n".utf8).write(to: root.appendingPathComponent("file\(n).txt"))
                try await repo.stage([path, "file\(n).txt"]); _ = try await repo.commit(message: "Context revision \(n)\n\nMessage body \(n)")
            }
            head = try await repo.rebaseCommit("HEAD").hash
            original = try Data(contentsOf: root.appendingPathComponent(path)); index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        }
        func own(_ owner: NSWindowController) {
            owners.append(owner); owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(.init(x: -24000, y: -24000)); owner.showWindow(nil)
        }
        func preserve() async throws {
            try require(try await repo.rebaseCommit("HEAD").hash == head, "Context menus changed HEAD")
            try require(try Data(contentsOf: repo.root.appendingPathComponent(".git/index")) == index, "Context menus changed the index")
            try require(try Data(contentsOf: repo.root.appendingPathComponent(path)) == original, "Context menus changed source contents")
        }
        func cleanup() async throws {
            addCoordinator?.retire(); addModel?.invalidate()
            for owner in owners {
                if let window = owner.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }
                owner.close()
            }
            for window in windows { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.close() }; window.close() }
            try await wait("owned worker drain") {
                AddWindowModel.activeOperations == 0 && BlameWindowModel.activeSyntaxRequests == 0 && BlameWindowModel.activeHistoryOperations == 0 && BlameWindowController.activeNavigationOperations == 0 && SynchronizationWindowModel.activeInlineOperations == 0 && SynchronizationWindowController.activeInlineReleases == 0
            }
            try require((owners.compactMap(\.window) + windows).allSatisfy { !$0.isVisible && $0.attachedSheet == nil }, "Owned context window remained visible")
            owners.removeAll(); windows.removeAll(); prefs.removePersistentDomain(forName: suite); board.releaseGlobally()
        }
    }
    static func add(_ c: Context) async throws {
        for name in ["untracked one.txt", "untracked 雪.txt"] { try Data((name + "\n").utf8).write(to: c.repo.root.appendingPathComponent(name)) }
        let model = AddWindowModel(repository: c.repo, access: nil, defaults: c.prefs); c.addModel = model
        model.setScope(["."]); try await model.read()
        let coordinator = AddFileTable.Coordinator(model: model); c.addCoordinator = coordinator
        let scroll = coordinator.make(), window = hiddenWindow(scroll); c.windows.append(window)
        let table = try unwrap(coordinator.table as? AddNativeTable, "Actual Add table missing")
        table.commandKeyWindow = { window }; window.makeFirstResponder(table)
        try require(table.numberOfRows >= 2 && model.highlighted.isEmpty, "Add fixture initial selection is not empty")
        let pointer = try unwrap(table.menu(for: mouse(table, row: 0)), "First Add pointer menu failed with no previous selection")
        pointer.delegate?.menuNeedsUpdate?(pointer)
        try require(model.highlighted.count == 1 && table.selectedRowIndexes == IndexSet(integer: 0), "Pointer menu did not select its exact unselected row")
        table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        model.selectionMark = coordinator.rows[1].path
        let selected = model.highlighted, mark = model.selectionMark
        coordinator.prepareContext(row: 1, column: 2)
        try require(coordinator.contextColumnID != nil, "Add pointer column setup missing")
        var presentations = 0, menu: NSMenu?, anchor = NSPoint.zero, correctView = false
        table.presentSelectionMenu = { value, point, view in
            presentations += 1; menu = value; anchor = point
            correctView = view === table
        }
        try require(table.accessibilityPerformShowMenu(), "Add accessibility menu refused selected files")
        try require(presentations == 1 && correctView && menu?.items.isEmpty == false && coordinator.contextColumnID == nil, "Add first AX menu missing or retained stale mouse column")
        try require(model.highlighted == selected && model.selectionMark == mark && table.selectedRowIndexes == IndexSet([0, 1]), "Add AX route changed the multiselection/focus")
        try require(table.rect(ofRow: 1).contains(anchor), "Add keyboard anchor ignored focused selected row")
        let uncheck = try unwrap(find(menu!, title: "Uncheck selected files"), "Add source Uncheck menu missing")
        try require(uncheck.image != nil && !uncheck.isHidden, "Add source command icon missing")
        try invoke(uncheck); try require(model.checked.intersection(selected).isEmpty, "Add captured Uncheck did not apply to both selected paths")
        table.keyDown(with: key(window)); try require(presentations == 2, "Add Shift-F10 did not use selected-row route")
        let check = try unwrap(find(menu!, title: "Check selected files"), "Add Check menu missing")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let checkedBefore = model.checked; try invoke(check)
        try require(model.checked == checkedBefore, "Add retained menu executed after selection replacement")
        table.commandKeyWindow = { nil }; let beforeBackground = presentations
        try require(!table.performKeyEquivalent(with: key(window)) && presentations == beforeBackground, "Background Add accepted Shift-F10")
        table.commandKeyWindow = { window }
        for blocked in 0..<2 {
            if blocked == 0 { model.busy = true } else { model.confirmingQuit = true }
            try require(!table.accessibilityPerformShowMenu(), "Busy/Quit Add showed menu")
            if blocked == 0 { model.busy = false } else { model.confirmingQuit = false }
        }
        try await withSheet(window) { try require(!table.accessibilityPerformShowMenu(), "Sheet-owned Add showed menu") }
        table.deselectAll(nil); try require(!table.accessibilityPerformShowMenu(), "Empty Add selection showed a keyboard menu")
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.retire(); try require(!table.accessibilityPerformShowMenu(), "Retired Add datasource showed menu")
        print("PASS: Add first pointer selection, focused multiselection AX/Shift-F10, source icon/action, stale receipt and busy/Quit/sheet/empty/retired refusal")
    }
    static func sync(_ c: Context) async throws {
        let owner = SynchronizationWindowController(repository: c.repo, access: nil, preferences: c.prefs)
        owner.model.sshSettings.enabled = false; c.own(owner)
        let model = owner.model, window = try unwrap(owner.window, "Sync owner missing")
        model.historyPasteboard = c.board
        try await wait("outgoing commits", window: window) { !model.busy && !model.hasPendingInlineWork && model.outgoing?.commits.count == 2 }
        // Both result directions are real history returned by Git; this source
        // route publishes the commits delivered by a completed local import.
        model.finishPatchImport(oldHead: c.first)
        try await wait("incoming commits", window: window) { !model.busy && !model.hasPendingInlineWork && model.incomingCommits?.count == 2 }
        for tab in [0, 4] {
            model.tab = tab
            try await wait("native Sync history \(tab)", window: window) {
                views(window.contentView).compactMap { $0 as? SynchronizationHistoryNativeTable }.contains { ($0.dataSource as? SynchronizationHistoryTable.Coordinator)?.sourceTab == tab && $0.numberOfRows == 2 }
            }
            let table = try unwrap(views(window.contentView).compactMap { $0 as? SynchronizationHistoryNativeTable }.first { ($0.dataSource as? SynchronizationHistoryTable.Coordinator)?.sourceTab == tab }, "Current Sync history missing")
            table.keyOwnerQuery = { $0 === window }; window.makeFirstResponder(table)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            var menu: NSMenu?, count = 0
            table.presentContextMenu = { value, _, _ in menu = value; count += 1 }
            // No manual delegate/menu update: verify the actual first invocation.
            let field = NSTextField(string: "Retained native input"); window.contentView!.addSubview(field); window.makeFirstResponder(field)
            let responder = window.firstResponder
            try require(table.accessibilityPerformShowMenu() && count == 1 && window.firstResponder === responder, "First Sync history AX menu missing or stole the native text responder")
            field.removeFromSuperview(); window.makeFirstResponder(table)
            let hashes = try unwrap(find(try unwrap(menu, "Sync menu not presented"), title: "Hashes"), "Sync history Hashes missing")
            try require(hashes.image != nil && table.selectedRowIndexes == IndexSet([0, 1]), "Sync history menu lost source icon or multiselection")
            let expected = model.historyEntries.prefix(2).map(\.hash).joined(separator: "\n")
            try invoke(hashes); try require(c.board.string(forType: .string) == expected, "Sync history native command lost captured displayed subjects")
            try require(table.performKeyEquivalent(with: key(window)) && count == 2, "Sync history Shift-F10 not routed")
            let stale = try unwrap(find(menu!, title: "Hashes"), "Sync stale Hashes missing")
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            c.board.clearContents(); c.board.setString("unchanged", forType: .string); try invoke(stale)
            try require(c.board.string(forType: .string) == "unchanged", "Sync history old selection receipt executed")
            table.keyOwnerQuery = { _ in false }
            try require(!table.showKeyboardContextMenu(), "Background Sync history opened keyboard menu")
            table.keyOwnerQuery = { $0 === window }
            model.confirmingQuit = true; try require(!table.accessibilityPerformShowMenu(), "Quit Sync history opened menu"); model.confirmingQuit = false
            try await withSheet(window) { try require(!table.accessibilityPerformShowMenu(), "Sheet-owned Sync history opened menu") }
            table.deselectAll(nil); try require(!table.accessibilityPerformShowMenu(), "Empty Sync history showed menu")
        }
        for tab in [1, 5] {
            model.tab = tab
            try await wait("native Sync files \(tab)", window: window) { views(window.contentView).compactMap { $0 as? SynchronizationFileNativeTable }.contains { ($0.dataSource as? SynchronizationFiles.Coordinator)?.state === model.displayedFileList && $0.numberOfRows >= 2 } }
            let table = try unwrap(views(window.contentView).compactMap { $0 as? SynchronizationFileNativeTable }.first { ($0.dataSource as? SynchronizationFiles.Coordinator)?.state === model.displayedFileList }, "Current Sync files missing")
            let coordinator = try unwrap(table.dataSource as? SynchronizationFiles.Coordinator, "Sync files datasource missing")
            let state = coordinator.state; state.clipboard = c.board
            table.keyOwnerQuery = { $0 === window }; window.makeFirstResponder(table)
            table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
            let selected = state.selection
            try require(selected.count == 2 && table.selectedRowIndexes == IndexSet([0, 1]), "Sync native selection did not synchronously retain both physical rows and model paths")
            var menu: NSMenu?, count = 0, anchorInside = false
            table.presentSelectionMenu = { value, point, _ in menu = value; count += 1; anchorInside = table.visibleRect.contains(point) }
            let field = NSTextField(string: "Retained native input"); window.contentView!.addSubview(field); window.makeFirstResponder(field)
            let responder = window.firstResponder
            try require(table.selectedRowIndexes == IndexSet([0, 1]) && state.selection == selected, "Sync native focus transfer cleared physical rows or model paths before contextual entry")
            let diagnostic = "tab=\(model.tab), rows=\(table.numberOfRows)/\(state.rows.count), available=\(state.available), current=\(table.contextMenuAvailable()), bounds=\(table.bounds), visible=\(table.visibleRect), row0=\(table.rect(ofRow: 0)), selected=\(table.selectedRowIndexes), focused=\(window.firstResponder === table), key=\(table.keyOwnerQuery(window)), nativeKey=\(window.isKeyWindow)"
            try require(table.accessibilityPerformShowMenu(), "First Sync file AX menu refused: " + diagnostic)
            try require(count == 1, "First Sync file AX did not present exactly once: count=\(count), " + diagnostic)
            try require(anchorInside, "First Sync file AX anchor escaped actual viewport: " + diagnostic)
            try require(window.firstResponder === responder, "First Sync file AX stole the native text responder: " + diagnostic)
            field.removeFromSuperview(); window.makeFirstResponder(table)
            let relative = try unwrap(find(menu!, id: "Sync.Files.copy.relativePaths"), "Sync file Relative paths missing")
            try require(relative.image != nil && find(menu!, id: "Sync.Files.copy.column") == nil && state.selection == selected, "Sync keyboard file popup lost icon/selection or invented pointer column")
            try invoke(relative)
            let expected = state.rows.prefix(2).map(\.path).joined(separator: "\n") + "\n"
            try require(c.board.string(forType: .string) == expected, "Sync file native clipboard used a foreign selection/order")
            try require(table.performKeyEquivalent(with: key(window)) && count == 2, "Sync file Shift-F10 not routed")
            let stale = try unwrap(find(menu!, id: "Sync.Files.copy.relativePaths"), "Sync file stale copy missing")
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            c.board.clearContents(); c.board.setString("unchanged", forType: .string); try invoke(stale)
            try require(c.board.string(forType: .string) == "unchanged", "Sync file stale selection receipt executed")
            table.keyOwnerQuery = { _ in false }; try require(!table.showSelectedContextMenu(), "Background Sync files showed menu"); table.keyOwnerQuery = { $0 === window }
            model.confirmingQuit = true; try require(!table.accessibilityPerformShowMenu(), "Quit Sync files showed menu"); model.confirmingQuit = false
            try await withSheet(window) { try require(!table.accessibilityPerformShowMenu(), "Sheet-owned Sync files showed menu") }
            let previousTab = model.tab; model.tab = 2
            try require(!table.accessibilityPerformShowMenu(), "Hidden Sync file list showed menu"); model.tab = previousTab
        }
        // Real local Fetch creates the source reference-result rows. It uses
        // only this private local bare repository, without authentication/network.
        _ = try await c.repo.run(["push", "origin", "HEAD:refs/heads/main"])
        _ = try await c.repo.run(["update-ref", "refs/remotes/origin/main", c.first])
        model.fetch()
        try await wait("local Fetch result", window: window) { !model.busy && !model.hasPendingInlineWork && !model.referenceChanges.isEmpty }
        model.tab = 3
        try await wait("native Sync reference result", window: window) { views(window.contentView).compactMap { $0 as? SynchronizationResultTable }.contains { $0.numberOfRows > 0 } }
        let result = try unwrap(views(window.contentView).compactMap { $0 as? SynchronizationResultTable }.first { $0.numberOfRows > 0 }, "Sync reference results missing")
        result.keyOwnerQuery = { $0 === window }; window.makeFirstResponder(result); result.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var resultMenu: NSMenu?, resultCount = 0, resultAnchorInside = false
        result.presentContextMenu = { value, point, _ in resultMenu = value; resultCount += 1; resultAnchorInside = result.visibleRect.contains(point) }
        try require(result.accessibilityPerformShowMenu() && resultCount == 1 && resultAnchorInside && resultMenu?.items.contains { !$0.isSeparatorItem && $0.image != nil } == true, "Sync result AX menu/source artwork missing")
        try require(result.performKeyEquivalent(with: key(window)) && resultCount == 2, "Sync result Shift-F10 not routed")
        result.keyOwnerQuery = { _ in false }; try require(!result.showKeyboardContextMenu(), "Background Sync result showed menu"); result.keyOwnerQuery = { $0 === window }
        try await withSheet(window) { try require(!result.accessibilityPerformShowMenu(), "Sheet-owned Sync result showed menu") }
        owner.close(); try require(!result.accessibilityPerformShowMenu(), "Retired Sync result showed menu")
        print("PASS: both Sync history/file directions and actual local Fetch results, first AX/Shift-F10 menus, source artwork/captured clipboard, focus/selection/sheet/Quit/hidden/retired policy")
    }
    static func blame(_ c: Context) async throws {
        let owner = BlameWindowController(repository: c.repo, access: nil, path: c.path, revision: c.head, preferences: c.prefs)
        c.own(owner); let model = owner.model, window = try unwrap(owner.window, "Blame owner missing")
        owner.commandKeyWindow = { window }
        try await wait("actual Blame source/history", window: window) {
            !model.busy && !model.syntaxWorking && model.lines.count == 90 && model.historyEntries.count == 3 && views(window.contentView).contains { $0 is BlameHistoryNativeTable }
        }
        let gutter = try unwrap(views(window.contentView).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.identifier.rawValue == "original" } }, "Blame attribution table missing")
        let history = try unwrap(views(window.contentView).compactMap { $0 as? BlameHistoryNativeTable }.first, "Blame native history missing")
        let source = try unwrap(views(window.contentView).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Blame source text" }, "Blame source editor missing")
        window.makeFirstResponder(gutter); gutter.selectRowIndexes(IndexSet(integer: 20), byExtendingSelection: false)
        let changedRange = (source.string as NSString).range(of: "let changed1 = 1")
        try require(changedRange.location != NSNotFound, "Private changed source line is missing")
        try require(model.selection == 21, "Native attribution row did not select source line21: actual=\(String(describing: model.selection)), nativeRow=\(gutter.selectedRow)")
        // BlameContainer.selectSourceLine defaults to includeBreak:false,
        // retaining exactly the line contents rather than its LF separator.
        try require(source.selectedRange() == changedRange, "Native attribution selected wrong source contents: expected=\(changedRange), actual=\(source.selectedRange())")
        // Source caret/row selection does not itself highlight an attribution
        // commit. The separate non-line margin action invokes highlight().
        model.highlight(20, additive: false)
        try require(model.selection == 21, "Annotation highlight moved the source line: actual=\(String(describing: model.selection))")
        try require(model.selectedLogHashes == [model.lines[20].hash], "Annotation highlight chose wrong source subject: expected=\(model.lines[20].hash), actual=\(model.selectedLogHashes)")
        let start = model.selection, hashes = model.selectedLogHashes
        var scrolls: [Int] = []; let realFirst = model.firstVisibleSourceRow, realScroll = model.scrollSourceRowToTop
        model.firstVisibleSourceRow = { 0 }; model.scrollSourceRowToTop = { scrolls.append($0) }
        model.navigateChange(previous: false); try require(scrolls == [20], "Available Blame navigation chose wrong next source block: actual=\(scrolls)")
        model.firstVisibleSourceRow = realFirst; model.scrollSourceRowToTop = realScroll
        for blocked in 0..<5 {
            switch blocked { case 0: model.busy = true; case 1: model.confirmingQuit = true; case 2: model.navigationSheetPresented = true; case 3: model.searchFeedbackBusy = true; default: model.historyChildBlocked = true }
            model.firstVisibleSourceRow = { 0 }; model.scrollSourceRowToTop = { scrolls.append($0) }; let beforeNavigation = scrolls.count
            model.navigateChange(previous: false)
            try require(scrolls.count == beforeNavigation, "Blocked Blame change navigation scrolled source")
            model.firstVisibleSourceRow = realFirst; model.scrollSourceRowToTop = realScroll
            model.highlight(40, additive: false); model.focusHistory([c.first], focus: c.first)
            gutter.selectRowIndexes(IndexSet(integer: 40), byExtendingSelection: false)
            try require(model.selection == start, "Blocked attribution changed the source line: blocker=\(blocked), expected=\(String(describing: start)), actual=\(String(describing: model.selection))")
            try require(model.selectedLogHashes == hashes, "Blocked history changed source subjects: blocker=\(blocked), expected=\(hashes), actual=\(model.selectedLogHashes)")
            try require(!gutter.accessibilityPerformShowMenu(), "Blocked attribution context request accepted: blocker=\(blocked)")
            try require(!history.accessibilityPerformShowMenu(), "Blocked history context request accepted: blocker=\(blocked)")
            try require(!source.accessibilityPerformShowMenu(), "Blocked source context request accepted: blocker=\(blocked)")
            switch blocked { case 0: model.busy = false; case 1: model.confirmingQuit = false; case 2: model.navigationSheetPresented = false; case 3: model.searchFeedbackBusy = false; default: model.historyChildBlocked = false }
        }
        var menu: NSMenu?, count = 0, copied = "", correctAnchor = false
        model.writeClipboard = { copied = $0 }
        model.presentHistoryMenu = { value, point, view in menu = value; count += 1; correctAnchor = view === history && history.visibleRect.contains(point) }
        history.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        try await wait("Blame native history selection", window: window) { model.selectedLogHashes.count == 2 }
        let selected = model.selectedLogHashes
        try require(history.accessibilityPerformShowMenu(), "Blame history AX entry refused")
        try await wait("first Blame history menu") { count == 1 && !model.readingHistoryParents }
        let hash = try unwrap(find(try unwrap(menu, "Blame first native menu missing"), title: "SHA-1"), "Blame native hash item missing")
        try require(hash.image != nil, "Blame history AX lost source command artwork")
        try require(correctAnchor, "Blame history AX anchor escaped its actual table/viewport: visible=\(history.visibleRect), selected=\(history.selectedRowIndexes)")
        try require(history.selectedRowIndexes == IndexSet([0, 1]), "Blame history AX changed native multiselection: actual=\(history.selectedRowIndexes)")
        try require(model.selectedLogHashes == selected, "Blame history AX changed model subjects: expected=\(selected), actual=\(model.selectedLogHashes)")
        try invoke(hash)
        let expected = model.historyEntries.filter { selected.contains($0.hash) }.map(\.hash).joined(separator: "\n")
        try require(copied == expected, "Blame history native command copied wrong subjects: expected=\(expected.debugDescription), actual=\(copied.debugDescription)")
        window.makeFirstResponder(history); history.keyDown(with: key(window))
        try await wait("Blame history Shift-F10") { count == 2 }
        let stale = try unwrap(find(menu!, title: "SHA-1"), "Blame retained hash item missing")
        model.confirmingQuit = true; copied = "unchanged"; try invoke(stale)
        try require(copied == "unchanged" && !history.accessibilityPerformShowMenu(), "Quit Blame history command executed")
        model.confirmingQuit = false
        try await withSheet(window) { try require(!history.accessibilityPerformShowMenu(), "Sheet-owned Blame history showed menu") }
        let previous = count; history.deselectAll(nil); try require(!history.accessibilityPerformShowMenu() && count == previous, "Empty Blame history showed menu")
        owner.close()
        try require(!history.accessibilityPerformShowMenu() && !gutter.accessibilityPerformShowMenu() && !source.accessibilityPerformShowMenu(), "Retired Blame native view showed menu")
        print("PASS: native Blame source attribution selection/change navigation, first history AX/Shift-F10 menu and captured hashes, blocked read/Quit/navigation/feedback/child/sheet/empty/retired policy")
    }
    static func run(_ mode: String) async throws {
        let context = Context()
        do {
            try await context.prepare()
            switch mode {
            case "add": try await add(context)
            case "sync": try await sync(context)
            case "blame": try await blame(context)
            default: throw Failure(description: "Unknown context entry case: " + mode)
            }
            try await context.preserve(); try await context.cleanup()
        } catch {
            let original = error
            do { try await context.cleanup() } catch { throw Failure(description: "\(original); cleanup: \(error)") }
            throw original
        }
    }
}
