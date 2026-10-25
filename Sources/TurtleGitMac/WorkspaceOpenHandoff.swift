// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// An external Finder/document request must not become a document owned by the
/// waiting Git tool process. Launch Services delivers it to a separate workspace.
@MainActor final class WorkspaceOpenHandoff {
    private final class Receipt {
        let urls: [URL]
        let leases: [RepositoryAccessLease]
        var failure: WorkspaceHandoffFailureController?
        var awaitingFailure = false
        init(_ urls: [URL]) {
            self.urls = urls
            leases = urls.filter(\.isFileURL).map { RepositoryAccessLease(url: $0) }
        }
    }
    private var receipts: [UUID: Receipt] = [:]
    private var retired = false
    var hasPendingWork: Bool { !receipts.isEmpty }
    var pendingCount: Int { receipts.count }
    var failureWindows: [NSWindow] { receipts.values.compactMap { $0.failure?.window } }
    var onStateChanged: () -> Void = {}
    var applicationURL: () -> URL = { Bundle.main.bundleURL }
    var owner: () -> NSWindow? = { NSApp.keyWindow }
    var launch: ([URL], URL, NSWorkspace.OpenConfiguration, @escaping (Error?) -> Void) -> Void = { urls, application, configuration, reply in
        guard application.isFileURL, application.pathExtension == "app" else {
            reply(WorkspaceHandoffFailure.unbundled); return
        }
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { _, error in
            Task { @MainActor in reply(error) }
        }
    }
    var presentFailure: ((String, @escaping () -> Void) -> Void)?
    static func accepts(_ url: URL) -> Bool {
        if url.isFileURL {
            return !url.path.contains("\0") && ["patch", "diff"].contains(url.pathExtension.lowercased())
        }
        return ["turtlegit://workspace","turtlegit://workspace?open=repository"].contains(url.absoluteString) || FinderRequest(url: url) != nil || (try? FinderServiceCommand.request(serviceURL:url)) != nil || (try? TurtleGitFinderServicesProvider.openSelection(from:url)) != nil
    }
    func submit(_ urls: [URL]) {
        guard !retired else { return }
        let accepted = urls.filter(Self.accepts)
        guard !accepted.isEmpty else { return }
        let id = UUID(), receipt = Receipt(accepted)
        receipts[id] = receipt; onStateChanged()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        let needsWorkspace=accepted.contains { $0.host == "service-open" || ["turtlegit://workspace","turtlegit://workspace?open=repository"].contains($0.absoluteString) }
        configuration.arguments=needsWorkspace ? []:["--turtlegit-action-only"]
        configuration.activates=accepted.contains { url in
            let action=FinderRequest(url:url)?.action ?? (try? FinderServiceCommand.request(serviceURL:url))?.action
            return action != .registerRepository
        }
        launch(accepted, applicationURL(), configuration) { [weak self, weak receipt] error in
            guard let self, let receipt, self.receipts[id] === receipt, !receipt.awaitingFailure else { return }
            guard !self.retired, let error else { self.finish(id); return }
            receipt.awaitingFailure = true
            let dismiss: () -> Void = { [weak self, weak receipt] in
                guard let self, let receipt, self.receipts[id] === receipt else { return }
                self.finish(id)
            }
            if let presentFailure = self.presentFailure { presentFailure(error.localizedDescription, dismiss) }
            else {
                let controller = WorkspaceHandoffFailureController(message: error.localizedDescription, onClosed: dismiss)
                receipt.failure = controller
                controller.present(owner: self.owner())
            }
        }
    }
    private func finish(_ id: UUID) {
        guard let receipt = receipts.removeValue(forKey: id) else { return }
        receipt.failure?.onClosed = {}; receipt.failure?.close()
        withExtendedLifetime(receipt.leases) {}
        onStateChanged()
    }
    func retire() {
        guard !retired else { return }; retired = true
        // Launched applications are independent user requests. Do not terminate
        // them. Keep in-flight receipts/scopes until Launch Services replies.
        for (id, receipt) in Array(receipts) where receipt.awaitingFailure { finish(id) }
        onStateChanged = {}
    }
}

private enum WorkspaceHandoffFailure: LocalizedError {
    case unbundled
    var errorDescription: String? { "Open the bundled TurtleGit for Mac application to handle Finder actions and patch documents." }
}

/// A non-modal, owned acknowledgment works even if the original Merge window
/// has already closed while Launch Services was starting the workspace.
@MainActor final class WorkspaceHandoffFailureController: NSWindowController, NSWindowDelegate {
    var onClosed: () -> Void
    private var ownerObserver: NSObjectProtocol?
    init(message: String, heading:String = "Unable to open the TurtleGit workspace", onClosed: @escaping () -> Void) {
        self.onClosed = onClosed
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 190), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "TurtleGit for Mac"
        super.init(window: window); window.delegate = self
        let heading = NSTextField(wrappingLabelWithString: heading)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        heading.preferredMaxLayoutWidth = 456
        let detail = NSTextField(wrappingLabelWithString: message); detail.isSelectable = true; detail.preferredMaxLayoutWidth = 456
        let button = NSButton(title: "OK", target: self, action: #selector(acknowledge(_:))); button.keyEquivalent = "\r"
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spacer, button]); footer.orientation = .horizontal
        let stack = NSStackView(views: [heading, detail, footer]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        window.contentView = NSView(); window.contentView!.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22), stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -18), footer.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        window.contentView!.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 500, height: max(190, stack.fittingSize.height + 44)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func present(owner: NSWindow?) {
        guard let window else { return }
        if let owner, owner.isVisible, owner.attachedSheet == nil {
            owner.beginSheet(window)
            ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        } else { window.center(); showWindow(nil); window.makeKeyAndOrderFront(nil) }
    }
    @objc private func acknowledge(_ sender: Any?) { close() }
    override func close() {
        if let window, let parent = window.sheetParent { parent.endSheet(window); window.orderOut(nil) }
        super.close()
    }
    func windowWillClose(_ notification: Notification) {
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
        let finished = onClosed; onClosed = {}; finished()
    }
    deinit { if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
}
