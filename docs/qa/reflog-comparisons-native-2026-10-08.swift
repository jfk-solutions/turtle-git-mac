import AppKit
import TurtleGitCore

@main struct ReferenceLogComparisonsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Comparison QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<4 {
            try Data("commit \(n)\n".utf8).write(to: root.appendingPathComponent("file"))
            if n == 0 { try Data("older\n".utf8).write(to: root.appendingPathComponent("older-only")) }
            if n == 1 { try FileManager.default.removeItem(at: root.appendingPathComponent("older-only")) }
            if n == 3 { try Data("newer\n".utf8).write(to: root.appendingPathComponent("newer-only")) }
            _ = try await repo.run(["add", "-A"]); _ = try await repo.commit(message: "commit \(n)")
        }
        _ = try await repo.run(["reset", "--soft", "HEAD"])
        try Data("staged content\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"])
        try Data("working café 🐢\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil && model.hasWorkingTree && model.entries.count == 5)
        let rows = model.entries, newest = rows[0], oldest = rows[4]
        let pair: Set<String> = [newest.id, oldest.id], continuous = Set(rows[0..<4].map(\.id)), noncontinuous = Set([rows[0].id, rows[2].id, rows[4].id])
        precondition(!model.canCompare(.revisions, ids: pair)); model.compare(.revisions, ids: pair)
        var comparisons: [RevisionComparisonWindowModel] = []
        model.onCompare = { from, to in
            let comparison = RevisionComparisonWindowModel(repository: repo, access: nil, from: from, to: to)
            comparisons.append(comparison); comparison.load()
        }
        let invalidSelections: [Set<String>] = [[], [newest.id], ["invalid", newest.id], noncontinuous]
        for invalid in invalidSelections {
            precondition(!model.canCompare(.revisions, ids: invalid)); model.compare(.revisions, ids: invalid)
        }
        precondition(comparisons.isEmpty)
        precondition(model.canCompare(.revisions, ids: pair)); model.compare(.revisions, ids: pair)
        precondition(model.canCompare(.revisions, ids: continuous)); model.compare(.revisions, ids: continuous)
        model.compare(.revisions, ids: [rows[0].id, rows[1].id])
        model.compare(.workingTree, ids: [oldest.id])
        model.compare(.workingTree, ids: pair); model.compare(.workingTree, ids: ["invalid"])
        model.busy = true; for command in [ReferenceLogComparisonCommand.revisions, .workingTree] { model.compare(command, ids: pair); precondition(!model.canCompare(command, ids: pair)) }; model.busy = false
        precondition(comparisons.count == 4)
        try await wait { comparisons.contains { $0.busy } }
        precondition(comparisons.allSatisfy { $0.error == nil })
        let revision = comparisons[0], snapshot = revision.snapshot!
        precondition(snapshot.from == .revision(oldest.hash) && snapshot.to == .revision(newest.hash))
        precondition(snapshot.files.contains { $0.path == "older-only" && $0.action == "D" } && snapshot.files.contains { $0.path == "newer-only" && $0.action == "A" })
        let patch = try await repo.revisionComparisonPatchData(snapshot, paths: ["file"])
        precondition(String(decoding: patch, as: UTF8.self).contains("-commit 0\n+commit 3"))
        precondition(comparisons[1].snapshot?.from == .revision(rows[3].hash) && comparisons[1].snapshot?.to == .revision(rows[0].hash))
        precondition(comparisons[2].snapshot?.files.isEmpty == true)
        let working = comparisons[3].snapshot!
        precondition(working.from == .revision(oldest.hash) && working.to == .workingTree)
        let workingPatch = try await repo.revisionComparisonPatchData(working, paths: ["file"])
        precondition(String(decoding: workingPatch, as: UTF8.self).contains("+working café 🐢") && !String(decoding: workingPatch, as: UTF8.self).contains("+staged content"))
        precondition(revision.canReuseForComparison(from: snapshot.from, to: snapshot.to))
        revision.from = newest.hash; precondition(!revision.canReuseForComparison(from: snapshot.from, to: snapshot.to)); revision.from = oldest.hash
        revision.busy = true; precondition(!revision.canReuseForComparison(from: snapshot.from, to: snapshot.to)); revision.busy = false
        revision.confirmingQuit = true; precondition(!revision.canReuseForComparison(from: snapshot.from, to: snapshot.to)); revision.confirmingQuit = false
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait { chooser.busy }; precondition(!chooser.canCompare(.revisions, ids: pair))
        var chooserCompared = 0; chooser.onCompare = { _, _ in chooserCompared += 1 }; chooser.compare(.revisions, ids: pair); precondition(chooserCompared == 1)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        precondition(head == afterHead && refs == afterRefs)
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(index == afterIndex && config == afterConfig && file == afterFile)
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git)
        _ = try await bare.run(["config", "user.name", "Comparison QA"]); _ = try await bare.run(["config", "user.email", "qa@example.invalid"])
        _ = try await bare.run(["update-ref", "--create-reflog", "refs/heads/main", oldest.hash]); _ = try await bare.run(["update-ref", "refs/heads/main", newest.hash])
        let bareModel = ReferenceLogWindowModel(repository: bare, access: nil, reference: "refs/heads/main")
        bareModel.reload(); try await wait { bareModel.busy }; precondition(bareModel.error == nil && !bareModel.hasWorkingTree && bareModel.entries.count == 2)
        var bareComparison: RevisionComparisonWindowModel?
        bareModel.onCompare = { from, to in let comparison = RevisionComparisonWindowModel(repository: bare, access: nil, from: from, to: to); bareComparison = comparison; comparison.load() }
        precondition(!bareModel.canCompare(.workingTree, ids: [bareModel.entries[0].id])); bareModel.compare(.workingTree, ids: [bareModel.entries[0].id]); precondition(bareComparison == nil)
        let barePair = Set(bareModel.entries.map(\.id)); precondition(bareModel.canCompare(.revisions, ids: barePair)); bareModel.compare(.revisions, ids: barePair)
        try await wait { bareComparison?.busy == true }; precondition(bareComparison?.error == nil && bareComparison?.snapshot?.from == .revision(oldest.hash) && bareComparison?.snapshot?.to == .revision(newest.hash))
        precondition(ReferenceLogComparisonCommand.workingTree.icon == .compare && ReferenceLogComparisonCommand.revisions.icon == .compare)
        print("RefLog comparisons: real Changed Files models preserve oldest/newest direction, added/deleted paths and working rather than staged content; arbitrary pair/continuous selection and duplicate-hash empty diff, stale/noncontinuous/empty/busy/callback and bare working-tree gates, chooser read-only dispatch and edited/busy reuse predicates passed; HEAD/refs/index/config/worktree unchanged, no displayed windows")
    }
}
