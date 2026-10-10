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
