import AppKit
import SwiftUI
import TurtleGitCore

private final class AddNativeTable: NSTableView {
    var toggleChecks: () -> Void = {}
    var copySelection: () -> Void = {}
    var deleteSelection: (Bool) -> Void = { _ in }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0 else { return nil }
        if !selectedRowIndexes.contains(index) { selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelection(event.modifierFlags.contains(.shift)); return
        }
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .control, .option]).isEmpty { toggleChecks(); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.contains(.command) { copySelection(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct AddFileTable: NSViewRepresentable {
    @ObservedObject var model: AddWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.refresh() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AddWindowModel
        private let nativeTable = AddNativeTable()
        var table: NSTableView { nativeTable }
        private var updating = false
        init(model: AddWindowModel) { self.model = model }
        var rows: [AddDialogEntry] {
            let descriptor = table.sortDescriptors.first
            return model.entries.sorted { a, b in
                let result: ComparisonResult
                switch descriptor?.key {
                case "ext": result = (a.path as NSString).pathExtension.localizedStandardCompare((b.path as NSString).pathExtension)
                case "size": result = (a.size ?? -1) == (b.size ?? -1) ? .orderedSame : (a.size ?? -1) < (b.size ?? -1) ? .orderedAscending : .orderedDescending
                case "date": result = (a.modified ?? .distantPast).compare(b.modified ?? .distantPast)
                default: result = a.path.localizedStandardCompare(b.path)
                }
                if result == .orderedSame { return a.path.localizedStandardCompare(b.path) == .orderedAscending }
                return descriptor?.ascending == false ? result == .orderedDescending : result == .orderedAscending
            }
        }
        func make() -> NSScrollView {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
            table.dataSource = self; table.delegate = self; table.allowsMultipleSelection = true; table.rowHeight = 22
            table.target = self; table.doubleAction = #selector(preview)
            nativeTable.toggleChecks = { [weak self] in self?.toggleSelectedChecks() }
            nativeTable.copySelection = { [weak self] in self?.copyText("relative") }
            nativeTable.deleteSelection = { [weak self] permanently in self?.deleteSelected(permanently: permanently, keyboard: true) }
            for (id, title, width) in [("check", "", 26.0), ("path", "Path", 440.0), ("ext", "Extension", 85.0), ("size", "Size", 90.0), ("date", "Modification date", 150.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
                if id != "check" { column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
                column.isHidden = id == "size" && !UserDefaults.standard.bool(forKey: "Add.ShowSize") || id == "date" && !UserDefaults.standard.bool(forKey: "Add.ShowModifiedDate")
                table.addTableColumn(column)
            }
            let header = NSMenu()
            for (key, title) in [("size", "Size"), ("date", "Modification date")] {
                let item = NSMenuItem(title: title, action: #selector(toggleColumn(_:)), keyEquivalent: ""); item.target = self; item.representedObject = key; header.addItem(item)
            }
            header.delegate = self; table.headerView?.menu = header
            let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
            for (title, action, icon) in [("Check selected files", #selector(check), MenuIcon.add), ("Uncheck selected files", #selector(uncheck), .revert), ("Diff", #selector(preview), .compare), ("View revision in alternative editor", #selector(editor), .editor), ("Open", #selector(open), .open), ("Open With…", #selector(openWith), .open), ("Explore to", #selector(reveal), .explore), ("Save As…", #selector(saveAs), .saveAs), ("Export…", #selector(export), .export), ("Delete", #selector(deleteItem), .remove)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon.contextImage(); menu.addItem(item)
            }
            menu.addItem(.separator())
            let clipboard = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: ""); clipboard.image = MenuIcon.copy.contextImage()
            let submenu = NSMenu(); submenu.autoenablesItems = false
            for (key, title) in [("full", "Full paths"), ("relative", "Relative paths"), ("names", "File/folder names"), ("ext", "Extensions"), ("all", "All visible columns")] {
                let item = NSMenuItem(title: title, action: #selector(copyItem(_:)), keyEquivalent: ""); item.target = self; item.representedObject = key; item.image = MenuIcon.copy.contextImage(); submenu.addItem(item)
            }
            clipboard.submenu = submenu; menu.addItem(clipboard)
            table.menu = menu; scroll.documentView = table; refresh(); return scroll
        }
        func refresh() {
            updating = true; table.reloadData()
            table.selectRowIndexes(IndexSet(rows.enumerated().compactMap { model.highlighted.contains($0.element.path) ? $0.offset : nil }), byExtendingSelection: false)
            updating = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
            guard rows.indices.contains(index) else { return nil }; let row = rows[index]
            if tableColumn?.identifier.rawValue == "check" {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow(_:))); button.identifier = NSUserInterfaceItemIdentifier(row.path)
                button.state = model.checked.contains(row.path) ? .on : .off; button.isEnabled = !model.busy && !model.confirmingQuit; return button
            }
            let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingMiddle
            switch tableColumn?.identifier.rawValue {
            case "ext": field.stringValue = StatusListClipboard.fileExtension(row.path)
            case "size": field.stringValue = row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
            case "date": field.stringValue = row.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "–"
            default:
                field.stringValue = row.path; field.textColor = NSColor(row.state.textColor)
                let cell = NSTableCellView(); cell.imageView = NSImageView(); cell.imageView?.image = row.state.icon.image(); cell.textField = field
                if let image = cell.imageView { image.frame = NSRect(x: 2, y: 3, width: 16, height: 16); cell.addSubview(image) }
                field.frame = NSRect(x: 23, y: 2, width: max(0, (tableColumn?.width ?? 440) - 26), height: 18); field.autoresizingMask = [.width]; cell.addSubview(field); cell.toolTip = row.path; return cell
            }
            return field
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating else { return }; model.highlighted = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].path : nil })
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { refresh() }
        @objc func toggleRow(_ sender: NSButton) { guard !model.busy, !model.confirmingQuit, let path = sender.identifier?.rawValue, model.entries.contains(where: { $0.path == path }) else { return }; if sender.state == .on { model.checked.insert(path) } else { model.checked.remove(path) } }
        var selectedRows: [AddDialogEntry] { rows.filter { model.highlighted.contains($0.path) } }
        var selectedIsFile: Bool {
            guard selectedRows.count == 1, let row = selectedRows.first,
                  let type = try? FileManager.default.attributesOfItem(atPath: model.repository.root.appendingPathComponent(row.path).path)[.type] as? FileAttributeType else { return false }
            return type != .typeDirectory
        }
        var canAct: Bool { !model.busy && !model.confirmingQuit && !selectedRows.isEmpty }
        @objc func check() { guard canAct else { return }; model.checked.formUnion(selectedRows.map(\.path)); refresh() }
        @objc func uncheck() { guard canAct else { return }; model.checked.subtract(selectedRows.map(\.path)); refresh() }
        func toggleSelectedChecks() {
            guard canAct else { return }
            if selectedRows.allSatisfy({ model.checked.contains($0.path) }) { uncheck() } else { check() }
        }
        @objc func preview() { guard canAct, selectedRows.count == 1, let row = selectedRows.first else { return }; model.onPreview(row.path) }
        func openSelected(_ action: AddFileOpenAction) { guard canAct, selectedIsFile, let row = selectedRows.first else { return }; model.onOpen(row.path, action) }
        @objc func open() { openSelected(.open) }
        @objc func openWith() { openSelected(.openWith) }
        @objc func editor() { openSelected(.editor) }
        @objc func reveal() { guard canAct, selectedRows.count == 1 else { return }; NSWorkspace.shared.activateFileViewerSelecting(selectedRows.map { model.repository.root.appendingPathComponent($0.path) }) }
        func cellText(_ row: AddDialogEntry, key: String) -> String {
            switch key {
            case "ext": return StatusListClipboard.fileExtension(row.path)
            case "size": return row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "–"
            case "date": return row.modified.map { $0.formatted(date: .numeric, time: .shortened) } ?? "–"
            default: return row.path
            }
        }
        func clipboardText(_ kind: String) -> String {
            guard canAct else { return "" }
            let columns = table.tableColumns.filter { !$0.isHidden && $0.identifier.rawValue != "check" }
            let heading = kind == "all" && columns.count > 1 ? columns.map(\.title).joined(separator: "\t") + "\n" : ""
            return heading + selectedRows.map { row in
                switch kind {
                case "full": return model.repository.root.appendingPathComponent(row.path).path
                case "names": return (row.path as NSString).lastPathComponent
                case "ext": return cellText(row, key: "ext")
                case "all": return columns.map { cellText(row, key: $0.identifier.rawValue) }.joined(separator: "\t")
                default: return row.path
                }
            }.joined(separator: "\n") + "\n"
        }
        func copyText(_ kind: String) {
            let text = clipboardText(kind); guard !text.isEmpty else { return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
        @objc func copyItem(_ sender: NSMenuItem) { guard let kind = sender.representedObject as? String else { return }; copyText(kind) }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? String, let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key)) else { return }
            column.isHidden.toggle(); UserDefaults.standard.set(!column.isHidden, forKey: key == "size" ? "Add.ShowSize" : "Add.ShowModifiedDate")
        }
        var canSave: Bool { canAct && selectedIsFile && selectedRows.first?.state != .deleted }
        var canExport: Bool { canAct && selectedRows.contains { $0.state != .deleted } }
        @objc func saveAs() { guard canSave, let row = selectedRows.first else { return }; model.onSave(row.path) }
        @objc func export() { guard canExport else { return }; model.onExport(selectedRows.filter { $0.state != .deleted }.map(\.path)) }
        var canDelete: Bool { canAct && selectedRows.contains { $0.status.canDeleteFromStatusList } }
        func deleteSelected(permanently: Bool, keyboard: Bool = false) {
            guard canDelete, !keyboard || selectedRows.contains(where: { $0.status.canDeleteWithKeyboard }) else { return }
            model.onDelete(selectedRows.map(\.status), permanently)
        }
        @objc func deleteItem() { deleteSelected(permanently: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
        var canIgnore: Bool { canAct && selectedRows.contains { $0.state == .untracked || $0.state == .deleted } }
        func ignoreSelected(mask: Bool = false, folder: Bool = false) {
            guard canIgnore else { return }
            var paths = selectedRows.map(\.path)
            if folder {
                guard paths.count == 1 else { return }
                let parent = (paths[0] as NSString).deletingLastPathComponent
                guard !parent.isEmpty, parent != "." else { return }; paths = [parent]
            } else if mask && !paths.contains(where: { !StatusListClipboard.fileExtension($0).isEmpty }) { return }
            model.onIgnore(paths, mask)
        }
        @objc func ignoreNames() { ignoreSelected() }
        @objc func ignoreExtensions() { ignoreSelected(mask: true) }
        @objc func ignoreFolder() { ignoreSelected(folder: true) }
        func updateIgnoreMenu(_ menu: NSMenu) {
            for item in menu.items where item.representedObject as? String == "Add.Ignore" { menu.removeItem(item) }
            guard canIgnore else { return }
            let paths = selectedRows.map(\.path), extensions = paths.map { StatusListClipboard.fileExtension($0) }
            let same = Set(extensions.map { $0.lowercased() }).count == 1
            let title = paths.count == 1 ? (paths[0] as NSString).lastPathComponent : "Ignore \(paths.count) items"
            func item(_ title: String, _ action: Selector? = nil) -> NSMenuItem {
                let result = NSMenuItem(title: title, action: action, keyEquivalent: ""); result.target = self
                result.image = MenuIcon.ignore.contextImage(); result.representedObject = "Add.Ignore"; return result
            }
            let index = menu.items.firstIndex(where: \.isSeparatorItem) ?? menu.items.count
            if same {
                let root = item("Ignore"); let submenu = NSMenu(); submenu.autoenablesItems = false
                submenu.addItem(item(title, #selector(ignoreNames)))
                if let ext = extensions.first, !ext.isEmpty { submenu.addItem(item("*" + ext, #selector(ignoreExtensions))) }
                if paths.count == 1 {
                    let parent = (paths[0] as NSString).deletingLastPathComponent
                    if !parent.isEmpty, parent != "." { submenu.addItem(item(parent, #selector(ignoreFolder))) }
                }
                root.submenu = submenu; menu.insertItem(root, at: index)
            } else {
                menu.insertItem(item(title, #selector(ignoreNames)), at: index)
                if extensions.contains(where: { !$0.isEmpty }) { menu.insertItem(item("Ignore \(paths.count) items by extension", #selector(ignoreExtensions)), at: index + 1) }
            }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === table.menu {
                updateIgnoreMenu(menu)
                for item in menu.items where !item.isSeparatorItem {
                    let icon: MenuIcon = item.representedObject as? String == "Add.Ignore" ? .ignore : item.action == #selector(saveAs) ? .saveAs : item.action == #selector(export) ? .export : item.action == #selector(deleteItem) ? .remove : item.action == #selector(check) ? .add : item.action == #selector(uncheck) ? .revert : item.action == #selector(preview) ? .compare : item.action == #selector(editor) ? .editor : item.action == #selector(open) || item.action == #selector(openWith) ? .open : item.submenu != nil ? .copy : .explore
                    item.image = icon.contextImage()
                    let single = [#selector(preview), #selector(editor), #selector(open), #selector(openWith), #selector(reveal)].contains(item.action)
                    let opensFile = [#selector(editor), #selector(open), #selector(openWith)].contains(item.action)
                    item.isHidden = opensFile && !selectedIsFile || item.action == #selector(deleteItem) && !canDelete || item.action == #selector(saveAs) && !canSave || item.action == #selector(export) && !canExport
                    item.isEnabled = canAct && (!single || selectedRows.count == 1) && (!opensFile || selectedIsFile) && (item.action != #selector(deleteItem) || canDelete) && (item.action != #selector(saveAs) || canSave) && (item.action != #selector(export) || canExport)
                    for child in item.submenu?.items ?? [] { child.image = (item.representedObject as? String == "Add.Ignore" ? MenuIcon.ignore : .copy).contextImage(); child.isEnabled = item.isEnabled }
                }
            } else {
                for item in menu.items { if let key = item.representedObject as? String { item.state = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.isHidden == false ? .on : .off } }
            }
        }
    }
}
