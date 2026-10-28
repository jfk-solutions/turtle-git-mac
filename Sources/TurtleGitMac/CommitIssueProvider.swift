// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor final class CommitIssueProviderOwner {
    private weak var parent: NSWindow?
    private let model: CommitWindowModel
    private(set) var picker: IssueProviderPickerController?
    private(set) var runtimeAlert: NSAlert?
    var presentRuntimeFailure: (NSWindow, NSAlert, @escaping (NSApplication.ModalResponse) -> Void) -> Bool = { owner, alert, reply in
        alert.beginSheetModal(for: owner, completionHandler: reply); return true
    }
    private var runtimeReply: ((Bool) -> Void)?
    private var runtimeWatcher: Task<Void, Never>?
    private var settlingRuntimeFailure = false
    private var retired = false
    init(model: CommitWindowModel, parent: NSWindow) {
        self.model = model; self.parent = parent
        model.cancelProviderIssues = { [weak self] in self?.retire() }
        model.acknowledgeProviderCheckFailure = { [weak self] message, token in
            guard let self else { return false }
            return await self.acknowledgeRuntimeFailure(message, token: token, completion: false)
        }
        model.acknowledgeProviderCompletionFailure = { [weak self] message, token in
            guard let self else { return false }
            return await self.acknowledgeRuntimeFailure(message, token: token, completion: true)
        }
        model.chooseProviderIssues = { [weak self] provider, context in
            guard let self, self.model.messageFocusAvailable, self.picker == nil, let parent = self.parent, parent.attachedSheet == nil else { return nil }
            return await withCheckedContinuation { continuation in
                let child = IssueProviderPickerController(provider: provider, context: context) { [weak self] result in self?.picker = nil; continuation.resume(returning: result) }
                self.picker = child
                if let window = child.window { window.alphaValue = parent.alphaValue; window.appearance = parent.effectiveAppearance; parent.beginSheet(window) } else { child.close() }
            }
        }
    }
    private func acknowledgeRuntimeFailure(_ message: String, token: OperationCancellation, completion: Bool) async -> Bool {
        guard !retired, !token.isCancelled, !Task.isCancelled, model.messageFocusAvailable, !model.confirmingQuit,
              runtimeAlert == nil, let parent else { return false }
        let owner: NSWindow
        if completion, let progress = parent.attachedSheet,
           let controller = progress.delegate as? CommitProgressWindowController,
           controller.model === model.commitProgress { owner = progress }
        else { owner = parent }
        guard owner.attachedSheet == nil else { return false }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Issue provider"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.window.alphaValue = owner.alphaValue; alert.window.appearance = owner.effectiveAppearance
        runtimeAlert = alert; settlingRuntimeFailure = false
        return await withCheckedContinuation { reply in
            runtimeReply = { reply.resume(returning: $0) }
            runtimeWatcher = Task { @MainActor [weak self, weak alert] in
                while !Task.isCancelled {
                    guard let self, let alert, self.runtimeAlert === alert, !self.settlingRuntimeFailure else { return }
                    if token.isCancelled || self.retired || !self.model.messageFocusAvailable || self.model.confirmingQuit {
                        self.settleRuntimeFailure(alert, accepted: false, token: token); return
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
            }
            let presented = presentRuntimeFailure(owner, alert) { [weak self, weak alert] response in
                guard let self, let alert else { return }
                self.settleRuntimeFailure(alert, accepted: response == .alertFirstButtonReturn, token: token)
            }
            if !presented { settleRuntimeFailure(alert, accepted: false, token: token) }
        }
    }
    private func settleRuntimeFailure(_ alert: NSAlert, accepted: Bool, token: OperationCancellation) {
        guard runtimeAlert === alert, !settlingRuntimeFailure else { return }
        settlingRuntimeFailure = true; runtimeWatcher?.cancel(); runtimeWatcher = nil
        let child = alert.window, owner = alert.window.sheetParent
        if let parent = child.sheetParent { parent.endSheet(child, returnCode: .abort) }
        child.orderOut(nil)
        Task { @MainActor [self, alert] in
            while child.sheetParent != nil || owner?.attachedSheet === child {
                await withCheckedContinuation { reply in DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { reply.resume() } }
            }
            child.close()
            guard runtimeAlert === alert else { return }
            runtimeAlert = nil; settlingRuntimeFailure = false
            let reply = runtimeReply; runtimeReply = nil
            reply?(accepted && !retired && !token.isCancelled && model.messageFocusAvailable && !model.confirmingQuit)
        }
    }
    func retire() {
        retired = true; picker?.close(); picker = nil
        if let alert = runtimeAlert { settleRuntimeFailure(alert, accepted: false, token: OperationCancellation()) }
    }
}
