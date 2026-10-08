import AppKit
import TurtleGitCore

@main struct ReferenceLogHistoryActionsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "History QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<3 { try Data("commit \(n)\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil && model.currentBranch == "main")
        let current = model.entries[0], older = model.entries[1], oldest = model.entries[2]
        precondition(model.currentHeadHash == current.hash)
        for command in ReferenceLogHistoryCommand.allCases { precondition(!model.canPerformHistory(command, ids: [older.id])); model.performHistory(command, ids: [older.id]) }
        var checkout: SwitchWindowModel?, reset: ResetWindowModel?, calls = 0
        model.onCheckout = { hash in calls += 1; let target = SwitchWindowModel(repository: repo, access: nil, revision: hash); checkout = target; target.load() }
        model.onReset = { hash in calls += 1; let target = ResetWindowModel(repository: repo, access: nil, revision: hash); reset = target; target.load() }
        precondition(!model.canPerformHistory(.checkout, ids: [current.id]) && model.canPerformHistory(.reset, ids: [current.id]))
        for command in ReferenceLogHistoryCommand.allCases {
            precondition(model.canPerformHistory(command, ids: [older.id])); model.performHistory(command, ids: [older.id])
            for ids in [Set<String>(), ["invalid"], [current.id, older.id]] { model.performHistory(command, ids: ids); precondition(!model.canPerformHistory(command, ids: ids)) }
        }
        try await wait { checkout?.busy == true || reset?.busy == true || reset?.chooser.busy == true }
        precondition(calls == 2 && checkout?.error == nil && checkout?.revision == older.hash && checkout?.options.target == .commit)
        precondition(reset?.error == nil && reset?.chooser.revision == older.hash && reset?.mode == .mixed && reset?.bare == false)
        checkout?.load(); try await wait { checkout?.busy == true }; precondition(checkout?.revision == older.hash, "Model reload must preserve explicit revision")
        model.busy = true; for command in ReferenceLogHistoryCommand.allCases { model.performHistory(command, ids: [older.id]) }; model.busy = false; precondition(calls == 2)
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait { chooser.busy }; chooser.onCheckout = { _ in preconditionFailure("Chooser checkout dispatched") }; chooser.onReset = { _ in preconditionFailure("Chooser reset dispatched") }
        for command in ReferenceLogHistoryCommand.allCases { chooser.performHistory(command, ids: [older.id]); precondition(!chooser.canPerformHistory(command, ids: [older.id])) }
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && file == afterFile)
        for n in 0..<2 { try Data("stash \(n)\n".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.saveStash(StashSaveOptions()) }
        model.reference = "refs/stash"; model.reload(); try await wait { model.busy }
        for command in ReferenceLogHistoryCommand.allCases { precondition(!model.canPerformHistory(command, ids: [model.entries[0].id]) && model.canPerformHistory(command, ids: [model.entries[1].id])) }
        model.invalidate(); precondition(!model.canPerformHistory(.reset, ids: [model.entries[1].id]))
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git)
        _ = try await bare.run(["config", "user.name", "History QA"]); _ = try await bare.run(["config", "user.email", "qa@example.invalid"])
        _ = try await bare.run(["update-ref", "--create-reflog", "refs/heads/main", oldest.hash]); _ = try await bare.run(["update-ref", "refs/heads/main", current.hash])
        let bareModel = ReferenceLogWindowModel(repository: bare, access: nil, reference: "refs/heads/main")
        bareModel.reload(); try await wait { bareModel.busy }; bareModel.onCheckout = { _ in preconditionFailure("Bare checkout dispatched") }; bareModel.onReset = { _ in preconditionFailure("Bare Reset menu dispatched") }
        for command in ReferenceLogHistoryCommand.allCases { precondition(!bareModel.canPerformHistory(command, ids: [bareModel.entries[1].id])); bareModel.performHistory(command, ids: [bareModel.entries[1].id]) }
        precondition(ReferenceLogHistoryCommand.allCases.map(\.icon) == [.reset, .checkout])
        _ = try await repo.run(["symbolic-ref", "HEAD", "refs/heads/unborn"])
        let unborn = ReferenceLogWindowModel(repository: repo, access: nil, reference: "refs/heads/main")
        unborn.reload(); try await wait { unborn.busy }; precondition(unborn.error == nil && unborn.currentHeadHash == nil)
        unborn.onReset = { _ in preconditionFailure("Unborn Reset dispatched") }; unborn.onCheckout = { _ in preconditionFailure("Unborn checkout dispatched") }
        for command in ReferenceLogHistoryCommand.allCases { precondition(!unborn.canPerformHistory(command, ids: [unborn.entries[0].id])); unborn.performHistory(command, ids: [unborn.entries[0].id]) }
        print("RefLog history actions: exact older hash presets actual Switch and Reset models without mutation; model reload retains checkout target; HEAD checkout/reset distinction, current/older stash, empty/stale/multi/busy/chooser/bare/unborn/invalidation gates and original icons passed; HEAD/refs/index/config/worktree unchanged by ordinary reads, no visible dialogs or execution")
    }
}
