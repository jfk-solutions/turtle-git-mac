import AppKit
import TurtleGitCore

@main struct RefLogTableVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func table(_ view: NSView) -> ReferenceLogTableView? {
        if let table = view as? ReferenceLogTableView { return table }
        return view.subviews.compactMap(table).first
    }
    @MainActor static func wait(_ ready: () -> Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }; throw Failure(description: "RefLog table did not settle") }
    @MainActor static func invoke(_ item: NSMenuItem) throws {
        guard item.isEnabled, let action = item.action else { throw Failure(description: "Disabled item: " + item.title) }
        print("Dispatch", item.title, NSStringFromSelector(action))
        try require(NSApp.sendAction(action, to: item.target, from: item), "Action dispatch failed: " + item.title)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("RefLog table failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let suite = "TurtleGit.RefLogTable.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "UseSystemLocaleForDates"); prefs.set(false, forKey: "RelativeTimes")
        let board = NSPasteboard(name: .init(suite)); defer { board.releaseGlobally() }
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Table QA"), ("user.email", "table@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("source")
        try Data("source\n".utf8).write(to: file); try await repo.stage(["source"]); _ = try await repo.commit(message: "first unique message")
        for _ in 0..<14 { _ = try await repo.run(["checkout", "--detach", "HEAD"]); _ = try await repo.run(["checkout", "main"]) }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: file)
        let owner = ReferenceLogWindowController(repository: repo, access: nil, reference: "HEAD", preferences: prefs)
        defer { owner.close() }
        owner.model.reload()
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !owner.model.busy && table(owner.window!.contentView!)?.numberOfRows == owner.model.entries.count && owner.model.entries.count > 20 }
        let native = table(owner.window!.contentView!)!, coordinator = native.owner!
        try require((native.headerView?.frame.height ?? 0) > 0, "Column header has no visible height")
        try require(native.tableColumns.map(\.title) == ["Hash", "Ref", "Action", "Message", "Date"], "Source column order changed")
        native.selectRowIndexes(IndexSet([0,1]), byExtendingSelection: false)
        try require(owner.model.selection.count == 2 && owner.model.entries[0].hash == owner.model.entries[1].hash, "Repeated hashes lost independent selector selection")
        let multi = coordinator.menu(pasteboard: board)
        try invoke(multi.item(withTitle: "Copy to clipboard")!.submenu!.item(withTitle: "SHA-1")!)
        try require(board.string(forType: .string) == owner.model.entries.prefix(2).map(\.hash).joined(separator: "\r\n"), "Multi-row Copy collapsed repeated hashes")
        let logRanges = multi.items.filter { $0.title.hasPrefix("Show log of ") }
        try require(logRanges.count == 3, "Two-row range menu lost source variants")
        owner.model.find = "first unique message"; owner.model.findNext()
        try await wait { native.selectedRowIndexes == IndexSet(integer: owner.model.entries.count-1) }
        try require(native.enclosingScrollView!.contentView.bounds.origin.y > 0, "Find did not reveal the selected row")
        native.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var opened = ""; owner.model.onLog = { opened = $0 }
        let single = coordinator.menu(pasteboard: board), show = single.item(withTitle: "Show log")!
        try require(show.image != nil, "Original Show Log icon missing")
        try invoke(show); try require(opened == owner.model.entries[0].hash, "Show Log routed the wrong row")
        opened = ""
        try require(NSApp.sendAction(native.doubleAction!, to: native.target, from: native), "Double-click action did not dispatch")
        try require(opened == owner.model.entries[0].hash, "Double-click action selected the wrong entry")
        let full = single.item(withTitle: "Copy to clipboard")!.submenu!.item(withTitle: "Full data")!
        try invoke(full)
        let date = ReferenceLogWindowModel.dateText(owner.model.entries[0], dates: .load(defaults: prefs))
        let dateColumn = native.tableColumns.firstIndex { $0.identifier.rawValue == "Date" }!
        let dateCell = native.view(atColumn: dateColumn, row: 0, makeIfNecessary: true) as? NSTableCellView
        try require(dateCell?.textField?.stringValue == date, "Displayed date differs from private settings")
        try require(board.string(forType: .string)?.contains("Date: " + date) == true, "Clipboard dates ignored private UI settings")
        prefs.set(false, forKey: "ShowAppContextMenuIcons")
        try require(coordinator.menu(pasteboard: board).items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil }, "Context icon preference ignored")
        prefs.set(true, forKey: "ShowAppContextMenuIcons")
        let header = coordinator.headerMenu()
        try invoke(header.item(withTitle: "Message")!)
        native.tableColumn(withIdentifier: .init("Hash"))!.width = 220
        native.moveColumn(0, toColumn: 4); coordinator.saveColumns()
        try require(prefs.stringArray(forKey: "RefLog.Columns.Order")?.last == "Hash", "Column reorder not saved")
        let reopened = ReferenceLogWindowController(repository: repo, access: nil, reference: "HEAD", preferences: prefs)
        defer { reopened.close() }
        reopened.model.reload()
        try await wait { reopened.window!.contentView!.layoutSubtreeIfNeeded(); return !reopened.model.busy && table(reopened.window!.contentView!) != nil }
        let restored = table(reopened.window!.contentView!)!
        try require(restored.tableColumns.last?.identifier.rawValue == "Hash" && abs(restored.tableColumn(withIdentifier: .init("Hash"))!.width-220) < 1 && restored.tableColumn(withIdentifier: .init("Message"))!.isHidden, "Reopened layout did not retain order/width/visibility")
        owner.model.busy = true; opened = ""; NSApp.sendAction(show.action!, to: show.target, from: show)
        try require(opened.isEmpty, "Busy table accepted stale Show Log")
        owner.model.busy = false
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(after == head && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: file)) == bytes, "Table interactions changed repository state")
        // A selector can survive refresh while pointing at a different commit.
        // Retained commands must reject that replacement, even for Copy.
        _ = try await repo.run(["commit", "--allow-empty", "-m", "replacement"])
        owner.model.reload(); try await wait { !owner.model.busy }
        board.clearContents(); board.setString("sentinel", forType: .string)
        NSApp.sendAction(full.action!, to: full.target, from: full)
        try require(board.string(forType: .string) == "sentinel", "Stale selector redirected Copy to new data")
        reopened.close(); owner.close(); opened = ""
        NSApp.sendAction(show.action!, to: show.target, from: show)
        try require(opened.isEmpty, "Closed RefLog retained a live action target")
        print("RefLog native table: five source columns, repeated-selector selection, source range menus/icons, private clipboard/date settings, Find scrolling, saved width/order/hide, busy/replaced-row/closed action guards and read-only repository preservation passed. Owned windows closed.")
    }
}
