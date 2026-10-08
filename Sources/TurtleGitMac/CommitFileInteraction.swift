import AppKit
import SwiftUI
import TurtleGitCore

/// Observe the public AppKit table underlying a SwiftUI Table without replacing
/// its selection, accessibility, checkbox or context-menu implementations.
struct CommitFileInteraction: NSViewRepresentable {
    let rows: [StatusListRow]
    let visibleColumns: Set<StatusListColumn>
    var availableColumns: Set<StatusListColumn> = Set(StatusListColumn.allCases)
    let columnText: (StatusEntry, StatusListColumn) -> String
    let savedOrder: [StatusListColumn]
    let savedWidths: [StatusListColumn: Double]
    let saveLayout: ([StatusListColumn], [StatusListColumn: Double]) -> Bool
    let setColumnVisible: (StatusListColumn, Bool) -> Void
    let resetColumns: (@escaping () async -> Bool, @escaping () -> Void) -> Void
    @Binding var focusedPath: String?
    let enabled: Bool
    let delete: ([StatusEntry], StatusEntry, Bool) -> Void
    let copy: ([StatusEntry], Bool) -> Void
    let copyColumn: ([StatusEntry], StatusListColumn) -> Void
    let toggleCheck: ([StatusEntry], StatusEntry) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Probe, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? nsView.frame.height)
    }
    func updateNSView(_ view: Probe, context: Context) {
        view.columnText = columnText
        view.savedOrder = savedOrder; view.savedWidths = savedWidths; view.saveLayout = saveLayout
        view.availableColumns = availableColumns; view.visibleColumns = visibleColumns; view.setColumnVisible = setColumnVisible; view.resetColumns = resetColumns
        view.rows = rows; view.focusedPath = $focusedPath
        view.enabled = enabled; view.delete = delete; view.copy = copy; view.copyColumn = copyColumn; view.toggleCheck = toggleCheck
        DispatchQueue.main.async { [weak view] in view?.configureColumns() }
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var rows: [StatusListRow] = []
        var visibleColumns = Set(StatusListColumn.defaultColumns)
        var availableColumns = Set(StatusListColumn.allCases)
        var columnText: (StatusEntry, StatusListColumn) -> String = { _, _ in "" }
        var savedOrder = StatusListColumn.allCases
        var savedWidths: [StatusListColumn: Double] = [:]
        var saveLayout: ([StatusListColumn], [StatusListColumn: Double]) -> Bool = { _, _ in false }
        var setColumnVisible: (StatusListColumn, Bool) -> Void = { _, _ in }
        var resetColumns: (@escaping () async -> Bool, @escaping () -> Void) -> Void = { _, _ in }
        var confirmResetColumns: (NSWindow) async -> Bool = { window in
            let alert = NSAlert(); alert.messageText = "Are you sure to reset columns?"
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            let answer = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
            return answer == .alertFirstButtonReturn
        }
        private weak var configuredTable: NSTableView?
        private var columnDefinitions: [ObjectIdentifier: StatusListColumn] = [:]
        private var originalColumns: [NSTableColumn] = []
        private var originalWidths: [ObjectIdentifier: CGFloat] = [:]
        private var desiredColumns: [NSTableColumn] = []
        private var desiredWidths: [ObjectIdentifier: CGFloat] = [:]
        private var layoutObservers: [NSObjectProtocol] = []
        private var trackingHeader = false
        private var draggingHeader = false
        private var adjustingLayout = false
        func rememberNativeColumnLayout(adjustedColumn: StatusListColumn? = nil) {
            guard enabled, !adjustingLayout, let table = configuredTable else { return }
            let order = table.tableColumns.compactMap { columnDefinitions[ObjectIdentifier($0)] }
            var widths = savedWidths
            if let adjustedColumn, let column = table.tableColumns.first(where: { columnDefinitions[ObjectIdentifier($0)] == adjustedColumn }) {
                widths[adjustedColumn] = Double(column.width)
            }
            guard saveLayout(order, widths) else { return }
            savedOrder = order; savedWidths = widths
            desiredColumns = [originalColumns[0]] + table.tableColumns.filter { columnDefinitions[ObjectIdentifier($0)] != nil }
            desiredWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { (ObjectIdentifier($0), $0.width) })
        }
        func fittedWidth(_ column: NSTableColumn, definition: StatusListColumn, includeHeader: Bool) -> CGFloat {
            let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let padding: CGFloat = definition == .path ? 38 : 14
            let content = rows.compactMap(\.entry).map {
                (columnText($0, definition) as NSString).size(withAttributes: [.font: font]).width + padding
            }.max() ?? column.minWidth
            let header = includeHeader ? (column.title as NSString).size(withAttributes: [.font: font]).width + 20 : 0
            return max(column.minWidth, min(column.maxWidth, ceil(max(content, header))))
        }
        @discardableResult func fitColumn(atNativeIndex index: Int, useDefault: Bool) -> Bool {
            guard enabled, let table = configuredTable, table.tableColumns.indices.contains(index),
                  let definition = columnDefinition(atNativeIndex: index), !table.tableColumns[index].isHidden else { return false }
            let column = table.tableColumns[index]
            var widths = savedWidths
            if useDefault { widths.removeValue(forKey: definition) }
            else { widths[definition] = Double(fittedWidth(column, definition: definition, includeHeader: false)) }
            guard saveLayout(savedOrder, widths) else { return false }
            savedWidths = widths
            configureColumns()
            return true
        }
        func dividerColumn(atHeaderPoint point: NSPoint) -> Int? {
            guard let table = configuredTable, let header = table.headerView, header.bounds.contains(point) else { return nil }
            return table.tableColumns.indices.first { index in
                !table.tableColumns[index].isHidden && columnDefinition(atNativeIndex: index) != nil &&
                abs(point.x - header.headerRect(ofColumn: index).maxX) <= 4
            }
        }
        private func applyNativeColumnLayout() {
            guard let table = configuredTable, !trackingHeader else { return }
            adjustingLayout = true; defer { adjustingLayout = false }
            for (index, column) in desiredColumns.enumerated() {
                if let current = table.tableColumns.firstIndex(where: { $0 === column }), current != index { table.moveColumn(current, toColumn: index) }
                if let width = desiredWidths[ObjectIdentifier(column)], abs(column.width - width) > 0.5 { column.width = width }
            }
        }
        func configureColumns() {
            guard let content = window?.contentView else { return }
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, contains(table) { return table }
                return view.subviews.compactMap(find).first
            }
            guard let table = find(content), table.tableColumns.count == StatusListColumn.allCases.count + 1 else { return }
            if configuredTable !== table {
                configuredTable = table; originalColumns = table.tableColumns
                columnDefinitions = Dictionary(uniqueKeysWithValues: zip(table.tableColumns.dropFirst(), StatusListColumn.allCases).map { (ObjectIdentifier($0.0), $0.1) })
                originalWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { (ObjectIdentifier($0), $0.width) })
                desiredColumns = originalColumns; desiredWidths = originalWidths
                for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
                layoutObservers = [NSTableView.columnDidMoveNotification, NSTableView.columnDidResizeNotification].map { name in
                    NotificationCenter.default.addObserver(forName: name, object: table, queue: .main) { [weak self] notification in
                        guard let self, self.trackingHeader,
                              self.draggingHeader || NSApplication.shared.currentEvent?.type == .leftMouseDragged else { return }
                        self.draggingHeader = true
                        let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn
                        let adjusted = name == NSTableView.columnDidResizeNotification ? column.flatMap { self.columnDefinitions[ObjectIdentifier($0)] } : nil
                        self.rememberNativeColumnLayout(adjustedColumn: adjusted)
                    }
                }
            }
            let byDefinition = Dictionary(uniqueKeysWithValues: originalColumns.dropFirst().compactMap { column -> (StatusListColumn, NSTableColumn)? in
                columnDefinitions[ObjectIdentifier(column)].map { ($0, column) }
            })
            desiredColumns = [originalColumns[0]] + savedOrder.compactMap { byDefinition[$0] }
            desiredWidths = originalWidths
            for (definition, column) in byDefinition where visibleColumns.contains(definition) && savedWidths[definition] == nil {
                desiredWidths[ObjectIdentifier(column)] = fittedWidth(column, definition: definition, includeHeader: true)
            }
            for (definition, width) in savedWidths {
                if let column = byDefinition[definition] { desiredWidths[ObjectIdentifier(column)] = max(column.minWidth, min(column.maxWidth, CGFloat(width))) }
            }
            table.allowsColumnReordering = enabled; table.allowsColumnResizing = enabled
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for column in table.tableColumns {
                if let definition = columnDefinitions[ObjectIdentifier(column)] { column.isHidden = !visibleColumns.contains(definition) && definition != .path }
            }
            applyNativeColumnLayout()
            table.headerView?.menu = columnMenu()
        }
        func columnDefinition(atNativeIndex index: Int) -> StatusListColumn? {
            guard let table = configuredTable, table.tableColumns.indices.contains(index) else { return nil }
            return columnDefinitions[ObjectIdentifier(table.tableColumns[index])]
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let reset = NSMenuItem(title: "Reset columns", action: #selector(resetColumnLayout(_:)), keyEquivalent: "")
            reset.target = self; reset.isEnabled = enabled; menu.addItem(reset); menu.addItem(.separator())
            for (index, column) in StatusListColumn.allCases.enumerated() where column != .path && availableColumns.contains(column) {
                let item = NSMenuItem(title: column.rawValue, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self; item.tag = index; item.state = visibleColumns.contains(column) ? .on : .off
                item.isEnabled = enabled && column != .path; menu.addItem(item)
            }
            return menu
        }
        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard enabled, StatusListColumn.allCases.indices.contains(sender.tag) else { return }
            let column = StatusListColumn.allCases[sender.tag]
            guard column != .path, availableColumns.contains(column) else { return }
            setColumnVisible(column, !visibleColumns.contains(column))
        }
        @objc private func resetColumnLayout(_ sender: Any?) {
            guard enabled, let window, window.attachedSheet == nil else { return }
            resetColumns({ [weak self, weak window] in
                guard let self, let window else { return false }
                let approved = await self.confirmResetColumns(window)
                return approved && self.window === window
            }, { [weak self] in self?.resetNativeLayout() })
        }
        private func resetNativeLayout() {
            guard configuredTable != nil else { return }
            desiredColumns = originalColumns; desiredWidths = originalWidths
            applyNativeColumnLayout()
        }
        var focusedPath: Binding<String?>?
        private var contextColumn: StatusListColumn?
        private var contextEntries: [StatusEntry] = []
        var enabled = false
        var delete: ([StatusEntry], StatusEntry, Bool) -> Void = { _, _, _ in }
        var copy: ([StatusEntry], Bool) -> Void = { _, _ in }
        var copyColumn: ([StatusEntry], StatusListColumn) -> Void = { _, _ in }
        var toggleCheck: ([StatusEntry], StatusEntry) -> Void = { _, _ in }
        private var monitor: Any?
        private var menuObserver: NSObjectProtocol?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .keyDown]) { [weak self] event in
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
            for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
            layoutObservers = []
        }
        deinit { stopObserving() }
        private func prepareClipboardMenu(_ menu: NSMenu) {
            guard window?.isKeyWindow == true, let column = contextColumn, !contextEntries.isEmpty,
                  let submenu = menu.items.first(where: { $0.title == "Copy to Clipboard" })?.submenu else { return }
            let identifier = NSUserInterfaceItemIdentifier("TurtleGit.CopyColumn")
            if let previous = submenu.items.first(where: { $0.identifier == identifier }) { submenu.removeItem(previous) }
            let item = NSMenuItem(title: "column '\(column.rawValue)'", action: #selector(copyCurrentColumn(_:)), keyEquivalent: "")
            item.identifier = identifier; item.target = self
            if let image = MenuIcon.copy.contextImage()?.copy() as? NSImage { image.size = NSSize(width: 16, height: 16); item.image = image }
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
            if event.type == .rightMouseDown { trackingHeader = false; draggingHeader = false }
            if event.type == .leftMouseDown {
                draggingHeader = false
                if let table = configuredTable, let header = table.headerView {
                    let point = header.convert(event.locationInWindow, from: nil)
                    trackingHeader = header.bounds.contains(point)
                    if event.clickCount == 2, let index = dividerColumn(atHeaderPoint: point) {
                        trackingHeader = false
                        if fitColumn(atNativeIndex: index, useDefault: event.modifierFlags.contains(.shift)) { return nil }
                    }
                }
            }
            if event.type == .leftMouseDragged { if trackingHeader { draggingHeader = true }; return event }
            if event.type == .leftMouseUp {
                if trackingHeader {
                    if draggingHeader { rememberNativeColumnLayout() }
                    trackingHeader = false; draggingHeader = false
                    DispatchQueue.main.async { [weak self] in self?.configureColumns() }
                }
                return event
            }
            if event.type != .keyDown {
                contextColumn = nil; contextEntries = []
                guard let content = window.contentView,
                      let table = table(at: event.locationInWindow, in: content) else { return event }
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                if event.type == .rightMouseDown && rows.indices.contains(row), rows[row].entry != nil {
                    let column = table.column(at: table.convert(event.locationInWindow, from: nil))
                    contextColumn = columnDefinition(atNativeIndex: column)
                    let rows = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: max(0, row))
                    contextEntries = StatusListGroups.files(at: rows, in: self.rows)
                }
                guard rows.indices.contains(row) else { return event }
                guard let entry = rows[row].entry else { return event.type == .leftMouseDown ? nil : event }
                // Native contextual clicks do not replace the highlighted rows.
                // Keep their anchor; StatusListSelection resolves an unselected
                // clicked row for that menu request without moving this anchor.
                let preserve = event.type == .rightMouseDown || event.modifierFlags.contains(.shift)
                if !preserve || focusedPath?.wrappedValue == nil { focusedPath?.wrappedValue = entry.path }
                return event
            }
            guard let table = window.firstResponder as? NSTableView, contains(table) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            contextColumn = nil; contextEntries = []
            if event.keyCode == 49, flags.isEmpty, enabled {
                let selected = StatusListGroups.files(at: table.selectedRowIndexes, in: rows)
                let mark = selected.first { $0.path == focusedPath?.wrappedValue } ?? selected.first
                if let mark { toggleCheck(selected, mark); return nil }
            }
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
