import AppKit
import TurtleGitCore

@MainActor enum ConflictPrompts {
    static func deleteSubmodule(_ request: SubmoduleDeletionRequest) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Delete “\(request.path)”?"
        alert.informativeText = request.gitError + "\n\nThe submodule folder could not be removed by Git. Delete moves the complete folder, including its local Git repository, to Trash and retries resolving the deletion."
        let delete = alert.addButton(withTitle: "Delete"); delete.keyEquivalent = ""
        let abort = alert.addButton(withTitle: "Abort"); abort.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
