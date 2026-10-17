import AppKit
import SwiftUI
import TurtleGitCore

private final class RevertProgressNativeWindow: NSWindow {
    var escape: () -> Void = {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.charactersIgnoringModifiers == "\u{1b}" { escape(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor final class RevertProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: RevertProgressWindowModel
    var onClosed: () -> Void = {}
    private var question: (UUID, NSAlert, (Bool) -> Void)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool, preferences: UserDefaults = .standard) {
        model = RevertProgressWindowModel(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess, preferences: preferences)
        let window = RevertProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 550), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Revert Progress", preferences: preferences)
        window.contentMinSize = NSSize(width: 800, height: 410); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RevertProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 550)); window.center()
        model.close = { [weak window] in window?.performClose(nil) }
        model.confirmCancellation = { [weak self] in await self?.askCancellation() ?? false }
        window.escape = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }

        DialogGeometry.attach(window, identifier: "RevertProgressDialog", legacyName: "RevertProgressDialog")
    }
    private func askCancellation() async -> Bool {
        guard !model.retired, question == nil, let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.messageText = "The operation is still running."; alert.informativeText = "Stop Revert after its current filesystem or Git step? Completed changes remain recoverable through the result."; alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        let id = UUID()
        return await withCheckedContinuation { continuation in question = (id, alert, { continuation.resume(returning: $0) }); alert.beginSheetModal(for: window) { [weak self] response in self?.finishQuestion(id, accepted: response == .alertFirstButtonReturn) } }
    }
    private func finishQuestion(_ id: UUID, accepted: Bool) {
        guard let pending = question, pending.0 == id else { return }; question = nil
        if pending.1.window.sheetParent === window { window?.endSheet(pending.1.window) }; pending.1.window.orderOut(nil); pending.2(accepted)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.confirmingCancellation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.retire(); if let pending = question { finishQuestion(pending.0, accepted: false) }; onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct RevertProgressRow: Identifiable {
    let id = UUID()
    let action: String
    let path: String
    var status: String
}

@MainActor final class RevertProgressWindowModel: ObservableObject, ActionLogProgress {
    let progressPresentation: GitCommandPresentation
    static private(set) var activeOperations = 0
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let entries: [StatusEntry]
    private let amend: Bool
    private let againstHead: Bool
    private let autoCloseSuccess: Bool
    let preferences: UserDefaults
    private let autoClosePolicy: GitProgressAutoClose
    private var cancellation: OperationCancellation?
    private var started = false
    private(set) var retired = false
    private var completedSuccessfully = false
    private var rowIndices: GitPathMap<Int> = [:]
    @Published fileprivate var rows: [RevertProgressRow] = []
    @Published var busy = true
    @Published private(set) var confirmingCancellation = false
    @Published var cancelRequested = false
    @Published var completed = 0
    @Published var total = 0
    @Published var current = "Preparing Revert…"
    @Published var information = ""
    @Published var commandOutput = ""
    @Published var failed = false
    @Published var cancelled = false
    @Published var trashedFiles: [URL] = []
    @Published var submodulePaths: [String] = []
    private var comparisonRevision: String?
    var confirmCancellation: () async -> Bool = { false }
    var onHandleSubmodules: (String, [String]) -> Void = { _, _ in }
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var execute: (([StatusEntry], OperationCancellation, @escaping @Sendable (WorkingFileRevertProgress) -> Void, @escaping @Sendable (GitOutputChunk) -> Void) async throws -> WorkingFileRevertResult)?
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.entries = entries; self.amend = amend; self.againstHead = againstHead; self.autoCloseSuccess = autoCloseSuccess; self.preferences = preferences; progressPresentation = GitCommandPresentation(defaults: preferences); autoClosePolicy = GitProgressAutoClose(preferences: preferences)
    }
    func retire() { guard !retired else { return }; if busy { cancelled = true }; saveActionLog(); retired = true; cancellation?.cancel() }
    func cancel() {
        guard !retired, busy, !cancelRequested, !confirmingCancellation, let request = cancellation else { return }
        if !preferences.bool(forKey: "ConfirmKillProcess") { stop(request); return }
        confirmingCancellation = true; Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1 }
            let accepted = await confirmCancellation()
            guard !retired else { return }; confirmingCancellation = false
            if busy, cancellation === request, accepted { stop(request) }
            finishAutomaticClose()
        }
    }
    private func stop(_ request: OperationCancellation) { cancelRequested = true; request.cancel(); current = "Cancelling after the current operation…" }
    private func receive(_ event: WorkingFileRevertProgress, request: OperationCancellation) {
        guard !retired, cancellation === request else { return }
        let key = event.step.rawValue + "\0" + event.path
        if let index = rowIndices[key] { rows[index].status = event.finished ? "Completed" : "In progress" }
        else { rowIndices[key] = rows.count; rows.append(RevertProgressRow(action: event.step.rawValue, path: event.path, status: event.finished ? "Completed" : "In progress")) }
        completed = event.completed; total = event.total
        if !cancelRequested { current = event.step.rawValue + ": " + event.path }
    }
    func start() { guard !started, !retired else { return }; started = true; run(refreshSelection: false) }
    func retry() { guard !retired, !busy, !confirmingCancellation, failed || cancelled else { return }; run(refreshSelection: true) }
    private func run(refreshSelection: Bool) {
        ProgressActionLog.nextAttempt(self); let request = OperationCancellation(); cancellation = request; busy = true; cancelRequested = false; failed = false; cancelled = false; completedSuccessfully = false; information = ""; commandOutput = ""; rows = []; rowIndices = [:]; completed = 0; total = 0; current = refreshSelection ? "Refreshing selected paths…" : "Preparing Revert…"; submodulePaths = []
        Self.activeOperations += 1
        Task {
            defer { Self.activeOperations -= 1; withExtendedLifetime(access) {}; if cancellation === request { cancellation = nil; if !retired { busy = false; saveActionLog(); finishAutomaticClose() } } }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let selected = refreshSelection ? try await repository.workingFileRevertSelection(entries, amend: amend, againstHead: againstHead, cancellation: request) : entries
                try request.check(); guard !retired else { return }
                let (stream, continuation) = AsyncStream<WorkingFileRevertProgress>.makeStream()
                let operation = Task { [self] in
                    defer { continuation.finish() }
                    return try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] progress in guard let self, !self.retired, self.cancellation === request else { return }; self.commandOutput = progress.output }, resultText: { _ in "" }) { [self] emit in
                        if let execute { return try await execute(selected, request, { continuation.yield($0) }, emit) }
                        return try await repository.revertWorkingFiles(selected, amend: amend, amendDiffToLastCommit: againstHead, cancellation: request, progress: { continuation.yield($0) }, onOutput: emit)
                    }
                }
                for await event in stream { receive(event, request: request) }
                let result = try await operation.value
                guard !retired, cancellation === request else { return }
                submodulePaths = result.submodulePaths; comparisonRevision = result.comparisonRevision; retainCopies(result.trashedFiles)
                information = "\(result.revertedPaths.count) file(s) reverted."; current = "Finished"; completedSuccessfully = true
                onFinished((trashedFiles.map { "Moved to Trash: " + $0.path } + [information]).joined(separator: "\n"), true)
            } catch {
                guard !retired, cancellation === request else { return }
                let failure = error as? WorkingFileRevertFailure
                cancelled = failure?.wasCancelled == true || request.isCancelled || error is OperationCancellationFailure
                failed = !cancelled; retainCopies(failure?.trashedFiles ?? [])
                current = cancelled ? "Cancelled" : "Revert failed"; information = error.localizedDescription
                if cancelled { information += "\n\nEarlier working-file changes remain; review current status before retrying." }
                commandOutput = LocalGitCommandProgress.failure(error, existing: commandOutput, preferences: preferences)
                for index in rows.indices where rows[index].status == "In progress" { rows[index].status = cancelled ? "Cancelled" : "Failed" }
                onFinished(information, false)
            }
        }
    }
    private func retainCopies(_ urls: [URL]) { var seen = GitPathSet(trashedFiles.map(\.path)); trashedFiles += urls.filter { seen.insert($0.path).inserted } }
    private func finishAutomaticClose() {
        guard !retired, !busy, !confirmingCancellation, completedSuccessfully else { return }
        if autoCloseSuccess && submodulePaths.isEmpty || autoClosePolicy.shouldClose(success: true, postActionCount: submodulePaths.isEmpty ? 0 : 1) { close() }
    }
    func handleSubmodules() { guard !retired, !busy, !confirmingCancellation, !failed, !cancelled, !submodulePaths.isEmpty, let revision = comparisonRevision else { return }; let paths = submodulePaths, callback = onHandleSubmodules; saveActionLog(); close(); callback(revision, paths) }
    func revealCopies() { guard !retired, !trashedFiles.isEmpty else { return }; NSWorkspace.shared.activateFileViewerSelecting(trashedFiles) }
    var clipboardOutput: String { rows.map { [$0.action, $0.path].joined(separator: "\t") }.joined(separator: "\n") + "\n\n" + commandOutput + "\n" + information + "\n" + trashedFiles.map { "Moved to Trash: " + $0.path }.joined(separator: "\n") }
    func copyOutput() { guard !retired else { return }; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(clipboardOutput, forType: .string) }
    var output: String { clipboardOutput }
    var actionLogRepository: URL { repository.root }
    var actionLogEligible: Bool { started && (!rows.isEmpty || !information.isEmpty || !commandOutput.isEmpty) }
    var actionLogFailed: Bool { failed }
    var actionLogCancelled: Bool { cancelled }
}

private struct RevertProgressDialog: View {
    @ObservedObject var model: RevertProgressWindowModel
    var body: some View {
        VStack(spacing: 10) {
            RevertProgressTable(model: model).contextMenu {
                TurtleGitContextMenu {
                    Button { model.copyOutput() } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }
                }
            }
            HStack {
                Text(model.current).lineLimit(1).help(model.current).foregroundStyle(model.failed ? Color.red : model.cancelled ? Color.orange : Color.primary)
                Spacer()
                if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)).frame(width: 230) }
                else if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
            }
            if !model.commandOutput.isEmpty { SubmoduleProgressOutputView(text: model.commandOutput, completed: !model.busy, success: !model.failed && !model.cancelled, preferences: model.preferences).frame(height: 90) }
            if !model.information.isEmpty {
                ScrollView { Text(model.information).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(model.failed ? Color.red : Color.primary) }.frame(maxHeight: 110)
            }
            HStack {
                if !model.trashedFiles.isEmpty { Button { model.revealCopies() } label: { CommandLabel(title: "Show saved copies in Finder", icon: .explore) } }
                if !model.busy && !model.failed && !model.cancelled && !model.submodulePaths.isEmpty {
                    Button { model.handleSubmodules() } label: { CommandLabel(title: "Handle submodules", icon: .compare) }
                }
                if !model.busy && (model.failed || model.cancelled) { Button { model.retry() } label: { CommandLabel(title: "Retry", icon: .refresh) }.disabled(model.confirmingCancellation) }
                Spacer()
                if model.total > 0 { Text("\(model.completed) / \(model.total) operations").font(.caption).foregroundStyle(.secondary) }
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.busy || model.confirmingCancellation)
                Button("Cancel") { model.cancel() }.disabled(!model.busy || model.cancelRequested || model.confirmingCancellation)
            }
        }.padding(12)
    }
}

/// The shared upstream progress list has Action and Path columns. Keep worker
/// state in tooltips and color rather than adding a third visible column.
struct RevertProgressTable: NSViewRepresentable {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: RevertProgressWindowModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.make() }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.table.reloadData() }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: RevertProgressWindowModel
        let table = NSTableView()
        init(model: RevertProgressWindowModel) { self.model = model }
        func make() -> NSScrollView {
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
            table.dataSource = self; table.delegate = self; table.rowHeight = 22
            table.allowsMultipleSelection = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            for (id, title, width) in [("action", "Action", 180.0), ("path", "Path", 650.0)] {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
            }
            scroll.documentView = table; return scroll
        }
        func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard model.rows.indices.contains(row), let tableColumn else { return nil }
            let item = model.rows[row]
            let field = NSTextField(labelWithString: tableColumn.identifier.rawValue == "action" ? item.action : item.path)
            field.lineBreakMode = .byTruncatingMiddle; field.toolTip = item.path + "\n" + item.status
            switch item.status {
            case "Completed": field.textColor = NSColor(FileState.modified.textColor)
            case "Failed": field.textColor = NSColor(FileState.conflicted.textColor)
            case "Cancelled": field.textColor = .systemOrange
            default: field.textColor = .labelColor
            }
            guard tableColumn.identifier.rawValue == "action" else { return field }
            let cell = NSTableCellView(frame: NSRect(x: 0, y: 0, width: tableColumn.width, height: 22))
            let image = NSImageView(frame: NSRect(x: 2, y: 3, width: 16, height: 16)); image.image = MenuIcon.revert.image()
            cell.imageView = image; cell.textField = field; cell.toolTip = field.toolTip
            cell.addSubview(image); field.frame = NSRect(x: 23, y: 2, width: max(0, tableColumn.width - 26), height: 18)
            field.autoresizingMask = [.width]; cell.addSubview(field); return cell
        }
    }
}
