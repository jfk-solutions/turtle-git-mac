import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class CreateRepositoryWindowController: NSWindowController, NSWindowDelegate {
    let model: CreateRepositoryWindowModel
    var onClosed: () -> Void = {}
    private var ownedAlert: NSAlert?
    init(folder: URL, access: RepositoryAccessLease) {
        model = CreateRepositoryWindowModel(folder: folder, access: access)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "\(folder.path) – Git Init – TurtleGit"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CreateRepositoryDialog(model: model))
        super.init(window: window); TurtleGitHelp.attach(window, topic: .createRepository); window.delegate = self
        window.setContentSize(NSSize(width: 600, height: 190)); window.center()
        model.close = { [weak self] in guard let self, self.model.canClose else { return }; self.window?.close() }
        model.confirm = { [weak self, weak window] warning, completion in
            guard let self, !self.model.retired, let window, window.attachedSheet == nil else { completion(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            if warning == .specialFolder {
                alert.messageText = "Create a repository in this special folder?"
                alert.informativeText = "\(folder.path)\n\nThis is a system, volume or personal root folder. Its contents would become part of the repository’s scope."
            } else {
                alert.messageText = "Create a bare repository in a nonempty folder?"
                alert.informativeText = "\(folder.path)\n\nThis folder already contains files. A bare repository stores its Git data directly here and has no working tree."
            }
            alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Proceed")
            self.ownedAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, !self.model.retired, self.ownedAlert === alert else { return }; self.ownedAlert = nil; completion(response == .alertSecondButtonReturn)
            }
        }
        model.showSuccess = { [weak self, weak window] in
            guard let self, !self.model.retired, let window, window.attachedSheet == nil else { return }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Repository created"
            alert.informativeText = "Initialized Git repository in \(folder.path)."
            alert.addButton(withTitle: "OK")
            self.ownedAlert = alert
            alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
                guard let self, !self.model.retired, self.ownedAlert === alert else { return }; self.ownedAlert = nil; self.model.acknowledgeSuccess()
            }
        }

        DialogGeometry.attach(window, identifier: "CreateRepositoryWindowController")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.canClose && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.retire(); if let alert = ownedAlert { window?.endSheet(alert.window, returnCode: .cancel); alert.window.orderOut(nil) }; ownedAlert = nil; onClosed(); onClosed = {}
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class CreateRepositoryWindowModel: ObservableObject {
    static var activeOperations = 0
    private(set) var retired = false
    @Published private(set) var asking = false
    @Published private(set) var confirmingSuccess = false
    var canClose: Bool { !busy && !asking && !confirmingSuccess }
    var executable: URL?
    private var cancellation: OperationCancellation?
    private var questionGeneration = UUID()
    private var pendingSuccessClose = false
    func retire() { retired = true; questionGeneration = UUID(); cancellation?.cancel(); asking = false; confirmingSuccess = false; close = {}; onInitialized = { _, _, _, _ in }; showSuccess = {} }
    func acknowledgeSuccess() {
        guard !retired, confirmingSuccess else { return }; confirmingSuccess = false
        if busy { pendingSuccessClose = true } else { close() }
    }
    private func ask(_ warning: InitializationWarning, answered: @escaping (Bool) -> Void) {
        guard !retired, !asking else { return }; asking = true
        let identity = UUID(); questionGeneration = identity; var settled = false
        confirm(warning) { [weak self] proceed in
            guard !settled, let self, !self.retired, self.asking, self.questionGeneration == identity else { return }
            settled = true; self.asking = false; answered(proceed)
        }
    }
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
        guard !retired, !busy, !asking, !completed else { return }
        do {
            if try RepositoryInitialization.warnings(for: folder, bare: false).contains(.specialFolder) {
                ask(.specialFolder) { [weak self] proceed in
                    guard let self else { return }
                    if proceed { self.confirmed.insert(.specialFolder); self.ready = true } else { self.close() }
                }
            } else { ready = true }
        } catch { self.error = error.localizedDescription }
    }
    func initialize() {
        guard !retired, ready, !busy, !asking, !confirmingSuccess, !completed else { return }
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
        ask(warning) { [weak self] proceed in
            guard let self, !self.retired else { return }
            if proceed { self.confirmed.insert(warning); self.review(Array(warnings.dropFirst()), bare: bare) }
            else { self.busy = false; self.close() }
        }
    }
    private func perform(bare: Bool) {
        guard !retired else { return }
        let token = OperationCancellation(); cancellation = token; Self.activeOperations += 1
        Task { [self, access] in
            defer {
                Self.activeOperations -= 1; withExtendedLifetime(access) {}
                if cancellation === token { cancellation = nil; busy = false }
                if pendingSuccessClose, !retired { pendingSuccessClose = false; close() }
            }
            do {
                let executable = try self.executable ?? GitRuntime.executable()
                let cwd = try CloneOptions.workingDirectory(for: folder)
                guard access.contains(cwd) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(cwd.path) }
                let output = try await GitRepository(root: cwd, executable: executable).initialize(at: folder, bare: bare, confirmedWarnings: confirmed, cancellation: token)
                let candidate = GitRepository(root: folder, executable: executable)
                let resolved = try await candidate.discoverRoot(cancellation: token)
                guard access.contains(resolved) else { throw RepositoryAccessFailure.repositoryRootOutsidePermission(resolved.path) }
                let repo = GitRepository(root: resolved, executable: executable)
                let actualBare = try await repo.isBare(cancellation: token)
                try token.check(); guard !retired else { return }
                completed = true; confirmingSuccess = true; onInitialized(repo, access, actualBare, output)
                guard !retired else { return }; showSuccess()
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }

}

private struct CreateRepositoryDialog: View {
    @ObservedObject var model: CreateRepositoryWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Make it Bare (No working directories)", isOn: $model.bare).toggleStyle(.checkbox).disabled(model.busy || model.asking || model.completed)
            Text("If you plan to work inside this folder, leave this unchecked. Typically a bare repository receives changes through Push. By convention, a bare repository folder has a name ending in .git.")
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 22)
            Spacer(minLength: 0)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("OK") { model.initialize() }.keyboardShortcut(.defaultAction).disabled(!model.ready || model.busy || model.asking || model.completed)
                Button("Cancel") { model.close() }.keyboardShortcut(.cancelAction).disabled(!model.canClose)
                Button("Help") { TurtleGitHelp.show(.createRepository) }
            }
        }.padding(16)
        .alert("Could not initialize a repository", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
