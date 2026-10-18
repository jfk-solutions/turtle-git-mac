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
        RepositoryWindowTitles.set(window, repository: model.repository.root, dialog: "Submodule Add", preferences: model.presentationPreferences); window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleAddProgressDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.presentSSH = { [weak window] prompt in
            guard let window, window.attachedSheet == nil, let child = prompt.window else { return false }
            child.alphaValue=window.alphaValue;child.appearance=window.appearance;window.makeFirstResponder(nil); window.beginSheet(child); return true
        }
        model.confirmCancellation = { [weak window] choose in
            guard let window, window.attachedSheet == nil else { choose(false); return }
            window.makeFirstResponder(nil)
            let alert = NSAlert(); alert.messageText = "The process is still running."; alert.informativeText = "Are you sure to abort?"
            let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            alert.window.alphaValue=window.alphaValue;alert.window.appearance=window.appearance
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
    private(set) static var activeOperations=0
    let repository: GitRepository
    private var access: RepositoryAccessLease?, sourceAccess: RepositoryAccessLease?, keyAccess: RepositoryAccessLease?
    var presentationPreferences: UserDefaults { preferences }
    private let options: SubmoduleAddOptions, preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private let identities: SSHIdentityAccessStore, makeSSHCoordinator: SSHCloneTransportFactory?
    private var token: OperationCancellation?, invalidated = false, started = false
    private var streamState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { streamState.presentation }
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
    var onAttemptCompleted:(SubmoduleAddOutcome)->Void = {_ in}
    @Published private(set) var lastOutcome=SubmoduleAddOutcome()
    var canRetry:Bool {started && !activeOperation && !invalidated && !success && (!lastOutcome.added || lastOutcome.receipt != nil)}
    var retryTitle:String {lastOutcome.added ? "Retry key configuration":"Retry"}
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
    func retry() { guard canRetry else { return }; ProgressActionLog.nextAttempt(self); execute(options,receipt:lastOutcome.added ? lastOutcome.receipt:nil) }
    private func execute(_ options: SubmoduleAddOptions,receipt:SubmoduleAddReceipt?=nil) {
        let request = OperationCancellation(); token = request; busy = true; success = false; output = receipt == nil ? "Adding submodule…":"Configuring the added submodule’s SSH key…"; error = nil; streamState.reset(); currentWork = ""; percentage = nil; completionRange = nil; cancelled = false; cancelling = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        let factory = makeSSHCoordinator, identities = identities, presenter = presentSSH
        let grants = (access, sourceAccess, keyAccess)
        let publish=onAttemptCompleted
        Self.activeOperations += 1
        Task {
            var outcome=SubmoduleAddOutcome(phase:receipt == nil ? .preparing:.configuringKey,added:receipt != nil,receipt:receipt)
            let coordinator:SSHTransportCoordinator?=receipt == nil ? (factory?(repository) ?? SSHTransportCoordinator(repository:repository,identities:identities)):nil
            if factory == nil {coordinator?.present=presenter}
            defer {
                coordinator?.close();withExtendedLifetime(grants) {};Self.activeOperations -= 1
                publish(outcome)
                if token === request {token=nil;busy=false;if !invalidated {saveActionLog();finishAutomaticClose()}}
            }
            do {
                if request.isCancelled { throw OperationCancellationFailure.cancelled }
                if GitRuntime.isAppStoreBuild {
                    guard grants.0?.hasSecurityScope == true, grants.0?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
                    let source = options.source.trimmingCharacters(in: .whitespacesAndNewlines)
                    let local = source.hasPrefix("/") ? URL(fileURLWithPath: source) : URL(string: source).flatMap { $0.isFileURL ? $0 : nil }
                    if receipt == nil,let local { guard grants.1?.hasSecurityScope == true, grants.1?.contains(local) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                    if let key=options.sshKey {guard grants.2?.hasSecurityScope == true,grants.2?.contains(key) == true else{throw RepositoryAccessFailure.securityScopeUnavailable}}
                }
                let parser = GitCliOutputParser(limit: streamState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    let observer:@Sendable (GitOutputChunk)->Void = {chunk in parser.appendChunk(chunk.data);continuation.yield(())}
                    if let receipt {return try await repository.retrySubmoduleAddKeyConfiguration(receipt,cancellation:request,onOutput:observer)}
                    return try await repository.addSubmoduleWithOutcome(options,cancellation:request,prepareTransport:options.sshKey.flatMap {key in coordinator.map {$0.explicitPreparation(path:key.path)}},onOutput:observer)
                }
                for await _ in updates { if !invalidated { streamState.consume(parser.processPending(), parser: parser); refreshOutput() } }
                if !invalidated { streamState.consume(parser.processPending(), parser: parser); streamState.consume(parser.finish(), parser: parser); refreshOutput() }
                outcome=try await operation.value
                guard !invalidated else{return};lastOutcome=outcome
                if !streamState.hasOutput {output=outcome.output.isEmpty ? (receipt == nil ? "Submodule added.":"Submodule SSH key configured."):outcome.output}
                success=true;finishOutput(success:true,request:request,startedAt:startedAt);onAdded(output)
            } catch {
                if let failure=error as? SubmoduleAddExecutionFailure {outcome=failure.outcome}
                else {outcome=SubmoduleAddOutcome(phase:receipt == nil ? .preparing:.configuringKey,added:receipt != nil,cancelled:request.isCancelled,output:error.localizedDescription,receipt:receipt)}
                guard !invalidated else {return};lastOutcome=outcome
                let underlying=(error as? SubmoduleAddExecutionFailure)?.underlying ?? error
                let message:String
                if outcome.added {message=error.localizedDescription}
                else if let failure=underlying as? GitFailure,streamState.hasOutput {message="Git command failed (\(failure.code))."}
                else {message=error.localizedDescription}
                output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
                if !request.isCancelled { self.error = message }
                finishOutput(success: false, request: request, startedAt: startedAt, exitCode: (underlying as? GitFailure)?.code)
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
            Text(model.lastOutcome.added && !model.success ? "Submodule added; SSH key configuration incomplete":"Adding submodule").font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red)
                .accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text:model.output, completed:!model.busy, completionRange:model.completionRange, success:model.success).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Adding…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Add failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                if !model.busy && !model.success { Button(model.retryTitle) { model.retry() }.disabled(!model.canRetry) }
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.success || model.confirmingCancellation || model.confirmingQuit || model.busy && model.cancelling)
            }
        }.padding(12)
    }
}
