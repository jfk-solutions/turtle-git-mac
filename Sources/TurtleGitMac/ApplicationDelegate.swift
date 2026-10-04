import AppKit

@MainActor final class TurtleGitApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var repositoryModel: RepositoryModel?
    private var confirmingQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if confirmingQuit { return .terminateLater }
        let controllers = sender.windows.compactMap { $0.delegate as? TextConflictWindowController }
        guard repositoryModel?.busy != true, !controllers.contains(where: { $0.model.busy }) else { return .terminateCancel }
        guard controllers.contains(where: { $0.model.dirty }) else { return .terminateNow }
        confirmingQuit = true
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
            for controller in controllers { controller.model.confirmingQuit = false }
            confirmingQuit = false
            sender.reply(toApplicationShouldTerminate: allowQuit)
        }
        return .terminateLater
    }
}
