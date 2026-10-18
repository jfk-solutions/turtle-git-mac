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
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.compareDefault(_:))
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
        coordinator.table?.owner = nil; coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.target = nil; coordinator.table?.doubleAction = nil
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
        var available: Bool { !retired && model.revisionMenuAvailable && table?.window != nil && table?.window?.attachedSheet == nil }
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
        func selectionShouldChange(in tableView: NSTableView) -> Bool { synchronizing || available && !model.revisionFiles.busy }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !synchronizing, available, !model.revisionFiles.busy, let table else { return }
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            if selected != model.selection { menuGeneration = UUID(); model.selection = selected }
        }
        @discardableResult func performDefaultComparison(alternate: Bool = false) -> Bool {
            guard available, model.columnPreferences.bool(forKey: "DiffByDoubleClickInLog"),
                  model.canPerformRevisionMenu(.compare, ids: model.selection),
                  let claim = model.captureRevisionMenu(model.selection), claim() else { return false }
            model.performRevisionMenu(.compare, ids: model.selection, alternate: alternate); return true
        }
        @objc func compareDefault(_ sender: Any?) { guard (table?.clickedRow ?? -1) >= 0 else { return }; _ = performDefaultComparison(alternate: NSEvent.modifierFlags.contains(.shift)) }
        func menu(ids: Set<String>, alternate: Bool) -> NSMenu {
            menuGeneration = UUID(); let generation = menuGeneration
            let menu = NSMenu(); menu.autoenablesItems = false
            guard available, let claim = model.captureRevisionMenu(ids) else { return menu }
            let selected = model.revisionMenuRows(ids), one = selected.count == 1
            let policy = model.revisionContextPolicy
            @discardableResult func add(_ title: String, icon: MenuIcon, to menu: NSMenu, allowed: @escaping @MainActor () -> Bool, action: @escaping @MainActor () -> Void) -> NSMenuItem {
                let target = RebaseReplayMenuTarget(allowed: { [weak self] in self?.available == true && self?.menuGeneration == generation && allowed() && claim() }, action: { [weak self] in self?.menuGeneration = UUID(); action() })
                let item = NSMenuItem(title: title, action: #selector(RebaseReplayMenuTarget.invoke(_:)), keyEquivalent: "")
                item.target = target; item.representedObject = target; item.image = icon.contextImage(defaults: model.columnPreferences)
                item.isEnabled = available && allowed(); menu.addItem(item); return item
            }
            for action in model.revisionActionChoices(ids) {
                add(action == .skip ? "Skip" : action.rawValue.capitalized, icon: action.icon, to: menu,
                    allowed: { [weak model] in model?.revisionActionChoices(ids).contains(action) == true },
                    action: { [weak model] in model?.setAction(action, ids: ids) })
            }
            func command(_ command: RebaseRevisionCommand, to menu: NSMenu, title: String? = nil, parent: Int? = nil, mode: LogRevisionDiffMode = .firstParent) {
                guard policy.contains(command.sourceCommand(single: one)) else { return }
                let item = add(title ?? (command == .compare && ids.count == 2 ? "Compare revisions" : command.rawValue), icon: command.icon, to: menu,
                    allowed: { [weak model] in model?.canPerformRevisionMenu(command, ids: ids) == true },
                    action: { [weak model] in model?.performRevisionMenu(command, ids: ids, alternate: alternate, parent: parent, diffMode: mode) })
                if command == .compare, model.columnPreferences.bool(forKey: "DiffByDoubleClickInLog"), parent == nil || parent == 1 {
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
                }
            }
            func separator() { if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) } }
            separator()
            if one { command(.workingTree, to: menu) }
            if one, let revision = selected.first?.commit, revision.parents.count > 1 {
                let unified = NSMenuItem(title: "Unified diff with", action: nil, keyEquivalent: "")
                unified.image = MenuIcon.unifiedDiff.contextImage(defaults: model.columnPreferences)
                let choices = NSMenu(); choices.autoenablesItems = false
                for (title, mode) in [("All Parents", LogRevisionDiffMode.allParents), ("Only Merged Files", .combined), ("Show extra changes after merge", .extraMergeChanges)] {
                    command(.unified, to: choices, title: title, mode: mode)
                }
                for parent in model.revisionMenuLog.parentChoices(for: revision) { command(.unified, to: choices, title: parent.title, mode: .parent(parent.number)) }
                unified.submenu = choices; unified.isEnabled = model.canPerformRevisionMenu(.unified, ids: ids)
                if policy.contains(.unifiedDiff) { menu.addItem(unified) }
                let compare = NSMenuItem(title: "Compare with previous revision", action: nil, keyEquivalent: "")
                compare.image = MenuIcon.compare.contextImage(defaults: model.columnPreferences)
                let parents = NSMenu(); parents.autoenablesItems = false
                for parent in model.revisionMenuLog.parentChoices(for: revision) { command(.compare, to: parents, title: parent.title, parent: parent.number) }
                compare.submenu = parents; compare.isEnabled = model.canPerformRevisionMenu(.compare, ids: ids)
                if model.columnPreferences.bool(forKey: "DiffByDoubleClickInLog") { compare.attributedTitle = NSAttributedString(string: compare.title, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]) }
                if policy.contains(.comparePrevious) { menu.addItem(compare) }
            } else {
                if !one || selected.first?.commit.parents.count == 1 { command(.unified, to: menu) }
                if !one || (selected.first?.commit.parents.count ?? 0) > 0 { command(.compare, to: menu) }
            }
            let groups: [[RebaseRevisionCommand]] = [[.log, .browse, .branch, .tag, .push], [.notes, .patch]]
            for group in groups {
                separator(); for value in group { command(value, to: menu) }
            }
            separator()
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
    var presentContextMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in menu.popUp(positioning: nil, at: point, in: view) }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let owner, owner.available else { return nil }
        let point = convert(event.locationInWindow, from: nil), row = self.row(at: point)
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return owner.menu(ids: owner.model.selection, alternate: event.modifierFlags.contains(.shift))
    }
    @discardableResult func showSelectionMenu() -> Bool {
        guard let owner, owner.available, let row = selectedRowIndexes.first, row < numberOfRows else { return false }
        let menu = owner.menu(ids: owner.model.selection, alternate: NSEvent.modifierFlags.contains(.shift))
        guard !menu.items.isEmpty else { return false }
        scrollRowToVisible(row)
        let visible = rect(ofRow: row).intersection(visibleRect)
        guard !visible.isEmpty else { return false }
        presentContextMenu(menu, NSPoint(x: visible.minX + 16, y: visible.midY), self); return true
    }
    override func accessibilityPerformShowMenu() -> Bool { showSelectionMenu() }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 121, flags == .shift, showSelectionMenu() { return }
        if [36, 76].contains(event.keyCode), flags.isEmpty, owner?.performDefaultComparison() == true { return }
        super.keyDown(with: event)
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
