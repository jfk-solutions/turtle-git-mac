import AppKit
import TurtleGitCore

@main struct ReferenceLogRemoteDefaultsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Remote QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["remote", "add", "alpha", "https://example.invalid/fixture.git"])
        for n in 0..<3 { try Data("commit \(n)\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil)
        let current = model.entries[0], older = model.entries[1], oldest = model.entries[2]
        for ref in ["refs/heads/local", "refs/remotes/zeta/topic", "refs/remotes/alpha/topic"] { _ = try await repo.run(["update-ref", ref, older.hash]) }
        _ = try await repo.run(["tag", "-a", "tag", "-m", "tag", older.hash])
        _ = try await repo.run(["update-ref", "refs/remotes/alpha/current", current.hash])
        model.reload(); try await wait { model.busy }
        precondition(model.referenceNamesByHash[older.hash] == ["refs/heads/local", "refs/remotes/alpha/topic", "refs/remotes/zeta/topic", "refs/tags/tag^{}"])
        var target: SwitchWindowModel?, calls = 0
        model.onCheckout = { revision in calls += 1; let next = SwitchWindowModel(repository: repo, access: nil, revision: revision); target = next; next.load() }
        func assertDefault(_ revision: String, branch: Bool) async throws {
            let ids: Set<String> = [branch ? older.id : oldest.id]
            model.performHistory(.checkout, ids: ids); try await wait { target?.busy == true }
            precondition(target?.error == nil && target?.revision == revision)
            precondition(target?.options.target == (branch ? .branch : .commit))
            if branch { precondition(target?.options.createBranch == true && target?.options.branchName == "topic" && target?.options.tracking == .automatic) }
            target?.load(); try await wait { target?.busy == true }; precondition(target?.revision == revision)
        }
        try Data("dirty\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref", "-d"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        try await assertDefault("refs/remotes/alpha/topic", branch: true)
        try await assertDefault(oldest.hash, branch: false)
        precondition(!model.canPerformHistory(.checkout, ids: [current.id]))
        for ids: Set<String> in [[], ["invalid"], [older.id, oldest.id], [current.id]] { model.performHistory(.checkout, ids: ids) }
        model.busy = true; model.performHistory(.checkout, ids: [older.id]); model.busy = false; precondition(calls == 2)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref", "-d"]).stdout
        precondition(head == afterHead && refs == afterRefs)
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(index == afterIndex && config == afterConfig && file == afterFile)
        _ = try await repo.run(["symbolic-ref", "refs/remotes/alpha/HEAD", "refs/remotes/alpha/topic"])
        model.reload(); try await wait { model.busy }
        try await assertDefault("refs/remotes/alpha/HEAD", branch: true)
        precondition(target?.branches.contains { $0.name == "refs/remotes/alpha/HEAD" } == true, "Explicit symbolic remote preset must appear in picker")
        _ = try await repo.run(["update-ref", "refs/remotes/alpha/topic", current.hash]); _ = try await repo.run(["update-ref", "refs/remotes/zeta/topic", current.hash])
        model.reload(); try await wait { model.busy }; model.performHistory(.checkout, ids: [older.id]); try await wait { target?.busy == true }
        precondition(target?.revision == older.hash && target?.options.target == .commit, "Refresh must discard moved remote candidates")
        // Execute the ordinary remote default through Core, without native windows or preferences.
        _ = try await repo.run(["update-ref", "refs/remotes/alpha/topic", older.hash])
        _ = try await repo.run(["restore", "--", "file"])
        var options = CheckoutOptions(); options.revision = "refs/remotes/alpha/HEAD"; options.createBranch = true; options.branchName = "topic"
        _ = try await repo.checkout(options)
        let branch = try await repo.branch(), upstream = try await repo.run(["rev-parse", "--symbolic-full-name", "@{upstream}"]).text.trimmingCharacters(in: .newlines)
        let switched = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        precondition(branch == "topic" && switched == older.hash && upstream == "refs/remotes/alpha/topic")
        model.invalidate(); precondition(!model.canPerformHistory(.checkout, ids: [older.id]))
        print("RefLog remote defaults: sorted matching remote before local/tag, immutable hash fallback, actual Switch model target/new branch/tracking/reload, explicit symbolic remote picker and resolved suggested name, moved-ref refresh and selection/HEAD/busy/invalidation gates passed; ordinary reads preserve HEAD/refs/index/config/working bytes; Core creates correctly tracked branch from symbolic remote; no windows or preferences")
    }
}
