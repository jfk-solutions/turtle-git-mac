import AppKit
import TurtleGitCore

/// Captures pane bytes before its sheet. The optional successful-save callback
/// can rebind that pane; no callback or write publishes after owner retirement.
@MainActor final class MergeSourceExport {
    static private(set) var activeExports = 0
    private(set) var panel: NSSavePanel?
    private(set) var question: NSAlert?
    private weak var window: NSWindow?
    private var retired = false, writing = false
    var stateChanged: (Bool) -> Void = { _ in }
    var failure: (String) -> Void = { _ in }
    var present: (NSSavePanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { panel, owner, completion in panel.beginSheetModal(for: owner, completionHandler: completion) }
    var presentQuestion: (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = { alert, owner, completion in alert.beginSheetModal(for: owner, completionHandler: completion) }
    var selectedURL: (NSSavePanel) -> URL? = { $0.url }
    func save(_ bytes: Data, name: String, owner: NSWindow, warning: String? = nil, didSave: (@MainActor (URL, RepositoryAccessLease) async throws -> Void)? = nil) {
        guard !retired, !writing, panel == nil, question == nil, owner.attachedSheet == nil else { return }
        window = owner; stateChanged(true)
        if let warning {
            let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = warning
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Save")
            question = alert
            presentQuestion(alert, owner) { [weak self, alert, weak owner] response in
                guard let self, !self.retired, self.question === alert else { return }; self.question = nil
                guard response == .alertSecondButtonReturn, let owner else { self.stateChanged(false); return }
                self.showPanel(bytes, name: name, owner: owner, didSave: didSave)
            }
        } else { showPanel(bytes, name: name, owner: owner, didSave: didSave) }
    }
    private func showPanel(_ bytes: Data, name: String, owner: NSWindow, didSave: (@MainActor (URL, RepositoryAccessLease) async throws -> Void)?) {
        guard !retired, panel == nil, owner.attachedSheet == nil else { stateChanged(false); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.canCreateDirectories = true
        self.panel = panel; window = owner
        present(panel, owner) { [weak self, panel] response in
            guard let self, !self.retired, self.panel === panel else { return }
            self.panel = nil
            guard response == .OK, let url = self.selectedURL(panel) else { self.stateChanged(false); return }
            let lease = RepositoryAccessLease(url: url)
            guard !GitRuntime.isAppStoreBuild || lease.hasSecurityScope else { self.failure(RepositoryAccessFailure.securityScopeUnavailable.localizedDescription); self.stateChanged(false); return }
            self.writing = true; Self.activeExports += 1
            Task { [self, lease] in
                defer { self.writing = false; Self.activeExports -= 1; withExtendedLifetime(lease) {}; if !self.retired { self.stateChanged(false) } }
                guard !self.retired else { return }
                do {
                    try bytes.write(to: url, options: .atomic)
                    if !self.retired { try await didSave?(url, lease) }
                }
                catch { if !self.retired { self.failure(error.localizedDescription) } }
            }
        }
    }
    func retire() {
        guard !retired else { return }; retired = true
        if let question { window?.endSheet(question.window, returnCode: .alertFirstButtonReturn); question.window.orderOut(nil) }; question = nil
        if let panel { window?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }; panel = nil
        stateChanged = { _ in }; failure = { _ in }
    }
}
