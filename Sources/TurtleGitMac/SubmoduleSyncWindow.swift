// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleSyncWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleSyncWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, scope: [String], preferences: UserDefaults = .standard) {
        model = SubmoduleSyncWindowModel(repository: repository, access: access, scope: scope, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Sync – TurtleGit"; window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleSyncDialog(model: model))
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.activeOperation, self.window?.attachedSheet == nil else { return }; self.window?.close() }
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

@MainActor final class SubmoduleSyncWindowModel: ObservableObject, ActionLogProgress {
    let repository: GitRepository
    private let access: RepositoryAccessLease?, scope: [String], preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
    private let token = OperationCancellation()
    private var started = false, invalidated = false
    private var outputState: GitProgressOutputState
    @Published var busy = false
    @Published var confirmingCancellation = false
    @Published var confirmingQuit = false
    @Published var cancelling = false
    @Published var cancelled = false
    @Published var success = false
    @Published var output = ""
    @Published var exitCode: Int32?
    var close: () -> Void = {}
    var onSynced: (SubmoduleSyncResult) -> Void = { _ in }
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
        guard !started, !invalidated, !confirmingQuit else { return }; started = true; busy = true
        Task {
            defer { withExtendedLifetime(access) {} }
            do {
                if GitRuntime.isAppStoreBuild { guard access?.hasSecurityScope == true, access?.contains(repository.root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable } }
                let parser = GitCliOutputParser(limit: outputState.limit)
                let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let operation = Task {
                    defer { continuation.finish() }
                    return try await repository.syncSubmodules(scope: scope, cancellation: token, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { outputState.consume(parser.processPending(), parser: parser); output = outputState.output } }
                if !invalidated { outputState.consume(parser.processPending(), parser: parser); outputState.consume(parser.finish(), parser: parser); output = outputState.output }
                let result = try await operation.value
                guard !invalidated else { busy = false; return }
                exitCode = result.exitCode; success = result.success
                if output.isEmpty { output = "No directories to synchronize." }
                if !success { output += "\nGit commands failed (\(result.exitCode))." }
                onSynced(result)
            } catch {
                guard !invalidated else { busy = false; return }
                let message = token.isCancelled ? "Submodule synchronization cancelled." : error.localizedDescription
                output += (output.isEmpty || output.hasSuffix("\n") ? "" : "\n") + message
            }
            cancelled = token.isCancelled; busy = false; saveActionLog(); finishAutomaticClose()
        }
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
            OutputView(text: model.output).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Synchronizing…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Synchronization failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                Button(model.busy ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.confirmingCancellation || model.confirmingQuit)
            }
        }.padding(12)
    }
}
