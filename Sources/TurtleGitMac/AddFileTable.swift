import AppKit
import SwiftUI
import TurtleGitCore

struct AddFileTable: NSViewRepresentable {
    @ObservedObject var model: AddWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.refresh() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        let model: AddWindowModel
        let table = NSTableView()
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
            for (title, action, icon) in [("Check selected files", #selector(check), MenuIcon.add), ("Uncheck selected files", #selector(uncheck), .revert), ("Diff", #selector(preview), .compare), ("Explore to", #selector(reveal), .explore)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon.contextImage(); menu.addItem(item)
            }
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
            case "ext": field.stringValue = (row.path as NSString).pathExtension
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
        @objc func check() { model.checked.formUnion(model.highlighted); refresh() }
        @objc func uncheck() { model.checked.subtract(model.highlighted); refresh() }
        @objc func preview() { guard !model.busy, !model.confirmingQuit else { return }; if table.clickedRow >= 0 && rows.indices.contains(table.clickedRow) { model.onPreview(rows[table.clickedRow].path) } else if model.highlighted.count == 1, let path = model.highlighted.first { model.onPreview(path) } }
        @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting(model.highlighted.map { model.repository.root.appendingPathComponent($0) }) }
        @objc func toggleColumn(_ sender: NSMenuItem) {
            guard let key = sender.representedObject as? String, let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key)) else { return }
            column.isHidden.toggle(); UserDefaults.standard.set(!column.isHidden, forKey: key == "size" ? "Add.ShowSize" : "Add.ShowModifiedDate")
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            if menu === table.menu {
                for item in menu.items {
                    let icon: MenuIcon = item.action == #selector(check) ? .add : item.action == #selector(uncheck) ? .revert : item.action == #selector(preview) ? .compare : .explore
                    item.image = icon.contextImage()
                    item.isEnabled = !model.busy && !model.confirmingQuit && !model.highlighted.isEmpty && (item.action != #selector(preview) || model.highlighted.count == 1)
                }
            } else {
                for item in menu.items { if let key = item.representedObject as? String { item.state = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(key))?.isHidden == false ? .on : .off } }
            }
        }
    }
}
