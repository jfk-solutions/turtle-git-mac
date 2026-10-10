// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SendPatchTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var rows: [SendPatchRow] = []
    private(set) var checked = Set<UUID>()
    var interactionEnabled = true
    var checksChanged: (Set<UUID>) -> Void = { _ in }
    var highlightChanged: (Set<UUID>) -> Void = { _ in }
    var openPatch: (UUID) -> Void = { _ in }
    var openAlternatePatch: ((UUID) -> Void)?
    var reviewPatch: ((UUID) -> Void)?
    var applyPatches: ((Set<UUID>) -> Void)?
    var canViewPatch = false
    var droppedFiles: ([URL]) -> Bool = { _ in false }
    var menuPreferences: UserDefaults = .standard
    private var updating = false
    private var contentWidth: CGFloat = 400
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dataSource = self; delegate = self; allowsMultipleSelection = true; allowsEmptySelection = true
        headerView = nil; rowHeight = 23; backgroundColor = .textBackgroundColor; columnAutoresizingStyle = .noColumnAutoresizing
        let check = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("check")); check.title = ""; check.width = 28; check.minWidth = 28; check.maxWidth = 28; addTableColumn(check)
        let path = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path")); path.title = "Path"; path.width = 500; path.maxWidth = .greatestFiniteMagnitude; addTableColumn(path)
        target = self; doubleAction = #selector(doubleClicked)
        registerForDraggedTypes([.fileURL])
        setAccessibilityLabel("Patches to send")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(rows: [SendPatchRow], checked: Set<UUID>, highlighted: Set<UUID>) {
        updating = true; defer { updating = false }
        self.checked = checked
        if self.rows != rows { self.rows = rows; reloadData() }
        for index in rows.indices {
            if let button = view(atColumn: 0, row: index, makeIfNecessary: false) as? NSButton {
                button.state = checked.contains(rows[index].id) ? .on : .off; button.isEnabled = interactionEnabled
            }
        }
        let indices = IndexSet(rows.indices.filter { highlighted.contains(rows[$0].id) })
        if selectedRowIndexes != indices { selectRowIndexes(indices, byExtendingSelection: false) }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        contentWidth = rows.map { (display($0.file.path) as NSString).size(withAttributes: [.font: font]).width + 32 }.max() ?? 400
        fitViewport(enclosingScrollView?.contentSize ?? .zero)
    }
    func fitViewport(_ viewport: NSSize) {
        let columnInset = rect(ofColumn: 1).maxX - tableColumns[1].width
        let pathWidth = max(400, contentWidth, viewport.width - columnInset)
        if tableColumns[1].width != pathWidth { tableColumns[1].width = pathWidth }
        let size = NSSize(width: max(viewport.width, rect(ofColumn: 1).maxX), height: max(CGFloat(rows.count) * (rowHeight + intercellSpacing.height), viewport.height))
        if frame.size != size { setFrameSize(size) }
    }
    private func display(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "↵") }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if tableColumn?.identifier.rawValue == "check" {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkClicked(_:)))
            button.tag = row; button.state = checked.contains(rows[row].id) ? .on : .off; button.isEnabled = interactionEnabled
            button.setAccessibilityLabel("Send " + rows[row].file.path); return button
        }
        let cell = NSTableCellView(), image = NSImageView(), text = NSTextField(labelWithString: display(rows[row].file.path))
        image.image = MenuIcon.patch.image(); text.font = .systemFont(ofSize: NSFont.systemFontSize); text.lineBreakMode = .byClipping
        cell.toolTip = rows[row].file.path; cell.textField = text; cell.imageView = image
        for view in [image, text] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), image.centerYAnchor.constraint(equalTo: cell.centerYAnchor), image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16), text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { updating || interactionEnabled }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating, interactionEnabled else { return }
        highlightChanged(Set(selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }))
    }
    @objc private func checkClicked(_ sender: NSButton) {
        guard interactionEnabled, rows.indices.contains(sender.tag) else { return }
        let id = rows[sender.tag].id
        if sender.state == .on { checked.insert(id) } else { checked.remove(id) }
        checksChanged(checked)
    }
    @objc private func doubleClicked() {
        guard interactionEnabled, clickedColumn != 0, rows.indices.contains(clickedRow) else { return }
        viewPatch(rows[clickedRow].id, alternate: NSEvent.modifierFlags.contains(.shift))
    }
    private final class MenuRequest: NSObject {
        let ids: Set<UUID>; let kind: Int
        init(_ ids: Set<UUID>, _ kind: Int) { self.ids = ids; self.kind = kind }
    }
    func contextMenuForSelection() -> NSMenu? {
        guard interactionEnabled else { return nil }
        let ids = Set(selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        guard !ids.isEmpty else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        func item(_ title: String, _ kind: Int, _ icon: MenuIcon, _ enabled: Bool) {
            let item = NSMenuItem(title: title, action: #selector(runMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = MenuRequest(ids, kind); item.isEnabled = enabled
            item.image = icon.contextImage(defaults: menuPreferences)
            if kind == 0 { item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize)]) }
            menu.addItem(item)
        }
        if ids.count == 1 {
            item("View Patch", 0, .unifiedDiff, canViewPatch)
            item("Review Patch with TurtleGitMerge", 1, .editConflict, reviewPatch != nil)
        }
        item("Apply Patch…", 2, .patch, applyPatches != nil)
        return menu
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactionEnabled else { return nil }
        let hit = row(at: convert(event.locationInWindow, from: nil))
        if rows.indices.contains(hit) && !selectedRowIndexes.contains(hit) {
            selectRowIndexes(IndexSet(integer: hit), byExtendingSelection: false)
        }
        return contextMenuForSelection()
    }
    @objc private func runMenu(_ item: NSMenuItem) {
        guard interactionEnabled, let request = item.representedObject as? MenuRequest else { return }
        let valid = request.ids.intersection(rows.map(\.id))
        if request.kind == 2 { guard !valid.isEmpty else { return }; applyPatches?(valid) }
        else if valid.count == 1, let id = valid.first {
            if request.kind == 0 && canViewPatch { viewPatch(id, alternate: NSEvent.modifierFlags.contains(.shift)) }
            else if request.kind == 1 { reviewPatch?(id) }
        }
    }
    func viewPatch(_ id: UUID, alternate: Bool) {
        guard interactionEnabled, canViewPatch, rows.contains(where: { $0.id == id }) else { return }
        if alternate, let openAlternatePatch { openAlternatePatch(id) } else { openPatch(id) }
    }
    private func dropURLs(_ pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map { $0 as URL } ?? []
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard interactionEnabled, !dropURLs(info.draggingPasteboard).isEmpty else { return [] }
        setDropRow(rows.count, dropOperation: .above); return .copy
    }
    func acceptFiles(from pasteboard: NSPasteboard) -> Bool {
        guard interactionEnabled else { return false }; return droppedFiles(dropURLs(pasteboard))
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        acceptFiles(from: info.draggingPasteboard)
    }
    override func keyDown(with event: NSEvent) {
        if interactionEnabled && event.keyCode == 49 {
            let ids = selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil }
            for id in ids { if checked.contains(id) { checked.remove(id) } else { checked.insert(id) } }
            let highlight = selectedRowIndexes
            checksChanged(checked)
            updating = true; reloadData(); selectRowIndexes(highlight, byExtendingSelection: false); updating = false
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor final class SendPatchScroll: NSScrollView {
    private var fitting = false
    override func tile() {
        super.tile()
        guard !fitting, let table = documentView as? SendPatchTable else { return }
        fitting = true; defer { fitting = false }; table.fitViewport(contentSize)
    }
}

struct SendPatchList: NSViewRepresentable {
    @ObservedObject var model: SendPatchWindowModel
    @Environment(\.isEnabled) private var enabled
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SendPatchScroll(); scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.documentView = SendPatchTable(frame: .zero); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SendPatchTable else { return }
        table.interactionEnabled = enabled
        table.checksChanged = { [weak model] in model?.setChecked($0) }
        table.highlightChanged = { [weak model] in model?.setHighlighted($0) }
        table.canViewPatch = model.showPatch != nil
        table.openAlternatePatch = { [weak model] in model?.openPatch($0, alternate: true) }
        table.reviewPatch = model.reviewPatch == nil ? nil : { [weak model] in model?.review($0) }
        table.applyPatches = model.applyPatches == nil ? nil : { [weak model] in model?.apply($0) }
        table.droppedFiles = { [weak model] in model?.appendDroppedFiles($0) ?? false }
        table.openPatch = { [weak model] in model?.openPatch($0) }
        table.configure(rows: model.rows, checked: model.checked, highlighted: model.highlighted)
    }
}

struct SendPatchNotification: Identifiable, Equatable {
    enum Kind: Equatable { case command, sending, notice, error, finishedSuccess, finishedFailure }
    let id = UUID()
    let action: String
    let path: String
    let kind: Kind
    var auxiliary: Bool { kind != .sending }
    @MainActor func color(preferences: UserDefaults) -> NSColor {
        switch kind {
        case .sending: return StatusTextPalette.native(.modified, preferences: preferences)
        case .error: return StatusTextPalette.native(.conflict, preferences: preferences)
        case .notice: return .textColor
        case .finishedSuccess: return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .textColor : SubmoduleProgressTextView.successColor
        case .finishedFailure: return SubmoduleProgressTextView.color(error: true)
        case .command:
            let value = preferences.object(forKey: "Colors.Cmd") as? NSNumber
            let packed = value.flatMap { $0.doubleValue == Double($0.intValue) && (0...0xffffff).contains($0.intValue) ? $0.intValue : nil } ?? 0x646464
            return NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let channels = StatusTextPalette.transform([(packed >> 16) & 255, (packed >> 8) & 255, packed & 255], dark: dark, highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
                return NSColor(srgbRed: CGFloat(channels[0])/255, green: CGFloat(channels[1])/255, blue: CGFloat(channels[2])/255, alpha: 1)
            }
        }
    }
}
/// CGitProgressList's Action/Path notifications. Send Mail uses base
/// NotificationData, which adds no file actions or double-click handler.
@MainActor final class SendPatchNotificationTable: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var rows: [SendPatchNotification] = []
    private var sourceRows: [SendPatchNotification] = []
    var running = true
    var preferences: UserDefaults = .standard
    var clipboard: NSPasteboard = .general
    private var sortedColumn: String?, ascending = true
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dataSource = self; delegate = self; allowsMultipleSelection = true; allowsEmptySelection = true
        backgroundColor = .textBackgroundColor; rowHeight = 22; columnAutoresizingStyle = .noColumnAutoresizing
        for (identifier, title, width) in [("action", "Action", CGFloat(150)), ("path", "Path", CGFloat(560))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title
            column.width = width; column.minWidth = 80; column.maxWidth = .greatestFiniteMagnitude; addTableColumn(column)
        }
        setAccessibilityLabel("Send mail progress notifications")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func configure(_ notifications: [SendPatchNotification], running: Bool) {
        self.running = running
        guard sourceRows != notifications else { return }
        let resizeForNewRows = sourceRows.count < 30
        let selected = Set(selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        let follow = enclosingScrollView.map { $0.documentVisibleRect.maxY >= bounds.maxY - rowHeight * 2 } ?? true
        sourceRows = notifications; rows = notifications
        if !running, let sortedColumn { sortBlocks(column: sortedColumn, ascending: ascending) }
        reloadData(); selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        if resizeForNewRows { resizeContentColumns() }
        fitViewport(enclosingScrollView?.contentSize ?? .zero)
        if follow, !rows.isEmpty { scrollRowToVisible(rows.count - 1) }
    }
    private func resizeContentColumns() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        do {
            for (index, column) in tableColumns.enumerated() {
                let widths = rows.prefix(30).map { (display(index == 0 ? $0.action : $0.path) as NSString).size(withAttributes: [.font: font]).width + 16 }
                let width = max(index == 0 ? 150 : 400, widths.max() ?? 0)
                if column.width != width { column.width = width }
            }
        }
    }
    func fitViewport(_ viewport: NSSize) {
        let inset = rect(ofColumn: 1).maxX - tableColumns[1].width
        let width = max(tableColumns[1].width, viewport.width - inset)
        if tableColumns[1].width != width { tableColumns[1].width = width }
        let size = NSSize(width: max(viewport.width, rect(ofColumn: 1).maxX), height: max(viewport.height, CGFloat(rows.count) * (rowHeight + intercellSpacing.height)))
        if frame.size != size { setFrameSize(size) }
    }
    private func display(_ text: String) -> String { text.replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "↵") }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let text = NSTextField(labelWithString: display(tableColumn?.identifier.rawValue == "action" ? rows[row].action : rows[row].path))
        text.font = .systemFont(ofSize: NSFont.systemFontSize); text.lineBreakMode = .byClipping
        text.textColor = selectedRowIndexes.contains(row) ? .selectedControlTextColor : rows[row].color(preferences: preferences)
        text.toolTip = tableColumn?.identifier.rawValue == "action" ? rows[row].action : rows[row].path
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadData(forRowIndexes: IndexSet(rows.indices), columnIndexes: IndexSet(integersIn: 0..<2))
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard !running else { return }
        let column = tableColumn.identifier.rawValue
        if sortedColumn == column { ascending.toggle() } else { sortedColumn = column; ascending = true }
        let selected = Set(selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        sortBlocks(column: column, ascending: ascending); reloadData()
        selectRowIndexes(IndexSet(rows.indices.filter { selected.contains(rows[$0].id) }), byExtendingSelection: false)
        for candidate in tableColumns { setIndicatorImage(candidate === tableColumn ? NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil) : nil, in: candidate) }
    }
    private func sortBlocks(column: String, ascending: Bool) {
        var start = 0
        while start < rows.count {
            if rows[start].auxiliary { start += 1; continue }
            var end = start + 1
            while end < rows.count && !rows[end].auxiliary { end += 1 }
            let sorted = rows[start..<end].sorted { lhs, rhs in
                let action = column == "action" ? lhs.action.compare(rhs.action) : .orderedSame
                let order = action == .orderedSame ? lhs.path.compare(rhs.path, options: .caseInsensitive) : action
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            rows.replaceSubrange(start..<end, with: sorted); start = end
        }
    }
    func selectedText(keyboard: Bool) -> String {
        let selected = selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        if keyboard { return selected.map { "\($0.action): \($0.path)  \r\n" }.joined() }
        var result = selected.map(\.path).joined(separator: "\r\n")
        while result.last?.isWhitespace == true { result.removeLast() }
        return result
    }
    func contextMenuForSelection() -> NSMenu? {
        guard !running, !selectedRowIndexes.isEmpty else { return nil }
        let menu = NSMenu(); menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy to clipboard", action: #selector(copyPaths(_:)), keyEquivalent: "")
        copy.target = self; copy.image = MenuIcon.copy.contextImage(defaults: preferences); menu.addItem(copy); return menu
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard !running else { return nil }
        let hit = row(at: convert(event.locationInWindow, from: nil))
        if rows.indices.contains(hit), !selectedRowIndexes.contains(hit) { selectRowIndexes(IndexSet(integer: hit), byExtendingSelection: false) }
        return contextMenuForSelection()
    }
    @objc func copyPaths(_ sender: Any?) { guard !running else { return }; write(selectedText(keyboard: false)) }
    private func write(_ text: String) { guard !text.isEmpty else { return }; clipboard.clearContents(); clipboard.setString(text, forType: .string) }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers?.lowercased() == "a" { selectRowIndexes(IndexSet(rows.indices), byExtendingSelection: false); return true }
        if event.charactersIgnoringModifiers?.lowercased() == "c" { write(selectedText(keyboard: true)); return true }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor private final class SendPatchNotificationScroll: NSScrollView {
    override func tile() { super.tile(); (documentView as? SendPatchNotificationTable)?.fitViewport(contentSize) }
}
struct SendPatchNotificationList: NSViewRepresentable {
    @ObservedObject var model: SendPatchProgressModel
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = SendPatchNotificationScroll(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        let table = SendPatchNotificationTable(); table.preferences = model.notificationPreferences; scroll.documentView = table
        table.configure(model.notifications, running: model.busy); return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? SendPatchNotificationTable else { return }
        table.configure(model.notifications, running: model.busy)
    }
}
