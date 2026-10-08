import AppKit
import TurtleGitCore

@main struct ReferenceLogParentComparisonsVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Diff QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "side"])
        try Data("main\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "main")
        _ = try await repo.run(["checkout", "side"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "side")
        _ = try await repo.run(["checkout", "main"]); _ = try await repo.run(["merge", "--no-commit", "side"], successfulExitCodes: 0...1)
        try Data([114, 101, 115, 111, 108, 118, 101, 100, 32, 255, 10]).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "manual merge")
        let merge = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "clean-side", base]); _ = try await repo.run(["checkout", "-b", "clean-main", base])
        try Data("left\n".utf8).write(to: root.appendingPathComponent("left")); try await repo.stage(["left"]); _ = try await repo.commit(message: "left")
        _ = try await repo.run(["checkout", "clean-side"])
        try Data("right\n".utf8).write(to: root.appendingPathComponent("right")); try await repo.stage(["right"]); _ = try await repo.commit(message: "right")
        _ = try await repo.run(["checkout", "clean-main"]); _ = try await repo.run(["merge", "--no-edit", "clean-side"])
        let clean = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "main"])
        _ = try await repo.run(["reset", "--soft", "HEAD"])
        try Data("dirty working\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }
        let merged = model.entries.first { $0.hash == merge }!, rootEntry = model.entries.first { $0.hash == base }!
        model.requestDiffParents(merged); model.requestDiffParents(rootEntry)
        try await wait { model.diffParents[merge] == nil || model.diffParents[base] == nil }
        let parents = model.diffParents[merge]!
        precondition(parents.count == 2 && !model.canCompareParent([merged.id]))
        var opened: [RevisionComparisonWindowModel] = []
        model.onCompare = { from, to in let comparison = RevisionComparisonWindowModel(repository: repo, access: nil, from: from, to: to); opened.append(comparison); comparison.load() }
        for parent in parents { precondition(model.canCompareParent([merged.id], number: parent.number)); model.compareParent([merged.id], number: parent.number) }
        let ordinary = model.entries.first { $0.hash == parents[0].hash }!
        model.requestDiffParents(ordinary); try await wait { model.diffParents[ordinary.hash] == nil }
        model.compareParent([ordinary.id])
        try await wait { opened.contains { $0.busy } }
        precondition(opened.count == 3 && opened.allSatisfy { $0.error == nil })
        for n in 0..<2 {
            let snapshot = opened[n].snapshot!
            precondition(snapshot.from == .revision(parents[n].hash) && snapshot.to == .revision(merge))
            let patch = try await repo.revisionComparisonPatchData(snapshot, paths: ["file"])
            precondition(patch.contains(255) && String(decoding: patch, as: UTF8.self).contains(n == 0 ? "-main" : "-side"))
        }
        precondition(opened[2].snapshot?.from == .revision(base) && opened[2].snapshot?.to == .revision(ordinary.hash))
        for number in [0, 3, -1] { model.compareParent([merged.id], number: number); precondition(!model.canCompareParent([merged.id], number: number)) }
        let invalidSelections: [Set<String>] = [[], ["stale"], [merged.id, rootEntry.id], [rootEntry.id]]
        for ids in invalidSelections { model.compareParent(ids); precondition(!model.canCompareParent(ids)) }
        model.busy = true; model.compareParent([merged.id]); precondition(!model.canCompareParent([merged.id])); model.busy = false
        precondition(opened.count == 3)
        let chooser = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD", selecting: true)
        chooser.reload(); try await wait { chooser.busy }; chooser.requestDiffParents(merged); try await wait { chooser.diffParents[merge] == nil }
        precondition(!chooser.canCompareParent([merged.id])); var chooserCalls = 0
        chooser.onCompare = { _, _ in chooserCalls += 1 }; chooser.compareParent([merged.id], number: 2); precondition(chooserCalls == 1)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && file == afterFile)
        model.invalidate(); model.compareParent([merged.id]); precondition(opened.count == 3 && !model.canCompareParent([merged.id]))
        let bareRoot = root.appendingPathComponent("bare.git")
        _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = GitRepository(root: bareRoot, executable: git)
        _ = try await bare.run(["config", "user.name", "Diff QA"]); _ = try await bare.run(["config", "user.email", "qa@example.invalid"])
        _ = try await bare.run(["update-ref", "--create-reflog", "refs/heads/main", base]); _ = try await bare.run(["update-ref", "refs/heads/main", merge])
        let bareModel = ReferenceLogWindowModel(repository: bare, access: nil, reference: "refs/heads/main")
        bareModel.reload(); try await wait { bareModel.busy }; let bareEntry = bareModel.entries[0]
        bareModel.requestDiffParents(bareEntry); try await wait { bareModel.diffParents[merge] == nil }
        var bareComparison: RevisionComparisonWindowModel?
        bareModel.onCompare = { from, to in let comparison = RevisionComparisonWindowModel(repository: bare, access: nil, from: from, to: to); bareComparison = comparison; comparison.load() }
        precondition(!bareModel.hasWorkingTree && bareModel.canCompareParent([bareEntry.id], number: 2))
        bareModel.compareParent([bareEntry.id], number: 2); try await wait { bareComparison?.busy == true }
        precondition(bareComparison?.error == nil && bareComparison?.snapshot?.from == .revision(parents[1].hash) && bareComparison?.snapshot?.to == .revision(merge))
        print("RefLog previous revision: ordinary and both merge parents load actual Changed Files with parent-to-selected direction and raw non-UTF8 patches; root/stale/multi/invalid-parent/busy/missing-callback/invalidation guards, read-only chooser and bare parent comparison passed; HEAD/refs/index/config/worktree unchanged, no displayed windows")
    }
}
