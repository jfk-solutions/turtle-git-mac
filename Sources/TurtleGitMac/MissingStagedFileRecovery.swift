// SPDX-License-Identifier: GPL-2.0-or-later
// Adapts GitStatusListCtrl::UpdateFileList's missing staged-file recovery.
import AppKit
import TurtleGitCore

/// One accepted status read owns the complete prompt/mutation sequence. The
/// captured list is intentionally not recollected after a successful repair.
@MainActor final class MissingStagedFileRecoverySession {
    struct Choice {
        let action: MissingStagedFileAction
        var doSameForRest = false
    }
    private(set) static var activeRequests = 0
    weak var ownerWindow: NSWindow?
    var choose: ((MissingStagedFile) async -> Choice?)?
    var showFailure: ((String) async -> Void)?
    var showRefreshNotice: (() async -> Void)?
    private(set) var alert: NSAlert?
    private(set) var busy = false
    private(set) var retired = false
    private(set) var refreshRequired = false
    private var token: OperationCancellation?

    func cancel() {
        token?.cancel()
        dismissAlert()
    }
    func retire() { retired = true; cancel() }
    private func dismissAlert() {
        guard let alert else { return }
        if let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
        alert.window.orderOut(nil)
    }
    func process(repository: GitRepository, entries: [StatusEntry], token: OperationCancellation,
                 isAvailable: @escaping () -> Bool) async throws {
        guard !busy, !retired else { throw OperationCancellationFailure.cancelled }
        func check() throws {
            try token.check()
            guard !retired, isAvailable(), !Task.isCancelled else { throw OperationCancellationFailure.cancelled }
        }
        try check()
        busy = true; self.token = token; refreshRequired = false
        Self.activeRequests += 1
        defer { busy = false; self.token = nil; Self.activeRequests -= 1 }
        // Cancellation can arrive while AppKit is awaiting an attached sheet.
        // End that owned sheet, then let its completion drain the continuation.
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if token.isCancelled || self.retired || !isAvailable() { token.cancel(); self.dismissAlert(); return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        defer { watcher.cancel() }
        let eligible = entries.filter { [Character("A"), "M", "R", "C", "T"].contains($0.index) && $0.state != .conflicted }
        guard !eligible.isEmpty else { return }
        let candidates = try await repository.missingStagedFiles(in: eligible, cancellation: token)
        try check()
        var repeated: Choice?
        for candidate in candidates {
            try check()
            let choice: Choice?
            if let repeated { choice = repeated }
            else if let choose { choice = await choose(candidate) }
            else { choice = await chooseNative(candidate) }
            try check()
            guard let choice else { token.cancel(); throw OperationCancellationFailure.cancelled }
            if choice.doSameForRest { repeated = choice }
            if choice.action == .ignore { continue }
            do {
                let result = try await repository.recoverMissingStagedFile(candidate, action: choice.action, cancellation: token)
                try check()
                refreshRequired = refreshRequired || result.changed
            } catch {
                try check()
                let message = (choice.action == .restoreFromIndex ? "Restoring from index failed:\n" : "Removing from index failed:\n") + candidate.path + "\n\n" + error.localizedDescription
                if let showFailure { await showFailure(message) }
                else { await showNative(message, style: .critical) }
                try check()
            }
        }
        if refreshRequired {
            if let showRefreshNotice { await showRefreshNotice() }
            else { await showNative("Due to changes to the index, please refresh the dialog (e.g., by pressing F5).", style: .informational) }
            try check()
        }
    }
    private func chooseNative(_ candidate: MissingStagedFile) async -> Choice? {
        guard let ownerWindow, ownerWindow.attachedSheet == nil, !retired, token?.isCancelled == false else { return nil }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "The staged file does not exist"
        alert.informativeText = "TurtleGit detected that the file \"" + candidate.path + "\" does not exist, but is staged as Added or Modified.\nThe commit dialog cannot handle this.\n\nDo you want to restore or remove it from the index?"
        alert.addButton(withTitle: "Restore this file from index")
        alert.addButton(withTitle: "Remove this file from index")
        let ignore = alert.addButton(withTitle: "Ignore"); ignore.keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do the same for the rest"
        guard let response = await present(alert, owner: ownerWindow) else { return nil }
        let action: MissingStagedFileAction
        switch response {
        case .alertFirstButtonReturn: action = .restoreFromIndex
        case .alertSecondButtonReturn: action = .removeFromIndex
        case .alertThirdButtonReturn: action = .ignore
        default: return nil
        }
        return Choice(action: action, doSameForRest: alert.suppressionButton?.state == .on)
    }

    private func showNative(_ message: String, style: NSAlert.Style) async {
        guard let ownerWindow, ownerWindow.attachedSheet == nil, !retired, token?.isCancelled == false else { return }
        let alert = NSAlert(); alert.alertStyle = style; alert.messageText = message
        alert.addButton(withTitle: "OK")
        _ = await present(alert, owner: ownerWindow)
    }
    private func present(_ alert: NSAlert, owner: NSWindow) async -> NSApplication.ModalResponse? {
        self.alert = alert
        alert.window.alphaValue = owner.alphaValue; alert.window.appearance = owner.effectiveAppearance
        let response: NSApplication.ModalResponse = await withCheckedContinuation { reply in
            alert.beginSheetModal(for: owner) { reply.resume(returning: $0) }
        }
        // AppKit's completion can precede its detachment animation. Retain the
        // read, owning permission lease and Quit fence until the child drains.
        while alert.window.sheetParent != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        alert.window.orderOut(nil)
        if self.alert === alert { self.alert = nil }
        return response
    }
}
