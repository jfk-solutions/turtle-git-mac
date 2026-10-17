// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TurtleGitCore

struct LFSProgressRow: Identifiable {
    enum Kind: Equatable { case command, file, error, finishedSuccess, finishedFailure }
    let id: String
    let action: String
    let text: String
    let kind: Kind
    static func completion(success: Bool, elapsed: TimeInterval, date: Date = Date()) -> String {
        let format = DateFormatter(); format.dateStyle = .short; format.timeStyle = .medium
        let milliseconds = Int(min(Double(Int.max - 1), max(0, elapsed.isFinite ? elapsed * 1000 : 0)))
        return "\(success ? "Success" : "Fail") (\(milliseconds) ms @ \(format.string(from: date)))"
    }
    static func clipboard(_ rows: [Self], keyboard: Bool) -> String {
        if keyboard { return rows.map { "\($0.action): \($0.text)  \n" }.joined() }
        var text = rows.map(\.text).joined(separator: "\n")
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }
    /// Auxiliary messages keep their positions; only contiguous file blocks sort.
    static func sorted(_ rows: [Self], column: String, ascending: Bool) -> [Self] {
        var output = rows, start = 0
        while start < output.count {
            guard output[start].kind == .file else { start += 1; continue }
            var end = start + 1
            while end < output.count && output[end].kind == .file { end += 1 }
            let block = output[start..<end].enumerated().sorted { left, right in
                var order = column == "action" ? left.element.action.compare(right.element.action, options: .literal) : .orderedSame
                if order == .orderedSame { order = left.element.text.compare(right.element.text, options: [.caseInsensitive, .literal], locale: Locale(identifier: "en_US_POSIX")) }
                if order == .orderedSame { return left.offset < right.offset }
                return order == (ascending ? .orderedAscending : .orderedDescending)
            }.map(\.element)
            output.replaceSubrange(start..<end, with: block); start = end
        }
        return output
    }
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
    var activateRow: (Int) -> Void = { _ in }
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { activateRow(row(at: convert(event.locationInWindow, from: nil))) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return super.menu(for: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers?.lowercased() == "a", event.modifierFlags.intersection([.command,.shift,.option,.control]) == .command { selectAll(nil); return true }
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
        private var renderedGeneration: UUID?
        private var sortedColumn: String?
        private var ascending = true
        init(model: LFSLocksWindowModel) { self.model = model }
        func make() -> NSScrollView {
            let table = LFSProgressNativeTable(icon: model?.operationLocked == true ? .lockBackdrop : .unlockBackdrop, defaults: model?.presentationPreferences ?? .standard)
            self.table = table; table.copySelection = { [weak self] in self?.copySelection() }
            table.activateRow = { [weak self] row in
                guard let self, self.rows.indices.contains(row), let model = self.model else { return }
                let value = self.rows[row]; Task { await model.progressDoubleClick(value) }
            }
            table.dataSource = self; table.delegate = self; table.rowHeight = 22
            table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.setAccessibilityLabel("LFS progress notifications")
            for (id,title,width) in [("action","Action",130.0),("path","Path",580.0)] {
                let column = NSTableColumn(identifier: .init(id)); column.title = NSLocalizedString(title,comment:""); column.width = width; column.minWidth = 70; table.addTableColumn(column)
            }
            table.menu = NSMenu(); table.menu?.delegate = self
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
            refresh(); return scroll
        }
        private var rows: [LFSProgressRow] { displayedRows }
        func refresh() {
            let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let follow = table.enclosingScrollView.map { $0.documentVisibleRect.maxY >= table.bounds.maxY - table.rowHeight * 2 } ?? true
            if renderedGeneration != model?.progressGeneration { renderedGeneration = model?.progressGeneration; sortedColumn = nil; ascending = true }
            let notifications = model?.notifications ?? []
            displayedRows = sortedColumn.map { LFSProgressRow.sorted(notifications, column: $0, ascending: ascending) } ?? notifications
            for column in table.tableColumns { table.setIndicatorImage(column.identifier.rawValue == sortedColumn ? NSImage(systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: ascending ? "Ascending" : "Descending") : nil, in: column) }
            if let model, renderedLocked != model.operationLocked { renderedLocked = model.operationLocked; table.setWatermark(model.operationLocked ? .lockBackdrop : .unlockBackdrop) }
            table.reloadData(); table.selectRowIndexes(IndexSet(rows.enumerated().compactMap { selected.contains($0.element.id) ? $0.offset : nil }), byExtendingSelection: false)
            if follow, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
            table.needsDisplay = true
        }
        func tableView(_ tableView: NSTableView, didClick column: NSTableColumn) {
            guard let model, model.progressRowsAvailable(model.progressGeneration) else { return }
            if sortedColumn == column.identifier.rawValue { ascending.toggle() } else { sortedColumn = column.identifier.rawValue; ascending = true }
            refresh()
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
            let selected = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            model.copyProgressKeyboard(LFSProgressRow.clipboard(selected, keyboard: true), generation: model.progressGeneration)
        }
        private final class CopyItem: NSMenuItem {
            private let invoke: () -> Void
            init(title: String, icon: MenuIcon = .copy, preferences: UserDefaults, invoke: @escaping () -> Void) {
                self.invoke = invoke; super.init(title: title, action: #selector(copyRows), keyEquivalent: "")
                target = self; image = icon.contextImage(defaults: preferences)
            }
            required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
            @objc private func copyRows() { invoke() }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); menu.autoenablesItems = false
            guard let model, model.progressRowsAvailable(model.progressGeneration) else { return }
            let values = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            guard let target = model.progressTarget(values) else { return }
            if let file = target.file {
                for command in LFSProgressCommand.allCases {
                    if (command == .open || command == .openWith), model.progressActions.isDirectory(file.text) { continue }
                    if command == .open || command == .lock || command == .explore && model.progressActions.isDirectory(file.text) { menu.addItem(.separator()) }
                    menu.addItem(CopyItem(title: command.rawValue, icon: command.icon, preferences: model.presentationPreferences) { [weak model] in
                        Task { await model?.progressCommand(command, target: target) }
                    })
                }
                menu.addItem(.separator())
            }
            let captured = LFSProgressRow.clipboard(values, keyboard: false)
            menu.addItem(CopyItem(title: "Copy to Clipboard", preferences: model.presentationPreferences) { [weak model] in model?.copyProgress(captured, generation: target.generation) })
        }
    }
}

struct LFSProgressTarget {
    let generation: UUID
    let rows: [LFSProgressRow]
    var file: LFSProgressRow? { rows.count == 1 && rows[0].kind == .file ? rows[0] : nil }
}

enum LFSProgressCommand: String, CaseIterable {
    case log = "Show log", open = "Open", openWith = "Open With…", explore = "Explore to"
    case lock = "LFS Lock", unlock = "LFS Unlock"
    var icon: MenuIcon {
        switch self {
        case .log: return .log
        case .open, .openWith: return .open
        case .explore: return .explore
        case .lock: return .lock
        case .unlock: return .unlock
        }
    }
}

/// Owned presentation shared by the Locks dialog and standalone/file-list progress.
@MainActor final class LFSProgressActionHost {
    private weak var model: LFSLocksWindowModel?
    private let access: RepositoryAccessLease?
    weak var window: NSWindow?
    private(set) var picker: NSOpenPanel?
    private(set) var logs: [UUID: LogWindowController] = [:]
    private(set) var operations: [UUID: LFSFileOperationController] = [:]
    var chooseApplication: (() async -> URL?)?
    var presentLog: (LogWindowController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    var presentOperation: ((NSWindow) -> Void)?
    var launch: (URL, URL?) async throws -> Void = { file, application in
        if let application {
            try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([file], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                    if let error { reply.resume(throwing: error) } else { reply.resume() }
                }
            }
        } else if !NSWorkspace.shared.open(file) { throw StatusFileActionFailure(message: "Could not open " + file.lastPathComponent + ".") }
    }
    var reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    init(model: LFSLocksWindowModel, access: RepositoryAccessLease?) { self.model = model; self.access = access }
    private func location(_ path: String) throws -> URL {
        guard let model, !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.lowercased() == ".git" }) else { throw LFSLocksFailure.selection }
        return model.repository.root.appendingPathComponent(path)
    }
    func isDirectory(_ path: String) -> Bool {
        guard let url = try? location(path) else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
    private func live(_ token: UUID) -> Bool { model?.retired == false && model?.progressActionToken == token }
    func perform(_ command: LFSProgressCommand, path: String, token: UUID) async throws {
        guard let model, live(token) else { return }
        let url = try location(path)
        switch command {
        case .log:
            if let showLog = model.onProgressLog { showLog(path); return }
            let id = UUID(), controller = LogWindowController(repository: model.repository, access: access, labelDefaults: model.presentationPreferences)
            logs[id] = controller
            controller.onClosed = { [weak self] in self?.logs.removeValue(forKey: id) }
            controller.model.setPathScope([path])
            presentLog(controller)
        case .explore: reveal(url)
        case .lock, .unlock:
            let id = UUID(), controller = LFSFileOperationController(repository: model.repository, access: access, defaults: model.presentationPreferences)
            operations[id] = controller; controller.standalonePresentation = presentOperation
            controller.model.onProgressLog = model.onProgressLog
            controller.onClosed = { [weak self] in self?.operations.removeValue(forKey: id) }
            controller.model.onPullAfterLock = { [weak model] in guard let model, !model.retired else { return }; model.onPullAfterLock() }
            if !controller.present(paths: [path], locked: command == .lock) { operations.removeValue(forKey: id) }
        case .open, .openWith:
            let application: URL?
            if command == .openWith {
                if let chooseApplication { application = await chooseApplication() }
                else {
                    guard let window, window.attachedSheet == nil else { return }
                    let panel = NSOpenPanel(); panel.title = "Open With"; panel.prompt = "Open"
                    panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                    panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true); picker = panel
                    application = await withCheckedContinuation { reply in panel.beginSheetModal(for: window) { reply.resume(returning: $0 == .OK ? panel.url : nil) } }
                    picker = nil
                }
                guard application != nil, live(token) else { return }
            } else { application = nil }
            guard live(token) else { return }
            let scoped = application?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { application?.stopAccessingSecurityScopedResource() } }
            try await launch(url, application)
        }
    }
    func retire() {
        picker?.cancel(nil); picker = nil
        let oldLogs = Array(logs.values), oldOperations = Array(operations.values)
        logs.removeAll(); operations.removeAll()
        for controller in oldLogs { controller.close() }
        for controller in oldOperations { controller.model.retire(); controller.close() }
        window = nil
    }
}
