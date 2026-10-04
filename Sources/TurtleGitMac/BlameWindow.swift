import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class BlameWindowController: NSWindowController, NSWindowDelegate {
    let model: BlameWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String) {
        model = BlameWindowModel(repository: repository, access: access, path: path, revision: revision)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(path) at \(revision.prefix(7)) – Blame – TurtleGit"
        window.minSize = NSSize(width: 820, height: 400); window.isReleasedWhenClosed = false
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
    @Published var snapshot: GitBlameSnapshot?
    @Published var busy = false
    @Published var error: String?
    @Published var ignoreWhitespace = false
    @Published var detectMoved = false
    @Published var detectCopied = false
    @Published var colorAge = true
    @Published var selection: Int?
    @Published var find = ""
    @Published var matchCase = false
    @Published var goTo = ""
    @Published var navigationMessage = ""
    var ranks: [String: Int] = [:]
    var historyCount = 0
    var onLog: ((String, String) -> Void)?
    var lines: [GitBlameLine] { snapshot?.lines ?? [] }
    var selectedLine: GitBlameLine? { selection.flatMap { index in lines.first { $0.number == index } } }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String, revision: String) {
        self.repository = repository; self.access = access; self.path = path; self.revision = revision
    }
    func invalidate() { generation += 1 }
    func reload() {
        guard !busy else { return }
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
                historyCount = history.count; revision = result.revision; snapshot = result
                if let selection, !result.lines.contains(where: { $0.number == selection }) { self.selection = nil }
                busy = false
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func showLog(_ line: GitBlameLine) { onLog?(line.filename, line.hash) }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
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
        let table = NSTableView(); table.delegate = context.coordinator; table.dataSource = context.coordinator
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
            label.textColor = .labelColor
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
            return view
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table else { return }
            if table.clickedRow >= 0 { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
            guard model.selectedLine != nil else { return }
            for (title, action, icon) in [("Show log", #selector(showLog), MenuIcon.log), ("Copy revision", #selector(copyRevision), .copy), ("Copy source line", #selector(copySource), .copy)] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; item.image = icon.image()
                item.isEnabled = action != #selector(showLog) || model.onLog != nil; menu.addItem(item)
            }
        }
        @objc func showLog() { if let line = model.selectedLine { model.showLog(line) } }
        @objc func copyRevision() { if let line = model.selectedLine { model.copy(line.hash) } }
        @objc func copySource() { if let line = model.selectedLine { model.copy(line.source) } }
    }
}

private final class BlameRowView: NSTableRowView {
    var ageColor: NSColor = .textBackgroundColor
    override func drawBackground(in dirtyRect: NSRect) {
        ageColor.setFill(); dirtyRect.fill()
    }
}
