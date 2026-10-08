import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class AddProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: AddProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mode: WorkingFileAddMode = .normal) {
        model = AddProgressWindowModel(repository: repository, access: access, paths: paths, mode: mode)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Add – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 580, height: 330)
        window.contentViewController = NSHostingController(rootView: AddProgressView(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }

        DialogGeometry.attach(window, identifier: "AddProgress", legacyName: "AddProgress")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.confirmingQuit }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class AddProgressWindowModel: ObservableObject {
    let repository: GitRepository
    let paths: [String]
    let mode: WorkingFileAddMode
    private let access: RepositoryAccessLease?
    private var cancellation = OperationCancellation()
    private var started = false
    @Published var busy = true
    @Published var confirmingQuit = false
    @Published var success = false
    @Published var cancelled = false
    @Published var information = "Adding…"
    var close: () -> Void = {}
    var onFinished: (String, Bool) -> Void = { _, _ in }
    var onCommit: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], mode: WorkingFileAddMode = .normal) { self.repository = repository; self.access = access; self.paths = paths; self.mode = mode; information = mode.rawValue + "…" }
    func cancel() { guard busy else { return }; cancellation.cancel(); information = "Cancelling…" }
    func run() async {
        guard !started else { return }; started = true
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let output = try await repository.addReviewedPaths(paths, mode: mode, cancellation: cancellation)
            success = true; information = "\(paths.count) item(s) added." + (output.isEmpty ? "" : "\n" + output)
        } catch { cancelled = cancellation.isCancelled; information = cancelled ? "Cancelled. The index was not replaced." : error.localizedDescription }
        busy = false; onFinished(information, success)
    }
    func changeMode(_ mode: WorkingFileAddMode) async {
        guard success, !busy, !confirmingQuit, mode != .normal else { return }
        cancellation = OperationCancellation(); busy = true; information = mode.rawValue + "…"
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            try await repository.setAddedFileMode(paths: paths, mode: mode, cancellation: cancellation)
            information = mode.rawValue + ": staged file modes updated."
        } catch {
            information = cancellation.isCancelled ? "Mode change cancelled. The index was not replaced." : error.localizedDescription
        }
        busy = false; onFinished(information, success)
    }
    func start() { Task { await run() } }
}
struct AddProgressView: View {
    @ObservedObject var model: AddProgressWindowModel
    var body: some View {
        VStack(spacing: 12) {
            AddProgressTable(model: model).frame(minHeight: 220)
            HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.information).textSelection(.enabled); Spacer() }
            HStack {
                if model.success {
                    HStack(spacing: 2) {
                        Button { model.onCommit() } label: { CommandLabel(title: "Commit…", icon: .commit) }
                        Menu {
                        Button { model.onCommit() } label: { CommandLabel(title: "Commit…", icon: .commit) }
                        if model.mode == .normal {
                            Button { Task { await model.changeMode(.executable) } } label: { CommandLabel(title: WorkingFileAddMode.executable.rawValue, icon: .add) }
                            Button { Task { await model.changeMode(.symlink) } } label: { CommandLabel(title: WorkingFileAddMode.symlink.rawValue, icon: .add) }
                        }
                        } label: { Image(systemName: "chevron.down").accessibilityLabel("Add post-actions") }
                        .menuStyle(.borderlessButton).fixedSize()
                    }.disabled(model.busy)
                }
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction) }
                else { Button("Close") { model.close() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(12).disabled(model.confirmingQuit)
    }
}
