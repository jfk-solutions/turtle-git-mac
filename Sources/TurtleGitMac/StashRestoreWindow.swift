import AppKit
import SwiftUI
import Combine
import TurtleGitCore

struct StashRestorePrompt {
    enum Kind { case question, notice, error }
    let id = UUID()
    let kind: Kind
    let message: String
    let detail: String
    let conflicted: Bool
    let rememberKey: String?
}

/// Apply/Pop use system progress upstream, followed by a result question or notice.
/// They do not use AutoCloseGitProgress or the Git progress Retry menu.
@MainActor final class StashRestoreWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    let repository: GitRepository
    let pop: Bool
    private let access: RepositoryAccessLease?
    private let reference: String?
    private let showChanges: Int
    let preferences: UserDefaults
    private var started = false, completed = false, invalidated = false
    private var cancellation: OperationCancellation?
    @Published private(set) var cancelled = false
    @Published private(set) var cancelling = false
    @Published private(set) var confirmingCancellation = false
    @Published private(set) var busy = false
    @Published private(set) var result: StashRestoreResult?
    @Published private(set) var error: String?
    @Published private(set) var prompt: StashRestorePrompt?
    @Published private(set) var output = ""
    @Published private(set) var currentWork = ""
    @Published private(set) var percentage: Int?
    var success: Bool { result?.conflicted == false && !cancelled && error == nil }
    var restore: (Bool, String?, OperationCancellation) async throws -> StashRestoreResult {
        didSet { let replacement = restore; restoreStreaming = { pop, reference, token, _ in try await replacement(pop, reference, token) } }
    }
    var restoreStreaming: (Bool, String?, OperationCancellation, @escaping @Sendable (GitOutputChunk) -> Void) async throws -> StashRestoreResult
    var confirmCancellation: (@escaping (Bool) -> Void) -> Void = { $0(false) }
    var onChanged: (String) -> Void = { _ in }
    var onViewChanges: () -> Void = {}
    var close: () -> Void = {}
    var onStateChanged: () -> Void = {}
    var onPresent: (StashRestorePrompt, @escaping (Bool, Bool) -> Void) -> Void = { _, choose in choose(false, false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1, preferences: UserDefaults = .standard) {
        restore = { try await repository.restoreStash(pop: $0, reference: $1, cancellation: $2) }
        restoreStreaming = { try await repository.restoreStash(pop: $0, reference: $1, cancellation: $2, onOutput: $3) }
        self.repository = repository; self.access = access; self.pop = pop; self.reference = reference; self.showChanges = showChanges; self.preferences = preferences
    }
    func invalidate() { invalidated = true; cancellation?.cancel(); confirmingCancellation = false; prompt = nil }
    func cancel() {
        guard !invalidated, busy, !cancelling, !confirmingCancellation, let token = cancellation else { return }
        if preferences.object(forKey: "ConfirmKillProcess") as? Bool == false { cancelling = true; token.cancel(); onStateChanged(); return }
        confirmingCancellation = true; onStateChanged()
        confirmCancellation { [weak self] accepted in
            guard let self, !self.invalidated, self.busy, self.confirmingCancellation, self.cancellation === token else { return }
            self.confirmingCancellation = false
            if accepted { self.cancelling = true; token.cancel() }
            self.onStateChanged()
        }
    }
    func start() {
        guard !started, !invalidated else { return }; started = true
        let token = OperationCancellation(); cancellation = token; Self.activeOperations += 1
        busy = true; onStateChanged()
        Task { await execute(token) }
    }
    private func execute(_ token: OperationCancellation) async {
        LocalGitCommandProgress.begin()
        defer { Self.activeOperations -= 1; LocalGitCommandProgress.end(); withExtendedLifetime(access) {}; busy = false; cancelling = false; confirmingCancellation = false; cancellation = nil; currentWork = ""; percentage = nil }

        do {
            guard !invalidated else { return }
            if token.isCancelled { throw OperationCancellationFailure.cancelled }
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let restored = try await LocalGitCommandProgress.stream(preferences: preferences, update: { [weak self] state in
                guard let self, !self.invalidated, self.cancellation === token else { return }
                self.output = state.output; self.currentWork = state.currentWork; self.percentage = state.percentage; self.onStateChanged()
            }, resultText: { $0.output }, operation: { [self] emit in try await restoreStreaming(pop, reference, token, emit) })
            guard !invalidated else { return }
            if token.isCancelled { throw OperationCancellationFailure.cancelled }
            result = restored; busy = false; confirmingCancellation = false; onChanged(restored.output); onStateChanged()
            let question = pop ? showChanges == 1 || showChanges == 0 && restored.conflicted : showChanges != 0
            let title = restored.conflicted ? "Stash \(pop ? "Pop" : "Apply") failed, there are conflicts" : "Stash \(pop ? "Pop" : "Apply") successful"
            if question {
                let key = pop ? restored.conflicted ? "StashPop.ShowConflictChanges" : "StashPop.ShowChanges" : nil
                if let key, let saved = preferences.object(forKey: key) as? Bool { finish(show: saved); return }
                present(StashRestorePrompt(kind: .question, message: title, detail: "Do you want to see changes?", conflicted: restored.conflicted, rememberKey: key))
            } else if !pop || showChanges > 1 {
                present(StashRestorePrompt(kind: .notice, message: title, detail: "", conflicted: restored.conflicted, rememberKey: nil))
            } else { finish(show: false) }
        } catch {
            guard !invalidated else { return }
            cancelled = token.isCancelled || error is OperationCancellationFailure || error is GitCommandCancellationFailure
            let detail = (error as? GitCommandCancellationFailure)?.result.text ?? error.localizedDescription
            output = LocalGitCommandProgress.failure(error, existing: output, preferences: preferences)
            self.error = cancelled ? nil : detail; busy = false; confirmingCancellation = false; onChanged(detail); onStateChanged()
            if cancelled {
                present(StashRestorePrompt(kind: .notice, message: "Stash \(pop ? "Pop" : "Apply") cancelled", detail: "Working-tree/index or stash changes already made are retained. Review Working Tree before continuing.\n\n" + detail, conflicted: false, rememberKey: nil))
            } else {
                present(StashRestorePrompt(kind: .error, message: "Stash \(pop ? "Pop" : "Apply") failed", detail: detail, conflicted: false, rememberKey: nil))
            }
        }
    }
    private func present(_ value: StashRestorePrompt) {
        prompt = value
        onPresent(value) { [weak self] show, remember in
            guard let self, !self.invalidated, !self.completed, self.prompt?.id == value.id else { return }
            if let key = value.rememberKey, remember { self.preferences.set(show, forKey: key) }
            self.finish(show: value.kind == .question && show)
        }
    }
    private func finish(show: Bool) {
        guard !completed, !invalidated, !busy else { return }; completed = true; prompt = nil; close()
        if show { onViewChanges() }
    }
}

@MainActor final class StashRestoreWindowController: NSWindowController, NSWindowDelegate {
    let model: StashRestoreWindowModel
    var repository: GitRepository { model.repository }
    var pop: Bool { model.pop }
    var onChanged: (String) -> Void { get { model.onChanged } set { model.onChanged = newValue } }
    var onViewChanges: () -> Void { get { model.onViewChanges } set { model.onViewChanges = newValue } }
    var onClosed: () -> Void = {}
    private let spinner = NSProgressIndicator()
    private let running = NSTextField(labelWithString: "Stash operation running…")
    private let waiting = NSTextField(labelWithString: "Please wait…")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var ownedAlert: NSAlert?
    private var ownedReply: ((Bool, Bool) -> Void)?
    private var cancellationAlert = false
    private var closed = false
    init(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1, preferences: UserDefaults = .standard) {
        model = StashRestoreWindowModel(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 390), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        RepositoryWindowTitles.set(window, repository: repository.root, dialog: "Stash \(pop ? "Pop" : "Apply")", preferences: preferences)
        window.isReleasedWhenClosed = false
        spinner.style = .spinning; spinner.startAnimation(nil)
        waiting.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [running, waiting]); labels.orientation = .vertical; labels.alignment = .leading
        let stack = NSStackView(views: [spinner, labels, cancelButton]); stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        let output = NSHostingView(rootView: StashRestoreOutputPanel(model: model))
        let container = NSStackView(views: [output, stack]); container.orientation = .vertical; container.alignment = .leading; container.spacing = 12; container.translatesAutoresizingMaskIntoConstraints = false
        window.minSize = NSSize(width: 600, height: 320); window.contentView?.addSubview(container)
        if let content = window.contentView {
            NSLayoutConstraint.activate([container.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16), container.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), container.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), output.widthAnchor.constraint(equalTo: container.widthAnchor), output.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)])
        }
        super.init(window: window); window.delegate = self; window.center()
        cancelButton.target = self; cancelButton.action = #selector(cancelPressed); cancelButton.keyEquivalent = "\u{1b}"
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.prompt == nil, self.ownedAlert == nil else { return }; self.close() }
        model.onStateChanged = { [weak self] in
            guard let self else { return }
            self.cancelButton.isEnabled = self.model.busy && !self.model.cancelling && !self.model.confirmingCancellation
            self.cancelButton.isHidden = !self.model.busy
            if self.model.busy {
                if let percentage = self.model.percentage { self.spinner.style = .bar; self.spinner.isIndeterminate = false; self.spinner.minValue = 0; self.spinner.maxValue = 100; self.spinner.doubleValue = Double(percentage) }
                else { self.spinner.style = .spinning; self.spinner.isIndeterminate = true; self.spinner.startAnimation(nil) }
                self.waiting.stringValue = self.model.cancelling ? "Cancelling…" : self.model.currentWork.isEmpty ? "Please wait…" : self.model.currentWork
            } else {
                self.spinner.stopAnimation(nil)
                self.running.stringValue = self.model.cancelled ? "Stash operation cancelled" : self.model.error == nil ? "Stash operation finished" : "Stash operation failed"
                self.waiting.stringValue = ""
                if self.cancellationAlert { self.endOwnedAlert() }
            }
        }
        model.confirmCancellation = { [weak self] choose in
            guard let self else { choose(false); return }
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = "Cancel Stash \(pop ? "Pop" : "Apply")?"
            alert.informativeText = "Git may already have changed the working tree, index or stash. Completed changes will be retained."
            alert.addButton(withTitle: "No"); alert.addButton(withTitle: "Yes")
            self.present(alert, cancellation: true) { accepted, _ in choose(accepted) }
        }
        model.onPresent = { [weak self] value, choose in
            guard let self else { choose(false, false); return }
            let alert = NSAlert(); alert.alertStyle = value.kind == .error ? .critical : value.conflicted && value.kind == .question ? .warning : .informational
            alert.messageText = value.message; alert.informativeText = value.detail
            if value.kind == .question {
                let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            } else { alert.addButton(withTitle: "OK") }
            if value.rememberKey != nil { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Remember my answer" }
            self.present(alert, cancellation: false) { accepted, remember in choose(value.kind == .question && accepted, remember) }
        }

        DialogGeometry.attach(window, identifier: "StashRestoreWindowController")
    }
    @objc private func cancelPressed() { model.cancel() }
    private func present(_ alert: NSAlert, cancellation: Bool, choose: @escaping (Bool, Bool) -> Void) {
        if cancellationAlert && !cancellation { endOwnedAlert() }
        guard !closed, ownedAlert == nil, let window, window.attachedSheet == nil else { choose(false, false); return }
        ownedAlert = alert; cancellationAlert = cancellation
        var answered = false
        let reply: (Bool, Bool) -> Void = { accepted, remember in guard !answered else { return }; answered = true; choose(accepted, remember) }
        ownedReply = reply
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.ownedAlert === alert, !self.closed else { reply(false, false); return }
            self.ownedAlert = nil; self.ownedReply = nil; self.cancellationAlert = false
            reply(cancellation ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on)
        }
    }
    private func endOwnedAlert() {
        let alert = ownedAlert, reply = ownedReply; ownedAlert = nil; ownedReply = nil; cancellationAlert = false
        if let alert { window?.endSheet(alert.window, returnCode: .abort); alert.window.orderOut(nil) }
        reply?(false, false)
    }
    func start() { model.start() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if model.busy { model.cancel(); return false }; return model.prompt == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { guard !closed else { return }; closed = true; model.invalidate(); endOwnedAlert(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}


private struct StashRestoreOutputPanel: View {
    @ObservedObject var model: StashRestoreWindowModel
    var body: some View {
        SubmoduleProgressOutputView(text: model.output, completed: !model.busy, success: model.success, preferences: model.preferences)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
