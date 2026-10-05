import AppKit
import SwiftUI
import TurtleGitCore
import UniformTypeIdentifiers

/// Adapts WorktreeListDlg and its shared ColumnManager to native table controls.
struct WorktreeListTable: NSViewRepresentable {
    @ObservedObject var model: WorktreeListWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.model = model; context.coordinator.update()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        static let columns: [(String, String, CGFloat)] = [("path", "Path", 150), ("hash", "Hash", 100), ("branch", "Branch", 100), ("locked", "Locked", 100), ("reason", "Reason", 100)]
        static let settingsKey = "WorktreeList.Columns.v1"
        var model: WorktreeListWindowModel
        weak var table: NSTableView?
        private let defaults: UserDefaults
        private var updating = false
        private var snapshot: [String] = []
        private var adjusted = Set<String>()
        init(model: WorktreeListWindowModel, defaults: UserDefaults = .standard) { self.model = model; self.defaults = defaults }
        func makeScrollView() -> NSScrollView {
            let table = WorktreeTableView(defaults: defaults)
            table.rowHeight = 23; table.intercellSpacing = NSSize(width: 4, height: 0)
            table.allowsMultipleSelection = true; table.allowsColumnReordering = true
            table.allowsColumnResizing = true; table.columnAutoresizingStyle = .noColumnAutoresizing
            table.usesAlternatingRowBackgroundColors = false
            table.setAccessibilityLabel("Worktree List")
            for (id, title, width) in Self.columns {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                column.title = title; column.width = width; column.minWidth = 24; column.maxWidth = 10_000
                if id == "reason" { column.headerCell.alignment = .right }
                table.addTableColumn(column)
            }
            self.table = table
            restoreColumns()
            let header = WorktreeTableHeaderView(frame: NSRect(x: 0, y: 0, width: table.bounds.width, height: max(23, table.headerView?.frame.height ?? 23)))
            header.buildMenu = { [weak self] in self?.columnMenu() }
            header.fitColumn = { [weak self] index, useDefault in self?.fitColumn(index, useDefault: useDefault) }
            table.headerView = header
            table.delegate = self; table.dataSource = self
            table.target = self; table.doubleAction = #selector(explore)
            let menu = NSMenu(); menu.delegate = self; table.menu = menu
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
            scroll.borderType = .bezelBorder; scroll.documentView = table
            update()
            return scroll
        }
        func update() {
            guard let table else { return }
            updating = true; defer { updating = false }
            let next = model.rows.map { row in ([row.id] + Self.columns.map { value($0.0, row: row) }).joined(separator: "\0") }
            if next != snapshot { snapshot = next; table.reloadData() }
            let indices = IndexSet(model.rows.enumerated().compactMap { model.selection.contains($0.element.id) ? $0.offset : nil })
            if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
            table.isEnabled = !model.busy
            table.allowsColumnReordering = !model.busy; table.allowsColumnResizing = !model.busy
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
        func value(_ id: String, row: GitWorktree) -> String {
            switch id {
            case "path": return row.path.path
            case "hash": return model.hashLabel(row)
            case "branch": return model.branchLabel(row)
            case "locked": return row.isMain ? "" : row.lockReason == nil ? "Unlocked" : "Locked"
            case "reason": return row.isMain ? "" : row.lockReason ?? ""
            default: return ""
            }
        }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard model.rows.indices.contains(row), let column else { return nil }
            let record = model.rows[row], id = column.identifier.rawValue
            let text = NSTextField(labelWithString: value(id, row: record))
            text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            text.font = id == "hash" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            text.toolTip = text.stringValue
            if id == "reason" { text.alignment = .right }
            guard id == "path" else { return text }
            let cell = NSTableCellView(); cell.textField = text
            let icon = NSImageView(); icon.image = NSWorkspace.shared.icon(for: .folder)
            cell.imageView = icon; cell.addSubview(icon); cell.addSubview(text)
            icon.translatesAutoresizingMaskIntoConstraints = false; text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            model.selection = Set(table.selectedRowIndexes.compactMap { model.rows.indices.contains($0) ? model.rows[$0].id : nil })
        }
        func tableViewColumnDidMove(_ notification: Notification) { if !updating { saveColumns() } }
        func tableViewColumnDidResize(_ notification: Notification) {
            guard !updating else { return }
            if let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn { adjusted.insert(column.identifier.rawValue) }
            saveColumns()
        }
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard tableView.tableColumns.indices.contains(column) else { return 24 }
            return fittedWidth(tableView.tableColumns[column], includeHeader: NSEvent.modifierFlags.contains(.shift))
        }
        func fittedWidth(_ column: NSTableColumn, includeHeader: Bool) -> CGFloat {
            let id = column.identifier.rawValue
            let font: NSFont = id == "hash" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            let content = model.rows.map { (value(id, row: $0) as NSString).size(withAttributes: [.font: font]).width + (id == "path" ? 28 : 14) }.max() ?? 24
            let header = includeHeader ? (column.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 20 : 0
            return min(column.maxWidth, max(column.minWidth, content, header))
        }
        func fitColumn(_ index: Int, useDefault: Bool) {
            guard !model.busy, let table, table.tableColumns.indices.contains(index) else { return }
            let column = table.tableColumns[index], id = column.identifier.rawValue
            updating = true; column.width = fittedWidth(column, includeHeader: useDefault); updating = false
            if useDefault { adjusted.remove(id) } else { adjusted.insert(id) }
            saveColumns()
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let reset = NSMenuItem(title: "Reset columns", action: #selector(confirmReset), keyEquivalent: ""); reset.target = self; reset.isEnabled = !model.busy
            menu.addItem(reset); menu.addItem(.separator())
            for (id, title, _) in Self.columns.dropFirst() {
                let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = id; item.state = table?.tableColumns.first(where: { $0.identifier.rawValue == id })?.isHidden == false ? .on : .off
                item.isEnabled = !model.busy; menu.addItem(item)
            }
            return menu
        }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard !model.busy, let id = sender.representedObject as? String, id != "path", let column = table?.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }
            updating = true; column.isHidden.toggle()
            if !column.isHidden { column.width = fittedWidth(column, includeHeader: true) }
            updating = false
            saveColumns()
        }
        @objc func confirmReset() {
            guard !model.busy else { return }; model.busy = true
            Task { defer { model.busy = false }; if await model.confirmResetColumns() { resetColumns() } }
        }
        func resetColumns() {
            guard let table else { return }; updating = true
            for (index, definition) in Self.columns.enumerated() {
                guard let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == definition.0 }) else { continue }
                table.moveColumn(current, toColumn: index)
                let column = table.tableColumns[index]; column.isHidden = false; column.width = fittedWidth(column, includeHeader: true)
            }
            adjusted = []; updating = false; saveColumns()
        }
        func saveColumns() {
            guard let table else { return }
            defaults.set(["order": table.tableColumns.map { $0.identifier.rawValue },
                          "hidden": table.tableColumns.filter { $0.isHidden && $0.identifier.rawValue != "path" }.map { $0.identifier.rawValue },
                          "widths": Dictionary(uniqueKeysWithValues: table.tableColumns.filter { adjusted.contains($0.identifier.rawValue) }.map { ($0.identifier.rawValue, Double($0.width)) })], forKey: Self.settingsKey)
        }
        private func restoreColumns() {
            guard let table, let saved = defaults.dictionary(forKey: Self.settingsKey) else { return }
            var placed = Set<String>(); var position = 0
            for id in saved["order"] as? [String] ?? [] {
                guard placed.insert(id).inserted, let current = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }) else { continue }
                table.moveColumn(current, toColumn: position); position += 1
            }
            let hidden = Set(saved["hidden"] as? [String] ?? [])
            let widths = saved["widths"] as? [String: Double] ?? [:]
            for column in table.tableColumns {
                let id = column.identifier.rawValue
                column.isHidden = id != "path" && hidden.contains(id)
                if let width = widths[id], width.isFinite { column.width = max(column.minWidth, min(column.maxWidth, width)); adjusted.insert(id) }
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); menu.autoenablesItems = false
            let ids = model.selection
            func add(_ title: String, _ icon: MenuIcon, _ action: Selector) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.image = icon.contextImage(defaults: defaults); item.target = self; item.isEnabled = !model.busy; menu.addItem(item)
            }
            if ids.count == 1 { add("Explore to", .explore, #selector(explore)) }
            if model.showLock(ids) { add("Lock", .lock, #selector(lock)) }
            if model.showUnlock(ids) { add("Unlock", .unlock, #selector(unlock)) }
            if model.showRemove(ids) { add("Remove", .remove, #selector(remove)); add("Force remove", .remove, #selector(forceRemove)) }
        }
        @objc func explore() { model.open(model.selection) }
        @objc func lock() { model.modify(.lock, ids: model.selection) }
        @objc func unlock() { model.modify(.unlock, ids: model.selection) }
        @objc func remove() { model.modify(.remove, ids: model.selection) }
        @objc func forceRemove() { model.modify(.removeForce, ids: model.selection) }
    }
}

final class WorktreeTableView: NSTableView {
    private let defaults: UserDefaults
    private let backdrop = MenuIcon.repositoryBackdrop.image(size: 128)
    init(defaults: UserDefaults) { self.defaults = defaults; super.init(frame: .zero) }
    required init?(coder: NSCoder) { defaults = .standard; super.init(coder: coder) }
    func backdropRect(in viewport: NSRect) -> NSRect? {
        guard defaults.object(forKey: "ShowListBackgroundImage") as? Bool ?? true,
              backdrop != nil, viewport.width > 0, viewport.height > 0 else { return nil }
        return NSRect(x: viewport.maxX - 128, y: isFlipped ? viewport.maxY - 128 : viewport.minY, width: 128, height: 128)
    }
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let rect = backdropRect(in: visibleRect), rect.intersects(clipRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visibleRect.intersection(clipRect)).addClip()
        backdrop?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0 && !selectedRowIndexes.contains(clicked) { selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false) }
        menu?.update(); return menu
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 96, let coordinator = delegate as? WorktreeListTable.Coordinator { coordinator.model.reload(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

private final class WorktreeTableHeaderView: NSTableHeaderView {
    var buildMenu: () -> NSMenu? = { nil }
    var fitColumn: (Int, Bool) -> Void = { _, _ in }
    override func menu(for event: NSEvent) -> NSMenu? { buildMenu() }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let table = tableView {
            let point = convert(event.locationInWindow, from: nil)
            for (index, column) in table.tableColumns.enumerated() where !column.isHidden {
                if abs(point.x - headerRect(ofColumn: index).maxX) <= 4 {
                    fitColumn(index, event.modifierFlags.contains(.shift)); return
                }
            }
        }
        super.mouseDown(with: event)
    }
}
