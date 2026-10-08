import AppKit
import TurtleGitCore

@MainActor final class RemoveWindowController: NSWindowController, NSWindowDelegate {
    let repository: GitRepository
    let request: RemovalRequest
    private let access: RepositoryAccessLease?
    var onClosed: () -> Void = {}
    var onChanged: (String) -> Void = { _ in }
    private var started = false
    private var handled = 0
    private var output: [String] = []
    private let spinner = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "Review the selected paths before removing them.")
    init(repository: GitRepository, access: RepositoryAccessLease?, request: RemovalRequest) {
        self.repository = repository; self.access = access; self.request = request
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 110), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "\(repository.root.lastPathComponent) – Delete\(request.keepLocal ? " (keep local)" : "") – TurtleGit"
        window.isReleasedWhenClosed = false
        spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        status.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [spinner, status]); stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([stack.centerYAnchor.constraint(equalTo: content.centerYAnchor), stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24)])
        }
        super.init(window: window); window.delegate = self; window.center()

        DialogGeometry.attach(window, identifier: "RemoveWindowController")
    }
    func start() {
        guard !started, let window else { return }; started = true
        if GitRuntime.isAppStoreBuild && (access?.hasSecurityScope != true || access?.contains(repository.root) != true) {
            let alert = NSAlert(error: RepositoryAccessFailure.securityScopeUnavailable)
            alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }; return
        }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = request.confirmation
        alert.informativeText = request.keepLocal
            ? "Local files will remain on disk. Their removal from version control will be staged."
            : "This removes the selected versioned files from the index and working tree, including local modifications. Commit to record the deletion."
        alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Remove")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn { self.next(0) } else { self.close() }
        }
    }
    private func next(_ index: Int) {
        guard index < request.paths.count else { finish(); return }
        let path = request.paths[index]
        status.stringValue = "Removing \(path)…"; spinner.startAnimation(nil)
        Task {
            do {
                let result = try await repository.removeVersionedPath(path, keepLocal: request.keepLocal)
                handled += 1; output.append(result); next(index + 1)
            } catch {
                spinner.stopAnimation(nil); status.stringValue = "Could not remove \(path)"
                output.append(error.localizedDescription)
                guard let window else { return }
                let alert = NSAlert(); alert.alertStyle = .critical
                alert.messageText = "Could not remove “\(path)”"; alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Abort"); alert.addButton(withTitle: "Ignore")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard let self else { return }
                    if response == .alertSecondButtonReturn { self.next(index + 1) } else { self.finish() }
                }
            }
        }
    }
    private func finish() {
        spinner.stopAnimation(nil); status.stringValue = "Removal finished"
        let summary = "\(handled) files removed."
        onChanged((output + [summary]).filter { !$0.isEmpty }.joined(separator: "\n"))
        guard let window else { return }
        let alert = NSAlert(); alert.alertStyle = .informational; alert.messageText = summary
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in self?.close() }
    }
    func windowWillClose(_ notification: Notification) { onClosed() }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
