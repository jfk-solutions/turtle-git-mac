import AppKit
import TurtleGitCore

@main struct ReferenceLogSearchVerification {
    @MainActor static func wait(_ model: ReferenceLogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "RefLog QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for message in ["First Needle", "Second needle", "Third Needle"] {
            try Data(message.utf8).write(to: root.appendingPathComponent("file"))
            try await repo.stage(["file"]); _ = try await repo.commit(message: message)
        }
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let controller = ReferenceLogWindowController(repository: repo, access: nil, reference: "HEAD")
        defer { controller.close() }
        let model = controller.model
        try await wait(model); precondition(model.entries.count == 3)
        guard let window = controller.window as? ReferenceLogNativeWindow else { preconditionFailure("Wrong native window") }
        // Construct direct key-handler inputs; events are never sent to an application.
        func key(_ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        model.openFind = { [weak controller] in controller?.openFind(visible: false) }
        precondition(window.handleFunctionKey(key(99)))
        guard let finder = controller.findController, let findWindow = finder.window else { preconditionFailure("Find not opened") }
        precondition(findWindow.sheetParent == nil && window.attachedSheet == nil && !findWindow.isVisible && !window.isVisible)
        model.find = "Needle"; model.selection = [model.entries[1].id]
        model.matchCase = false; model.findNext(); precondition(model.selection == [model.entries[1].id]) // Start includes selected row.
        model.findNext(); precondition(model.selection == [model.entries[2].id])
        model.findNext(); precondition(model.searchWrapped && model.selection == [model.entries[0].id])
        precondition(window.handleFunctionKey(key(99))); precondition(controller.findController === finder && model.find == "Needle")
        model.find = "Other"; precondition(!model.searchWrapped)
        model.find = "Needle"
        model.matchCase = true; model.selection = [model.entries[1].id]; model.findNext(); precondition(model.selection == [model.entries[2].id])
        for query in [model.entries[0].hash, model.entries[0].selector, "commit"] {
            model.find = query; model.selection = [model.entries[0].id]; model.findNext(); precondition(model.selection == [model.entries[0].id])
        }
        model.find = "not present"; let selected = model.selection; model.findNext()
        precondition(model.error == "\"not present\" was not found." && model.selection == selected); model.error = nil
        model.busy = true; model.find = "Needle"; model.findNext(); precondition(model.selection == selected)
        precondition(!window.handleFunctionKey(key(99)) && !window.handleFunctionKey(key(96))); model.busy = false
        precondition(!window.handleFunctionKey(key(0)))
        precondition(window.handleFunctionKey(key(96))); try await wait(model)
        precondition(controller.findController === finder && !model.searchWrapped)
        finder.close(); precondition(controller.findController == nil)
        controller.openFind(visible: false); precondition(controller.findController != nil && model.find.isEmpty && !model.matchCase)
        let owned = controller.findController!
        var childCloses = 0; let releaseOwner = owned.onClosed
        owned.onClosed = { childCloses += 1; releaseOwner() }
        controller.close()
        precondition(controller.findController == nil, "Parent retained finder")
        precondition(childCloses == 1, "Owned finder did not close exactly once")
        precondition(owned.window?.isVisible == false && window.isVisible == false)
        let selecting = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        selecting.reload(); try await wait(selecting)
        selecting.find = "First"; selecting.findNext(); precondition(selecting.selectedEntry?.message == "First Needle")
        let endHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let endIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), endConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), endFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == endHead && index == endIndex && config == endConfig && file == endFile)
        print("RefLog modeless Find: hidden non-sheet singleton, F3 reuse, F5 refresh, selected-row cursor, repeated/wrapped/case/ref/action/hash searches, no-match and busy guards, close/reopen and parent cleanup, selection-mode search and unchanged HEAD/index/config/worktree passed; direct synthetic keys only")
    }
}
