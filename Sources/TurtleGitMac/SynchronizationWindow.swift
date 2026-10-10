// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SynchronizationWindowController: NSWindowController, NSWindowDelegate {
    let model: SynchronizationWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Git Synchronization – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        model.comparison.window = window; window.center()
        DialogGeometry.attach(window, identifier: "SyncDlg", legacyName: "SyncDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.hasBlockingChild, sender.attachedSheet == nil else { return false }
        if let child = model.comparison.comparisonWindows.values.first(where: { $0.model.dirty }) {
            child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        Array(model.comparison.comparisonWindows.values).forEach { $0.close() }
        Array(model.comparison.unifiedWindows.values).forEach { $0.close() }
        onClosed()
    }
}

@MainActor final class SynchronizationWindowModel: ObservableObject {
    let repository: GitRepository
    let access: RepositoryAccessLease?
    let preferences: UserDefaults
    let comparison: RevisionComparisonWindowModel
    weak var window: NSWindow?
    @Published private(set) var localBranches: [String] = []
    @Published private(set) var remotes: [String] = []
    @Published private(set) var branchHistory: [String] = []
    @Published private(set) var urlHistory: [String] = []
    @Published var localBranch = ""
    @Published var remoteBranch = ""
    @Published var remote = ""
    @Published var force = false
    @Published var confirmingQuit = false {
        didSet {
            comparison.confirmingQuit = confirmingQuit
            for viewer in comparison.unifiedWindows.values { viewer.model.confirmingQuit = confirmingQuit }
        }
    }
    @Published var tab = 0
    @Published var fileSelection = Set<String>()
    @Published private(set) var outgoing: SynchronizationOutgoing?
    @Published private(set) var graph: [CommitGraphRow] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var token: OperationCancellation?
    private(set) var closed = false
    var onLog: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var hasBlockingChild: Bool {
        NSApp.modalWindow != nil || comparison.busy || comparison.comparisonWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil } || comparison.unifiedWindows.values.contains { $0.model.busy || $0.window?.attachedSheet != nil }
    }
    var remoteChoices: [String] {
        var seen = Set<GitReferenceName>()
        return (urlHistory + remotes).filter { seen.insert(GitReferenceName($0)).inserted }.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
    }
    private var historyKey: String { "TurtleGit.Sync." + repository.root.path }
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.preferences = preferences
        comparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"))
        branchHistory = preferences.stringArray(forKey: historyKey + ".branches") ?? []
        urlHistory = preferences.stringArray(forKey: historyKey + ".urls") ?? []
    }
    var status: String {
        if busy { return "Loading…" }
        if let error { return error }
        switch outgoing?.disposition {
        case .unknownURL: return "Outgoing commits are unknown for a URL."
        case .unknownRemoteBranch: return "Remote branch is unknown."
        case .upToDate: return "Up to date."
        case .needsForce: return "Local branch is not a fast-forward of the remote branch. Enable Force to show outgoing changes."
        case .outgoing: return "\(outgoing?.commits.count ?? 0) outgoing commits"
        case nil: return ""
        }
    }
    func invalidate() { closed = true; token?.cancel(); token = nil; comparison.invalidate(); busy = false }
    func reload(selectTracking: Bool = false, initial: Bool = false) {
        guard !closed, !confirmingQuit, !hasBlockingChild else { return }
        token?.cancel()
        let request = OperationCancellation(); token = request; busy = true; error = nil
        outgoing = nil; graph = []; fileSelection = []; comparison.snapshot = nil
        let local = localBranch, selectedRemote = remote, selectedBranch = remoteBranch, forced = force
        Task {
            defer { if token === request { token = nil; busy = false } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let catalog = try await repository.synchronizationBranches(localBranch: initial ? nil : local, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                let branch = initial ? catalog.currentBranch : local
                let destination = selectTracking || initial ? catalog.trackedBranch : selectedBranch
                let url = selectTracking || initial ? (catalog.trackedRemote.isEmpty ? (initial ? (urlHistory.first ?? catalog.remotes.first ?? "") : selectedRemote) : catalog.trackedRemote) : selectedRemote
                localBranches = catalog.localBranches; remotes = catalog.remotes
                localBranch = branch; remoteBranch = destination; remote = url
                let projection = try await repository.synchronizationOutgoing(localBranch: branch, remote: url, remoteBranch: destination, force: forced, cancellation: request)
                guard !closed, token === request, !request.isCancelled else { return }
                outgoing = projection; graph = CommitGraph.layout(projection.commits); comparison.snapshot = projection.comparison
                // Native control edits never write Git configuration or refs.
            } catch {
                guard !closed, token === request, !request.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    func compareFiles(unified: Bool) {
        guard !closed, !confirmingQuit, !busy, outgoing?.comparison != nil, !fileSelection.isEmpty else { return }
        if unified { comparison.showPatch(fileSelection, alternate: false) }
        else { comparison.compare(fileSelection) }
    }
}

private struct SynchronizationDialog: View {
    @ObservedObject var model: SynchronizationWindowModel
    private func edit(_ key: ReferenceWritableKeyPath<SynchronizationWindowModel, String>, tracking: Bool = false) -> Binding<String> {
        Binding(get: { model[keyPath: key] }, set: { model[keyPath: key] = $0; model.reload(selectTracking: tracking) })
    }
    var body: some View {
        VStack(spacing: 10) {
            GroupBox {
                VStack(spacing: 10) {
                    HStack {
                        Text("Local Branch:")
                        Picker("Local Branch", selection: Binding(get: { GitReferenceName(model.localBranch) }, set: { model.localBranch = $0.rawValue; model.reload(selectTracking: true) })) {
                            ForEach(model.localBranches.map { GitReferenceName($0) }, id: \.self) { Text($0.rawValue).tag($0) }
                        }.labelsHidden()
                        Text("Remote Branch:")
                        FetchHistoryCombo(value: edit(\.remoteBranch), choices: model.branchHistory, label: "Remote Branch")
                    }
                    HStack {
                        Text("Remote URL:")
                        FetchHistoryCombo(value: edit(\.remote), choices: model.remoteChoices, label: "Remote URL")
                    }
                    Toggle("Force", isOn: Binding(get: { model.force }, set: { model.force = $0; model.reload() }))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(6)
            }.disabled(model.hasBlockingChild)
            Picker("Changes", selection: $model.tab) {
                Text("Outgoing Commits").tag(0); Text("Outgoing Changes").tag(1)
            }.pickerStyle(.segmented)
            if model.tab == 0 {
                SynchronizationHistoryTable(model: model)
            } else {
                SynchronizationFiles(model: model)
                HStack {
                    Button { model.compareFiles(unified: false) } label: { CommandLabel(title: "Compare two revisions", icon: .compare) }.disabled(model.fileSelection.isEmpty || model.busy)
                    Button { model.compareFiles(unified: true) } label: { CommandLabel(title: "Show unified diff", icon: .compare) }.disabled(model.fileSelection.isEmpty || model.busy)
                    Spacer()
                }
            }
            HStack {
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                Button("Refresh") { model.reload() }.disabled(model.hasBlockingChild)
                Spacer()
                Button("Close") { model.window?.performClose(nil) }.keyboardShortcut(.defaultAction)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).foregroundStyle(model.error == nil ? Color.secondary : Color.red).textSelection(.enabled)
                Spacer()
            }
        }.padding(12).disabled(model.confirmingQuit).onAppear { model.reload(initial: true) }
    }
}

private struct SynchronizationFiles: View {
    @ObservedObject var model: SynchronizationWindowModel
    private var files: [CommitFile] { model.outgoing?.comparison?.files ?? [] }
    private func state(_ file: CommitFile) -> FileState {
        switch file.action.first { case "A": return .added; case "D": return .deleted; default: return .modified }
    }
    var body: some View {
        Table(files, selection: $model.fileSelection) {
                    TableColumn("Path") { file in
                        HStack {
                            Image(nsImage: state(file).icon.image() ?? NSImage()).resizable().frame(width: 16, height: 16)
                            Text(file.path).foregroundStyle(model.fileSelection.contains(file.id) ? Color.primary : state(file).textColor(preferences: model.preferences))
                        }.help(file.oldPath.map { "Renamed from " + $0 } ?? file.path)
                    }
                    TableColumn("Extension") { file in Text(file.fileExtension) }.width(80)
                    TableColumn("Status") { file in Text(file.status) }.width(70)
                    TableColumn("Added") { file in Text(file.addedText) }.width(65)
                    TableColumn("Deleted") { file in Text(file.removedText) }.width(65)
                }.contextMenu {
                    Button { model.compareFiles(unified: false) } label: { CommandLabel(title: "Compare two revisions", icon: .compare) }
                    Button { model.compareFiles(unified: true) } label: { CommandLabel(title: "Show unified diff", icon: .compare) }
                }
    }
}

private struct SynchronizationHistoryTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView(); table.rowHeight = 24; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("graph", "Graph", 90.0), ("hash", "Hash", 110.0), ("message", "Message", 450.0), ("author", "Author", 150.0), ("date", "Date", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        if model.preferences === UserDefaults.standard { table.autosaveName = "TurtleGit.SyncOut.RevisionColumns"; table.autosaveTableColumns = true }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.showLog)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model; (scroll.documentView as? NSTableView)?.reloadData()
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SynchronizationWindowModel
        init(_ model: SynchronizationWindowModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { model.outgoing?.commits.count ?? 0 }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let entries = model.outgoing?.commits, entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            if column?.identifier.rawValue == "graph" {
                let cell = GraphCell(); cell.preferences = model.preferences; cell.parentCount = entry.parents.count
                if model.graph.indices.contains(row) { cell.graph = model.graph[row] }; return cell
            }
            let text: String
            switch column?.identifier.rawValue {
            case "hash": text = String(entry.hash.prefix(8))
            case "message": text = entry.subject
            case "author": text = entry.author
            case "date": text = entry.date
            default: text = ""
            }
            let cell = NSTextField(labelWithString: text); cell.lineBreakMode = .byTruncatingTail; return cell
        }
        @objc func showLog(_ table: NSTableView) {
            guard !model.closed, !model.confirmingQuit, !model.busy, let entries = model.outgoing?.commits, entries.indices.contains(table.clickedRow) else { return }
            model.onLog(entries[table.clickedRow].hash)
        }
    }
}
