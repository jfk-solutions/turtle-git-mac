// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleAddProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleAddProgressWindowModel
    var onClosed: () -> Void = {}
    init(model: SubmoduleAddProgressWindowModel) {
        self.model = model
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Add – TurtleGit"; window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleAddProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.presentSSH = { [weak window] prompt in
            guard let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            window.makeFirstResponder(nil)
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.beginSheetModal(for: window) { choose($0 == .alertFirstButtonReturn) }
        }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.saveActionLog(); model.invalidate()
        if let window, let child = window.attachedSheet { window.endSheet(child, returnCode: .abort); child.close() }
        onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleAddProgressWindowModel: ObservableObject, ActionLogProgress {
    let repository: GitRepository
    private var access: RepositoryAccessLease?, sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?
    private let options: SubmoduleAddOptions, preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private let identities: SSHIdentityAccessStore, makeSSHCoordinator: SSHCloneTransportFactory?
    private var token: OperationCancellation?, invalidated = false, started = false
    private var streamState: GitProgressOutputState
    @Published private(set) var busy = false
    @Published private(set) var success = false
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published var confirmingCancellation = false
    @Published var confirmingQuit = false
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    @Published private(set) var completionRange: NSRange?
    @Published private(set) var error: String?
    var close: () -> Void = {}
    var onAdded: (String) -> Void = { _ in }
    var presentSSH: (SSHKeyPassphraseWindowController) -> Bool = { _ in false }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var activeOperation: Bool { busy || confirmingCancellation || confirmingQuit }
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy }
    init(repository: GitRepository, access: RepositoryAccessLease?, sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?,
         options: SubmoduleAddOptions, preferences: UserDefaults = .standard, identities: SSHIdentityAccessStore = SSHIdentityAccessStore(), makeSSHCoordinator: SSHCloneTransportFactory? = nil) {
        self.repository = repository; self.access = access; self.sourceAccess = sourceAccess; self.keyAccess = keyAccess
        self.options = options; self.preferences = preferences; self.identities = identities; self.makeSSHCoordinator = makeSSHCoordinator
        autoClosePolicy = GitProgressAutoClose(preferences: preferences); streamState = GitProgressOutputState(preferences: preferences)
    }
    func start() { guard !started, !invalidated, !confirmingQuit else { return }; started = true; execute(options) }
    func retry() { guard started, !activeOperation, !invalidated, !success else { return }; ProgressActionLog.nextAttempt(self); execute(options) }
    private func execute(_ options: SubmoduleAddOptions) {
        let request = OperationCancellation(); token = request; busy = true; success = false; output = "Adding submodule…"; error = nil; streamState.reset(); currentWork = ""; percentage = nil; completionRange = nil; cancelled = false; cancelling = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        let factory = makeSSHCoordinator, identities = identities, presenter = presentSSH
        let grants = (access, sourceAccess, keyAccess)
        Task {
            let coordinator = factory?(repository) ?? SSHTransportCoordinator(repository: repository, identities: identities)
            if factory == nil { coordinator.present = presenter }
            defer { coordinator.close(); withExtendedLifetime(grants) {}; if token === request { token = nil; busy = false; if !invalidated { saveActionLog(); finishAutomaticClose() } } }
            do {
                if request.isCancelled { throw OperationCancellationFailure.cancelled }
                if GitRuntime.isAppStoreBuild {
                    guard grants.0?.hasSecurityScope == true, grants.0?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let source = options.source.trimmingCharacters(in: .whitespacesAndNewlines)
                    let local = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source).flatMap { $0.isFileURL ? $0 : nil }
                    if let local { guard grants.1?.hasSecurityScope == true, grants.1?.contains(local) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                }
                let parser = GitCliOutputParser(limit: streamState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.addSubmodule(options, cancellation: request, prepareTransport: options.sshKey.map { coordinator.explicitPreparation(path: $0.path) }, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { streamState.consume(parser.processPending(), parser: parser); refreshOutput() } }
                if !invalidated { streamState.consume(parser.processPending(), parser: parser); streamState.consume(parser.finish(), parser: parser); refreshOutput() }
                let text = try await operation.value
                guard !invalidated else { return }; if !streamState.hasOutput { output = text.isEmpty ? "Submodule added." : text }; success = true; finishOutput(success: true, request: request, startedAt: startedAt); onAdded(output)
            } catch {
                guard !invalidated else { return }
                let message: String
                if let failure = error as? GitFailure, streamState.hasOutput { message = "Git command failed (\(failure.code))." }
                else { message = error.localizedDescription }
                output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
                if !request.isCancelled { self.error = message }
                finishOutput(success: false, request: request, startedAt: startedAt, exitCode: (error as? GitFailure)?.code)
            }
        }
    }
    private func refreshOutput() {
        output = streamState.output; currentWork = streamState.currentWork; percentage = streamState.percentage
    }
    private func finishOutput(success: Bool, request: OperationCancellation, startedAt: TimeInterval, exitCode: Int32? = nil) {
        let completion = SubmoduleProgressCompletion(success: success, cancelled: request.isCancelled, exitCode: exitCode,
            elapsed: ProcessInfo.processInfo.systemUptime - startedAt, preferences: preferences)
        cancelled = request.isCancelled
        currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to: &output)
    }

    func invalidate() { invalidated = true; token?.cancel(); access = nil; sourceAccess = nil; keyAccess = nil }
    func cancel() {
        guard busy, !invalidated, !confirmingCancellation, !confirmingQuit, !cancelling else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.token?.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token?.cancel() }
    }
    private func finishAutomaticClose() {
        if !activeOperation, !invalidated, autoClosePolicy.shouldClose(success: success, postActionCount: success ? 0 : 1) { close() }
    }
}

private struct SubmoduleAddProgressDialog: View {
    @ObservedObject var model: SubmoduleAddProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adding submodule").font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red)
                .accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text:model.output, completed:!model.busy, completionRange:model.completionRange, success:model.success).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Adding…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Add failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                if !model.busy && !model.success { Button("Retry") { model.retry() }.disabled(model.activeOperation) }
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.success || model.confirmingCancellation || model.confirmingQuit || model.busy && model.cancelling)
            }
        }.padding(12)
    }
}
