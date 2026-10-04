import AppKit
import SwiftUI
import TurtleGitCore

private struct BlameParentMenuTarget {
    let choice: GitBlameParentComparison
    let originalLine: Int
}

@MainActor final class BlameWindowController: NSWindowController, NSWindowDelegate {
    let model: BlameWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String) {
        model = BlameWindowModel(repository: repository, access: access, path: path, revision: revision)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) at \(revision.prefix(7)) – Blame – TurtleGit"
        window.minSize = NSSize(width: 820, height: 400); window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentViewController = NSHostingController(rootView: BlameDialog(model: model))
        super.init(window: window); window.delegate = self; window.setContentSize(NSSize(width: 1120, height: 700)); window.center(); model.reload()
    }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class BlameWindowModel: ObservableObject {
    let repository: GitRepository, path: String
    private let access: RepositoryAccessLease?
    private var revision: String
    private var generation = 0
    private var pendingLine: Int?
    private var clipboardGeneration = 0
    @Published var copyingLog = false
    @Published var snapshot: GitBlameSnapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var ignoreWhitespace = false
    @Published var detectMoved = false
    @Published var detectCopied = false
    @Published var colorAge = true
    @Published var selection: Int?
    @Published var parentChoices: [GitBlameParentComparison] = []
    @Published var loadingParents = false
    private var parentGeneration = 0
    private var parentCache: [String: [GitBlameParentComparison]] = [:]
    @Published var highlightedHash: String?
    @Published var hoveredLine: Int?
    @Published var find = ""
    @Published var matchCase = false
    @Published var goTo = ""
    @Published var navigationMessage = ""
    var ranks: [String: Int] = [:]
    private var origins: [String: GitBlameLine] = [:]
    var historyCount = 0
    var onLog: ((String, String) -> Void)?
    var onChanges: ((RevisionComparisonSnapshot) -> Void)?
    var onPrevious: ((String, String, Int) -> Void)?
    var lines: [GitBlameLine] { snapshot?.lines ?? [] }
    private func line(_ number: Int?) -> GitBlameLine? {
        guard let number, number > 0, lines.indices.contains(number - 1) else { return nil }; return lines[number - 1]
    }
    var selectedLine: GitBlameLine? { line(selection) }
    var highlightedLine: GitBlameLine? { highlightedHash.flatMap { origins[$0] } }
    var hoverLine: GitBlameLine? { line(hoveredLine) }
    func highlight(_ row: Int) {
        guard lines.indices.contains(row) else { return }
        let hash = lines[row].hash; highlightedHash = highlightedHash == hash ? nil : hash
    }
    func highlightKind(_ line: GitBlameLine) -> Int {
        if let selected = highlightedLine {
            if line.hash == selected.hash { return 1 }
            if line.author == selected.author { return 2 }
        }
        if let hovered = hoverLine {
            if line.hash == hovered.hash { return 3 }
            if line.author == hovered.author { return 4 }
        }
        return 0
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String) {
        self.repository = repository; self.access = access; self.path = path; self.revision = revision
    }
    func invalidate() { generation += 1; parentGeneration += 1; clipboardGeneration += 1; copyingLog = false }
    func prepareParentMenu(number: Int, completion: @escaping () -> Void) {
        selection = number; loadParents(completion: completion)
    }
    private func loadParents(completion: @escaping () -> Void) {
        parentGeneration += 1; let request = parentGeneration
        guard let line = selectedLine else { parentChoices = []; loadingParents = false; return }
        let key = line.hash + "\0" + line.filename
        if let cached = parentCache[key] { parentChoices = cached; loadingParents = false; completion(); return }
        parentChoices = []; loadingParents = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let choices = try await repository.blameParentComparisons(revision: line.hash, path: line.filename)
                guard request == parentGeneration else { return }
                parentCache[key] = choices; parentChoices = choices; loadingParents = false
                if selectedLine?.number == line.number, selectedLine?.hash == line.hash, selectedLine?.filename == line.filename { completion() }
            } catch { if request == parentGeneration { self.error = error.localizedDescription; loadingParents = false } }
        }
    }
    func reload() {
        guard !busy else { return }
        parentGeneration += 1; parentChoices = []; loadingParents = false
        clipboardGeneration += 1; copyingLog = false
        generation += 1; let request = generation
        var options = GitBlameOptions(); options.ignoreWhitespace = ignoreWhitespace; options.detectMoved = detectMoved; options.detectCopied = detectCopied
        busy = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.blame(path: path, revision: revision, options: options)
                let history = try await repository.run(["log", "--format=%H", "--follow", result.revision, "--", path]).text.split(separator: "\n").map(String.init)
                guard request == generation else { return }
                ranks = Dictionary(history.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
                origins = Dictionary(result.lines.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
                historyCount = history.count; revision = result.revision; snapshot = result
                if let selection, !result.lines.contains(where: { $0.number == selection }) { self.selection = nil }
                busy = false; applyPendingLine()
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func selectOriginalLine(_ number: Int) {
        pendingLine = max(1, number)
        if !busy, snapshot != nil { applyPendingLine() }
    }
    private func applyPendingLine() {
        guard let number = pendingLine else { return }
        pendingLine = nil
        guard !lines.isEmpty else { selection = nil; navigationMessage = "The previous file has no lines."; return }
        let selected = min(number, lines.count)
        goTo = String(selected); selection = selected; navigationMessage = "Line \(selected)"
    }
    func showLog(_ line: GitBlameLine) { onLog?(line.filename, line.hash) }
    func copyLogMessage(_ hash: String) {
        let request = generation
        clipboardGeneration += 1; let clipboardRequest = clipboardGeneration
        copyingLog = true; error = nil
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let text = try await repository.commitLogText(revision: hash)
                guard request == generation, clipboardRequest == clipboardGeneration else { return }
                copy(text)
            } catch {
                if request == generation, clipboardRequest == clipboardGeneration { self.error = error.localizedDescription; copyingLog = false }
            }
        }
    }
    func copy(_ text: String) {
        clipboardGeneration += 1; copyingLog = false
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
    func findLine(previous: Bool) {
        guard !find.isEmpty, !lines.isEmpty else { return }
        let start = selection.map { $0 - 1 } ?? (previous ? 0 : -1), count = lines.count
        for offset in 1...count {
            let index = ((start + (previous ? -offset : offset)) % count + count) % count
            let line = lines[index]
            if [line.hash, line.author, line.source].contains(where: { $0.range(of: find, options: matchCase ? [] : .caseInsensitive) != nil }) {
                selection = line.number; navigationMessage = "Line \(line.number)"; return
            }
        }
        navigationMessage = "No match"
    }
    func goToLine() {
        guard let number = Int(goTo), number > 0, number <= lines.count else { navigationMessage = "Enter a line from 1 to \(lines.count)."; return }
        selection = number; navigationMessage = "Line \(number)"
    }
}

private struct BlameDialog: View {
    @ObservedObject var model: BlameWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Ignore whitespace", isOn: $model.ignoreWhitespace)
                Toggle("Detect moved lines", isOn: $model.detectMoved)
                Toggle("Detect copied lines", isOn: $model.detectCopied)
                Button("Reload") { model.reload() }
                Spacer(); Toggle("Colorize by age", isOn: $model.colorAge)
            }.disabled(model.busy)
            HStack {
                TextField("Find revision, author or source", text: $model.find).onSubmit { model.findLine(previous: false) }
                Toggle("Match case", isOn: $model.matchCase)
                Button("Previous") { model.findLine(previous: true) }
                Button("Next") { model.findLine(previous: false) }.keyboardShortcut("g", modifiers: .command)
                TextField("Line", text: $model.goTo).frame(width: 70).onSubmit { model.goToLine() }
                Button("Go To Line") { model.goToLine() }
            }.disabled(model.busy)
            if model.busy { ProgressView("Reading annotations…").controlSize(.small) }
            if model.loadingParents { ProgressView("Reading previous revisions…").controlSize(.small) }
            if model.copyingLog { ProgressView("Reading log message for clipboard…").controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            BlameTable(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            if let line = model.selectedLine {
                Text("\(line.hash) • \(line.author) <\(line.email)>").font(.system(size: 11)).textSelection(.enabled)
                Text("\(line.summary)\nOrigin: \(line.filename), line \(line.originalLine)").font(.system(size: 11)).textSelection(.enabled)
            }
            Text("\(model.lines.count) lines • \(model.navigationMessage)").font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(12)
    }
}

private struct BlameTable: NSViewRepresentable {
    @ObservedObject var model: BlameWindowModel
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = BlameTableView(); table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.onMarginClick = { [weak coordinator = context.coordinator] row in coordinator?.model.highlight(row) }
        table.onContextMenu = { [weak coordinator = context.coordinator] row, event in
            guard let coordinator, coordinator.table != nil, coordinator.model.lines.indices.contains(row), !coordinator.model.busy else { return }
            coordinator.model.prepareParentMenu(number: row + 1) { [weak coordinator] in
                guard let coordinator, let table = coordinator.table, let menu = table.menu, table.window?.isVisible == true else { return }
                NSMenu.popUpContextMenu(menu, with: event, for: table)
            }
        }
        table.onHover = { [weak coordinator = context.coordinator] row in
            guard let model = coordinator?.model else { return }
            let number = row.map { $0 + 1 }
            if model.hoveredLine != number { model.hoveredLine = number }
        }
        table.rowHeight = 22; table.intercellSpacing = NSSize(width: 6, height: 0)
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsMultipleSelection = false
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.showLog)
        for (id, title, width) in [("revision", "Revision", 100.0), ("author", "Author", 150), ("date", "Date", 145), ("line", "Line", 55), ("source", "Source", 1500)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; column.minWidth = 40; table.addTableColumn(column)
        }
        table.setAccessibilityLabel("Annotated source")
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        context.coordinator.table = table
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        if coordinator.revision != model.snapshot?.revision {
            coordinator.revision = model.snapshot?.revision
            let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let width = model.lines.reduce(CGFloat(600)) { max($0, ($1.source as NSString).size(withAttributes: [.font: font]).width + 24) }
            table.tableColumns.last?.width = width
        }
        table.reloadData()
        if let number = model.selection {
            let row = number - 1
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row) }
        } else { table.deselectAll(nil) }
        coordinator.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
        var model: BlameWindowModel
        weak var table: NSTableView?
        var updating = false
        var revision: String?
        init(_ model: BlameWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.lines.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }; model.selection = table.selectedRow >= 0 ? table.selectedRow + 1 : nil
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < model.lines.count else { return nil }; let line = model.lines[row]
            let id = tableColumn?.identifier.rawValue ?? "source"
            var source = line.source
            while source.hasSuffix("\r") { source.removeLast() }
            if row == 0, source.hasPrefix("\u{feff}") { source.removeFirst() }
            let value: String
            switch id {
            case "revision": value = String(line.hash.prefix(8))
            case "author": value = line.author
            case "date": value = DateFormatter.localizedString(from: line.date, dateStyle: .short, timeStyle: .short)
            case "line": value = String(line.number)
            default: value = source
            }
            let label = NSTextField(labelWithString: value); label.font = id == "source" || id == "revision" ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            label.lineBreakMode = .byClipping; label.maximumNumberOfLines = 1
            label.toolTip = "\(line.hash)\n\(line.author)\n\(line.summary)\n\(line.filename):\(line.originalLine)"
            label.textColor = [1, 2].contains(model.highlightKind(line)) ? .alternateSelectedControlTextColor : .labelColor
            return label
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = BlameRowView()
            guard row < model.lines.count else { return view }
            let dark = tableView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let old = dark ? [32, 32, 32] : [255, 255, 255], new = dark ? [80, 80, 0] : [255, 255, 80]
            var slider = 0
            if model.colorAge, let rank = model.ranks[model.lines[row].hash] {
                slider = min(100, max(0, (model.historyCount - rank) * 100 / (model.historyCount + 1)))
            }
            func component(_ index: Int) -> CGFloat { CGFloat((new[index] * slider + old[index] * (100 - slider)) / 100) / 255 }
            view.ageColor = NSColor(srgbRed: component(0), green: component(1), blue: component(2), alpha: 1)
            switch model.highlightKind(model.lines[row]) {
            case 1: view.ageColor = dark ? NSColor(srgbRed: 0, green: 30.0 / 255, blue: 80.0 / 255, alpha: 1) : .selectedContentBackgroundColor
            case 2:
                let selected = dark ? NSColor(srgbRed: 0, green: 30.0 / 255, blue: 80.0 / 255, alpha: 1) : .selectedContentBackgroundColor
                let highlightText = dark ? NSColor(srgbRed: 240.0 / 255, green: 240.0 / 255, blue: 240.0 / 255, alpha: 1) : .white
                view.ageColor = selected.blended(withFraction: dark ? 0.15 : 0.35, of: highlightText) ?? selected
            case 3, 4:
                let percentage = model.highlightKind(model.lines[row]) == 3 ? 20 : 10
                let level = ((dark ? 240 : 0) * percentage + (dark ? 32 : 255) * (100 - percentage)) / 100
                view.ageColor = NSColor(srgbRed: CGFloat(level) / 255, green: CGFloat(level) / 255, blue: CGFloat(level) / 255, alpha: 1)
            default: break
            }
            view.revisionHighlighted = [1, 2].contains(model.highlightKind(model.lines[row]))
            return view
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let selectedLine = model.selectedLine else { return }
            if model.loadingParents {
                let loading = NSMenuItem(title: "Reading previous revisions…", action: nil, keyEquivalent: ""); loading.isEnabled = false; menu.addItem(loading)
            } else if !model.parentChoices.isEmpty {
                let originalLine = selectedLine.originalLine
                func addCommand(title: String, action: Selector, icon: MenuIcon, enabled: Bool) {
                    func item(_ choice: GitBlameParentComparison, title: String) -> NSMenuItem {
                        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                        item.target = self; item.image = icon.image()
                        item.representedObject = BlameParentMenuTarget(choice: choice, originalLine: originalLine)
                        item.isEnabled = enabled; return item
                    }
                    if model.parentChoices.count == 1 { menu.addItem(item(model.parentChoices[0], title: title)) }
                    else {
                        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: ""); parent.image = icon.image()
                        let submenu = NSMenu(); submenu.autoenablesItems = false
                        for choice in model.parentChoices { submenu.addItem(item(choice, title: "Parent \(choice.parentNumber) (\(choice.revision.prefix(8)))")) }
                        parent.submenu = submenu; menu.addItem(parent)
                    }
                }
                addCommand(title: "Blame previous revision", action: #selector(blamePrevious(_:)), icon: .blame, enabled: model.onPrevious != nil)
                addCommand(title: "Show changes", action: #selector(showChanges(_:)), icon: .compare, enabled: model.onChanges != nil)
            }
            let log = NSMenuItem(title: "Show log", action: #selector(showLog), keyEquivalent: "")
            log.target = self; log.image = MenuIcon.log.image(); log.isEnabled = model.onLog != nil; menu.addItem(log)
            menu.addItem(.separator())
            for (title, action, icon) in [("Copy revision", #selector(copyRevision), MenuIcon.copy), ("Copy log message", #selector(copyLogMessage(_:)), .copy), ("Copy source line", #selector(copySource), .copy)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon.image()
                item.representedObject = selectedLine.hash; menu.addItem(item)
            }
        }
        @objc func showLog() { if let line = model.selectedLine { model.showLog(line) } }
        @objc func showChanges(_ sender: NSMenuItem) {
            if let target = sender.representedObject as? BlameParentMenuTarget { model.onChanges?(target.choice.comparison) }
        }
        @objc func blamePrevious(_ sender: NSMenuItem) {
            if let target = sender.representedObject as? BlameParentMenuTarget {
                model.onPrevious?(target.choice.path, target.choice.revision, target.originalLine)
            }
        }
        @objc func copyLogMessage(_ sender: NSMenuItem) {
            if let hash = sender.representedObject as? String { model.copyLogMessage(hash) }
        }
        @objc func copyRevision() { if let line = model.selectedLine { model.copy(line.hash) } }
        @objc func copySource() { if let line = model.selectedLine { model.copy(line.source) } }
    }
}

private final class BlameTableView: NSTableView {
    var onMarginClick: (Int) -> Void = { _ in }
    var onContextMenu: (Int, NSEvent) -> Void = { _, _ in }
    var onHover: (Int?) -> Void = { _ in }
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), row = row(at: point), column = column(at: point)
        if event.modifierFlags.contains(.control) { onContextMenu(row, event); return }
        super.mouseDown(with: event)
        if event.clickCount == 1, row >= 0, (0...2).contains(column) { onMarginClick(row) }
    }
    override func rightMouseDown(with event: NSEvent) {
        onContextMenu(row(at: convert(event.locationInWindow, from: nil)), event)
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil), row = row(at: point), column = column(at: point)
        onHover(row >= 0 && (0...2).contains(column) ? row : nil)
        super.mouseMoved(with: event)
    }
    override func mouseExited(with event: NSEvent) { onHover(nil); super.mouseExited(with: event) }
}

private final class BlameRowView: NSTableRowView {
    var ageColor: NSColor = .textBackgroundColor
    var revisionHighlighted = false
    override func drawBackground(in dirtyRect: NSRect) {
        ageColor.setFill(); dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        if revisionHighlighted { ageColor.setFill(); dirtyRect.fill() }
        else { super.drawSelection(in: dirtyRect) }
    }
}
