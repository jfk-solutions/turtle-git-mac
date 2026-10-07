import AppKit
import TurtleGitCore

@main struct ReferenceLogRevisionHandoffsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Handoff QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<3 { try Data("commit \(n)".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        try Data("dirty working content".utf8).write(to: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil)
        let older = model.entries[1], ids: Set<String> = [older.id]
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        for command in ReferenceLogRevisionCommand.allCases { precondition(!model.canPerform(command, ids: ids)); model.perform(command, ids: ids) }
        var browsed: RepositoryBrowserWindowModel?, exported: ExportWindowModel?, branch: BranchTagWindowModel?, tag: BranchTagWindowModel?, calls = 0
        model.onBrowseRepository = { hash in calls += 1; let browser = RepositoryBrowserWindowModel(repository: repo, access: nil, revision: hash); browsed = browser; browser.refresh() }
        model.onExport = { hash in calls += 1; let export = ExportWindowModel(repository: repo, access: nil); exported = export; export.load(revision: hash) }
        model.onCreateReference = { isTag, hash in calls += 1; let creation = BranchTagWindowModel(repository: repo, access: nil, isTag: isTag); if isTag { tag = creation } else { branch = creation }; creation.load(revision: hash) }
        for command in ReferenceLogRevisionCommand.allCases {
            precondition(model.canPerform(command, ids: ids)); model.perform(command, ids: ids)
            model.perform(command, ids: []); model.perform(command, ids: ["invalid"]); model.perform(command, ids: Set(model.entries.map(\.id)))
        }
        precondition(calls == 4)
        try await wait { browsed?.busy == true || exported?.busy == true || branch?.busy == true || tag?.busy == true || branch?.chooser.busy == true || tag?.chooser.busy == true }
        precondition(browsed?.error == nil && browsed?.snapshot?.objectID == older.hash && browsed?.entries.count == 1)
        let oldBlob = try await repo.run(["rev-parse", older.hash + ":file"]).text.trimmingCharacters(in: .newlines)
        precondition(browsed?.entries.first?.objectID == oldBlob)
        precondition(exported?.error == nil && exported?.revision == older.hash && exported?.wholeProject == true && exported?.destination.isEmpty == true)
        precondition(branch?.error == nil && branch?.useHead == false && branch?.chooser.revision == older.hash && branch?.options.isTag == false)
        precondition(tag?.error == nil && tag?.useHead == false && tag?.chooser.revision == older.hash && tag?.options.isTag == true)
        model.busy = true; for command in ReferenceLogRevisionCommand.allCases { model.perform(command, ids: ids); precondition(!model.canPerform(command, ids: ids)) }; model.busy = false; precondition(calls == 4)
        precondition(browsed?.canReuseForRevision(older.hash) == true)
        browsed?.revision = "HEAD"; precondition(browsed?.canReuseForRevision(older.hash) == false)
        browsed?.revision = older.hash; browsed?.busy = true; precondition(browsed?.canReuseForRevision(older.hash) == false); browsed?.busy = false
        browsed?.revision = "HEAD"; browsed?.refresh(); try await wait { browsed?.busy == true }
        precondition(browsed?.canReuseForRevision("HEAD") == true)
        browsed?.revision = older.hash; precondition(browsed?.canReuseForRevision(older.hash) == false, "Edited revision must not reuse a different loaded tree")
        browsed?.invalidate(); precondition(browsed?.canReuseForRevision(older.hash) == false)
        precondition(exported?.canReuseForRevision(older.hash, directory: "") == true)
        exported?.commit = "HEAD"; precondition(exported?.canReuseForRevision(older.hash, directory: "") == false); exported?.commit = older.hash
        exported?.destination = root.appendingPathComponent("draft.zip").path; precondition(exported?.canReuseForRevision(older.hash, directory: "") == false); exported?.destination = ""
        exported?.busy = true; precondition(exported?.canReuseForRevision(older.hash, directory: "") == false); exported?.busy = false
        precondition(exported?.canReuseForRevision(older.hash, directory: "subdirectory") == false)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && file == afterFile)
        // Current stash is excluded from branch/tag creation; older stash commits are allowed.
        for n in 0..<2 { try Data("stash \(n)".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.saveStash(StashSaveOptions()) }
        model.reference = "refs/stash"; model.reload(); try await wait { model.busy }; precondition(model.error == nil)
        let current = model.entries[0], previous = model.entries[1]
        precondition(model.currentStashHash == current.hash && model.isOnStash(current) && !model.isOnStash(previous))
        precondition(!model.canPerform(.createBranch, ids: [current.id]) && !model.canPerform(.createTag, ids: [current.id]))
        precondition(model.canPerform(.createBranch, ids: [previous.id]) && model.canPerform(.createTag, ids: [previous.id]))
        precondition(model.canPerform(.browseRepository, ids: [current.id]) && model.canPerform(.export, ids: [current.id]))
        let parents = try await repo.run(["rev-list", "--parents", "-n", "1", current.hash]).text.split(whereSeparator: \.isWhitespace)
        precondition(parents.count == 3)
        _ = try await repo.run(["update-ref", "--create-reflog", "refs/heads/stash-index-view", String(parents[2])])
        _ = try await repo.run(["update-ref", "refs/heads/stash-index-view", current.hash])
        model.reference = "refs/heads/stash-index-view"; model.reload(); try await wait { model.busy }
        precondition(model.entries.count == 2 && model.isOnStash(model.entries[1]) && !model.canPerform(.createTag, ids: [model.entries[1].id]))
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait { chooser.busy }
        chooser.onCreateReference = { _, _ in preconditionFailure("Chooser creation dispatched") }
        for command in [ReferenceLogRevisionCommand.createBranch, .createTag] { chooser.perform(command, ids: [chooser.entries[0].id]); precondition(!chooser.canPerform(command, ids: [chooser.entries[0].id])) }
        precondition(ReferenceLogRevisionCommand.allCases.map(\.icon) == [.repositoryBrowser, .branch, .tag, .export])
        print("RefLog revision handoffs: four immutable older-hash callbacks load real browser tree, Branch/Tag bases and whole-project Export without auto-create/export; missing/multi/invalid/busy guards, current/older stash and adjacent two-parent index gates, chooser creation guard and original icon mapping passed; ordinary HEAD/refs/index/config/worktree unchanged, no displayed UI")
    }
}
