import AppKit
import TurtleGitCore

@main struct ReferenceLogDeletionVerification {
    @MainActor static func wait(_ model: ReferenceLogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy)
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Delete QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<4 { try Data("commit \(n)".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait(model); let original = model.entries
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        var prompts: [String] = [], accept: (() -> Void)?, changes = 0
        model.confirmDelete = { text, clear, proceed in precondition(!clear); prompts.append(text); accept = proceed }
        model.onChanged = { _ in changes += 1 }
        model.delete([original[0].id]); precondition(prompts.last == "\"HEAD@{0}\" will be permanently deleted. It can NOT be recovered!\n\nDo you really want to continue?")
        let declined = try await repo.referenceLog("HEAD"); precondition(declined == original && !model.busy); accept = nil // Abort never invokes proceed.
        model.delete([], clear: true); model.delete(["invalid"]); model.busy = true; model.delete([original[0].id]); model.busy = false; precondition(prompts.count == 1)
        model.delete([original[0].id, original[2].id]); precondition(prompts.last == "Do you really want to permanently delete the 2 selected refs? It can NOT be recovered!")
        accept?(); try await wait(model); precondition(model.error == nil && changes == 1 && model.entries.map(\.subject) == [original[1].subject, original[3].subject])
        let branch = try await repo.referenceLog("refs/heads/main"); precondition(branch.count == 4)
        model.delete([model.entries[0].id]); _ = try await repo.run(["reset", "--soft", "HEAD"])
        let newer = try await repo.referenceLog("HEAD"); accept?(); try await wait(model)
        precondition(model.error == ReferenceLogFailure.stale.localizedDescription && changes == 1 && model.entries == newer); model.error = nil
        model.delete([model.entries[0].id]); model.reference = "refs/heads/main"; accept?()
        precondition(model.error == ReferenceLogFailure.stale.localizedDescription && !model.busy && changes == 1); model.error = nil
        model.reload(); try await wait(model); let branchRows = model.entries
        model.delete(Set(branchRows.map(\.id))); accept?(); try await wait(model); precondition(model.entries.isEmpty && model.error == nil && changes == 2)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && index == afterIndex && config == afterConfig && file == afterFile)
        // General entry deletion must preserve stash drop's stack semantics.
        for n in 0..<3 { try Data("stash \(n)".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.saveStash(StashSaveOptions()) }
        model.reference = "refs/stash"; model.reload(); try await wait(model); let stashes = model.entries
        model.confirmDelete = { _, _, proceed in proceed() }
        model.delete([stashes[0].id, stashes[2].id]); try await wait(model); precondition(model.entries.map(\.hash) == [stashes[1].hash])
        model.delete([], clear: true); try await wait(model); precondition(model.entries.isEmpty && model.error == nil)
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait(chooser); var chooserPrompts = 0
        chooser.confirmDelete = { _, _, _ in chooserPrompts += 1 }; chooser.delete(Set(chooser.entries.map(\.id))); precondition(chooserPrompts == 0)
        for clear in [false, true] {
            let alert = ReferenceLogWindowController.deletionAlert(message: "QA", clear: clear)
            precondition(alert.buttons.map(\.title) == ["Delete", "Abort"] && alert.window.defaultButtonCell === alert.buttons[clear ? 1 : 0].cell)
            alert.window.close()
        }
        print("RefLog deletion: source singular/multiple prompts and Abort retention; HEAD reverse-index deletion, stale-after-prompt and changed-ref rejection, whole branch-log removal without moving HEAD/index/config/worktree, stash drop/Clear regression, chooser guards and actual hidden default-button alerts passed; no displayed prompt or physical click")
    }
}
