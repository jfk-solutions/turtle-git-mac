import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class StashWindowController: NSWindowController, NSWindowDelegate {
    let model: StashWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?) {
        model = StashWindowModel(repository: repository, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Stash – TurtleGit"
        window.minSize = NSSize(width: 500, height: 272); window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 272)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: StashDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 560, height: 240)); window.center()
        model.close = { [weak window] in window?.close() }
        model.confirmUntracked = { [weak window] proceed in
            guard let window else { return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Include untracked files?"
            alert.informativeText = "Untracked files will be saved in the stash and removed from the working tree. Restore them by applying or popping the stash."
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Continue")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Do not show this warning again (if Continue is selected)"
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return }
                if alert.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "Stash.NoIncludeUntrackedWarning") }
                proceed()
            }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class StashWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published var options = StashSaveOptions()
    @Published var busy = false
    @Published var error: String?
    var confirmUntracked: (@escaping () -> Void) -> Void = { _ in }
    var close: () -> Void = {}
    var onSaved: (StashSaveResult) -> Void = { _ in }
    var onFailed: (String) -> Void = { _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?) { self.repository = repository; self.access = access }
    func save() {
        guard !busy else { return }
        let snapshot = options
        if snapshot.includeUntracked && !UserDefaults.standard.bool(forKey: "Stash.NoIncludeUntrackedWarning") {
            confirmUntracked { [weak self] in self?.perform(snapshot) }
        } else { perform(snapshot) }
    }
    private func perform(_ snapshot: StashSaveOptions) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { let result = try await repository.saveStash(snapshot); onSaved(result); close() }
            catch { let details = error.localizedDescription; self.error = details; onFailed(details) }
        }
    }
}
private struct StashDialog: View {
    @ObservedObject var model: StashWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Stash Message") { TextField("Optional stash message", text: $model.options.message).textFieldStyle(.roundedBorder).padding(8) }
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("include untracked", isOn: $model.options.includeUntracked).disabled(model.options.all)
                    Toggle("--all", isOn: $model.options.all).disabled(model.options.includeUntracked).help("Include untracked and ignored files.")
                }.toggleStyle(.checkbox).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.save() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-stash.html")!) }
            }
        }.padding(16).disabled(model.busy)
        .alert("Stash failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
