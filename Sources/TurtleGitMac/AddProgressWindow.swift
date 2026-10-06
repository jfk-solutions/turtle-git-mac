import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AddProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: AddProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) {
        model = AddProgressWindowModel(repository: repository, access: access, paths: paths)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Add – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 330)
        window.contentViewController = NSHostingController(rootView: AddProgressView(model: model))
        super.init(window: window); window.delegate = self; window.setFrameAutosaveName("AddProgress"); window.center()
        model.close = { [weak window] in window?.close() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
struct AddProgressRow: Identifiable { var id: String { path }; let path: String }
@MainActor final class AddProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let paths: [String]
    private let access: RepositoryAccessLease?
    private let cancellation = OperationCancellation()
    private var started = false
    @Published var busy = true
    @Published var confirmingQuit = false
    @Published var success = false
    @Published var cancelled = false
    @Published var information = "Adding…"
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var onCommit: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String]) { self.repository = repository; self.access = access; self.paths = paths }
    func cancel() { guard busy else { return }; cancellation.cancel(); information = "Cancelling…" }
    func run() async {
        guard !started else { return }; started = true
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let output = try await repository.addReviewedPaths(paths, cancellation: cancellation)
            success = true; information = "\(paths.count) item(s) added." + (output.isEmpty ? "" : "\n" + output)
        } catch { cancelled = cancellation.isCancelled; information = cancelled ? "Cancelled. The index was not replaced." : error.localizedDescription }
        busy = false; onFinished(information, success)
    }
    func start() { Task { await run() } }
}
struct AddProgressView: View {
    @ObservedObject var model: AddProgressWindowModel
    var body: some View {
        VStack(spacing: 12) {
            Table(model.paths.map { AddProgressRow(path: $0) }) {
                TableColumn("Action") { _ in CommandLabel(title: "Add", icon: .add) }.width(100)
                TableColumn("Path", value: \.path)
                TableColumn("Status") { _ in Text(model.busy ? "In progress" : model.success ? "Added" : model.cancelled ? "Cancelled" : "Failed").foregroundStyle(model.success ? FileState.added.textColor : Color.primary) }.width(100)
            }
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.information).textSelection(.enabled); Spacer() }
            HStack {
                if model.success { Button { model.onCommit() } label: { CommandLabel(title: "Commit…", icon: .commit) } }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12).disabled(model.confirmingQuit)
    }
}
