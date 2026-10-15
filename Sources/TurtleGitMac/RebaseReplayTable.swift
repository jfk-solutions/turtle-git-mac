// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Native report cells keep their values and identifiers when columns are
/// revealed or moved, independent of SwiftUI's hosted-cell virtualization.
struct RebaseReplayTable: NSViewRepresentable {
    @ObservedObject var model: RebaseWindowModel
    let dates: HistoryDateSettings
    @AppStorage("LogFontForLogCtrl") private var useLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    private var configuredFont: NSFont? { useLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize) : nil }
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = RebaseReplayNativeTable(); table.owner = context.coordinator
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Rebase commits")
        let widths: [CGFloat] = [90, 40, 95, 420, 130, 150, 200, 130, 200, 150, 110, 100]
        for (index, name) in RebaseColumnLayout.Probe.names.enumerated() {
            let column = NSTableColumn(identifier: .init(name)); column.title = name; column.width = widths[index]
            column.minWidth = index == 3 ? 100 : 30; column.maxWidth = 10000; table.addTableColumn(column)
        }
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.borderType = .bezelBorder
        context.coordinator.table = table; context.coordinator.update(model: model, dates: dates, font: configuredFont)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update(model: model, dates: dates, font: configuredFont) }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.retired = true; coordinator.menuGeneration = UUID()
        coordinator.table?.owner = nil; coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        struct Row: Equatable {
            let id: String, values: [String], action: RebaseAction, progress: RebaseEntryProgress
        }
        private(set) var model: RebaseWindowModel
        weak var table: RebaseReplayNativeTable?
        private var rows: [Row] = []
        private var font: NSFont?
        private var synchronizing = false
        var retired = false, menuGeneration = UUID()
        init(model: RebaseWindowModel) { self.model = model }
        var available: Bool { !retired && !model.retired && !model.busy && table?.window != nil && table?.window?.attachedSheet == nil }
        func update(model: RebaseWindowModel, dates: HistoryDateSettings, font: NSFont?) {
            guard !retired, let table else { return }; self.model = model
            let next = model.entries.map { entry in
                Row(id: entry.id, values: [entry.action == .skip ? "Skip" : entry.action.rawValue.capitalized,
                    String(model.entryNumber(entry)), entry.commit.hash, entry.commit.logLine(fullMessage: model.fullCommitMessageOnLogLine),
                    entry.commit.author, dates.format(entry.commit.date), entry.commit.email, entry.commit.committer,
                    entry.commit.committerEmail, dates.format(entry.commit.committerDate), model.issueColumnValues[entry.commit.hash] ?? "",
                    model.svnColumnValues[entry.commit.hash] ?? ""], action: entry.action, progress: entry.progress)
            }
            let changed = rows != next || self.font != font
            self.font = font; rows = next; synchronizing = true
            if changed {
                menuGeneration = UUID()
                let face = font ?? .systemFont(ofSize: NSFont.systemFontSize)
                table.rowHeight = max(24, ceil(face.ascender - face.descender + face.leading) + 6)
                table.reloadData()
            }
            let selected = IndexSet(rows.indices.filter { model.selection.contains(rows[$0].id) })
            if selected != table.selectedRowIndexes { menuGeneration = UUID(); table.selectRowIndexes(selected, byExtendingSelection: false) }
            synchronizing = false
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let tableColumn,
                  let column = RebaseColumnLayout.Probe.names.firstIndex(of: tableColumn.identifier.rawValue) else { return nil }
            let key = NSUserInterfaceItemIdentifier("RebaseCell." + tableColumn.identifier.rawValue)
            let cell = tableView.makeView(withIdentifier: key, owner: nil) as? RebaseReplayNativeCell ?? RebaseReplayNativeCell(action: column == 0)
            cell.identifier = key; let value = rows[row]
            var face = font ?? (column == 2 ? NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular) : NSFont.systemFont(ofSize: NSFont.systemFontSize))
            if value.progress == .current { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
            cell.configure(value.values[column], font: face, secondary: value.action == .skip || value.progress == .completed,
                           icon: column == 0 ? value.action.icon.image() : nil, rightAligned: column == 1,
                           progress: value.progress == .completed ? "Completed" : value.progress == .current ? "Current" : "Pending", column: tableColumn.title)
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard rows.indices.contains(row) else { return nil }
            let view = RebaseReplayNativeRow(); view.action = rows[row].action; return view
        }
        func selectionShouldChange(in tableView: NSTableView) -> Bool { synchronizing || available }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, available, let table else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if selected != model.selection { menuGeneration = UUID(); model.selection = selected }
        }
        func menu(ids: Set<String>, alternate: Bool) -> NSMenu {
            menuGeneration = UUID(); let generation = menuGeneration
            let menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, icon: MenuIcon, to menu: NSMenu, allowed: @escaping @MainActor () -> Bool, action: @escaping @MainActor () -> Void) {
                let target = RebaseReplayMenuTarget(allowed: { [weak self] in self?.available == true && self?.menuGeneration == generation && allowed() }, action: { [weak self] in self?.menuGeneration = UUID(); action() })
                let item = NSMenuItem(title: title, action: #selector(RebaseReplayMenuTarget.invoke(_:)), keyEquivalent: "")
                item.target = target; item.representedObject = target; item.image = icon.contextImage(defaults: model.columnPreferences)
                item.isEnabled = available && allowed(); menu.addItem(item)
            }
            for action in RebaseAction.allCases {
                add(action == .skip ? "Skip" : action.rawValue.capitalized, icon: action.icon, to: menu,
                    allowed: { [weak model] in guard let model else { return false }; return !ids.isEmpty && model.editable && !(model.options.preserveMerges && action == .squash && model.entries.contains { ids.contains($0.id) && $0.commit.parents.count != 1 }) },
                    action: { [weak model] in model?.setAction(action, ids: ids) })
            }
            guard !model.revisionMenuRows(ids).isEmpty else { return menu }
            let groups: [[RebaseRevisionCommand]] = [[.workingTree, .compare, .unified], [.log, .browse, .branch, .tag, .push], [.notes, .patch]]
            func command(_ command: RebaseRevisionCommand, to menu: NSMenu) {
                add(command == .compare && ids.count == 2 ? "Compare revisions" : command.rawValue, icon: command.icon, to: menu,
                    allowed: { [weak model] in model?.canPerformRevisionMenu(command, ids: ids) == true },
                    action: { [weak model] in model?.performRevisionMenu(command, ids: ids, alternate: alternate) })
            }
            for group in groups { menu.addItem(.separator()); for value in group { command(value, to: menu) } }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            copy.image = MenuIcon.copy.contextImage(defaults: model.columnPreferences); copy.isEnabled = model.revisionMenuAvailable
            let choices = NSMenu(); choices.autoenablesItems = false
            for value in [RebaseRevisionCommand.details, .detailsWithoutPaths, .hashes, .authors, .authorNames, .authorEmails, .subjects, .messages] { command(value, to: choices) }
            copy.submenu = choices; menu.addItem(copy)
            return menu
        }
    }
}

@MainActor final class RebaseReplayNativeTable: NSTableView {
    weak var owner: RebaseReplayTable.Coordinator?
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, owner.available else { return nil }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return owner.menu(ids: owner.model.selection, alternate: event.modifierFlags.contains(.shift))
    }
}
@MainActor final class RebaseReplayNativeCell: NSTableCellView {
    private var secondary = false
    init(action: Bool) {
        super.init(frame: .zero)
        let field = NSTextField(labelWithString: ""); field.lineBreakMode = .byTruncatingTail; field.maximumNumberOfLines = 1
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField = field; let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 5
        if action { let image = NSImageView(); image.imageScaling = .scaleProportionallyDown; imageView = image; row.addArrangedSubview(image); image.widthAnchor.constraint(equalToConstant: 16).isActive = true; image.heightAnchor.constraint(equalToConstant: 16).isActive = true }
        row.addArrangedSubview(field); addSubview(row); row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), row.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColor() } }
    private func updateColor() { textField?.textColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : secondary ? .secondaryLabelColor : .labelColor }
    func configure(_ value: String, font: NSFont, secondary: Bool, icon: NSImage?, rightAligned: Bool, progress: String, column: String) {
        textField?.stringValue = value; textField?.font = font; textField?.alignment = rightAligned ? .right : .left
        imageView?.image = icon; self.secondary = secondary; toolTip = value; updateColor()
        textField?.setAccessibilityLabel(column); textField?.setAccessibilityHelp(progress)
    }
}
@MainActor private final class RebaseReplayNativeRow: NSTableRowView {
    var action: RebaseAction = .pick
    override func drawBackground(in dirtyRect: NSRect) {
        if !isSelected, action == .edit || action == .squash {
            (action == .edit ? NSColor.systemYellow : .systemGray).withAlphaComponent(0.16).setFill(); bounds.fill()
        } else { super.drawBackground(in: dirtyRect) }
    }
}
@MainActor private final class RebaseReplayMenuTarget: NSObject {
    private let allowed: () -> Bool, action: () -> Void
    private var used = false
    init(allowed: @escaping () -> Bool, action: @escaping () -> Void) { self.allowed = allowed; self.action = action }
    @objc func invoke(_ sender: Any?) { guard !used, allowed() else { return }; used = true; action() }
}
