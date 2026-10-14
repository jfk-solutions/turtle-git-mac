import AppKit
import SwiftUI
import TurtleGitCore

/// Preserve the initiating action's Shift choice across asynchronous preparation.
/// Nested comparison routes inherit it; independent actions capture their own event.
enum ComparisonToolInvocation {
    @TaskLocal static var alternate: Bool?
    @MainActor static var capture: Bool { alternate ?? NSEvent.modifierFlags.contains(.shift) }
    @MainActor static var cacheKey: String { capture ? "alternate" : "default" }
}

/// Own the complete selected-file launch, including its question and Git reads.
/// The initiating window is captured before any suspension; switching windows
/// cannot move the question or retarget the eventual viewers.
@MainActor final class FileListComparisonSession {
    private(set) static var activeOperations = 0
    let cancellation: OperationCancellation
    let alternateTool: Bool
    private weak var window: NSWindow?
    private let preferences: UserDefaults
    private var observer: NSObjectProtocol?
    private var alert: NSAlert?
    private var started = false
    var confirmation: ((Int) async -> Bool)?

    init(window: NSWindow?, preferences: UserDefaults = .standard, cancellation: OperationCancellation = OperationCancellation(), alternateTool: Bool? = nil) {
        self.window = window; self.preferences = preferences; self.cancellation = cancellation
        self.alternateTool = alternateTool ?? ComparisonToolInvocation.capture
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            }
        }
    }
    func cancel() {
        cancellation.cancel()
        if let alert, let window, window.attachedSheet === alert.window {
            window.endSheet(alert.window, returnCode: .cancel); alert.window.orderOut(nil)
        }
    }
    func check() throws {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
    }
    func run(selectedCount: Int, operation: (OperationCancellation) async throws -> Void) async throws {
        guard !started else { throw OperationCancellationFailure.cancelled }
        started = true; Self.activeOperations += 1
        defer {
            Self.activeOperations -= 1
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            alert = nil
        }
        try check()
        if AdvancedListBehavior(defaults: preferences).warnsBeforeDiffs(count: selectedCount) {
            let accepted: Bool
            if let confirmation { accepted = await confirmation(selectedCount) }
            else {
                guard let window, window.attachedSheet == nil else { return }
                let question = NSAlert(); question.messageText = "Open diffs for \(selectedCount) files?"
                question.informativeText = "Each selected file opens in its own viewer."
                question.addButton(withTitle: "Yes"); question.addButton(withTitle: "No"); alert = question
                accepted = await withCheckedContinuation { reply in
                    question.beginSheetModal(for: window) { reply.resume(returning: $0 == .alertFirstButtonReturn) }
                }
            }
            try check()
            guard accepted else { return }
        }
        try await ComparisonToolInvocation.$alternate.withValue(alternateTool) {
            try await operation(cancellation)
        }
        try check()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Source group headings span the list, independently of text-column widths.
/// This drawing layer leaves the underlying native row/accessibility and input
/// implementations intact and never intercepts pointer events.
final class FileListGroupHeaders: NSView {
    weak var table: NSTableView?
    var rows: [StatusListRow] = []
    var font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var headings: [(title: String, rect: NSRect)] {
        guard let table, table.numberOfRows == rows.count else { return [] }
        let visible = table.visibleRect
        return rows.enumerated().compactMap { index, row in
            guard let group = row.group else { return nil }
            var rect = table.rect(ofRow: index)
            rect.origin.x = visible.minX; rect.size.width = visible.width
            return (group.title, rect)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        for heading in headings where heading.rect.intersects(dirtyRect) {
            NSColor.controlBackgroundColor.setFill(); heading.rect.fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: paragraph]
            let text = heading.title as NSString
            let available = heading.rect.insetBy(dx: 12, dy: 0)
            let measured = text.size(withAttributes: attributes)
            let rect = NSRect(x: available.minX, y: available.midY - measured.height / 2, width: available.width, height: measured.height)
            text.draw(in: rect, withAttributes: attributes)
            let start = available.minX + measured.width + 12
            if start < available.maxX {
                NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
                NSRect(x: start, y: available.midY, width: available.maxX - start, height: 1).fill()
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Observe the public AppKit table underlying a SwiftUI Table without replacing
/// its selection, accessibility, checkbox or context-menu implementations.
struct CommitFileInteraction: NSViewRepresentable {
    @AppStorage("LogFontForFileListCtrl") private var useLogFont = false
    @AppStorage("LogFontName") private var fontName = MessageEditorFont.defaultName
    @AppStorage("LogFontSize") private var fontSize = MessageEditorFont.defaultSize
    let rows: [StatusListRow]
    var leadingColumnCount = 1
    var keyboardDeleteEnabled = true
    var nativeColumns = StatusListColumn.allCases
    var rowTexts: [[StatusListColumn: String]]? = nil
    var itemIDs: [String]? = nil
    var copyIDs: (([String], Bool) -> Void)? = nil
    var copyColumnIDs: (([String], StatusListColumn) -> Void)? = nil
    var toggleCheckIDs: (([String], String) -> Void)? = nil
    var configureRefresh: ((Probe) -> Void)? = nil
    var preferences:UserDefaults = .standard
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
        view.preferences=preferences
        view.fileListFont = useLogFont ? MessageEditorFont.resolve(name: fontName, size: fontSize) : nil
        view.leadingColumnCount = leadingColumnCount; view.keyboardDeleteEnabled = keyboardDeleteEnabled
        view.nativeColumns = nativeColumns; view.rowTexts = rowTexts; view.itemIDs = itemIDs
        view.copyIDs = copyIDs; view.copyColumnIDs = copyColumnIDs; view.toggleCheckIDs = toggleCheckIDs
        view.columnText = columnText
        view.savedOrder = savedOrder; view.savedWidths = savedWidths; view.saveLayout = saveLayout
        view.availableColumns = availableColumns; view.visibleColumns = visibleColumns; view.setColumnVisible = setColumnVisible; view.resetColumns = resetColumns
        view.rows = rows; view.focusedPath = $focusedPath
        view.enabled = enabled; view.delete = delete; view.copy = copy; view.copyColumn = copyColumn; view.toggleCheck = toggleCheck
        configureRefresh?(view)
        view.scheduleColumnConfiguration()
    }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var preferences:UserDefaults = .standard
        var fileListFont: NSFont?
        var rows: [StatusListRow] = []
        var leadingColumnCount = 1
        var keyboardDeleteEnabled = true
        var nativeColumns = StatusListColumn.allCases
        var rowTexts: [[StatusListColumn: String]]? = nil
        var itemIDs: [String]? = nil
        var copyIDs: (([String], Bool) -> Void)? = nil
        var copyColumnIDs: (([String], StatusListColumn) -> Void)? = nil
        var toggleCheckIDs: (([String], String) -> Void)? = nil
        var visibleColumns = Set(StatusListColumn.defaultColumns)
        var availableColumns = Set(StatusListColumn.allCases)
        var columnText: (StatusEntry, StatusListColumn) -> String = { _, _ in "" }
        var savedOrder = StatusListColumn.allCases
        var savedWidths: [StatusListColumn: Double] = [:]
        var saveLayout: ([StatusListColumn], [StatusListColumn: Double]) -> Bool = { _, _ in false }
        var setColumnVisible: (StatusListColumn, Bool) -> Void = { _, _ in }
        var resetColumns: (@escaping () async -> Bool, @escaping () -> Void) -> Void = { _, _ in }
        private var resetAlert:NSAlert?
        private var resetReply:((Bool)->Void)?
        lazy var confirmResetColumns:(NSWindow) async -> Bool = { [weak self] window in
            guard let self,self.integrationActive,self.window === window,window.attachedSheet == nil else {return false}
            let alert=NSAlert();alert.messageText="Are you sure to reset columns?"
            alert.addButton(withTitle:"Yes");alert.addButton(withTitle:"No");self.resetAlert=alert
            return await withCheckedContinuation { continuation in
                self.resetReply={continuation.resume(returning:$0)}
                alert.beginSheetModal(for:window) { [weak self] response in
                    guard let self,self.resetAlert === alert else {return}
                    self.finishResetQuestion(response == .alertFirstButtonReturn)
                }
            }
        }
        private func finishResetQuestion(_ accepted:Bool) {
            let reply=resetReply;resetReply=nil
            if let alert=resetAlert {resetAlert=nil;alert.window.sheetParent?.endSheet(alert.window,returnCode:.abort);alert.window.orderOut(nil)}
            reply?(accepted)
        }
        private weak var configuredTable: NSTableView?
        private var columnDefinitions: [ObjectIdentifier: StatusListColumn] = [:]
        private var originalColumns: [NSTableColumn] = []
        private var originalWidths: [ObjectIdentifier: CGFloat] = [:]
        private var desiredColumns: [NSTableColumn] = []
        private var desiredWidths: [ObjectIdentifier: CGFloat] = [:]
        private var layoutObservers: [NSObjectProtocol] = []
        private var geometryObservers: [NSObjectProtocol] = []
        private(set) var groupHeaders: FileListGroupHeaders?
        private var integrationActive = false
        private var integrationGeneration = UUID()
        private var configurationScheduled = false
        func scheduleColumnConfiguration() {
            guard !configurationScheduled else { return }; configurationScheduled = true
            let generation = integrationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.integrationGeneration == generation else { return }
                self.configurationScheduled = false
                guard self.integrationActive else { return }; self.configureColumns()
            }
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance(); scheduleColumnConfiguration()
        }
        private func configureGroupHeadings(_ table: NSTableView) {
            guard rows.contains(where: { $0.group != nil }) else { groupHeaders?.removeFromSuperview(); groupHeaders = nil; return }
            let layer = groupHeaders ?? FileListGroupHeaders(frame: table.bounds)
            groupHeaders = layer; layer.table = table; layer.rows = rows
            layer.font = fileListFont.map { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) } ?? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
            layer.frame = table.bounds; layer.setAccessibilityElement(false)
            table.addSubview(layer, positioned: .above, relativeTo: nil)
            layer.needsDisplay = true
        }
        private struct ListPosition {
            let origin: NSPoint
            let selectedIndex: Int?
            let focusedIndex: Int?
        }
        private var listPosition: ListPosition?
        private var positionGeneration = UUID()
        private var positionCompletion: (() -> Void)?
        private func finishListPosition() { let reply = positionCompletion; positionCompletion = nil; reply?() }

        func cancelListPosition() { positionGeneration = UUID(); listPosition = nil; finishListPosition() }
        func storeListPosition() {
            positionGeneration = UUID(); finishListPosition()
            guard let table = configuredTable, let scroll = table.enclosingScrollView else { listPosition = nil; return }
            let mark = focusedPath?.wrappedValue.flatMap { id in itemIDs?.firstIndex(of: id) }
            listPosition = ListPosition(origin: scroll.contentView.bounds.origin, selectedIndex: table.selectedRowIndexes.first, focusedIndex: mark)
        }
        func restoreListPosition(ids: [String], enabled: Bool, completion: @escaping () -> Void = {}) {
            finishListPosition()
            let position = listPosition; listPosition = nil
            positionGeneration = UUID(); let generation = positionGeneration
            var answered = false
            let reply = { guard !answered else { return }; answered = true; completion() }
            positionCompletion = reply
            DispatchQueue.main.async { [weak self] in
                guard let self else { reply(); return }
                self.applyListPosition(position, ids: ids, enabled: enabled, generation: generation, remaining: 1000)
            }
        }
        private func applyListPosition(_ position: ListPosition?, ids: [String], enabled: Bool, generation: UUID, remaining: Int) {
            guard positionGeneration == generation else { return }
            guard let table = configuredTable, let scroll = table.enclosingScrollView,
                  table.numberOfRows == ids.count && itemIDs == ids else {
                if remaining > 0 && window != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                    self?.applyListPosition(position, ids: ids, enabled: enabled, generation: generation, remaining: remaining - 1)
                } } else { finishListPosition() }
                return
            }
            scroll.layoutSubtreeIfNeeded(); table.layoutSubtreeIfNeeded()
            if enabled, let position {
                if let row = position.selectedIndex, ids.indices.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                if let row = position.focusedIndex, ids.indices.contains(row) { focusedPath?.wrappedValue = ids[row] }
                scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(NSRect(origin: position.origin, size: scroll.contentView.bounds.size)).origin)
            } else {
                table.deselectAll(nil); focusedPath?.wrappedValue = nil; scroll.contentView.scroll(to: .zero)
            }
            scroll.reflectScrolledClipView(scroll.contentView)
            // Give the SwiftUI selection binding the same run-loop turn before
            // callers expose the list as ready for a new selection.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.positionGeneration == generation else { return }
                self.finishListPosition()
            }
        }
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
            desiredColumns = Array(originalColumns.prefix(leadingColumnCount)) + table.tableColumns.filter { columnDefinitions[ObjectIdentifier($0)] != nil }
            desiredWidths = Dictionary(uniqueKeysWithValues: table.tableColumns.map { (ObjectIdentifier($0), $0.width) })
        }
        func fittedWidth(_ column: NSTableColumn, definition: StatusListColumn, includeHeader: Bool) -> CGFloat {
            let font = fileListFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let padding: CGFloat = definition == .path ? 38 : 14
            let texts = rowTexts?.map { $0[definition] ?? "" } ?? rows.compactMap(\.entry).map { columnText($0, definition) }
            let content = texts.map { ($0 as NSString).size(withAttributes: [.font: font]).width + padding }.max() ?? column.minWidth
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
            guard integrationActive, let content = window?.contentView else { return }
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView, contains(table) { return table }
                return view.subviews.compactMap(find).first
            }
            guard let table = find(content), table.tableColumns.count == nativeColumns.count + leadingColumnCount else { return }
            let currentObjects = Set(table.tableColumns.map(ObjectIdentifier.init))
            let originalObjects = Set(originalColumns.map(ObjectIdentifier.init))
            if configuredTable !== table || currentObjects != originalObjects || layoutObservers.isEmpty {
                for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }; geometryObservers = []
                groupHeaders?.removeFromSuperview(); groupHeaders = nil
                configuredTable = table; originalColumns = table.tableColumns
                columnDefinitions = Dictionary(uniqueKeysWithValues: zip(table.tableColumns.dropFirst(leadingColumnCount), nativeColumns).map { column, fallback in
                    let named = StatusListColumn(rawValue: column.headerCell.stringValue)
                    return (ObjectIdentifier(column), named.flatMap { nativeColumns.contains($0) ? $0 : nil } ?? fallback)
                })
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
            let byDefinition = Dictionary(uniqueKeysWithValues: originalColumns.dropFirst(leadingColumnCount).compactMap { column -> (StatusListColumn, NSTableColumn)? in
                columnDefinitions[ObjectIdentifier(column)].map { ($0, column) }
            })
            desiredColumns = Array(originalColumns.prefix(leadingColumnCount)) + savedOrder.compactMap { byDefinition[$0] }
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
            configureGroupHeadings(table)
            if geometryObservers.isEmpty {
                table.postsFrameChangedNotifications = true
                var observations: [(Notification.Name, AnyObject)] = [(NSView.frameDidChangeNotification, table)]
                if let clip = table.enclosingScrollView?.contentView { clip.postsBoundsChangedNotifications = true; observations.append((NSView.boundsDidChangeNotification, clip)) }
                if let window { observations.append((NSWindow.didResizeNotification, window)) }
                geometryObservers = observations.map { name, object in
                    NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        guard let self, !self.adjustingLayout else { return }; self.scheduleColumnConfiguration()
                    }
                }
            }
        }
        func columnDefinition(atNativeIndex index: Int) -> StatusListColumn? {
            guard let table = configuredTable, table.tableColumns.indices.contains(index) else { return nil }
            return columnDefinitions[ObjectIdentifier(table.tableColumns[index])]
        }
        func columnMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let reset = NSMenuItem(title: "Reset columns", action: #selector(resetColumnLayout(_:)), keyEquivalent: "")
            reset.target = self; reset.isEnabled = enabled; menu.addItem(reset); menu.addItem(.separator())
            for (index, column) in StatusListColumn.allCases.enumerated() where column != .path && nativeColumns.contains(column) && availableColumns.contains(column) {
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
        private var contextIDs: [String] = []
        var enabled = false
        var delete: ([StatusEntry], StatusEntry, Bool) -> Void = { _, _, _ in }
        var copy: ([StatusEntry], Bool) -> Void = { _, _ in }
        var copyColumn: ([StatusEntry], StatusListColumn) -> Void = { _, _ in }
        var toggleCheck: ([StatusEntry], StatusEntry) -> Void = { _, _ in }
        private var closeObserver:NSObjectProtocol?
        private var monitor: Any?
        private var menuObserver: NSObjectProtocol?
        func acceptsFileDrop(at location: CGPoint) -> Bool {
            guard enabled, window?.attachedSheet == nil, let table = configuredTable else { return false }
            let point = NSPoint(x: location.x, y: isFlipped ? location.y : bounds.height - location.y)
            let row = table.row(at: table.convert(point, from: self))
            return row < 0 || rows.indices.contains(row) && rows[row].group == nil
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stopObserving()
            guard window != nil else { return }
            integrationActive = true; scheduleColumnConfiguration()
            closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.stopObserving()}
            }
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
            finishResetQuestion(false)
            if let closeObserver {NotificationCenter.default.removeObserver(closeObserver);self.closeObserver=nil}
            integrationActive = false; integrationGeneration = UUID(); configurationScheduled = false
            for observer in geometryObservers { NotificationCenter.default.removeObserver(observer) }; geometryObservers = []
            groupHeaders?.removeFromSuperview(); groupHeaders = nil
            cancelListPosition()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
            menuObserver = nil
            for observer in layoutObservers { NotificationCenter.default.removeObserver(observer) }
            layoutObservers = []
        }
        deinit { stopObserving() }
        private func prepareClipboardMenu(_ menu: NSMenu) {
            guard window?.isKeyWindow == true, let column = contextColumn, (!contextEntries.isEmpty || !contextIDs.isEmpty),
                  let submenu = menu.items.first(where: { $0.title == "Copy to Clipboard" })?.submenu else { return }
            let identifier = NSUserInterfaceItemIdentifier("TurtleGit.CopyColumn")
            if let previous = submenu.items.first(where: { $0.identifier == identifier }) { submenu.removeItem(previous) }
            let item = NSMenuItem(title: "column '\(column.rawValue)'", action: #selector(copyCurrentColumn(_:)), keyEquivalent: "")
            item.identifier = identifier; item.target = self
            if let image = MenuIcon.copy.contextImage(defaults:preferences)?.copy() as? NSImage { image.size = NSSize(width: 16, height: 16); item.image = image }
            submenu.addItem(item)
        }
        @objc private func copyCurrentColumn(_ sender: NSMenuItem) {
            guard let column = contextColumn else { return }
            if !contextIDs.isEmpty { copyColumnIDs?(contextIDs, column) }
            else if !contextEntries.isEmpty { copyColumn(contextEntries, column) }
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
        func observe(_ event: NSEvent) -> NSEvent? {
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
                contextColumn = nil; contextEntries = []; contextIDs = []
                guard let content = window.contentView,
                      let table = table(at: event.locationInWindow, in: content) else { return event }
                let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                if let itemIDs, itemIDs.indices.contains(row) {
                    if rows.count == itemIDs.count && rows[row].group != nil {return event.type == .leftMouseDown ? nil:event}
                    if event.type == .rightMouseDown {
                        contextColumn = columnDefinition(atNativeIndex: table.column(at: table.convert(event.locationInWindow, from: nil)))
                        let indexes = table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer: row)
                        contextIDs = indexes.compactMap { itemIDs.indices.contains($0) ? itemIDs[$0] : nil }
                    }
                    let preserve = event.type == .rightMouseDown || event.modifierFlags.contains(.shift)
                    if !preserve || focusedPath?.wrappedValue == nil { focusedPath?.wrappedValue = itemIDs[row] }
                    return event
                }
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
            contextColumn = nil; contextEntries = []; contextIDs = []
            if let itemIDs {
                let selected = table.selectedRowIndexes.compactMap { index in itemIDs.indices.contains(index) && (rows.count != itemIDs.count || rows[index].entry != nil) ? itemIDs[index]:nil }
                if flags.isEmpty,rows.count == itemIDs.count,rows.contains(where:{$0.group != nil}),[125,126,115,119].contains(event.keyCode) {
                    let forward=event.keyCode == 125 || event.keyCode == 115,endpoint=event.keyCode == 115 || event.keyCode == 119
                    let anchor=endpoint ? nil:focusedPath?.wrappedValue.flatMap {itemIDs.firstIndex(of:$0)} ?? (table.selectedRow >= 0 ? table.selectedRow:nil)
                    guard let target=StatusListGroups.nextFileRow(after:anchor,forward:forward,in:rows) else {return nil}
                    table.selectRowIndexes(IndexSet(integer:target),byExtendingSelection:false);table.scrollRowToVisible(target);focusedPath?.wrappedValue=itemIDs[target];return nil
                }
                if event.keyCode == 49, flags.isEmpty, enabled, leadingColumnCount > 0,
                   let mark = selected.first(where: { $0 == focusedPath?.wrappedValue }) ?? selected.first {
                    toggleCheckIDs?(selected, mark); return nil
                }
                let commandCopy = event.keyCode == 8 && flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
                let controlInsert = event.keyCode == 114 && flags.contains(.control)
                if (commandCopy || controlInsert), !selected.isEmpty { copyIDs?(selected, flags.contains(.shift)); return nil }
                if [123,124,125,126,115,119].contains(event.keyCode), !flags.contains(.shift) {
                    DispatchQueue.main.async { [weak self, weak table] in
                        guard let self, let table, table.selectedRowIndexes.count == 1, itemIDs.indices.contains(table.selectedRow) else { return }
                        self.focusedPath?.wrappedValue = itemIDs[table.selectedRow]
                    }
                }
                return event
            }
            if event.keyCode == 49, flags.isEmpty, enabled, leadingColumnCount > 0 {
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
            if keyboardDeleteEnabled && (event.keyCode == 51 || event.keyCode == 117) {
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
