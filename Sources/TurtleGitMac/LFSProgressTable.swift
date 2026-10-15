// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

struct LFSProgressRow: Identifiable {
    enum Kind: Equatable { case command, file, error, finishedSuccess, finishedFailure }
    let id: String
    let action: String
    let text: String
    let kind: Kind
    @MainActor func color(preferences: UserDefaults) -> NSColor {
        switch kind {
        case .file: return .textColor
        case .error: return StatusTextPalette.text(.conflict, preferences: preferences)
        case .finishedSuccess: return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .textColor : SubmoduleProgressTextView.successColor
        case .finishedFailure: return SubmoduleProgressTextView.color(error: true)
        case .command: return ProgressNotificationColor.command(preferences: preferences)
        }
    }
}

/// Preserve callback order without allowing delayed tasks to join a later batch.
final class LFSProgressMailbox: @unchecked Sendable {
    enum Event { case started(String), result(LFSFileResult) }
    private let lock = NSLock()
    private var events: [Event] = []
    func append(_ event: Event) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    func drain() -> [Event] { lock.lock(); defer { lock.unlock() }; let reply = events; events = []; return reply }
}

struct LFSCapturedMenu: View {
    @ObservedObject var model: LFSLocksWindowModel
    let target: LFSLocksWindowModel.MenuTarget
    var body: some View {
        TurtleGitContextMenu {
            ForEach(target.actions, id: \.self) { action in
                Button { Task { await model.setSelectionLocked(target, locked: action == .lock) } } label: {
                    CommandLabel(title: action.rawValue, icon: action == .lock ? .lock : .unlock)
                }.disabled(!model.accepts(target))
            }
            Menu {
                Button { model.copy(target, information: .fullPaths) } label: { CommandLabel(title: "Full paths", icon: .copy) }
                Button { model.copy(target, information: .relativePaths) } label: { CommandLabel(title: "Relative paths", icon: .copy) }
                Button { model.copy(target, information: .names) } label: { CommandLabel(title: "File/folder names", icon: .copy) }
                Button { model.copy(target, information: .all) } label: { CommandLabel(title: "Copy all information to clipboard", icon: .copy) }
            } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }.disabled(!model.accepts(target))
        }
    }
}

private final class LFSProgressNativeTable: NativeWatermarkTable {
    var copySelection: () -> Void = {}
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "c", event.modifierFlags.intersection([.command,.shift,.option,.control]) == .command { copySelection(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

struct LFSProgressTable: NSViewRepresentable {
    @ObservedObject var model: LFSLocksWindowModel
    @ObservedObject private var colors = StatusColorUpdates.shared
    @AppStorage("ShowListBackgroundImage") private var background = true
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ scroll: NSScrollView, context: Context) { _ = background; context.coordinator.refresh() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        private weak var model: LFSLocksWindowModel?
        private(set) var table: NativeWatermarkTable!
        private var displayedRows: [LFSProgressRow] = []
        private var renderedLocked: Bool?
        init(model: LFSLocksWindowModel) { self.model = model }
        func make() -> NSScrollView {
            let table = LFSProgressNativeTable(icon: model?.operationLocked == true ? .lockBackdrop : .unlockBackdrop, defaults: model?.presentationPreferences ?? .standard)
            self.table = table; table.copySelection = { [weak self] in self?.copySelection() }
            table.dataSource = self; table.delegate = self; table.rowHeight = 22
            table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityLabel("LFS progress notifications")
            for (id,title,width) in [("action","Action",130.0),("path","Path",580.0)] {
                let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = 70; table.addTableColumn(column)
            }
            table.menu = NSMenu(); table.menu?.delegate = self
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
            refresh(); return scroll
        }
        private var rows: [LFSProgressRow] { displayedRows }
        func refresh() {
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let follow = table.enclosingScrollView.map { $0.documentVisibleRect.maxY >= table.bounds.maxY - table.rowHeight * 2 } ?? true
            displayedRows = model?.notifications ?? []
            if let model, renderedLocked != model.operationLocked { renderedLocked = model.operationLocked; table.setWatermark(model.operationLocked ? .lockBackdrop : .unlockBackdrop) }
            table.reloadData(); table.selectRowIndexes(IndexSet(rows.enumerated().compactMap { selected.contains($0.element.id) ? $0.offset : nil }), byExtendingSelection: false)
            if follow, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
            table.needsDisplay = true
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let model else { return nil }
            let value = rows[row], field = NSTextField(labelWithString: column?.identifier.rawValue == "action" ? value.action : value.text)
            field.lineBreakMode = .byTruncatingMiddle; field.textColor = value.color(preferences: model.presentationPreferences)
            field.toolTip = value.text; return field
        }
        func copySelection() {
            guard let model else { return }
            let text = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].text : nil }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            model.copyProgress(text, generation: model.progressGeneration)
        }
        private final class CopyItem: NSMenuItem {
            private let invoke: () -> Void
            init(title: String, preferences: UserDefaults, invoke: @escaping () -> Void) {
                self.invoke = invoke; super.init(title: title, action: #selector(copyRows), keyEquivalent: "")
                target = self; image = MenuIcon.copy.contextImage(defaults: preferences)
            }
            required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
            @objc private func copyRows() { invoke() }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); menu.autoenablesItems = false
            guard let model, model.progressRowsAvailable(model.progressGeneration) else { return }
            let values = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].text : nil }
            guard !values.isEmpty else { return }
            let captured = values.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), generation = model.progressGeneration
            menu.addItem(CopyItem(title: "Copy to Clipboard", preferences: model.presentationPreferences) { [weak model] in model?.copyProgress(captured, generation: generation) })
        }
    }
}
