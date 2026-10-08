import AppKit
import TurtleGitCore

/// Upstream Apply/Pop run immediately, then offer the repository-status handoff.
@MainActor final class StashRestoreWindowController: NSWindowController, NSWindowDelegate {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    let pop: Bool
    private let reference: String?
    var onChanged: (String) -> Void = { _ in }
    var onViewChanges: () -> Void = {}
    var onClosed: () -> Void = {}
    private var started = false
    private let spinner = NSProgressIndicator()
    private let running = NSTextField(labelWithString: "Stash operation running…")
    private let waiting = NSTextField(labelWithString: "Please wait…")
    init(repository: GitRepository, access: RepositoryAccessLease?, pop: Bool, reference: String? = nil) {
        self.repository = repository; self.access = access; self.pop = pop; self.reference = reference
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
    }
    func start() {
        guard !started else { return }; started = true
        Task {
            do {
                if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) { throw RepositoryAccessFailure.securityScopeUnavailable }
                let result = try await repository.restoreStash(pop: pop, reference: reference)
                onChanged(result.output); present(result)
            } catch {
                spinner.stopAnimation(nil); running.stringValue = "Stash operation failed"; waiting.stringValue = ""
                onChanged(error.localizedDescription)
                guard let window else { return }
                let alert = NSAlert(); alert.alertStyle = .critical
                alert.messageText = "Stash \(pop ? "Pop" : "Apply") failed"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
            }
        }
    }
    private func present(_ result: StashRestoreResult) {
        guard let window else { return }
        spinner.stopAnimation(nil); running.stringValue = "Stash operation finished"; waiting.stringValue = ""
        let key = result.conflicted ? "StashPop.ShowConflictChanges" : "StashPop.ShowChanges"
        if pop, let saved = UserDefaults.standard.object(forKey: key) as? Bool {
            close(); if saved { onViewChanges() }; return
        }
        let alert = NSAlert(); alert.alertStyle = result.conflicted ? .warning : .informational
        alert.messageText = result.conflicted ? "Stash \(pop ? "Pop" : "Apply") failed, there are conflicts" : "Stash \(pop ? "Pop" : "Apply") successful"
        alert.informativeText = "Do you want to see changes?"
        alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
        if pop { alert.showsSuppressionButton = true; alert.suppressionButton?.title = "Remember my answer" }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            let show = response == .alertFirstButtonReturn
            if self.pop && alert.suppressionButton?.state == .on { UserDefaults.standard.set(show, forKey: key) }
            self.close(); if show { self.onViewChanges() }
        }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
