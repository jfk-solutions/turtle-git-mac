import AppKit
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
    let repository: GitRepository
    let pop: Bool
    private let access: RepositoryAccessLease?
    private let reference: String?
    private let showChanges: Int
    private let preferences: UserDefaults
    private var started = false, completed = false, invalidated = false
    @Published private(set) var busy = false
    @Published private(set) var result: StashRestoreResult?
    @Published private(set) var error: String?
    @Published private(set) var prompt: StashRestorePrompt?
    var onChanged: (String) -> Void = { _ in }
    var onViewChanges: () -> Void = {}
    var close: () -> Void = {}
    var onStateChanged: () -> Void = {}
    var onPresent: (StashRestorePrompt, @escaping (Bool, Bool) -> Void) -> Void = { _, choose in choose(false, false) }
    init(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1, preferences: UserDefaults = .standard) {
        self.repository = repository; self.access = access; self.pop = pop; self.reference = reference; self.showChanges = showChanges; self.preferences = preferences
    }
    func invalidate() { invalidated = true; prompt = nil }
    func start() {
        guard !started, !invalidated else { return }; started = true; busy = true; onStateChanged()
        Task { await execute() }
    }
    private func execute() async {
        do {
            if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
            let restored = try await repository.restoreStash(pop: pop, reference: reference)
            result = restored; busy = false; onChanged(restored.output); onStateChanged()
            guard !invalidated else { return }
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
            self.error = error.localizedDescription; busy = false; onChanged(error.localizedDescription); onStateChanged()
            guard !invalidated else { return }
            present(StashRestorePrompt(kind: .error, message: "Stash \(pop ? "Pop" : "Apply") failed", detail: error.localizedDescription, conflicted: false, rememberKey: nil))
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
    init(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil, showChanges: Int = 1, preferences: UserDefaults = .standard) {
        model = StashRestoreWindowModel(repository: repository, access: access, pop: pop, reference: reference, showChanges: showChanges, preferences: preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Stash \(pop ? "Pop" : "Apply") – TurtleGit"
        window.isReleasedWhenClosed = false
        spinner.style = .spinning; spinner.startAnimation(nil)
        waiting.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [running, waiting]); labels.orientation = .vertical; labels.alignment = .leading
        let stack = NSStackView(views: [spinner, labels]); stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: content.centerYAnchor), stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)])
        }
        super.init(window: window); window.delegate = self; window.center()
        model.close = { [weak self] in guard let self, !self.model.busy, self.model.prompt == nil, self.window?.attachedSheet == nil else { return }; self.close() }
        model.onStateChanged = { [weak self] in
            guard let self else { return }
            if self.model.busy { self.spinner.startAnimation(nil) }
            else { self.spinner.stopAnimation(nil); self.running.stringValue = self.model.error == nil ? "Stash operation finished" : "Stash operation failed"; self.waiting.stringValue = "" }
        }
        model.onPresent = { [weak window] value, choose in
            guard let window, window.attachedSheet == nil else { choose(false, false); return }
            let alert = NSAlert(); alert.alertStyle = value.kind == .error ? .critical : value.conflicted && value.kind == .question ? .warning : .informational
            alert.messageText = value.message; alert.informativeText = value.detail
            if value.kind == .question {
                let yes = alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No"); yes.keyEquivalent = "\r"; alert.window.defaultButtonCell = yes.cell as? NSButtonCell
            } else { alert.addButton(withTitle: "OK") }
            if value.rememberKey != nil { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Remember my answer" }
            alert.beginSheetModal(for: window) { response in choose(value.kind == .question && response == .alertFirstButtonReturn, alert.suppressionButton?.state == .on) }
        }

        DialogGeometry.attach(window, identifier: "StashRestoreWindowController")
    }
    func start() { model.start() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && model.prompt == nil && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) { model.invalidate(); onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
