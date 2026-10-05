import AppKit
import SwiftUI
import TurtleGitCore

/// Observe the public AppKit table underlying a SwiftUI Table without replacing
/// its selection, accessibility, checkbox or context-menu implementations.
struct CommitFileInteraction: NSViewRepresentable {
    let rows: [StatusListRow]
    @Binding var focusedPath: String?
    let enabled: Bool
    let delete: ([StatusEntry], StatusEntry, Bool) -> Void
    let copy: ([StatusEntry], Bool) -> Void
    let copyColumn: ([StatusEntry], StatusListColumn) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.rows = rows; view.focusedPath = $focusedPath
        view.enabled = enabled; view.delete = delete; view.copy = copy; view.copyColumn = copyColumn
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var rows: [StatusListRow] = []
        var focusedPath: Binding<String?>?
        private var contextColumn: StatusListColumn?
        private var contextEntries: [StatusEntry] = []
        var enabled = false
        var delete: ([StatusEntry], StatusEntry, Bool) -> Void = { _, _, _ in }
        var copy: ([StatusEntry], Bool) -> Void = { _, _ in }
        var copyColumn: ([StatusEntry], StatusListColumn) -> Void = { _, _ in }
        private var monitor: Any?
        private var menuObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let self else { return event }
                return self.observe(event)
            }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                self?.prepareClipboardMenu(menu)
            }
        }
        func stopObserving() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
            menuObserver = nil
        }
        deinit { stopObserving() }
        private func prepareClipboardMenu(_ menu: NSMenu) {
            guard window?.isKeyWindow == true, let column = contextColumn, !contextEntries.isEmpty,
                  let submenu = menu.items.first(where: { $0.title == "Copy to Clipboard" })?.submenu else { return }
            let identifier = NSUserInterfaceItemIdentifier("TurtleGit.CopyColumn")
            if let previous = submenu.items.first(where: { $0.identifier == identifier }) { submenu.removeItem(previous) }
            let item = NSMenuItem(title: "column '\(column.rawValue)'", action: #selector(copyCurrentColumn(_:)), keyEquivalent: "")
            item.identifier = identifier; item.target = self
            if let image = MenuIcon.copy.image()?.copy() as? NSImage { image.size = NSSize(width: 16, height: 16); item.image = image }
            submenu.addItem(item)
        }
        @objc private func copyCurrentColumn(_ sender: NSMenuItem) {
            guard let column = contextColumn, !contextEntries.isEmpty else { return }
            copyColumn(contextEntries, column)
        }
        private func table(at point: NSPoint, in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, contains(table),
               table.visibleRect.contains(table.convert(point, from: nil)) { return table }
            for child in view.subviews {
                if let table = table(at: point, in: child) { return table }
            }
            return nil
        }
        private func contains(_ table: NSTableView) -> Bool {
            let area = convert(bounds, to: nil)
            return area.intersects(table.convert(table.visibleRect, to: nil))
        }
        private func observe(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window else { return event }
            if event.type != .keyDown {
                contextColumn = nil; contextEntries = []
                guard let content = window.contentView,
                      let table = table(at: event.locationInWindow, in: content) else { return event }
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                if event.type == .rightMouseDown && rows.indices.contains(row), rows[row].entry != nil {
                    let column = table.column(at: table.convert(event.locationInWindow, from: nil))
                    contextColumn = StatusListColumn.nativeColumn(column)
                    let rows = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: max(0, row))
                    contextEntries = StatusListGroups.files(at: rows, in: self.rows)
                }
                guard rows.indices.contains(row) else { return event }
                guard let entry = rows[row].entry else { return event.type == .leftMouseDown ? nil : event }
                // Right-clicking a selected row preserves the selection mark;
                // Shift extends the range from the existing mark.
                let preserve = event.type == .rightMouseDown && table.selectedRowIndexes.contains(row)
                    || event.modifierFlags.contains(.shift)
                if !preserve || focusedPath?.wrappedValue == nil { focusedPath?.wrappedValue = entry.path }
                return event
            }
            guard let table = window.firstResponder as? NSTableView, contains(table) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            contextColumn = nil; contextEntries = []
            // Headers are presentation rows. Skip them for ordinary navigation,
            // retaining AppKit's range selection and modifier behavior.
            if flags.isEmpty, rows.contains(where: { $0.group != nil }), [125, 126, 115, 119].contains(event.keyCode) {
                let forward = event.keyCode == 125 || event.keyCode == 115
                let endpoint = event.keyCode == 115 || event.keyCode == 119
                let current = endpoint || table.selectedRow < 0 ? nil : Optional(table.selectedRow)
                guard let target = StatusListGroups.nextFileRow(after: current, forward: forward, in: rows), let entry = rows[target].entry else { return nil }
                table.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
                table.scrollRowToVisible(target); focusedPath?.wrappedValue = entry.path
                return nil
            }
            let commandCopy = event.keyCode == 8 && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
            let controlInsert = event.keyCode == 114 && flags.contains(.control)
            if commandCopy || controlInsert {
                let selected = StatusListGroups.files(at: table.selectedRowIndexes, in: rows)
                guard !selected.isEmpty else { return event }
                copy(selected, flags.contains(.shift)); return nil
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                guard enabled else { return event }
                let selected = StatusListGroups.files(at: table.selectedRowIndexes, in: rows)
                let mark = rows.compactMap(\.entry).first { $0.path == focusedPath?.wrappedValue } ?? (selected.count == 1 ? selected.first : nil)
                guard !selected.isEmpty, let mark, mark.canDeleteWithKeyboard else { return event }
                delete(selected, mark, flags.contains(.shift))
                return nil
            }
            // AppKit applies arrow/Home/End selection after the local monitor.
            // A non-range keyboard move starts a new selection mark.
            if [123, 124, 125, 126, 115, 119].contains(event.keyCode), !flags.contains(.shift) {
                DispatchQueue.main.async { [weak self, weak table] in
                    guard let self, let table, table.selectedRowIndexes.count == 1,
                          self.rows.indices.contains(table.selectedRow), let entry = self.rows[table.selectedRow].entry else { return }
                    self.focusedPath?.wrappedValue = entry.path
                }
            }
            return event
        }
    }
}
