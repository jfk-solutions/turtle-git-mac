// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SynchronizationWindowController: NSWindowController, NSWindowDelegate {
    let model: SynchronizationWindowModel
    var onClosed: () -> Void = {}
    private var cancellationAlert: NSAlert?
    init(repository: GitRepository, access: RepositoryAccessLease?, preferences: UserDefaults = .standard) {
        model = SynchronizationWindowModel(repository: repository, access: access, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 660), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Git Synchronization – TurtleGit"
        window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 860, height: 500)
        window.contentViewController = NSHostingController(rootView: SynchronizationDialog(model: model))
        super.init(window: window); window.delegate = self; model.window = window
        model.sshSettings.present = { [weak self] prompt in
            guard let self, !self.model.closed, !self.model.confirmingQuit, let window = self.window, window.attachedSheet == nil else { return false }
            guard let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.confirmCancellation = { [weak self] reply in
            guard let self, !self.model.closed, let window = self.window, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "Cancel synchronization?"
            alert.informativeText = "Git may have already updated remote-tracking references."
            alert.addButton(withTitle: "Keep Running"); alert.addButton(withTitle: "Cancel Operation")
            self.cancellationAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                if self?.cancellationAlert === alert { self?.cancellationAlert = nil }
                reply(response == .alertSecondButtonReturn)
            }
        }
        model.comparison.window = window; window.center()
        DialogGeometry.attach(window, identifier: "SyncDlg", legacyName: "SyncDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.transportRunning, !model.confirmingCancellation, !model.hasBlockingChild, sender.attachedSheet == nil else { return false }
        if let child = model.comparison.comparisonWindows.values.first(where: { $0.model.dirty }) {
            child.window?.makeKeyAndOrderFront(nil); child.window?.performClose(nil); return false
        }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        model.invalidate()
        if let alert = cancellationAlert, window?.attachedSheet === alert.window { window?.endSheet(alert.window, returnCode: .abort) }
        cancellationAlert = nil
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
    let sshSettings: SSHTransportSettings
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
    @Published private(set) var referenceChanges: [SynchronizationReferenceChange] = []
    @Published var hideUnchangedReferences = false { didSet { preferences.set(hideUnchangedReferences, forKey: "RefCompareHideUnchanged") } }
    var referenceRows: [SynchronizationReferenceChange] {
        referenceChanges.filter { !hideUnchangedReferences || $0.kind != .same }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return $0.name.rawValue.localizedStandardCompare($1.name.rawValue) == .orderedAscending
        }
    }
    @Published private(set) var outgoing: SynchronizationOutgoing?
    @Published private(set) var graph: [CommitGraphRow] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var transportRunning = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var cancelling = false
    @Published private(set) var commandOutput = ""
    @Published private(set) var commandSucceeded = false
    @Published private(set) var commandCompleted = false
    @Published private(set) var percentage: Int?
    @Published private(set) var currentWork = ""
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var onTransportFinished: (String) -> Void = { _ in }
    private var outputState: GitProgressOutputState
    private var cancellationQuestion: UUID?
    private var transportID: UUID?
    private var token: OperationCancellation?
    private(set) var closed = false
    var onLog: (String) -> Void = { _ in }
    var onCommit: () -> Void = {}
    var onReferenceLog: (String) -> Void = { _ in }
    var onReferenceCompare: (String, String) -> Void = { _, _ in }
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
        sshSettings = SSHTransportSettings(repository: repository)
        outputState = GitProgressOutputState(preferences: preferences)
        comparison = RevisionComparisonWindowModel(repository: repository, access: access, from: .revision("HEAD"), to: .revision("HEAD"))
        branchHistory = preferences.stringArray(forKey: historyKey + ".branches") ?? []
        urlHistory = preferences.stringArray(forKey: historyKey + ".urls") ?? []
        sshSettings.load(preferences, key: historyKey + ".autoload")
        hideUnchangedReferences = preferences.bool(forKey: "RefCompareHideUnchanged")
    }
    var status: String {
        if transportRunning { return cancelling ? "Cancelling…" : (currentWork.isEmpty ? "Running Git…" : currentWork) }
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
    func invalidate() { closed = true; token?.cancel(); token = nil; comparison.invalidate(); busy = false; confirmingCancellation = false; cancellationQuestion = nil; transportID = nil }
    func reload(selectTracking: Bool = false, initial: Bool = false) {
        guard !closed, !confirmingQuit, !transportRunning, !hasBlockingChild else { return }
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
    /// Non-integrating entries of SyncDlg's Pull split button. Pull and
    /// Fetch & Rebase require their own checkout/tracking/Rebase workflow.
    func fetch(_ action: SynchronizationTransportAction = .fetch) {
        guard [.fetch, .fetchAllBranches, .remoteUpdate, .prune].contains(action),
              !closed, !confirmingQuit, !confirmingCancellation, !busy, !hasBlockingChild, window?.attachedSheet == nil else { return }
        let operationID = UUID(); transportID = operationID
        let request = OperationCancellation(); token = request; busy = true; transportRunning = true
        cancelling = false; commandCompleted = false; commandSucceeded = false; referenceChanges = []
        outputState.reset(); commandOutput = ""; percentage = nil; currentWork = ""; error = nil; tab = 2
        var options = SynchronizationTransportOptions(action: action)
        options.localBranch = localBranch; options.remote = remote; options.remoteBranch = remoteBranch; options.force = force
        let factory = sshSettings.capture()
        sshSettings.save(preferences, key: historyKey + ".autoload")
        Task {
            let coordinator = factory?(); defer { coordinator?.close() }
            defer { if transportID == operationID { token = nil; busy = false; transportRunning = false; transportID = nil } }
            let parser = GitCliOutputParser(limit: outputState.limit)
            var oldReferences: SynchronizationReferenceSnapshot?
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let plan = try await repository.synchronizationTransportPlan(options, cancellation: request)
                oldReferences = try await repository.synchronizationReferenceSnapshot(cancellation: request)
                guard !closed, token === request else { return }
                if request.isCancelled { throw OperationCancellationFailure.cancelled }
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.synchronize(plan, cancellation: request,
                        onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) }, prepareTransport: coordinator?.preparation)
                }
                for await _ in updates { consume(parser.processPending(), parser: parser, request: request) }
                consume(parser.processPending(), parser: parser, request: request)
                consume(parser.finish(), parser: parser, request: request)
                let result = try await operation.value
                guard !closed, token === request else { return }
                if !outputState.hasOutput { commandOutput = result.command.text }
                commandSucceeded = true
            } catch {
                guard !closed, token === request else { return }
                let message: String
                if request.isCancelled { message = "Synchronization cancelled." }
                else if let failure = error as? GitFailure, outputState.hasOutput { message = "Git command failed (\(failure.code))." }
                else { message = error.localizedDescription }
                commandOutput += (commandOutput.isEmpty || commandOutput.hasSuffix("\n") ? "" : "\n") + message
                self.error = message
            }
            guard !closed, token === request else { return }
            // A normal cancellation may still move refs. Inspect with a fresh
            // token; forced owner closure cancels this read as well.
            if let before = oldReferences {
                let inspection = OperationCancellation(); token = inspection
                do {
                    let after = try await repository.synchronizationReferenceSnapshot(cancellation: inspection)
                    let rows = try await repository.synchronizationReferenceChanges(from: before, to: after, cancellation: inspection)
                    guard !closed, token === inspection else { return }
                    referenceChanges = rows
                    tab = 3
                } catch {
                    guard !closed, token === inspection else { return }
                    commandOutput += "\nReading reference changes failed.\n" + error.localizedDescription
                }
                guard !closed, token === inspection else { return }
            }
            commandCompleted = true; cancelling = false; transportRunning = false; busy = false; token = nil; transportID = nil
            onTransportFinished(commandOutput)
            // Fetch completion refreshes outgoing projection, not incoming HEAD.
            // A cancelled/failed Git command can still have updated references.
            reload()
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser, request: OperationCancellation) {
        guard !closed, token === request else { return }
        outputState.consume(emission, parser: parser)
        commandOutput = outputState.output; percentage = outputState.percentage; currentWork = outputState.currentWork
    }
    func cancelTransport() {
        guard !closed, !confirmingQuit, transportRunning, !cancelling, !confirmingCancellation, let request = token else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            let question = UUID(); cancellationQuestion = question; confirmingCancellation = true
            confirmCancellation { [weak self] accepted in
                guard let self, !self.closed, self.cancellationQuestion == question else { return }
                self.cancellationQuestion = nil; self.confirmingCancellation = false
                guard self.token === request, self.transportRunning else { return }
                if accepted { self.cancelling = true; request.cancel() }
            }
        } else { cancelling = true; request.cancel() }
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
                    HStack { SSHAutoloadToggle(settings: model.sshSettings); Spacer() }
                    Toggle("Force", isOn: Binding(get: { model.force }, set: { model.force = $0; model.reload() }))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(6)
            }.disabled(model.transportRunning || model.hasBlockingChild)
            Picker("Changes", selection: $model.tab) {
                Text("Outgoing Commits").tag(0); Text("Outgoing Changes").tag(1); Text("Command Log").tag(2); Text("Ref changes").tag(3)
            }.pickerStyle(.segmented)
            if model.tab == 3 {
                SynchronizationReferenceTable(model: model)
                    .overlay {
                        if model.referenceRows.isEmpty {
                            Text(model.transportRunning ? "Please wait…" : "No differences found.").foregroundStyle(.secondary).allowsHitTesting(false)
                        }
                    }
            } else if model.tab == 2 {
                SubmoduleProgressOutputView(text: model.commandOutput, completed: model.commandCompleted, success: model.commandSucceeded, preferences: model.preferences)
                if model.transportRunning {
                    if let value = model.percentage { ProgressView(value: Double(value), total: 100) }
                    else { ProgressView().progressViewStyle(.linear) }
                }
            } else if model.tab == 0 {
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
                HStack(spacing: 0) {
                    Button { model.fetch() } label: { CommandLabel(title: "Fetch", icon: .fetch) }
                    Menu {
                        Button { model.fetch(.fetch) } label: { CommandLabel(title: "Fetch", icon: .fetch) }
                        Button { model.fetch(.fetchAllBranches) } label: { CommandLabel(title: "Fetch All", icon: .fetch) }
                        Button { model.fetch(.remoteUpdate) } label: { CommandLabel(title: "Remote Update", icon: .fetch) }
                        Button { model.fetch(.prune) } label: { CommandLabel(title: "Cleanup stale remote branches", icon: .clean) }
                    } label: { Image(systemName: "chevron.down").accessibilityLabel("Fetch actions") }.menuStyle(.borderlessButton).fixedSize()
                }.disabled(model.busy || model.hasBlockingChild)
                Button { model.onLog(model.localBranch) } label: { CommandLabel(title: "Show log", icon: .log) }.disabled(model.busy || model.localBranch.isEmpty)
                Button { model.onCommit() } label: { CommandLabel(title: "Commit", icon: .commit) }.disabled(model.busy)
                Button("Refresh") { model.reload() }.disabled(model.transportRunning || model.hasBlockingChild)
                Spacer()
                if model.transportRunning {
                    Button(model.cancelling ? "Cancelling…" : "Cancel") { model.cancelTransport() }
                        .keyboardShortcut(.cancelAction).disabled(model.cancelling || model.confirmingCancellation)
                } else {
                    Button("Close") { model.window?.performClose(nil) }.keyboardShortcut(.defaultAction)
                }
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

private final class SynchronizationReferenceNativeTable: NSTableView {
    var makeMenu: () -> NSMenu? = { nil }
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        return makeMenu()
    }
}
private final class SynchronizationReferenceHeader: NSTableHeaderView {
    var makeMenu: () -> NSMenu? = { nil }
    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }
}
private struct SynchronizationReferenceTable: NSViewRepresentable {
    @ObservedObject var model: SynchronizationWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = SynchronizationReferenceNativeTable(); table.rowHeight = 24
        let titles = ["Reference", "Type", "Change", "Old hash", "Old message", "New hash", "New message"]
        for (index, title) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title; column.width = [180.0, 110, 140, 100, 200, 100, 200][index]
            column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: true)
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        let header = SynchronizationReferenceHeader(); header.makeMenu = { [weak coordinator = context.coordinator] in coordinator?.headerMenu() }; table.headerView = header
        table.makeMenu = { [weak table, weak coordinator = context.coordinator] in coordinator?.rowMenu(table?.selectedRow ?? -1) }
        if model.preferences === UserDefaults.standard { table.autosaveName = "TurtleGit.SyncRefs.Columns"; table.autosaveTableColumns = true }
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.documentView = table
        context.coordinator.table = table; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model; context.coordinator.reload()
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var model: SynchronizationWindowModel
        weak var table: NSTableView?
        var rows: [SynchronizationReferenceChange] = []
        init(_ model: SynchronizationWindowModel) { self.model = model }
        private func field(_ row: SynchronizationReferenceChange, _ column: Int) -> String {
            switch column {
            case 0: return row.shortName
            case 1: return row.typeName
            case 2: return row.change
            case 3: return row.oldHash ?? ""
            case 4: return row.oldMessage
            case 5: return row.newHash ?? ""
            default: return row.newMessage
            }
        }
        func reload() {
            let selected = table.flatMap { rows.indices.contains($0.selectedRow) ? rows[$0.selectedRow].id : nil }
            rows = model.referenceRows
            if let descriptor = table?.sortDescriptors.first, let column = Int(descriptor.key ?? "") {
                rows = rows.enumerated().sorted { a, b in
                    let lhs = field(a.element, column), rhs = field(b.element, column)
                    let order = [0, 4, 6].contains(column) ? lhs.localizedStandardCompare(rhs) : lhs.compare(rhs, options: .literal)
                    if order == .orderedSame { return a.offset < b.offset }
                    return descriptor.ascending ? order == .orderedAscending : order == .orderedDescending
                }.map(\.element)
            }
            table?.reloadData()
            if let selected, let index = rows.firstIndex(where: { $0.id == selected }) { table?.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
            else { table?.deselectAll(nil) }
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { reload() }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard rows.indices.contains(row), let index = Int(column?.identifier.rawValue ?? "") else { return nil }
            let entry = rows[row]
            let value = field(entry, index)
            let text = NSTextField(labelWithString: [3, 5].contains(index) ? String(value.prefix(8)) : value)
            text.lineBreakMode = .byTruncatingTail; text.toolTip = value
            if index == 0, let icon = ReferenceTypeIcon(referenceName: entry.name.rawValue)?.image() {
                let image = NSImageView(image: icon); image.setContentHuggingPriority(.required, for: .horizontal)
                let stack = NSStackView(views: [image, text]); stack.orientation = .horizontal; stack.spacing = 4; return stack
            }
            return text
        }
        private var available: Bool { !model.closed && !model.busy && !model.confirmingQuit && !model.confirmingCancellation && !model.hasBlockingChild }
        func headerMenu() -> NSMenu {
            let menu = NSMenu(); menu.autoenablesItems = false
            let item = NSMenuItem(title: "Hide unchanged refs", action: #selector(toggleUnchanged), keyEquivalent: "")
            item.target = self; item.state = model.hideUnchangedReferences ? .on : .off; menu.addItem(item); return menu
        }
        @objc func toggleUnchanged() { model.hideUnchangedReferences.toggle() }
        func rowMenu(_ row: Int) -> NSMenu? {
            guard rows.indices.contains(row) else { return nil }
            let entry = rows[row], menu = NSMenu(); menu.autoenablesItems = false
            func add(_ title: String, _ selector: Selector, _ icon: MenuIcon) {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
                item.representedObject = entry; item.isEnabled = available
                item.image = MenuPresentationSettings.applicationContextIcons(defaults: model.preferences) ? icon.image() : nil
                menu.addItem(item)
            }
            if let hash = entry.oldHash { add("Show log of " + String(hash.prefix(8)), #selector(oldLog(_:)), .log) }
            if let hash = entry.newHash, entry.oldHash != hash { add("Show log of " + String(hash.prefix(8)), #selector(newLog(_:)), .log) }
            if entry.oldHash != nil && entry.newHash != nil && entry.oldHash != entry.newHash { add("Compare revisions", #selector(compare(_:)), .compare) }
            add("Reflog", #selector(reflog(_:)), .log); return menu
        }
        @objc func oldLog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let hash = row.oldHash else { return }; model.onLog(hash) }
        @objc func newLog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let hash = row.newHash else { return }; model.onLog(hash) }
        @objc func compare(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange, let old = row.oldHash, let new = row.newHash else { return }; model.onReferenceCompare(old, new) }
        @objc func reflog(_ sender: NSMenuItem) { guard available, let row = sender.representedObject as? SynchronizationReferenceChange else { return }; model.onReferenceLog(row.name.rawValue) }
    }
}
