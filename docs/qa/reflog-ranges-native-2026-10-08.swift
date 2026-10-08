import AppKit
import TurtleGitCore

@main struct ReferenceLogRangesVerification {
    @MainActor static func wait(_ busy: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while busy() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!busy(), "Native load timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Range QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        for n in 0..<3 { try Data("commit \(n)\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "commit \(n)") }
        let main = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "-b", "side", "HEAD~1"])
        try Data("side\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "side only")
        let side = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["checkout", "main"]); _ = try await repo.run(["reset", "--soft", "HEAD"])
        try Data("dirty working bytes\n".utf8).write(to: root.appendingPathComponent("file"))
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), config = try Data(contentsOf: root.appendingPathComponent(".git/config")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let model = ReferenceLogWindowModel(repository: repo, access: nil, reference: "HEAD")
        model.reload(); try await wait { model.busy }; precondition(model.error == nil)
        let first = model.entries.first { $0.hash == main }!, last = model.entries.first { $0.hash == side }!, pair: Set<String> = [first.id, last.id]
        let suite = "TurtleGit.RefLogRanges.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        var logs: [LogWindowModel] = []
        defer { logs.forEach { $0.invalidate() } }
        model.onLogRange = { range in
            let log = LogWindowModel(repository: repo, access: nil, labelDefaults: preferences)
            log.search = "impossible filter"; log.useDates = true; log.endRevision = "invalid old revision"; log.historyPaths = ["file"]; log.showWholeProject = false
            ReferenceLogWindowModel.configureRangeLog(log, range: range); logs.append(log); log.reload()
        }
        for command in ReferenceLogRangeCommand.allCases { model.showLogRange(command, ids: pair) }
        let invalidSelections: [Set<String>] = [[], [first.id], [first.id, "invalid"], Set(model.entries.map(\.id))]
        for ids in invalidSelections {
            for command in ReferenceLogRangeCommand.allCases { precondition(model.logRange(command, ids: ids) == nil); model.showLogRange(command, ids: ids) }
        }
        model.busy = true; model.showLogRange(.forward, ids: pair); model.busy = false; precondition(logs.count == 3)
        try await wait { logs.contains { $0.busy || $0.loadingActions } }
        precondition(logs.allSatisfy { $0.error == nil && $0.endRevision == nil && !$0.allBranches && !$0.showWorkingTree && $0.historyPaths.isEmpty && $0.showWholeProject && $0.search.isEmpty && !$0.useDates })
        precondition(logs[0].revisionRange == HistoryRevisionRange(from: side, to: main) && Set(logs[0].entries.map(\.hash)) == [main])
        precondition(logs[1].revisionRange == HistoryRevisionRange(from: main, to: side) && Set(logs[1].entries.map(\.hash)) == [side])
        precondition(logs[2].revisionRange == HistoryRevisionRange(from: side, to: main, kind: .symmetricDifference) && Set(logs[2].entries.map(\.hash)) == [main, side])
        precondition(logs[2].graph.count == logs[2].entries.count)
        let range = logs[0].revisionRange!
        precondition(logs[0].canReuseForRange(range)); logs[0].busy = true; precondition(!logs[0].canReuseForRange(range)); logs[0].busy = false
        logs[0].revisionRange = logs[1].revisionRange; precondition(!logs[0].canReuseForRange(range)); logs[0].revisionRange = range
        ReferenceLogWindowModel.configureRevisionLog(logs[0], revision: main); precondition(logs[0].revisionRange == nil && logs[0].endRevision == main)
        let duplicateRows = model.entries.filter { $0.hash == main }; precondition(duplicateRows.count >= 2)
        model.showLogRange(.forward, ids: Set(duplicateRows.prefix(2).map(\.id)))
        try await wait { logs.last!.busy || logs.last!.loadingActions }; precondition(logs.last!.error == nil && logs.last!.entries.isEmpty)
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterRefs = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index")), afterConfig = try Data(contentsOf: root.appendingPathComponent(".git/config")), afterFile = try Data(contentsOf: root.appendingPathComponent("file"))
        precondition(head == afterHead && refs == afterRefs && index == afterIndex && config == afterConfig && file == afterFile)
        print("RefLog Log ranges: native forward/reverse/symmetric models load exact divergent sets and graph rows; old filters/date/path/end/working scope cleared, empty/one/stale/multi/busy dispatch rejected, duplicate-hash range empty and edited/busy reuse guards passed; ordinary revision resets range; HEAD/refs/index/config/worktree unchanged, no displayed UI")
    }
}
