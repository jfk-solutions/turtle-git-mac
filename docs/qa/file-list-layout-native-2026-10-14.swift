import AppKit
import TurtleGitCore

@main struct FileListLayoutVerification {
    final class TableSource: NSObject, NSTableViewDataSource {
        var count = 0
        func numberOfRows(in tableView: NSTableView) -> Int { count }
        func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { row }
    }
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message: "File-list layout timeout")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("File-list layout failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("tracked")); try await repo.stage(["tracked"]); _ = try await repo.commit(message: "base")
        try Data("changed\n".utf8).write(to: root.appendingPathComponent("tracked"))
        for i in 0..<50 { try Data("new\n".utf8).write(to: root.appendingPathComponent("new-\(i)")) }
        let suite = "TurtleGit.FileListLayout." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let owner = StatusWindowController(repository: repo, access: nil, defaults: prefs), model = owner.model
        defer { model.invalidate(); owner.close() }
        model.reload(); try await wait { !model.busy && StatusWindowModel.activeOperations == 0 }
        try await wait { views(owner.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let probe = views(owner.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        let table = views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        try await wait { probe.groupHeaders?.headings.count == 2 && table.tableColumns.filter { !$0.isHidden }.count == 6 }
        let heading = probe.groupHeaders!.headings.first!
        try require(heading.rect.width == table.visibleRect.width && heading.rect.width > table.tableColumns.first!.width, "Group title is constrained to first column")
        try require(probe.groupHeaders!.hitTest(.zero) == nil, "Group drawing intercepts pointer input")
        let originalRows = probe.rows, selection = model.selection
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            owner.window!.appearance = NSAppearance(named: appearance)
            try await Task.sleep(nanoseconds: 50_000_000)
            probe.configureColumns()
            try require(table.tableColumns.filter { !$0.isHidden }.count == 6 && probe.rows == originalRows && model.selection == selection, "Appearance changed layout or file identities")
        }
        let order = [StatusListColumn.status, .path] + StatusListColumn.allCases.filter { ![.status, .path].contains($0) }
        _ = model.saveColumnLayout(order: order, widths: [.path: 333])
        try await wait { probe.columnDefinition(atNativeIndex: 0) == .status }
        let baseline = prefs.dictionaryRepresentation()
        // SwiftUI owns its NSOutlineView column/data-source objects. Exercise
        // replacement policy on an ordinary native table, without mutating
        // SwiftUI's private hierarchy or invalidating its continuations.
        let replacementWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        replacementWindow.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)), scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 300)), replacementTable = NSTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200))
        let data = TableSource(); data.count = originalRows.count; replacementTable.dataSource = data
        replacementTable.headerView = NSTableHeaderView()
        for definition in StatusListColumn.allCases { let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(definition.rawValue)); column.title = definition.rawValue; column.minWidth = 40; column.maxWidth = 1000; column.width = 100; replacementTable.addTableColumn(column) }
        scroll.documentView = replacementTable; host.addSubview(scroll)
        let replacementProbe = CommitFileInteraction.Probe(frame: host.bounds)
        replacementProbe.leadingColumnCount = 0; replacementProbe.rows = originalRows; replacementProbe.visibleColumns = Set(model.visibleColumns)
        replacementProbe.savedOrder = order; replacementProbe.savedWidths = [.path: 333]; replacementProbe.enabled = true
        host.addSubview(replacementProbe); replacementWindow.contentView = host; replacementTable.reloadData(); replacementProbe.configureColumns()
        defer { replacementProbe.stopObserving(); replacementWindow.close(); withExtendedLifetime(data) {} }
        let originals = replacementTable.tableColumns
        for original in originals { replacementTable.removeTableColumn(original) }
        for original in originals {
            let replacement = NSTableColumn(identifier: original.identifier); replacement.title = original.headerCell.stringValue
            replacement.minWidth = original.minWidth; replacement.maxWidth = original.maxWidth; replacement.width = original.width
            replacementTable.addTableColumn(replacement)
        }
        replacementProbe.configureColumns()
        try require(replacementProbe.columnDefinition(atNativeIndex: 0) == .status && replacementProbe.columnDefinition(atNativeIndex: 1) == .path, "Replaced columns lost semantic mapping or saved order")
        let path = replacementTable.tableColumns.first { $0.headerCell.stringValue == "Path" }!
        try require(abs(path.width - 333) < 1 && replacementTable.tableColumns.filter { !$0.isHidden }.count == 6 && replacementTable.tableColumns.first { $0.headerCell.stringValue == "Filename" }!.isHidden, "Replaced columns lost adjusted width/visibility")
        try require(prefs.dictionaryRepresentation() as NSDictionary == baseline as NSDictionary, "Automatic repair persisted a synthetic user layout")
        let clip = table.enclosingScrollView!.contentView
        clip.scroll(to: NSPoint(x: 10, y: 200)); table.enclosingScrollView!.reflectScrolledClipView(clip)
        probe.configureColumns()
        try require(probe.groupHeaders!.headings.allSatisfy { abs($0.rect.minX - table.visibleRect.minX) < 1 }, "Group heading does not follow horizontal viewport")
        let commit = CommitWindowController(repository: repo, access: nil, defaults: prefs)
        defer { commit.model.invalidateForClose(); commit.close() }
        commit.model.reload()
        try await wait { !commit.model.busy && views(commit.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let commitProbe = views(commit.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        try await wait { commitProbe.groupHeaders?.headings.isEmpty == false }
        try require(commitProbe.leadingColumnCount == 1 && commitProbe.groupHeaders!.headings.allSatisfy { $0.rect.width > 500 }, "Commit checkbox table lost full-width group headings")
        commit.model.invalidateForClose(); commit.close()
        let layer = probe.groupHeaders!
        probe.stopObserving(); probe.scheduleColumnConfiguration()
        try await Task.sleep(nanoseconds: 50_000_000)
        try require(layer.superview == nil && probe.groupHeaders == nil, "Retired queued configuration reinstalled group layer")
        owner.close()
        print("File-list layout: full-width group geometry, pointer passthrough, appearance identities, simulated replaced-column remapping/order/width/visibility, no preference writes, viewport anchoring and retired observer teardown passed. Private native window closed.")
    }
}
