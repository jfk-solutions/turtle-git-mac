import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class RenameWindowController: NSWindowController, NSWindowDelegate {
    let model: RenameWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        model = RenameWindowModel(repository: repository, access: access, source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 150), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Rename – TurtleGit"
        window.contentMinSize = NSSize(width: 520, height: 150)
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 150)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: RenameDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak window] in window?.close() }
        model.browse = { [weak self] in self?.browse() }

        DialogGeometry.attach(window, identifier: "RenameDialog", legacyName: "RenameDialog")
    }
    private func browse() {
        guard let window else { return }
        let panel = NSSavePanel()
        let original = model.repository.root.appendingPathComponent(model.source)
        panel.title = "Rename"; panel.prompt = "Choose destination"
        panel.directoryURL = original.deletingLastPathComponent(); panel.nameFieldStringValue = model.name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let target = panel.url else { return }
            model?.chooseDestination(target)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class RenameWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let source: String
    @Published var name: String
    @Published var busy = false
    @Published var error: String?
    var close: () -> Void = {}
    var browse: () -> Void = {}
    var onRenamed: (String, String, String) -> Void = { _, _, _ in }
    init(repository: GitRepository, access: RepositoryAccessLease?, source: String) {
        self.repository = repository; self.access = access; self.source = source
        name = (source as NSString).lastPathComponent
    }
    func chooseDestination(_ target: URL) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do {
                let root = repository.root.standardizedFileURL.path
                guard target.isFileURL, target.path.hasPrefix(root + "/") else { throw RenameFailure.outsideWorkingTree }
                let parent = try CloneOptions.workingDirectory(for: target.deletingLastPathComponent())
                let targetRoot = try await GitRepository(root: parent, executable: repository.executable).discoverRoot()
                guard targetRoot.resolvingSymlinksInPath() == repository.root.resolvingSymlinksInPath() else { throw RenameFailure.outsideWorkingTree }
                let base = repository.root.appendingPathComponent(source).deletingLastPathComponent().path
                // Express a same-worktree move relative to the source's directory.
                let from = base.split(separator: "/"), to = target.path.split(separator: "/")
                var shared = 0
                while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
                let relative = Array(repeating: "..", count: from.count - shared) + to.dropFirst(shared).map(String.init)
                let proposed = relative.joined(separator: "/")
                _ = try RenameOptions(source: source, name: proposed).destination(root: repository.root)
                name = proposed
            } catch { self.error = error.localizedDescription }
        }
    }
    func rename() {
        guard !busy else { return }
        let options = RenameOptions(source: source, name: name)
        do {
            let destination = try options.destination(root: repository.root)
            if GitRuntime.isAppStoreBuild && access?.contains(repository.root) != true { throw RepositoryAccessFailure.securityScopeUnavailable }
            busy = true
            Task {
                defer { busy = false }
                do {
                    let output = try await repository.rename(options)
                    onRenamed(source, destination, output); close()
                } catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct RenameDialog: View {
    @ObservedObject var model: RenameWindowModel
    @FocusState private var nameFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename “\((model.source as NSString).lastPathComponent)”: ").lineLimit(2).help(model.source)
            HStack {
                Text("New name:").frame(width: 90, alignment: .leading)
                TextField("New name", text: $model.name).textFieldStyle(.roundedBorder).focused($nameFocused)
                Button("…") { model.browse() }.help("Choose a destination in the same working tree")
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.rename() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
            }
        }.padding(16).disabled(model.busy).onAppear { nameFocused = true }
        .alert("Could not rename", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil; nameFocused = true }
        } message: { Text(model.error ?? "") }
    }
}
