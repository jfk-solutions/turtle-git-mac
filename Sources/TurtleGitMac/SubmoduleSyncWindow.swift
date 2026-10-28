// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleSyncWindowController: NSWindowController, NSWindowDelegate {
    var commandProgressScope: CommandProgressScope? { model.commandProgressScope }
    let model: SubmoduleSyncWindowModel
    var onClosed: () -> Void = {}
    private var closing=false
    private var release:FinderFilesystemWorkflowRelease?
    private var retiringChildren:[NSWindow]=[]
    private let question=SubmoduleServiceQuestion()
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool {get{question.presentQuestion}set{question.presentQuestion=newValue}}
    var finderServiceCanPresent:Bool {!closing && !model.isRetired}
    private var underlyingWorkPending:Bool {model.pendingOperations>0 || question.hasPendingWork || window?.sheetParent != nil || window?.attachedSheet != nil || retiringChildren.contains{$0.sheetParent != nil || $0.attachedSheet != nil}}
    var finderServiceWorkPending:Bool {release != nil || underlyingWorkPending}
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], preferences: UserDefaults = .standard) {
        model = SubmoduleSyncWindowModel(repository: repository, access: access, scope: scope, preferences: preferences)
        let window = SubmoduleProgressNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Submodule Sync", preferences: preferences); window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleSyncDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
        window.escapeAction = { [weak model] in guard let model else { return }; if model.busy { model.cancel() } else { model.close() } }
        model.confirmCancellation={ [weak self] choose in guard let self else{choose(false);return};self.question.ask(owner:self.window,choose:choose) }
        DialogGeometry.attach(window, identifier: "ProgressDlg")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return !model.activeOperation && sender.attachedSheet == nil }
    func windowWillClose(_ notification:Notification){
        guard notification.object as? NSWindow === window,!closing else{return};closing=true
        if let child=window?.attachedSheet{retiringChildren.append(child)}
        model.saveActionLog();question.retire();model.invalidate()
        if let window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.sheetParent?.endSheet(window,returnCode:.abort)}
        let release=FinderFilesystemWorkflowRelease(ready:{[self] in !underlyingWorkPending}){[self] in self.release=nil;retiringChildren.removeAll();let done=onClosed;onClosed={};done()};self.release=release;release.start()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class SubmoduleSyncWindowModel: ObservableObject, ActionLogProgress {
    let commandProgressScope = CommandProgressContext.current
    private(set) static var activeOperations=0
    private(set) var pendingOperations=0
    var isRetired:Bool {invalidated}
    let repository: GitRepository
    private let access: RepositoryAccessLease?, scope: [String], preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private let token = OperationCancellation()
    private var started = false, invalidated = false
    private var startedAt: TimeInterval = 0
    @Published private(set) var completionRange: NSRange?
    private var outputState: GitProgressOutputState
    var progressPresentation: GitCommandPresentation { outputState.presentation }
    @Published var busy = false
    @Published var confirmingCancellation = false
    @Published var confirmingQuit = false
    @Published var cancelling = false
    @Published var cancelled = false
    @Published var success = false
    @Published var currentWork = ""
    @Published var percentage: Int?
    @Published var output = ""
    @Published var exitCode: Int32?
    var close: () -> Void = {}
    var onSynced: (SubmoduleSyncResult) -> Void = { _ in }
    var onAttemptCompleted: (SubmoduleSyncResult) -> Void = { _ in }
    @Published private(set) var result: SubmoduleSyncResult?
    var presentationPreferences: UserDefaults { preferences }
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var activeOperation: Bool { busy || confirmingCancellation || confirmingQuit }
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy }
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.scope = scope; self.preferences = preferences
        autoClosePolicy = GitProgressAutoClose(preferences: preferences); outputState = GitProgressOutputState(preferences: preferences)
    }
    func invalidate() { invalidated = true; token.cancel() }
    func start() {
        CommandProgressContext.perform(commandProgressScope) { startInCommandProgressScope() }
    }
    private func startInCommandProgressScope() {
        guard !started, !invalidated, !confirmingQuit else { return }; started = true; busy = true; startedAt = ProcessInfo.processInfo.systemUptime;Self.activeOperations += 1;pendingOperations += 1
        Task {
            defer { Self.activeOperations -= 1;pendingOperations -= 1;withExtendedLifetime(access) {} }
            var receipt:SubmoduleSyncResult?
            do {
                if GitRuntime.isAppStoreBuild { guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                let parser = GitCliOutputParser(limit: outputState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.syncSubmodulesWorkflow(scope: scope, cancellation: token, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { consume(parser.processPending(), parser: parser) } }
                if !invalidated { consume(parser.processPending(), parser: parser); consume(parser.finish(), parser: parser) }
                let result = try await operation.value;receipt=result
                if !invalidated {
                    exitCode = result.exitCode; success = result.success
                    if output.isEmpty { output = "No directories to synchronize." }
                }
            } catch {
                if let failure=error as? SubmoduleSyncExecutionFailure {receipt=failure.result;if !invalidated {exitCode=failure.result.exitCode}}
                if !invalidated {
                    let message = token.isCancelled ? "Submodule synchronization cancelled." : error.localizedDescription
                    output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
                }
            }
            if let receipt,!receipt.entries.isEmpty {onAttemptCompleted(receipt)}
            guard !invalidated else{busy=false;return}
            result=receipt
            if token.isCancelled {success=false}
            cancelled = token.isCancelled
            let completion = SubmoduleProgressCompletion(success:success, cancelled:cancelled, exitCode:exitCode, elapsed:ProcessInfo.processInfo.systemUptime - startedAt, preferences:preferences)
            currentWork = completion.currentWork; percentage = 100; completionRange = completion.append(to:&output)
            busy = false; saveActionLog()
            if success,let receipt {onSynced(receipt)}
            if !invalidated {finishAutomaticClose()}
        }
    }
    private func consume(_ emission: GitCliOutputParser.Emission, parser: GitCliOutputParser) {
        outputState.consume(emission, parser: parser); output = outputState.output
        currentWork = outputState.currentWork; percentage = outputState.percentage
    }
    func cancel() {
        guard busy, !invalidated, !confirmingCancellation, !confirmingQuit, !cancelling else { return }
        if preferences.bool(forKey: "ConfirmKillProcess") {
            confirmingCancellation = true; var answered = false
            confirmCancellation { [weak self] accepted in
                guard !answered, let self, !self.invalidated else { return }; answered = true; self.confirmingCancellation = false
                if self.busy && accepted { self.cancelling = true; self.token.cancel() }
                self.finishAutomaticClose()
            }
        } else { cancelling = true; token.cancel() }
    }
    private func finishAutomaticClose() { if !activeOperation, !invalidated, autoClosePolicy.shouldClose(success: success, postActionCount: 0) { close() } }
}

private struct SubmoduleSyncDialog: View {
    @ObservedObject var model: SubmoduleSyncWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronizing submodule URLs").font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            Text(model.currentWork.isEmpty ? " " : model.currentWork).font(.caption).lineLimit(1).help(model.currentWork)
            ProgressView(value: Double(model.busy ? model.percentage ?? 0 : 100), total: 100)
                .tint(model.busy ? .accentColor : model.success ? .blue : .red)
                .accessibilityLabel("Git command progress")
            SubmoduleProgressOutputView(text:model.output, completed:!model.busy, completionRange:model.completionRange, success:model.success).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { GitCommandActivity(animate: model.progressPresentation.animateActivity) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Synchronizing…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Synchronization failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                Button("Close") { model.close() }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                Button("Abort") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.success || model.confirmingCancellation || model.confirmingQuit || model.busy && model.cancelling)
            }
        }.padding(12)
    }
}
