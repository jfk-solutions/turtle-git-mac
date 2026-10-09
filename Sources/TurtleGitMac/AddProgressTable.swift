import AppKit
import SwiftUI
import TurtleGitCore

struct AddProgressTable: NSViewRepresentable {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: AddProgressWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.table.reloadData() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: AddProgressWindowModel
        let table = NativeWatermarkTable(icon: .addBackdrop)
        init(model: AddProgressWindowModel) { self.model = model }
        func make() -> NSScrollView {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
            table.dataSource = self; table.delegate = self; table.rowHeight = 22
            table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id, title, width) in [("action", "Action", 120.0), ("path", "Path", 560.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
            }
            scroll.documentView = table; return scroll
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.paths.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard model.paths.indices.contains(row) else { return nil }
            let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingMiddle
            switch tableColumn?.identifier.rawValue {
            case "action":
                field.stringValue = model.busy ? "In progress" : model.success ? "Added" : model.cancelled ? "Cancelled" : "Failed"
                field.textColor = model.success ? NSColor(FileState.added.textColor) : model.busy || model.cancelled ? .labelColor : NSColor(FileState.conflicted.textColor)
                let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 120, height: 22)); let image = NSImageView(frame: NSRect(x: 2, y: 3, width: 16, height: 16)); image.image = MenuIcon.add.image(); cell.imageView = image; cell.textField = field
                cell.addSubview(image); field.frame = NSRect(x: 23, y: 2, width: max(0, (tableColumn?.width ?? 120) - 26), height: 18); field.autoresizingMask = [.width]; cell.addSubview(field); return cell
            default: field.stringValue = model.paths[row]; field.toolTip = model.paths[row]
            }
            return field
        }
    }
}
