// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Diagnosis is independent of repository adoption. Folder access authorizes
/// reading; only the explicit trust flow may modify protected Git configuration.
@MainActor final class InaccessibleRepositoryWindowModel: ObservableObject {
    static private(set) var activeOperations = 0
    let repository: GitRepository
    let access: RepositoryAccessLease
    let root: URL
    @Published private(set) var diagnosis: GitRepositoryDiagnosis?
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published private(set) var status = ""
    @Published var error: String?
    @Published var confirmingQuit = false
    private(set) var retired = false
    private(set) var trustReceipt: GitSafeDirectoryTrustReceipt?
    private var generation = UUID(), question: UUID?
    private var cancellation: OperationCancellation?
    private var pendingAnswer: ((Bool) -> Void)?
    private var closeAfterDrain = false
    var close: () -> Void = {}
    var onRetry: () -> Void = {}
    var dismissOwnedQuestion: (@escaping () -> Void) -> Void = { $0() }
    var askTrust: (String, @escaping (Bool) -> Void) -> Void = { _, reply in reply(false) }
    var authorizeConfiguration: (URL, @escaping (Bool) -> Void) -> Void = { _, reply in reply(false) }
    var readDiagnosis: (OperationCancellation) async throws -> GitRepositoryDiagnosis
    var prepareTrust: (GitRepositoryDiagnosis, OperationCancellation) async throws -> GitSafeDirectoryTrustPlan
    var configurationCandidates: (GitRepositoryDiagnosis) async throws -> [URL]
    var writeTrust: (GitSafeDirectoryTrustPlan, OperationCancellation) async throws -> GitSafeDirectoryTrustReceipt
    var requiresFolderScope = GitRuntime.isAppStoreBuild

    init(repository: GitRepository, access: RepositoryAccessLease, diagnosis: GitRepositoryDiagnosis? = nil) {
        self.repository = repository; self.access = access; root = repository.root; self.diagnosis = diagnosis
        readDiagnosis = { try await repository.diagnoseRepositoryAccess(cancellation: $0) }
        prepareTrust = { try await repository.prepareSafeDirectoryTrust($0, cancellation: $1) }
        configurationCandidates = { try await repository.safeDirectoryConfigurationCandidates($0) }
        writeTrust = { try await repository.addSafeDirectoryTrust($0, cancellation: $1) }
    }
    var available: Bool { !retired && !busy && !confirmingQuit }
    var canTrust: Bool { available && diagnosis?.canTrust == true }
    var canRetry: Bool { available && diagnosis != nil }
    var details: String { diagnosis?.detail ?? "" }
    var copyText: String { root.path + "\n\n" + details + (error.map { "\n\n" + $0 } ?? "") }
    func copy(to pasteboard: NSPasteboard = .general) { pasteboard.clearContents(); pasteboard.setString(copyText, forType: .string) }
    private func live(_ token: OperationCancellation) -> Bool {
        !retired && cancellation === token && !token.isCancelled
    }
    private func run(_ action: @escaping (OperationCancellation) async throws -> Void) {
        guard available else { return }
        let token = OperationCancellation(), request = generation
        cancellation = token; busy = true; cancelling = false; error = nil
        Self.activeOperations += 1
        Task { [self] in
            defer {
                Self.activeOperations -= 1
                withExtendedLifetime(access) {}
                if generation == request, cancellation === token {
                    cancellation = nil; busy = false; cancelling = false
                    if closeAfterDrain && !retired { closeAfterDrain = false; close() }
                }
            }
            do {
                guard access.contains(root), !requiresFolderScope || access.hasSecurityScope else { throw RepositoryAccessFailure.securityScopeUnavailable }
                try await action(token)
            } catch {
                guard !retired, generation == request, cancellation === token else { return }
                if token.isCancelled {
                    status = "Operation cancelled. Any completed configuration change is retained; refresh the diagnosis to inspect the repository."
                } else { self.error = error.localizedDescription }
            }
        }
    }
    func refresh() {
        run { [self] token in
            status = "Checking repository…"
            let value = try await readDiagnosis(token)
            guard live(token) else { return }
            diagnosis = value; status = value.canTrust ? "Review the diagnosis before choosing whether to trust this exact repository." : "Diagnosis complete."
        }
    }
    private func answer(_ present: (@escaping (Bool) -> Void) -> Void, token: OperationCancellation) async -> Bool {
        guard live(token), !confirmingQuit else { return false }
        let identity = UUID(); question = identity
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply: (Bool) -> Void = { [weak self] value in
                guard !answered else { return }; answered = true
                guard let self else { continuation.resume(returning: false); return }
                let accepted = self.question == identity && self.live(token) && !self.confirmingQuit
                if self.question == identity { self.question = nil; self.pendingAnswer = nil }
                continuation.resume(returning: accepted && value)
            }
            pendingAnswer = reply; present(reply)
        }
    }
    func trust() {
        guard canTrust, let accepted = diagnosis else { return }
        run { [self] token in
            // Candidate paths are lexical only. Acquire directory authority
            // before prepareTrust inspects/canonicalizes global/XDG files.
            let candidates = try await configurationCandidates(accepted)
            for file in candidates {
                guard live(token), await answer({ authorizeConfiguration(file, $0) }, token: token), live(token) else { return }
            }
            let plan = try await prepareTrust(accepted, token)
            guard live(token), await answer({ askTrust(plan.root.path + "\n\n" + plan.configurationFile.path, $0) }, token: token), live(token) else { return }
            guard live(token), await answer({ authorizeConfiguration(plan.configurationFile, $0) }, token: token), live(token) else { return }
            status = "Recording safe.directory…"
            let receipt = try await writeTrust(plan, token)
            trustReceipt = receipt
            guard !retired, cancellation === token else { return }
            status = "safe.directory was recorded. Choose Retry explicitly to reopen the repository."
            guard live(token) else { return }
            let latest = try await readDiagnosis(token)
            guard live(token) else { return }; diagnosis = latest
        }
    }
    func retry() { guard canRetry else { return }; onRetry() }
    func cancel() {
        guard busy, !cancelling else { return }
        cancelling = true; cancellation?.cancel()
        let reply = pendingAnswer; pendingAnswer = nil; question = nil
        dismissOwnedQuestion { reply?(false) }
    }
    @discardableResult func requestClose() -> Bool {
        guard busy else { return false }; closeAfterDrain = true; cancel(); return true
    }
    func retire() {
        guard !retired else { return }; retired = true
        cancellation?.cancel(); let reply = pendingAnswer; pendingAnswer = nil; question = nil
        dismissOwnedQuestion { reply?(false) }; generation = UUID()
    }
}

@MainActor final class InaccessibleRepositoryWindowController: NSWindowController, NSWindowDelegate {
    let model: InaccessibleRepositoryWindowModel
    var onClosed: () -> Void = {}
    var presentQuestion: ((NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var presentFolder: ((NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?
    var selectedFolder: (NSOpenPanel) -> URL? = { $0.url }
    var configurationAuthorized: (URL) -> Bool = { GitConfigurationPermissions.authorized($0) }
    var rememberConfiguration: (URL, URL) throws -> Void = { try GitConfigurationPermissions.remember($0, for: $1) }
    private var ownedSheet: NSWindow?
    init(repository: GitRepository, access: RepositoryAccessLease, diagnosis: GitRepositoryDiagnosis? = nil) {
        model = InaccessibleRepositoryWindowModel(repository: repository, access: access, diagnosis: diagnosis)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 690, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Inaccessible repository – TurtleGit"; window.minSize = .init(width: 580, height: 360); window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: InaccessibleRepositoryDialog(model: model)); host.sizingOptions = []
        window.contentViewController = host
        super.init(window: window); window.delegate = self
        model.close = { [weak self] in self?.window?.performClose(nil) }
        model.dismissOwnedQuestion = { [weak self] completion in
            guard let self else { completion(); return }; self.dismissQuestion(completion: completion)
        }
        model.askTrust = { [weak self] path, reply in
            guard let self, let window = self.window, !self.model.retired, window.attachedSheet == nil else { reply(false); return }
            let alert = NSAlert(); alert.messageText = "Add this repository to safe.directory?"
            alert.informativeText = path + "\n\nThis changes Git's protected global configuration. Folder access and Git repository trust are separate decisions."
            alert.alertStyle = .warning; alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Add to safe.directory")
            self.ownedSheet = alert.window
            let complete: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self, self.ownedSheet === alert.window else { reply(false); return }
                SettingsLifecycleSheetDrain.close([alert.window]) { [weak self] in
                    guard let self, self.ownedSheet === alert.window else { reply(false); return }
                    self.ownedSheet = nil; reply(response == .alertSecondButtonReturn)
                }
            }
            if let presentQuestion = self.presentQuestion { presentQuestion(alert, window, complete) }
            else { alert.beginSheetModal(for: window, completionHandler: complete) }
        }
        model.authorizeConfiguration = { [weak self] file, reply in self?.authorize(file, reply: reply) ?? reply(false) }
    }
    private func authorize(_ file: URL, reply: @escaping (Bool) -> Void) {
        guard !model.retired, let window, window.attachedSheet == nil else { reply(false); return }
        if configurationAuthorized(file) { reply(true); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.title = "Authorize Git configuration"; panel.prompt = "Authorize"
        panel.message = "Select the folder containing " + file.path + ". Git must create its adjacent lock file."
        var directory = file.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" { directory.deleteLastPathComponent() }
        panel.directoryURL = directory; panel.alphaValue = window.alphaValue; ownedSheet = panel
        let complete: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self, let panel, self.ownedSheet === panel else { reply(false); return }
            let directory = self.selectedFolder(panel)
            SettingsLifecycleSheetDrain.close([panel]) { [weak self] in
                guard let self, self.ownedSheet === panel else { reply(false); return }
                self.ownedSheet = nil
                guard !self.model.retired, !self.model.cancelling, !self.model.confirmingQuit, response == .OK, let directory else { reply(false); return }
                do { try self.rememberConfiguration(directory, file); reply(true) }
                catch { self.model.error = error.localizedDescription; reply(false) }
            }
        }
        if let presentFolder { presentFolder(panel, window, complete) }
        else { panel.beginSheetModal(for: window, completionHandler: complete) }
    }
    private func dismissQuestion(completion: @escaping () -> Void) {
        guard let sheet = ownedSheet else { completion(); return }
        SettingsLifecycleSheetDrain.close([sheet]) { [weak self] in
            if self?.ownedSheet === sheet { self?.ownedSheet = nil }; completion()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !model.confirmingQuit else { return false }
        if model.requestClose() { return false }
        return sender.attachedSheet == nil
    }
    func windowWillClose(_ notification: Notification) { model.retire(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct InaccessibleRepositoryDialog: View {
    @ObservedObject var model: InaccessibleRepositoryWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(nsImage: MenuIcon.clean.image() ?? NSImage()).resizable().frame(width: 32, height: 32); Text("Inaccessible repository").font(.headline) }
            Text(model.root.path).font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(3)
            ScrollView { Text(model.details).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(8).background(Color(nsColor: .textBackgroundColor))
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !model.status.isEmpty { Text(model.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button { model.copy() } label: { CommandLabel(title: "Copy", icon: .copy) }.disabled(model.details.isEmpty)
                Button { model.refresh() } label: { CommandLabel(title: "Refresh", icon: .refresh) }.disabled(!model.available)
                Spacer()
                if model.busy { ProgressView().controlSize(.small); Button("Cancel") { model.cancel() }.disabled(model.cancelling) }
                Button("Close") { model.close() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button("Add to safe.directory…") { model.trust() }.disabled(!model.canTrust)
                Spacer()
                Button("Retry") { model.retry() }.disabled(!model.canRetry)
            }
        }.padding(18)
    }
}
