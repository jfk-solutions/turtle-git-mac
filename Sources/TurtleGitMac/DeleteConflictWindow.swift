import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class DeleteConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: DeleteConflictWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) {
        model = DeleteConflictWindowModel(repository: repository, access: access, path: path)
        let size = NSSize(width: 760, height: 280)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(path) – Conflict – TurtleGit"; window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: DeleteConflictDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(size); window.center()
        model.close = { [weak window] in window?.close() }

        DialogGeometry.attach(window, identifier: "DeleteConflictWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class DeleteConflictWindowModel: ObservableObject {
    let repository: GitRepository
    let path: String
    private let access: RepositoryAccessLease?
    @Published var details: DeleteConflictDetails?
    @Published var busy = false
    @Published var error: String?
    @Published var patch: String?
    var close: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, path: String) { self.repository = repository; self.access = access; self.path = path }
    func abort() { if !busy { close() } }
    func load() {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { details = try await repository.deleteConflictDetails(path: path) }
            catch { self.error = error.localizedDescription }
        }
    }
    func resolve(deleting: Bool) {
        guard !busy, let details else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let output = try await repository.resolveDeleteConflict(details.entry, deleting: deleting)
                onChanged(output); close()
            } catch { self.error = error.localizedDescription }
        }
    }
    func compare() {
        guard !busy, let details, details.canCompare else { return }; busy = true
        Task {
            defer { busy = false }
            do { patch = try await repository.deleteConflictChanges(details.entry) }
            catch { self.error = error.localizedDescription }
        }
    }
}
private struct DeleteConflictDialog: View {
    @ObservedObject private var statusColorUpdates = StatusColorUpdates.shared
    @ObservedObject var model: DeleteConflictWindowModel
    func side(_ side: ConflictSide, details: DeleteConflictDetails) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(side.reference).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let commit = side.commit { Button { model.onLog(commit) } label: { CommandLabel(title: "Show log", icon: .log) }.frame(width: 140).accessibilityLabel("Show log for \(side.reference)") }
            }.frame(height: 26)
            HStack {
                Text(side.status).foregroundStyle(side.status == "Deleted" ? FileState.deleted.textColor : FileState.modified.textColor).frame(maxWidth: .infinity, alignment: .leading)
                if details.canCompare && side.stage == details.changedStage { Button { model.compare() } label: { CommandLabel(title: "Show changes", icon: .compare) }.frame(width: 140) }
            }.frame(height: 26)
        }
    }
    var body: some View {
        VStack(spacing: 12) {
            GroupBox("Delete/modify merge conflict") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let details = model.details { side(details.first, details: details); side(details.second, details: details) }
                    else { ProgressView().controlSize(.small).frame(height: 105) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }; Spacer()
                Button(model.details?.keepTitle ?? "Modified") { model.resolve(deleting: false) }.disabled(model.details == nil)
                Button("Delete") { model.resolve(deleting: true) }.disabled(model.details == nil)
                Button("Abort") { model.abort() }.keyboardShortcut(.defaultAction)
                Button { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-resolve.html")!) } label: { CommandLabel(title: "Help", icon: .help) }
            }
        }.padding(12).disabled(model.busy).onAppear { model.load() }
        .background(Button("") { model.abort() }.keyboardShortcut(.cancelAction).hidden())
        .alert("Could not resolve conflict", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .sheet(isPresented: Binding(get: { model.patch != nil }, set: { if !$0 { model.patch = nil } })) {
            VStack { Text("Show changes – \(model.path)").font(.headline); OutputView(text: model.patch ?? "").frame(minWidth: 850, minHeight: 520); Button("Close") { model.patch = nil }.keyboardShortcut(.cancelAction) }.padding(12)
        }
    }
}
