import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CreateRepositoryWindowController: NSWindowController, NSWindowDelegate {
    let model: CreateRepositoryWindowModel
    var onClosed: () -> Void = {}
    init(folder: URL, access: RepositoryAccessLease) {
        model = CreateRepositoryWindowModel(folder: folder, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(folder.path) – Git Init – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CreateRepositoryDialog(model: model))
        super.init(window: window); window.delegate = self
        window.setContentSize(NSSize(width: 600, height: 190)); window.center()
        model.close = { [weak window] in window?.close() }
        model.confirm = { [weak window] warning, completion in
            guard let window else { return }
            let alert = NSAlert(); alert.alertStyle = .warning
            if warning == .specialFolder {
                alert.messageText = "Create a repository in this special folder?"
                alert.informativeText = "\(folder.path)\n\nThis is a system, volume or personal root folder. Its contents would become part of the repository’s scope."
            } else {
                alert.messageText = "Create a bare repository in a nonempty folder?"
                alert.informativeText = "\(folder.path)\n\nThis folder already contains files. A bare repository stores its Git data directly here and has no working tree."
            }
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Proceed")
            alert.beginSheetModal(for: window) { completion($0 == .alertSecondButtonReturn) }
        }
        model.showSuccess = { [weak window] in
            guard let window else { return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Repository created"
            alert.informativeText = "Initialized Git repository in \(folder.path)."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in window.close() }
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CreateRepositoryWindowModel: ObservableObject {
    let folder: URL
    let access: RepositoryAccessLease
    @Published var bare: Bool
    @Published var ready = false
    @Published var busy = false
    @Published var completed = false
    @Published var error: String?
    private var confirmed: Set<InitializationWarning> = []
    var close: () -> Void = {}
    var confirm: (InitializationWarning, @escaping (Bool) -> Void) -> Void = { _, _ in }
    var showSuccess: () -> Void = {}
    var onInitialized: (GitRepository, RepositoryAccessLease, Bool, String) -> Void = { _, _, _, _ in }
    init(folder: URL, access: RepositoryAccessLease) {
        self.folder = folder; self.access = access; bare = RepositoryInitialization.defaultsToBare(folder)
    }
    func prepare() {
        do {
            if try RepositoryInitialization.warnings(for: folder, bare: false).contains(.specialFolder) {
                confirm(.specialFolder) { [weak self] proceed in
                    guard let self else { return }
                    if proceed { self.confirmed.insert(.specialFolder); self.ready = true } else { self.close() }
                }
            } else { ready = true }
        } catch { self.error = error.localizedDescription }
    }
    func initialize() {
        guard ready, !busy, !completed else { return }
        do {
            guard access.contains(folder), !GitRuntime.isAppStoreBuild || access.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
            let warnings = try RepositoryInitialization.warnings(for: folder, bare: bare).subtracting(confirmed)
            let snapshot = bare
            busy = true
            review(Array([InitializationWarning.specialFolder, .nonemptyBare].filter(warnings.contains)), bare: snapshot)
        } catch { self.error = error.localizedDescription }
    }
    private func review(_ warnings: [InitializationWarning], bare: Bool) {
        guard let warning = warnings.first else { perform(bare: bare); return }
        confirm(warning) { [weak self] proceed in
            guard let self else { return }
            if proceed { self.confirmed.insert(warning); self.review(Array(warnings.dropFirst()), bare: bare) }
            else { self.busy = false; self.close() }
        }
    }
    private func perform(bare: Bool) {
        Task {
            defer { busy = false }
            do {
                let executable = try GitRuntime.executable()
                let cwd = try CloneOptions.workingDirectory(for: folder)
                guard access.contains(cwd) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(cwd.path) }
                let output = try await GitRepository(root: cwd, executable: executable).initialize(at: folder, bare: bare, confirmedWarnings: confirmed)
                let candidate = GitRepository(root: folder, executable: executable)
                let resolved = try await candidate.discoverRoot()
                guard access.contains(resolved) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path) }
                let repo = GitRepository(root: resolved, executable: executable)
                let actualBare = try await repo.isBare()
                completed = true; onInitialized(repo, access, actualBare, output)
                showSuccess()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct CreateRepositoryDialog: View {
    @ObservedObject var model: CreateRepositoryWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Make it Bare (No working directories)", isOn: $model.bare).toggleStyle(.checkbox)
            Text("If you plan to work inside this folder, leave this unchecked. Typically a bare repository receives changes through Push. By convention, a bare repository folder has a name ending in .git.")
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.initialize() }.keyboardShortcut(.defaultAction)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction)
                Button("Help") { NSWorkspace.shared.open(URL(string: "https://tortoisegit.org/docs/tortoisegit/tgit-dug-create.html")!) }
            }
        }.padding(16).disabled(!model.ready || model.busy || model.completed)
        .alert("Could not initialize a repository", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
