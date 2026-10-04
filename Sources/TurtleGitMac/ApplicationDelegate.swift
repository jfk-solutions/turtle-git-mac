import AppKit

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var repositoryModel: RepositoryModel?
    private var confirmingQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmingQuit { return .terminateLater }
        let controllers = sender.windows.compactMap { $0.delegate as? TextConflictWindowController }
        let commits = sender.windows.compactMap { $0.delegate as? CommitWindowController }
        let reverts = sender.windows.compactMap { $0.delegate as? RevertWindowController }
        guard !reverts.contains(where: { $0.model.busy }), !commits.contains(where: { $0.model.busy }), repositoryModel?.busy != true, !controllers.contains(where: { $0.model.busy }) else { return .terminateCancel }
        guard !commits.isEmpty || controllers.contains(where: { $0.model.dirty }) else { return .terminateNow }
        confirmingQuit = true
        repositoryModel?.confirmingQuit = true
        for revert in reverts { revert.model.confirmingQuit = true }
        for commit in commits { commit.setQuitConfirmation(true) }
        for controller in controllers { controller.model.confirmingQuit = true }
        Task {
            var allowQuit = true
            for controller in controllers where controller.model.dirty {
                controller.window?.makeKeyAndOrderFront(nil)
                let alert = NSAlert(); alert.messageText = "Save changes to “\(controller.model.path)” before quitting?"
                alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Don’t Save"); alert.addButton(withTitle: "Cancel")
                switch alert.runModal() {
                case .alertFirstButtonReturn:
                    let saved = await withCheckedContinuation { continuation in
                        controller.model.save(markResolved: false) { continuation.resume(returning: $0) }
                    }
                    if !saved { allowQuit = false }
                case .alertSecondButtonReturn: break
                default: allowQuit = false
                }
                if !allowQuit { break }
            }
            if allowQuit {
                for commit in commits {
                    commit.window?.makeKeyAndOrderFront(nil)
                    let approved = await withCheckedContinuation { continuation in
                        commit.model.cancel(closeWindow: false) { continuation.resume(returning: $0) }
                    }
                    if !approved { allowQuit = false; break }
                }
            }
            if allowQuit { for commit in commits { commit.model.restoreCopies.removeAll() } }
            for revert in reverts { revert.model.confirmingQuit = false }
            for commit in commits { commit.setQuitConfirmation(false) }
            repositoryModel?.confirmingQuit = false
            for controller in controllers { controller.model.confirmingQuit = false }
            confirmingQuit = false
            sender.reply(toApplicationShouldTerminate: allowQuit)
        }
        return .terminateLater
    }
}
