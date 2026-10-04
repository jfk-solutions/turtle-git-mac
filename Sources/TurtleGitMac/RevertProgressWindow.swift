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
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool) {
        model = RevertProgressWindowModel(repository: repository, access: access, entries: entries, amend: amend, againstHead: againstHead, autoCloseSuccess: autoCloseSuccess)
        let window = RevertProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 550), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Revert Progress – TurtleGit"
        window.contentMinSize = NSSize(width: 800, height: 410); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RevertProgressDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 1000, height: 550)); window.setFrameAutosaveName("RevertProgressDialog"); window.center()
        model.close = { [weak window] in window?.close() }
        window.escape = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return true }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct RevertProgressRow: Identifiable {
    let id = UUID()
    let action: String
    let path: String
    var status: String
}

@MainActor final class RevertProgressWindowModel: ObservableObject {
    private let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let entries: [StatusEntry]
    private let amend: Bool
    private let againstHead: Bool
    private let autoCloseSuccess: Bool
    private let cancellation = OperationCancellation()
    private var started = false
    private var rowIndices: [String: Int] = [:]
    @Published fileprivate var rows: [RevertProgressRow] = []
    @Published var busy = true
    @Published var cancelRequested = false
    @Published var completed = 0
    @Published var total = 0
    @Published var current = "Preparing Revert…"
    @Published var information = ""
    @Published var failed = false
    @Published var cancelled = false
    @Published var trashedFiles: [URL] = []
    @Published var submodulePaths: [String] = []
    private var comparisonRevision: String?
    var onHandleSubmodules: (String, [String]) -> Void = { _, _ in }
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, entries: [StatusEntry], amend: Bool, againstHead: Bool, autoCloseSuccess: Bool) {
        self.repository = repository; self.access = access; self.entries = entries; self.amend = amend; self.againstHead = againstHead; self.autoCloseSuccess = autoCloseSuccess
    }
    func cancel() { guard busy, !cancelRequested else { return }; cancelRequested = true; cancellation.cancel(); current = "Cancelling after the current operation…" }
    private func receive(_ event: WorkingFileRevertProgress) {
        let key = event.step.rawValue + "\0" + event.path
        if let index = rowIndices[key] { rows[index].status = event.finished ? "Completed" : "In progress" }
        else { rowIndices[key] = rows.count; rows.append(RevertProgressRow(action: event.step.rawValue, path: event.path, status: event.finished ? "Completed" : "In progress")) }
        completed = event.completed; total = event.total
        if !cancelRequested { current = event.step.rawValue + ": " + event.path }
    }
    func start() {
        guard !started else { return }; started = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let (stream, continuation) = AsyncStream<WorkingFileRevertProgress>.makeStream()
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.revertWorkingFiles(entries, amend: amend, amendDiffToLastCommit: againstHead, cancellation: cancellation) { continuation.yield($0) }
                }
                for await event in stream { receive(event) }
                let result = try await operation.value
                submodulePaths = result.submodulePaths; comparisonRevision = result.comparisonRevision
                trashedFiles = result.trashedFiles
                information = "\(result.revertedPaths.count) file(s) reverted."
                current = "Finished"
                busy = false
                onFinished((result.trashedFiles.map { "Moved to Trash: " + $0.path } + [information]).joined(separator: "\n"), true)
                if autoCloseSuccess && submodulePaths.isEmpty { close() }
            } catch {
                let failure = error as? WorkingFileRevertFailure
                cancelled = failure?.wasCancelled == true || error is OperationCancellationFailure
                failed = !cancelled; trashedFiles = failure?.trashedFiles ?? []
                current = cancelled ? "Cancelled" : "Revert failed"
                information = error.localizedDescription
                if cancelled { information += "\n\nThe Git index was not replaced. Earlier working-file changes remain." }
                for index in rows.indices where rows[index].status == "In progress" { rows[index].status = cancelled ? "Cancelled" : "Failed" }
                busy = false; onFinished(information, false)
            }
        }
    }
    func handleSubmodules() {
        guard !busy, !failed, !cancelled, !submodulePaths.isEmpty, let revision = comparisonRevision else { return }
        close(); onHandleSubmodules(revision, submodulePaths)
    }
    func revealCopies() { guard !trashedFiles.isEmpty else { return }; NSWorkspace.shared.activateFileViewerSelecting(trashedFiles) }
    func copyOutput() {
        let text = rows.map { [$0.action, $0.path, $0.status].joined(separator: "\t") }.joined(separator: "\n") + "\n\n" + information
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct RevertProgressDialog: View {
    @ObservedObject var model: RevertProgressWindowModel
    private func color(_ status: String) -> Color {
        switch status { case "Completed": return .green; case "Failed": return .red; case "Cancelled": return .orange; default: return .primary }
    }
    var body: some View {
        VStack(spacing: 10) {
            Table(model.rows) {
                TableColumn("Action") { row in CommandLabel(title: row.action, icon: .revert) }.width(160)
                TableColumn("Path") { row in Text(row.path).lineLimit(1).help(row.path) }.width(min: 330, ideal: 530)
                TableColumn("Status") { row in Text(row.status).foregroundStyle(color(row.status)) }.width(115)
            }.contextMenu {
                Button { model.copyOutput() } label: { CommandLabel(title: "Copy to Clipboard", icon: .copy) }
            }
            HStack {
                Text(model.current).lineLimit(1).help(model.current).foregroundStyle(model.failed ? Color.red : model.cancelled ? Color.orange : Color.primary)
                Spacer()
                if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)).frame(width: 230) }
                else if model.busy { ProgressView().controlSize(.small) }
            }
            if !model.information.isEmpty {
                ScrollView { Text(model.information).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(model.failed ? Color.red : Color.primary) }.frame(maxHeight: 110)
            }
            HStack {
                if !model.trashedFiles.isEmpty { Button { model.revealCopies() } label: { CommandLabel(title: "Show saved copies in Finder", icon: .explore) } }
                if !model.busy && !model.failed && !model.cancelled && !model.submodulePaths.isEmpty {
                    Button { model.handleSubmodules() } label: { CommandLabel(title: "Handle submodules", icon: .compare) }
                }
                Spacer()
                if model.total > 0 { Text("\(model.completed) / \(model.total) operations").font(.caption).foregroundStyle(.secondary) }
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.busy)
                Button("Cancel") { model.cancel() }.disabled(!model.busy || model.cancelRequested)
            }
        }.padding(12)
    }
}
