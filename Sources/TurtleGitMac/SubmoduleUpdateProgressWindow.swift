// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class SubmoduleUpdateProgressWindowController: NSWindowController, NSWindowDelegate {
    let model: SubmoduleUpdateProgressWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults = .standard) {
        model = SubmoduleUpdateProgressWindowModel(repository: repository, access: access, paths: paths, options: options, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 430), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Submodule Update – TurtleGit"; window.contentMinSize = NSSize(width: 600, height: 320); window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SubmoduleUpdateProgressDialog(model: model))
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

@MainActor final class SubmoduleUpdateProgressWindowModel: ObservableObject, ActionLogProgress {
    let repository: GitRepository
    private let access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults, autoClosePolicy: GitProgressAutoClose
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
    var onUpdated: (String) -> Void = { _ in }
    var onBisect: (BisectOperation) -> Void = { _ in }
    @Published private(set) var postActions: [BisectOperation] = []
    private var dispatched = false
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var activeOperation: Bool { busy || confirmingCancellation || confirmingQuit }
    var actionLogRepository: URL { repository.root }
    var actionLogCancelled: Bool { cancelled }
    var actionLogEligible: Bool { started && !busy }
    init(repository: GitRepository, access: RepositoryAccessLease?, paths: [String], options: SubmoduleUpdateOptions, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.paths = paths; self.options = options; self.preferences = preferences
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
                    return try await repository.updateSubmodules(paths: paths, options: options, cancellation: token, onOutput: { chunk in parser.appendChunk(chunk.data); continuation.yield(()) })
                }
                for await _ in updates { if !invalidated { outputState.consume(parser.processPending(), parser: parser); output = outputState.output } }
                if !invalidated { outputState.consume(parser.processPending(), parser: parser); outputState.consume(parser.finish(), parser: parser); output = outputState.output }
                let result = try await operation.value
                guard !invalidated else { busy = false; return }
                // Use this worktree's administrative directory, not the common Git directory.
                var directory = try await repository.run(["rev-parse", "--absolute-git-dir"], cancellation: token).stdout
                if directory.last == 10 { directory.removeLast() }
                guard !invalidated, !token.isCancelled else { busy = false; return }
                let active = FileManager.default.fileExists(atPath: URL(fileURLWithPath: String(decoding: directory, as: UTF8.self)).appendingPathComponent("BISECT_START").path)
                exitCode = 0; success = true
                if output.isEmpty { output = "Submodule update completed." }
                postActions = active ? [.good, .bad, .skip, .reset] : []
                onUpdated(result)

            } catch {
                guard !invalidated else { busy = false; return }
                if let failure = error as? GitFailure { exitCode = failure.code }
                let message: String
                if token.isCancelled { message = "Submodule update cancelled." }
                else if let failure = error as? GitFailure, !output.isEmpty { message = "Git command failed (\(failure.code))." }
                else { message = error.localizedDescription }
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
    func perform(_ operation: BisectOperation) {
        guard !activeOperation, !invalidated, success, !dispatched, postActions.contains(operation) else { return }
        dispatched = true; onBisect(operation); close()
    }
    func action(for operation: BisectOperation) -> RepositoryAction {
        switch operation { case .good: return .bisectGood; case .bad: return .bisectBad; case .skip: return .bisectSkip; case .reset: return .bisectReset }
    }
    private func finishAutomaticClose() { if !activeOperation, !invalidated, autoClosePolicy.shouldClose(success: success, postActionCount: postActions.count) { close() } }
}

private struct SubmoduleUpdateProgressDialog: View {
    @ObservedObject var model: SubmoduleUpdateProgressWindowModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Updating submodules").font(.headline)
            Text(model.repository.root.path).font(.caption).textSelection(.enabled)
            OutputView(text: model.output).frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.busy ? model.cancelling ? "Cancelling…" : "Updating…" : model.cancelled ? "Cancelled" : model.success ? "Finished" : "Update failed").foregroundStyle(model.busy ? Color.primary : model.success ? Color.green : Color.red)
                Spacer()
                if let first = model.postActions.first {
                    Button { model.perform(first) } label: { CommandLabel(title: model.action(for: first).title, icon: model.action(for: first).icon) }.keyboardShortcut(.defaultAction).disabled(model.activeOperation)
                    Menu {
                        ForEach(model.postActions, id: \.self) { operation in
                            Button { model.perform(operation) } label: { CommandLabel(title: model.action(for: operation).title, icon: model.action(for: operation).icon) }
                        }
                    } label: { Image(systemName: "chevron.down").accessibilityLabel("Submodule update post-actions") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(model.activeOperation)
                }
                Button(model.busy ? "Cancel" : "Close") { if model.busy { model.cancel() } else { model.close() } }.keyboardShortcut(.cancelAction).disabled(model.confirmingCancellation || model.confirmingQuit)
            }
        }.padding(12)
    }
}
