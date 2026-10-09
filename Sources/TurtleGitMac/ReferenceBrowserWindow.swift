import AppKit
import SwiftUI
import TurtleGitCore

private final class ReferenceBrowserNativeWindow: NSWindow {
    var refresh: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if event.keyCode == 96 { refresh(); return true }; return super.performKeyEquivalent(with: event) }
}
@MainActor final class ReferenceBrowserWindowController: NSWindowController, NSWindowDelegate {
    let model: ReferenceBrowserWindowModel
    var onClosed: () -> Void = {}
    private(set) var reflog: ReferenceLogWindowController?
    private(set) var descriptionEditor: ReferenceDescriptionWindowController?
    var presentDescription: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    var presentReflog: (NSWindow, NSWindow) -> Bool = { owner, child in guard owner.attachedSheet == nil else { return false }; owner.beginSheet(child); return true }
    private var completion: ((String?) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, initial: String, preferences: UserDefaults = .standard, onChoose: @escaping (String?) -> Void) {
        model = ReferenceBrowserWindowModel(repository: repository, access: access, initial: initial, preferences: preferences); completion = onChoose
        let window = ReferenceBrowserNativeWindow(contentRect: .init(x: 0, y: 0, width: 1130, height: 660), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Browse references – TurtleGit"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 940, height: 450)
        window.contentViewController = NSHostingController(rootView: ReferenceBrowserDialog(model: model).defaultAppStorage(preferences))
        super.init(window: window); window.delegate = self; window.center()
        window.refresh = { [weak model] in model?.load() }
        model.onReflog = { [weak self] name in self?.showReflog(name) }
        model.onEditDescription = { [weak self] in self?.editDescription() }
        model.finish = { [weak self] reference in self?.finish(reference) }
        DialogGeometry.attach(window, identifier: "BrowseRefs", legacyName: "BrowseRefs")
    }
    private func showReflog(_ reference: String) {
        guard let owner = window, owner.attachedSheet == nil, !model.busy, !model.hasChild, !model.closed else { return }
        model.hasChild = true
        let child = ReferenceLogWindowController(repository: model.repository, access: model.access, reference: reference, preferences: model.preferences)
        reflog = child
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.reflog === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.reflog = nil; self.model.hasChild = false
        }
        guard let window = child.window, presentReflog(owner, window) else { child.close(); reflog = nil; model.hasChild = false; return }
    }
    func editDescription() {
        guard let owner = window, owner.attachedSheet == nil, model.canEditDescription,
              let chosen = model.chosen,
              let branch = GitReferenceName.removingPrefix("refs/heads/", from: chosen.name.rawValue) else { return }
        model.hasChild = true
        let repository = model.repository, access = model.access
        let child = ReferenceDescriptionWindowController(text: chosen.description, preferences: model.preferences) { text, cancellation in
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            try await repository.updateBranchDescription(branch, message: text, cancellation: cancellation)
        }
        descriptionEditor = child
        child.onClosed = { [weak self, weak child] in
            guard let self, let child, self.descriptionEditor === child else { return }
            if let window = child.window, window.sheetParent === self.window { self.window?.endSheet(window) }
            self.descriptionEditor = nil; self.model.hasChild = false
            if child.saved && !self.model.closed { self.model.load() }
        }
        guard let window = child.window, presentDescription(owner, window) else { child.close(); return }
        child.focusEditor()
    }
    func abandonPresentation() { completion = nil; close() }
    private func finish(_ reference: String?) {
        guard let completion, !model.hasChild, window?.attachedSheet == nil else { return }; self.completion = nil
        if let window { window.sheetParent?.endSheet(window); window.close() }; completion(reference)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { guard !model.hasChild, sender.attachedSheet == nil else { return false }; finish(nil); return false }
    func windowWillClose(_ notification: Notification) { model.invalidate(); descriptionEditor?.close(); descriptionEditor = nil; reflog?.close(); reflog = nil; model.hasChild = false; let completion = completion; self.completion = nil; completion?(nil); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ReferenceBrowserWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    private let initial: String
    private var token: OperationCancellation?
    private var invalidated = false
    private(set) var initialFocusPending = true
    var closed: Bool { invalidated }
    @Published var hasChild = false
    @Published private(set) var bare = false
    private(set) var folders: [GitReferenceName] = ["refs"]
    @Published private(set) var snapshot: ReferenceBrowserSnapshot?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var folder: GitReferenceName = "refs"
    @Published var selected: GitReferenceName?
    @Published var query = ""
    static let allFields: HistorySearchFields = [.referenceNames, .subject, .authors, .revisions]
    @Published var fields: HistorySearchFields = allFields
    @Published var mergeFilter = ReferenceBrowserMergeFilter.all
    @Published var nested: Bool
    @Published var sortColumn = "name"
    @Published var descending = false
    var finish: (String?) -> Void = { _ in }
    var onEditDescription: (() -> Void)?
    var canEditDescription: Bool { canAccept && chosen?.objectType == "commit" && chosen.flatMap { GitReferenceName.removingPrefix("refs/heads/", from: $0.name.rawValue) } != nil }
    var onLog: ((String) -> Void)?
    var onReflog: ((String) -> Void)?
    var onBrowse: ((String) -> Void)?
    var onCompare: ((String) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, initial: String, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.initial = initial; self.preferences = preferences
        nested = preferences.object(forKey: "RefBrowserIncludeNestedRefs") as? Bool ?? true
    }
    var rows: [ReferenceBrowserRow] {
        (snapshot?.rows(folder: folder, nested: nested, query: query, fields: fields) ?? []).sorted { lhs, rhs in
            let comparison: ComparisonResult
            if sortColumn == "authorDate" || sortColumn == "committerDate" {
                let a = sortColumn == "authorDate" ? lhs.reference.authorDate ?? 0 : lhs.reference.committerDate ?? 0
                let b = sortColumn == "authorDate" ? rhs.reference.authorDate ?? 0 : rhs.reference.committerDate ?? 0
                comparison = a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending
            } else if sortColumn == "hash" { comparison = lhs.reference.hash.compare(rhs.reference.hash, options: .caseInsensitive) }
            else { comparison = text(lhs, column: sortColumn).localizedStandardCompare(text(rhs, column: sortColumn)) }
            if comparison == .orderedSame { return lhs.reference.name.rawValue.utf8.lexicographicallyPrecedes(rhs.reference.name.rawValue.utf8) }
            return descending ? comparison == .orderedDescending : comparison == .orderedAscending
        }
    }
    var chosen: BrowserReference? { guard let selected else { return nil }; return rows.first { $0.reference.name == selected }?.reference }
    var canAccept: Bool { !busy && !hasChild && !invalidated && chosen != nil }
    func text(_ row: ReferenceBrowserRow, column: String) -> String {
        let ref = row.reference
        switch column {
        case "name": return row.name
        case "upstream": return ref.upstream
        case "subject": return ref.subject
        case "author": return ref.author
        case "committer": return ref.committer
        case "hash": return ref.hash
        case "description": return ref.description.replacingOccurrences(of: "\n", with: " ")
        case "authorDate", "committerDate":
            guard let epoch = column == "authorDate" ? ref.authorDate : ref.committerDate else { return "" }
            let timestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: epoch)); return HistoryDateSettings.load(defaults: preferences).format(timestamp)
        default: return ""
        }
    }
    func load() {
        guard !invalidated, !hasChild else { return }
        let requested = selected?.rawValue ?? (snapshot == nil ? initial : folder.rawValue)
        token?.cancel(); let request = OperationCancellation(); token = request; busy = true; error = nil
        let filter = mergeFilter
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.referenceBrowser(filter: filter, cancellation: request)
                let bare = try await repository.isBare()
                guard !invalidated, token === request else { return }
                let choice = result.initialSelection(requested); folders = result.folders; self.bare = bare; snapshot = result; folder = choice.folder; selected = choice.reference; refilter()
            } catch { if !invalidated, token === request, !request.isCancelled { self.error = error.localizedDescription } }
        }
    }
    func invalidate() { invalidated = true; initialFocusPending = false; token?.cancel(); token = nil; busy = false }
    func setFolder(_ folder: GitReferenceName) { guard !busy, !hasChild, folders.contains(folder) else { return }; self.folder = folder; selected = nil }
    func refilter() { if let selected, !rows.contains(where: { $0.reference.name == selected }) { self.selected = nil } }
    func nestedChanged() { preferences.set(nested, forKey: "RefBrowserIncludeNestedRefs"); load() }
    func currentBranch() { guard !busy, !hasChild, let snapshot, let branch = snapshot.currentBranch else { return }; let choice = snapshot.initialSelection(branch.rawValue); folder = choice.folder; selected = choice.reference; refilter() }
    func accept() { guard canAccept, let chosen else { return }; finish(chosen.name.rawValue) }
    func cancel() { finish(nil) }
    func focusIfReady(_ table: NSTableView) {
        guard initialFocusPending, !invalidated, !busy, !hasChild, snapshot != nil, let window = table.window, window.attachedSheet == nil else { return }
        if window.makeFirstResponder(table) { initialFocusPending = false }
    }
}
struct ReferenceBrowserDialog: View {
    @ObservedObject var model: ReferenceBrowserWindowModel
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Color.clear.frame(width: 190)
                Text("Filter:")
                ReferenceBrowserSearchField(text: $model.query).onChange(of: model.query) { _ in model.refilter() }
                Menu { ForEach([(HistorySearchFields.referenceNames, "Refname"), (.subject, "Subject"), (.authors, "Authors"), (.revisions, "SHA-1")], id: \.0.rawValue) { field, title in
                    Toggle(title, isOn: Binding(get: { model.fields.contains(field) }, set: { enabled in if enabled { model.fields.insert(field) } else { model.fields.remove(field) }; model.refilter() }))
                }; Divider(); Button("Toggle filters") { model.fields = ReferenceBrowserWindowModel.allFields.subtracting(model.fields); model.refilter() }
                } label: { CommandLabel(title: "Filter by", icon: .log) }
                Picker("Branch filter", selection: $model.mergeFilter) { ForEach(ReferenceBrowserMergeFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 170).onChange(of: model.mergeFilter) { _ in model.load() }
            }.disabled(model.busy)
            ReferenceBrowserNativeView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Toggle("Show nested refs", isOn: $model.nested).onChange(of: model.nested) { _ in model.nestedChanged() }.disabled(model.busy)
                Text("Showing \(model.rows.count) ref(s), \(model.chosen == nil ? 0 : 1) ref(s) selected").font(.system(size: 11)).foregroundStyle(.secondary)
                if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button("Current Branch") { model.currentBranch() }.disabled(model.busy || model.snapshot?.currentBranch == nil)
                Button("OK") { model.accept() }.keyboardShortcut(.defaultAction).disabled(!model.canAccept)
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-browse-ref.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(10).disabled(model.hasChild).onAppear { model.load() }
        .alert("Browse references failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct ReferenceBrowserSearchField: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.isEnabled) private var enabled
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(); field.placeholderString = "Filter references"; field.setAccessibilityLabel("Filter references")
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:)); return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        if !field.stringValue.utf8.elementsEqual(text.utf8) { field.stringValue = text }
        field.isEnabled = enabled; context.coordinator.change = { text = $0 }
    }
    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) { field.target = nil; coordinator.change = { _ in } }
    final class Coordinator: NSObject { var change: (String) -> Void = { _ in }; @objc func changed(_ sender: NSSearchField) { guard sender.isEnabled else { return }; change(sender.stringValue) } }
}
struct ReferenceBrowserNativeView: NSViewRepresentable {
    @ObservedObject var model: ReferenceBrowserWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView(); split.delegate = context.coordinator; split.isVertical = true; split.dividerStyle = .thin
        let tree = NSOutlineView(); tree.headerView = nil; tree.setAccessibilityLabel("Reference namespaces")
        let folder = NSTableColumn(identifier: .init("folder")); folder.width = 185; tree.addTableColumn(folder); tree.outlineTableColumn = folder; tree.rowHeight = 22
        let table = NSTableView(); table.rowHeight = 23; table.allowsMultipleSelection = false; table.setAccessibilityLabel("References")
        for (id, title, width) in [("name", "Branch Name", 210.0), ("upstream", "Tracked branch", 150), ("authorDate", "Last Author Date", 140), ("subject", "Last Commit", 280), ("author", "Last Author", 130), ("committerDate", "Date Last Commit", 140), ("committer", "Last Committer", 130), ("hash", "SHA-1", 170), ("description", "Description", 180)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = 70; table.addTableColumn(column)
        }
        tree.delegate = context.coordinator; tree.dataSource = context.coordinator; table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.accept)
        let menu = NSMenu(); menu.delegate = context.coordinator; table.menu = menu
        for view in [tree, table] { let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = view; split.addArrangedSubview(scroll) }
        context.coordinator.tree = tree; context.coordinator.table = table
        split.setPosition(190, ofDividerAt: 0)
        return split
    }
    func updateNSView(_ split: NSSplitView, context: Context) {
        let coordinator = context.coordinator; coordinator.model = model; coordinator.update()
        DispatchQueue.main.async { [weak coordinator, weak table = coordinator.table, weak split] in guard let coordinator, let table else { return }; if let split, !coordinator.positioned, split.bounds.width > 0 { split.setPosition(190, ofDividerAt: 0); coordinator.positioned = true }; coordinator.model.focusIfReady(table) }
    }
    static func dismantleNSView(_ split: NSSplitView, coordinator: Coordinator) { split.delegate = nil; coordinator.tree?.delegate = nil; coordinator.tree?.dataSource = nil; coordinator.table?.delegate = nil; coordinator.table?.dataSource = nil; coordinator.table?.menu?.delegate = nil }
    @MainActor final class Folder: NSObject { let key: GitReferenceName; var children: [Folder] = []; weak var parent: Folder?; init(_ key: GitReferenceName) { self.key = key } }
    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSSplitViewDelegate {
        var model: ReferenceBrowserWindowModel
        weak var tree: NSOutlineView?; weak var table: NSTableView?
        private var paths: [GitReferenceName] = [], folders: [GitReferenceName: Folder] = [:], visible: [ReferenceBrowserRow] = []
        var positioned = false
        private var updating = false
        init(model: ReferenceBrowserWindowModel) { self.model = model }
        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view === splitView.subviews.last }
        func update() {
            guard let tree, let table else { return }; updating = true; defer { updating = false }
            let paths = model.folders
            if paths != self.paths {
                self.paths = paths; folders = Dictionary(uniqueKeysWithValues: paths.map { ($0, Folder($0)) })
                for path in paths where path != "refs" {
                    let bytes = Array(path.rawValue.utf8), slash = bytes.lastIndex(of: 47)!
                    let parent = folders[GitReferenceName(String(decoding: bytes[..<slash], as: UTF8.self))]
                    let child = folders[path]!; child.parent = parent; parent?.children.append(child)
                }
                tree.reloadData(); if let root = folders["refs"] { tree.expandItem(root) }
            }
            if let chosen = folders[model.folder] {
                var ancestors: [Folder] = []; var parent = chosen.parent
                while let current = parent { ancestors.append(current); parent = current.parent }
                for ancestor in ancestors.reversed() { tree.expandItem(ancestor) }
                let row = tree.row(forItem: chosen); if row >= 0 { tree.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            }
            visible = model.rows; table.reloadData()
            let selected = visible.firstIndex { $0.reference.name == model.selected }
            table.selectRowIndexes(selected.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false)
            if let selected { table.scrollRowToVisible(selected) }
            let heads = model.folder == "refs/heads" || GitReferenceName.removingPrefix("refs/heads/", from: model.folder.rawValue) != nil
            for id in ["upstream", "description"] { table.tableColumn(withIdentifier: .init(id))?.isHidden = !heads }
            tree.isEnabled = !model.busy && !model.hasChild; table.isEnabled = !model.busy && !model.hasChild
            for column in table.tableColumns { table.setIndicatorImage(nil, in: column) }
            if let column = table.tableColumn(withIdentifier: .init(model.sortColumn)) {
                table.highlightedTableColumn = column
                table.setIndicatorImage(NSImage(named: NSImage.Name(model.descending ? "NSDescendingSortIndicator" : "NSAscendingSortIndicator")), in: column)
            }
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Folder)?.children.count ?? (folders["refs"] == nil ? 0 : 1) }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { if let folder = item as? Folder { return folder.children[index] }; return folders["refs"]! }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Folder).children.isEmpty }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            let folder = item as! Folder; let cell = NSTableCellView(); let text = NSTextField(labelWithString: String(decoding: folder.key.rawValue.utf8.split(separator: 47).last!, as: UTF8.self)); text.frame = .init(x: 22, y: 1, width: 165, height: 20); cell.addSubview(text); cell.textField = text
            let icon = NSImageView(frame: .init(x: 1, y: 3, width: 16, height: 16)); icon.image = NSImage(named: NSImage.folderName); cell.addSubview(icon); cell.imageView = icon; return cell
        }
        func outlineViewSelectionDidChange(_ notification: Notification) { guard !updating, let tree, let folder = tree.item(atRow: tree.selectedRow) as? Folder else { return }; model.setFolder(folder.key) }
        func numberOfRows(in tableView: NSTableView) -> Int { visible.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard visible.indices.contains(row), let column = tableColumn else { return nil }
            let item = visible[row]; let text = NSTextField(labelWithString: model.text(item, column: column.identifier.rawValue)); text.lineBreakMode = .byTruncatingTail
            text.toolTip = item.reference.name.rawValue
            if item.reference.name == model.snapshot?.currentBranch { text.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            return text
        }
        func tableViewSelectionDidChange(_ notification: Notification) { guard !updating, let table else { return }; model.selected = visible.indices.contains(table.selectedRow) ? visible[table.selectedRow].reference.name : nil }
        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) { let id = tableColumn.identifier.rawValue; if model.sortColumn == id { model.descending.toggle() } else { model.sortColumn = id; model.descending = false } }
        @objc func accept() { model.accept() }
        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems(); guard !model.busy, !model.hasChild, let table else { return }
            if visible.indices.contains(table.clickedRow), table.selectedRow != table.clickedRow { table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false) }
            guard model.chosen != nil else { return }; menu.autoenablesItems = false
            func item(_ title: String, _ action: Selector, _ icon: MenuIcon, _ enabled: Bool) { let entry = NSMenuItem(title: title, action: action, keyEquivalent: ""); entry.target = self; entry.image = icon.contextImage(defaults: model.preferences); entry.isEnabled = enabled; menu.addItem(entry) }
            item("Select", #selector(accept), .checkout, model.canAccept); menu.addItem(.separator())
            let chosen = model.chosen!
            if chosen.objectType == "commit" { item("Show log", #selector(log), .log, model.onLog != nil) }
            let branch = GitReferenceName.removingPrefix("refs/heads/", from: chosen.name.rawValue) != nil || GitReferenceName.removingPrefix("refs/remotes/", from: chosen.name.rawValue) != nil
            if branch { item("Show Reflog", #selector(reflog), .log, model.onReflog != nil) }
            if model.canEditDescription { item("Edit description", #selector(editDescription), .rename, model.onEditDescription != nil) }
            item("Browse repository", #selector(browse), .repositoryBrowser, model.onBrowse != nil)
            if !model.bare && chosen.objectType == "commit" { item("Compare with working tree", #selector(compare), .compare, model.onCompare != nil) }
            menu.addItem(.separator()); item("Copy reference name", #selector(copyName), .copy, true)
        }
        @objc func editDescription() { if model.canEditDescription { model.onEditDescription?() } }
        @objc func log() { if let chosen = model.chosen { model.onLog?(chosen.name.rawValue) } }
        @objc func reflog() { if let chosen = model.chosen { model.onReflog?(chosen.name.rawValue) } }
        @objc func browse() { if let chosen = model.chosen { model.onBrowse?(chosen.name.rawValue) } }
        @objc func compare() { if let chosen = model.chosen { model.onCompare?(chosen.name.rawValue) } }
        @objc func copyName() { if let chosen = model.chosen { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(chosen.name.rawValue, forType: .string) } }
    }
}

// CInputDlg's branch-description use: multiline input, end caret, Ctrl+Return,
// shared log font and InputDlg geometry. See NOTICE for upstream provenance.
private final class ReferenceDescriptionTextView: NSTextView {
    var accept: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), event.keyCode == 36 || event.keyCode == 76 { accept(); return }
        super.keyDown(with: event)
    }
}
@MainActor final class ReferenceDescriptionWindowController: NSWindowController, NSWindowDelegate {
    let editor: NSTextView
    let ok = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var busy = false
    private(set) var saved = false
    private var closed = false
    private var token: OperationCancellation?
    private var fontObserver: NSObjectProtocol?
    private let preferences: UserDefaults
    private let write: (String, OperationCancellation) async throws -> Void
    var onClosed: () -> Void = {}
    init(text: String, preferences: UserDefaults, write: @escaping (String, OperationCancellation) async throws -> Void) {
        self.preferences = preferences; self.write = write
        let input = ReferenceDescriptionTextView(frame: .zero); editor = input
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 510, height: 255), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Edit description"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 360, height: 210)
        super.init(window: window); window.delegate = self
        let content = NSView(); window.contentView = content
        let hint = NSTextField(labelWithString: "Edit description")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = input
        input.isRichText = false; input.allowsUndo = true; input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]; input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = .init(width: 0, height: CGFloat.greatestFiniteMagnitude)
        input.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainerInset = .init(width: 5, height: 5); input.string = text
        input.setAccessibilityLabel("Branch description"); input.undoManager?.removeAllActions()
        errorLabel.textColor = .systemRed
        ok.bezelStyle = .rounded; cancelButton.bezelStyle = .rounded
        ok.target = self; ok.action = #selector(save); cancelButton.target = self; cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"; input.accept = { [weak self] in self?.save() }
        for view in [hint, scroll, errorLabel, ok, cancelButton] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), hint.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: hint.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: errorLabel.topAnchor, constant: -5),
            errorLabel.leadingAnchor.constraint(equalTo: hint.leadingAnchor), errorLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), errorLabel.bottomAnchor.constraint(equalTo: ok.topAnchor, constant: -6),
            cancelButton.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), cancelButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10), cancelButton.widthAnchor.constraint(equalToConstant: 80),
            ok.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8), ok.bottomAnchor.constraint(equalTo: cancelButton.bottomAnchor), ok.widthAnchor.constraint(equalToConstant: 80)
        ])
        updateFont(); window.center(); DialogGeometry.attach(window, identifier: "InputDlg", legacyName: "InputDlg")
        fontObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: preferences, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateFont() } }
    }
    private func updateFont() {
        guard !closed else { return }
        let ranges = editor.selectedRanges
        editor.undoManager?.disableUndoRegistration()
        editor.font = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName, size: preferences.object(forKey: "LogFontSize") as? Int ?? MessageEditorFont.defaultSize)
        editor.undoManager?.enableUndoRegistration(); editor.selectedRanges = ranges
    }
    func focusEditor() { guard !closed, !busy, let window else { return }; window.makeFirstResponder(editor); editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0)) }
    @objc func save() {
        guard !busy, !closed else { return }
        busy = true; editor.isEditable = false; ok.isEnabled = false; cancelButton.isEnabled = false; errorLabel.stringValue = ""
        let request = OperationCancellation(); token = request; let text = editor.string
        Task {
            do {
                try await write(text, request)
                guard !closed, token === request else { return }
                saved = true; close()
            } catch {
                guard !closed, token === request else { return }
                token = nil; busy = false; editor.isEditable = true; ok.isEnabled = true; cancelButton.isEnabled = true
                errorLabel.stringValue = error.localizedDescription; window?.makeFirstResponder(editor)
            }
        }
    }
    @objc func cancel() { guard !busy, !closed else { return }; close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }; closed = true; token?.cancel(); token = nil
        if let fontObserver { NotificationCenter.default.removeObserver(fontObserver) }; fontObserver = nil
        if let window { window.sheetParent?.endSheet(window) }; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
