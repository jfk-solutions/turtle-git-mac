import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class LogWindowController: NSWindowController, NSWindowDelegate {
    let model: LogWindowModel
    var onClosed: () -> Void = {}
    private var selectionCompletion: ((LogEntry?) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, onChoose: ((LogEntry?) -> Void)? = nil) {
        model = LogWindowModel(repository: repository, access: access, selecting: onChoose != nil)
        selectionCompletion = onChoose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Log Messages – TurtleGit"
        window.minSize = NSSize(width: 1080, height: 700)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: LogDialog(model: model))
        super.init(window: window)
        window.delegate = self
        window.setContentSize(NSSize(width: 1120, height: 780))
        window.center()
        model.close = { [weak self] in
            guard let self else { return }
            if self.model.selecting { self.finishSelection(nil) } else { self.window?.close() }
        }
        model.finishSelection = { [weak self] revision in self?.finishSelection(revision) }
        model.reload()
    }
    private func finishSelection(_ revision: LogEntry?) {
        guard let completion = selectionCompletion else { return }; selectionCompletion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }
        completion(revision)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.selecting { finishSelection(nil); return false }; return true
    }
    func windowWillClose(_ notification: Notification) {
        let completion = selectionCompletion; selectionCompletion = nil
        completion?(nil); onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

enum LogRevisionCommand: String, Identifiable {
    case branch = "Create branch at this version…"
    case tag = "Create tag at this version…"
    case checkout = "Switch/Checkout to this…"
    case push = "Push…"
    case reset = "Reset current branch to this…"
    case cherryPick = "Cherry Pick this commit…"
    case revert = "Revert changes by this commit…"
    var id: String { rawValue }
}

struct LogCommandRequest: Identifiable {
    let id = UUID()
    let command: LogRevisionCommand
    let revision: LogEntry
}

@MainActor final class LogWindowModel: ObservableObject {
    let repository: GitRepository
    let selecting: Bool
    // Keep the security-scoped grant alive if the main repository window changes.
    private let access: RepositoryAccessLease?
    @Published var entries: [LogEntry] = []
    @Published var graph: [CommitGraphRow] = []
    @Published var selected = Set<String>()
    @Published var files: [CommitFile] = []
    @Published var selectedFiles = Set<String>()
    @Published var allBranches = false
    @Published var endRevision: String?
    @Published var historyPaths: [String] = []
    @Published var showWholeProject = true
    @Published var search = ""
    @Published var filterPaths = ""
    @Published var from = Date(timeIntervalSince1970: 0)
    @Published var to = Date()
    @Published var useDates = false
    @Published var busy = false
    @Published var bare = true
    @Published var error: String?
    @Published var patch: String?
    @Published var commandRequest: LogCommandRequest?
    private var generation = 0
    private var detailGeneration = 0
    private var limit = 200
    var onCreateReference: (Bool, String) -> Void = { _, _ in }
    var onPush: (String) -> Void = { _ in }
    var onCheckout: (String) -> Void = { _ in }
    var onReset: (String) -> Void = { _ in }
    var onCompare: ((ComparisonRevision, ComparisonRevision) -> Void)?
    var onFileCompare: ((ComparisonRevision, ComparisonRevision, [String]) -> Void)?
    var close: () -> Void = {}
    var finishSelection: (LogEntry?) -> Void = { _ in }
    var revisions: [LogEntry] { entries.filter { selected.contains($0.hash) } }
    var revision: LogEntry? { revisions.count == 1 ? revisions.first : nil }
    var visibleFiles: [CommitFile] { files.filter { filterPaths.isEmpty || $0.path.localizedCaseInsensitiveContains(filterPaths) } }
    var message: String {
        guard let revision else { return selected.isEmpty ? "Select a revision to see its commit message and changed files." : "\(selected.count) revisions selected." }
        return "SHA-1: \(revision.hash)\nAuthor: \(revision.author) <\(revision.email)>\nDate: \(revision.date)\n" +
            (revision.parents.isEmpty ? "" : "Parents: \(revision.parents.joined(separator: " "))\n") + "\n" + revision.message
    }
    init(repository: GitRepository, access: RepositoryAccessLease?, selecting: Bool = false) { self.repository = repository; self.access = access; self.selecting = selecting }
    func accept() {
        if selecting { guard !busy, let revision else { return }; finishSelection(revision) }
        else { close() }
    }
    func setPathScope(_ paths: [String]) {
        let scope = paths.contains(".") ? [] : paths
        guard historyPaths != scope || showWholeProject != scope.isEmpty else { return }
        historyPaths = scope; showWholeProject = scope.isEmpty; reload()
    }
    func reload(more: Bool = false) {
        if more { limit += 200 } else { limit = 200 }
        generation += 1; let request = generation
        var options = HistoryOptions(); options.endRevision = endRevision; options.allBranches = allBranches; options.search = search; options.limit = limit
        if !showWholeProject { options.paths = historyPaths }
        if useDates { options.since = Calendar.current.startOfDay(for: from); options.until = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) }
        busy = true
        Task {
            do {
                let bare = try await repository.isBare()
                let result = try await repository.history(options: options)
                guard request == generation else { return }
                self.bare = bare
                entries = result; graph = CommitGraph.layout(result)
                selected.formIntersection(Set(result.map(\.hash)))
                if selected.isEmpty, let first = result.first { selected = [first.hash] }
                busy = false; select(selected)
            } catch { if request == generation { self.error = error.localizedDescription; busy = false } }
        }
    }
    func select(_ hashes: Set<String>) {
        selected = hashes; selectedFiles = []; files = []
        detailGeneration += 1; let request = detailGeneration
        guard let revision else { return }
        Task {
            do {
                let result = try await repository.files(in: revision)
                guard request == detailGeneration else { return }
                files = result
            } catch { if request == detailGeneration { self.error = error.localizedDescription } }
        }
    }
    func request(_ command: LogRevisionCommand) {
        guard !busy, let revision else { return }
        guard !bare || ![LogRevisionCommand.checkout, .cherryPick, .revert].contains(command) else { return }
        if command == .branch || command == .tag { onCreateReference(command == .tag, revision.hash); return }
        if command == .push { onPush(revision.hash); return }
        if command == .checkout { onCheckout(revision.hash); return }
        if command == .reset { onReset(revision.hash); return }
        commandRequest = LogCommandRequest(command: command, revision: revision)
    }
    func execute(_ request: LogCommandRequest, value: String) {
        if bare && [LogRevisionCommand.checkout, .cherryPick, .revert].contains(request.command) {
            error = "This operation requires a working tree."; return
        }
        let hash = request.revision.hash
        var args: [String]
        switch request.command {
        case .branch: commandRequest = nil; onCreateReference(false, hash); return
        case .tag: commandRequest = nil; onCreateReference(true, hash); return
        case .push: commandRequest = nil; onPush(hash); return
        case .checkout: commandRequest = nil; onCheckout(hash); return
        case .reset: commandRequest = nil; onReset(hash); return
        case .cherryPick: args = ["cherry-pick", hash]
        case .revert: args = ["revert", "--no-commit", hash]
        }
        commandRequest = nil; busy = true
        Task {
            do { _ = try await repository.run(args); busy = false; reload() }
            catch { self.error = error.localizedDescription; busy = false; reload() }
        }
    }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func diff(workingTree: Bool = false, path: String? = nil) {
        guard !workingTree || !bare else { return }
        let revisions = self.revisions
        guard !revisions.isEmpty else { return }
        Task {
            do {
                if revisions.count == 2, !workingTree {
                    var args = ["diff", "--no-ext-diff", "--no-color", revisions[1].hash, revisions[0].hash, "--"]
                    if let path { args.append(path) }
                    patch = try await repository.run(args).text
                } else { patch = try await repository.revisionDiff(revisions[0], path: path, workingTree: workingTree) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func compareFiles(_ ids: Set<String>, workingTree: Bool = false) {
        guard !busy, let onFileCompare, let revision, !workingTree || !bare else { return }
        let paths = files.filter { ids.contains($0.id) }.map(\.path)
        guard !paths.isEmpty else { return }
        let from: ComparisonRevision = workingTree ? .revision(revision.hash) : revision.parents.first.map { .revision($0) } ?? .emptyTree
        let to: ComparisonRevision = workingTree ? .workingTree : .revision(revision.hash)
        onFileCompare(from, to, paths)
    }
    func compare(workingTree: Bool = false) {
        guard !busy, let onCompare, !workingTree || !bare else { return }
        let chosen = revisions
        guard chosen.count == 1 || chosen.count == 2 && !workingTree else { return }
        if workingTree { onCompare(.revision(chosen[0].hash), .workingTree) }
        else if chosen.count == 2 { onCompare(.revision(chosen[1].hash), .revision(chosen[0].hash)) }
        else { onCompare(chosen[0].parents.first.map { .revision($0) } ?? .emptyTree, .revision(chosen[0].hash)) }
    }
}

struct LogDialog: View {
    @ObservedObject var model: LogWindowModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Text(model.repository.root.lastPathComponent).foregroundStyle(.blue).lineLimit(1)
                Toggle("Dates", isOn: $model.useDates).toggleStyle(.checkbox)
                DatePicker("From:", selection: $model.from, displayedComponents: .date).disabled(!model.useDates)
                DatePicker("To:", selection: $model.to, displayedComponents: .date).disabled(!model.useDates)
                TextField("Search commit messages", text: $model.search).textFieldStyle(.roundedBorder).onSubmit { model.reload() }
                Button("Search") { model.reload() }.disabled(model.busy)
            }.font(.system(size: 12))
            VSplitView {
                RevisionTable(model: model).frame(minHeight: 200, idealHeight: 350)
                OutputView(text: model.message).frame(minHeight: 110, idealHeight: 150)
                Table(model.visibleFiles, selection: $model.selectedFiles) {
                    TableColumn("Path") { file in
                        Text(file.path).foregroundStyle(.blue).help(file.oldPath.map { "Renamed from \($0)" } ?? file.path)
                    }.width(min: 260, ideal: 460)
                    TableColumn("Extension") { file in Text((file.path as NSString).pathExtension) }.width(80)
                    TableColumn("Status", value: \.status).width(95)
                    TableColumn("Lines added") { file in Text(file.added.map(String.init) ?? "–").foregroundStyle(.blue) }.width(90)
                    TableColumn("Lines removed") { file in Text(file.removed.map(String.init) ?? "–").foregroundStyle(.blue) }.width(105)
                }.frame(minHeight: 130, idealHeight: 180)
                .contextMenu(forSelectionType: String.self) { ids in
                    Button { model.compareFiles(ids) } label: { CommandLabel(title: "Compare with base", icon: .compare) }.disabled(ids.isEmpty || model.onFileCompare == nil || model.busy)
                    Button { model.selectedFiles = ids; fileDiff() } label: { CommandLabel(title: "Show changes as unified diff", icon: .unifiedDiff) }.disabled(ids.count != 1 || model.busy)
                    Button { model.compareFiles(ids, workingTree: true) } label: { CommandLabel(title: "Compare with working tree", icon: .compare) }.disabled(ids.isEmpty || model.bare || model.onFileCompare == nil || model.busy)
                    Divider()
                    Button { model.copy(model.files.filter { ids.contains($0.id) }.map(\.path).joined(separator: "\n")) } label: { CommandLabel(title: "Copy paths to clipboard", icon: .copy) }.disabled(ids.isEmpty)
                } primaryAction: { ids in
                    model.selectedFiles = ids; model.compareFiles(ids)
                }
            }
            Text("Showing \(model.entries.count) revision(s) • \(model.selected.count) revision(s) selected • \(model.files.count) changed file(s) (merge changes against first parent)")
                .font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Toggle("All Branches", isOn: $model.allBranches).toggleStyle(.checkbox).disabled(model.endRevision != nil).onChange(of: model.allBranches) { _ in model.reload() }
                if !model.historyPaths.isEmpty {
                    Toggle("Show Whole Project", isOn: $model.showWholeProject).toggleStyle(.checkbox).onChange(of: model.showWholeProject) { _ in model.reload() }
                        .help(model.historyPaths.joined(separator: "\n"))
                }
                Spacer()
                TextField("Filter paths", text: $model.filterPaths).textFieldStyle(.roundedBorder).frame(maxWidth: 430)
            }
            HStack {
                Button("Refresh") { model.reload() }.disabled(model.busy)
                Button("Show next 200") { model.reload(more: true) }.disabled(model.busy)
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-showlog.html")!) }
                Button("OK") { model.accept() }.disabled(model.selecting && (model.busy || model.revision == nil)).keyboardShortcut(.defaultAction)
                if model.selecting { Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction) }
            }
        }.padding(12).frame(minWidth: 1040, minHeight: 650)
        .alert("Git operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(item: $model.commandRequest) { request in LogRevisionDialog(model: model, request: request) }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack {
                Text("Unified Diff").font(.headline)
                OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520)
                HStack { Spacer(); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }
            }.padding(12)
        }
    }
    func fileDiff(workingTree: Bool = false) {
        guard let path = model.selectedFiles.first else { return }
        model.diff(workingTree: workingTree, path: path)
    }
}

struct RevisionTable: NSViewRepresentable {
    @ObservedObject var model: LogWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = HistoryTableView()
        table.rowHeight = 24; table.intercellSpacing = NSSize(width: 4, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("graph", "Graph", 65.0), ("hash", "SHA-1", 92.0), ("message", "Message", 420.0), ("author", "Author", 140.0), ("date", "Date", 170.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            column.minWidth = id == "graph" ? 38 : 70; table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.doubleAction = #selector(Coordinator.showDiff); table.target = context.coordinator
        table.menu = NSMenu(); table.menu?.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model
        guard let table = coordinator.table else { return }
        coordinator.updating = true
        let signature = model.entries.map { $0.hash + $0.references.map(\.name).joined() + String($0.isHead) }
        if signature != coordinator.signature {
            coordinator.signature = signature
            table.reloadData()
            if let column = table.tableColumns.first {
                column.width = CGFloat(max(65, min(240, (model.graph.map(\.width).max() ?? 1) * 14 + 24)))
            }
        }
        let indices = IndexSet(model.entries.enumerated().compactMap { model.selected.contains($0.element.hash) ? $0.offset : nil })
        if table.selectedRowIndexes != indices { table.selectRowIndexes(indices, byExtendingSelection: false) }
        coordinator.updating = false
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var model: LogWindowModel
        weak var table: NSTableView?
        var updating = false
        var signature: [String] = []
        init(model: LogWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.entries.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            let entry = model.entries[row]
            if column?.identifier.rawValue == "graph" {
                let view = GraphCell(); view.graph = model.graph[row]; view.setAccessibilityLabel("\(entry.parents.count) parents, graph lane \(model.graph[row].column + 1)")
                return view
            }
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1
            text.font = .systemFont(ofSize: 12, weight: entry.isHead ? .bold : .regular)
            switch column?.identifier.rawValue {
            case "hash": text.stringValue = String(entry.hash.prefix(10)); text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            case "author": text.stringValue = entry.author
            case "date": text.stringValue = entry.date.replacingOccurrences(of: "T", with: " ").prefix(19).description
            default:
                let label = NSMutableAttributedString()
                for reference in entry.references {
                    let color: NSColor = reference.isCurrent ? .systemRed : reference.name.hasPrefix("refs/tags/") ? .systemYellow : reference.name.hasPrefix("refs/remotes/") ? .systemOrange : .systemGreen
                    label.append(NSAttributedString(string: " \(reference.label) ", attributes: [.backgroundColor: color.withAlphaComponent(0.3), .font: NSFont.systemFont(ofSize: 11, weight: .medium)]))
                    label.append(NSAttributedString(string: " "))
                }
                label.append(NSAttributedString(string: entry.subject, attributes: [.font: text.font!]))
                text.attributedStringValue = label
            }
            text.toolTip = entry.subject + "\n" + entry.hash
            let cell = NSTableCellView(); cell.addSubview(text); cell.textField = text
            text.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            let hashes = Set(table.selectedRowIndexes.compactMap { model.entries.indices.contains($0) ? model.entries[$0].hash : nil })
            if hashes != model.selected { model.select(hashes) }
        }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            func item(_ title: String, _ selector: Selector, icon: MenuIcon, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.image = icon.image(); item.target = self; item.isEnabled = enabled; menu.addItem(item)
            }
            menu.autoenablesItems = false
            let one = model.revision != nil, two = model.revisions.count == 2
            item("Compare with working tree", #selector(workingDiff), icon: .compare, enabled: one && !model.bare && !model.busy && model.onCompare != nil)
            item(two ? "Compare revisions" : "Compare with previous revision", #selector(compare), icon: .compare, enabled: (one || two) && !model.busy && model.onCompare != nil)
            item("Show changes as unified diff", #selector(showDiff), icon: .unifiedDiff, enabled: one || two)
            menu.addItem(.separator())
            item("Reset current branch to this…", #selector(reset), icon: .reset, enabled: one && !model.busy)
            item("Switch/Checkout to this…", #selector(checkout), icon: .checkout, enabled: one && !model.busy && !model.bare)
            item("Create branch at this version…", #selector(branch), icon: .branch, enabled: one && !model.busy)
            item("Create tag at this version…", #selector(tag), icon: .tag, enabled: one && !model.busy)
            item("Push…", #selector(push), icon: .push, enabled: one && !model.busy)
            menu.addItem(.separator())
            item("Revert changes by this commit…", #selector(revert), icon: .revert, enabled: one && !model.busy && !model.bare && model.revision?.parents.count == 1)
            item("Cherry Pick this commit…", #selector(cherryPick), icon: .cherryPick, enabled: one && !model.busy && !model.bare && model.revision?.parents.count == 1)
            menu.addItem(.separator())
            let clipboard = NSMenu(title: "Copy to clipboard")
            clipboard.autoenablesItems = false
            for (title, selector) in [("Full log details", #selector(copyDetails)), ("Hashes", #selector(copyHashes)),
                ("Authors", #selector(copyAuthors)), ("Author names", #selector(copyAuthorNames)),
                ("Author emails", #selector(copyAuthorEmails)), ("Subjects", #selector(copySubjects)), ("Messages", #selector(copyMessages))] {
                let child = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                child.target = self; child.image = MenuIcon.copy.image(); child.isEnabled = !model.selected.isEmpty
                clipboard.addItem(child)
            }
            let parent = NSMenuItem(title: "Copy to clipboard", action: nil, keyEquivalent: "")
            parent.image = MenuIcon.copy.image(); parent.submenu = clipboard; menu.addItem(parent)
        }
        @objc func reset() { model.request(.reset) }
        @objc func push() { model.request(.push) }
        @objc func checkout() { model.request(.checkout) }
        @objc func branch() { model.request(.branch) }
        @objc func tag() { model.request(.tag) }
        @objc func revert() { model.request(.revert) }
        @objc func cherryPick() { model.request(.cherryPick) }
        @objc func showDiff() { model.diff() }
        @objc func compare() { model.compare() }
        @objc func workingDiff() { model.compare(workingTree: true) }
        @objc func copyAuthors() { model.copy(model.revisions.map { "\($0.author) <\($0.email)>" }.joined(separator: "\n")) }
        @objc func copyAuthorNames() { model.copy(model.revisions.map(\.author).joined(separator: "\n")) }
        @objc func copyAuthorEmails() { model.copy(model.revisions.map(\.email).joined(separator: "\n")) }
        @objc func copySubjects() { model.copy(model.revisions.map(\.subject).joined(separator: "\n")) }
        @objc func copyHashes() { model.copy(model.revisions.map(\.hash).joined(separator: "\n")) }
        @objc func copyMessages() { model.copy(model.revisions.map(\.message).joined(separator: "\n\n")) }
        @objc func copyDetails() { model.copy(model.revisions.map { "\($0.hash)\n\($0.author) <\($0.email)>\n\($0.date)\n\n\($0.message)" }.joined(separator: "\n\n")) }
    }
}

final class HistoryTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        menu?.update()
        return menu
    }
}

final class GraphCell: NSView {
    var graph: CommitGraphRow? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let graph else { return }
        let colors: [NSColor] = [.systemBlue, .systemRed, .systemGreen, .systemOrange, .systemPurple, .systemTeal]
        func point(_ column: Int, _ y: CGFloat) -> NSPoint { NSPoint(x: 12 + CGFloat(column) * 14, y: y) }
        let mid = bounds.height / 2
        for edge in graph.edges {
            let path = NSBezierPath(); path.lineWidth = 1.5
            let start = point(edge.from, edge.startsAtNode ? mid : 0)
            let end = point(edge.to, edge.endsAtNode ? mid : bounds.height)
            path.move(to: start)
            if edge.from == edge.to { path.line(to: end) }
            else { path.curve(to: end, controlPoint1: NSPoint(x: start.x, y: (start.y + end.y) / 2), controlPoint2: NSPoint(x: end.x, y: (start.y + end.y) / 2)) }
            colors[edge.color % colors.count].setStroke(); path.stroke()
        }
        let position = point(graph.column, mid)
        let rect = NSRect(x: position.x - 3.5, y: position.y - 3.5, width: 7, height: 7)
        colors[graph.color % colors.count].setFill()
        (graph.junction ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)).fill()
    }
}

struct LogRevisionDialog: View {
    @ObservedObject var model: LogWindowModel
    let request: LogCommandRequest
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.command.rawValue.replacingOccurrences(of: "…", with: "")).font(.title2)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text("Version: \(request.revision.hash)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(request.revision.subject)
            if request.command == .branch || request.command == .tag {
                TextField(request.command == .branch ? "Branch name" : "Tag name", text: $value).textFieldStyle(.roundedBorder)
            }
            if request.command == .revert {
                Text("Apply the reverse changes to the index and working tree without committing. Review and commit them from the Commit dialog.").foregroundStyle(.secondary)
            } else if request.command == .cherryPick {
                Text("Apply this commit to the current branch. Conflicts may require resolution before continuing.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.commandRequest = nil }.keyboardShortcut(.cancelAction)
                Button("OK") { model.execute(request, value: value) }.keyboardShortcut(.defaultAction)
                    .disabled((request.command == .branch || request.command == .tag) && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 550)
    }
}
