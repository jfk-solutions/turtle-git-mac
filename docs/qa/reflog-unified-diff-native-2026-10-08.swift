import AppKit
import TurtleGitCore

@main struct ReferenceLogUnifiedDiffVerification {
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
        precondition(model.diffParents[merge]?.map(\.subject) == ["main", "side"] && !model.canInspect([rootEntry.id]))
        var received: [(Data, Bool)] = []
        model.onUnifiedDiff = { bytes, alternate in received.append((bytes, alternate)) }
        for mode in [ReferenceLogDiffMode.parent(1), .parent(2), .allParents, .onlyMergedFiles, .extraChanges] {
            let expected = try await repo.referenceLogUnifiedDiff(merge, mode: mode)
            model.inspect([merged.id], mode: mode, alternate: true); try await wait { model.busy }
            precondition(model.error == nil && received.last?.0 == expected.bytes && received.last?.1 == (mode != .extraChanges))
        }
        precondition(received.count == 5 && received[0].0.contains(255))
        let patch = PatchWindowModel(repository: repo, access: nil); patch.setReadOnlyDiff(received[0].0)
        precondition(patch.exportDocument.bytes == received[0].0)
        let pair: Set<String> = [merged.id, rootEntry.id]
        model.inspect(pair); try await wait { model.busy }
        let expectedPair = try await repo.referenceLogUnifiedDiff(from: base, to: merge); precondition(received.last?.0 == expectedPair && received.last?.1 == false)
        let duplicate = Set(model.entries.filter { $0.hash == merge }.prefix(2).map(\.id)); precondition(duplicate.count == 2)
        model.inspect(duplicate); try await wait { model.busy }; precondition(received.last?.0.isEmpty == true)
        let beforeInvalid = received.count
        let invalidSelections: [Set<String>] = [[], ["invalid"], Set(model.entries.map(\.id))]
        for ids in invalidSelections { model.inspect(ids) }
        model.inspect([merged.id], mode: .parent(9)); model.busy = true; model.inspect(pair); model.busy = false; precondition(received.count == beforeInvalid)
        model.reload(); try await wait { model.busy }; precondition(model.diffParents[merge]?.count == 2)
        let cleanEntry = model.entries.first { $0.hash == clean }!
        model.requestDiffParents(cleanEntry); try await wait { model.diffParents[clean] == nil }
        model.inspect([cleanEntry.id], mode: .extraChanges); try await wait { model.busy }
        precondition(model.information == "No extra changes after merge" && received.count == beforeInvalid)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && file == afterFile)
        model.invalidate(); model.inspect(pair); precondition(received.count == beforeInvalid)
        print("RefLog unified diffs: all merge choices and parent labels, exact raw bytes including non-UTF8 into read-only Patch model, Shift boolean handoff, source two-revision direction and duplicate empty diff, root/invalid/multi/busy/invalidation guards and refresh metadata retained; HEAD/refs/index/config/worktree unchanged, no visible viewer or external app")
    }
}
