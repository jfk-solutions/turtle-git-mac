import AppKit
import TurtleGitCore

@main struct SynchronizationVerification {
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Synchronization did not settle")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = try await repo.run(["remote", "add", "origin", "/tmp/no-network-required"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/review", base])
        _ = try await repo.run(["config", "branch.main.remote", "origin"])
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/review"])
        let path = "changed 雪.txt"
        try Data("new\n".utf8).write(to: root.appendingPathComponent(path)); try await repo.stage([path]); _ = try await repo.commit(message: "outgoing")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), refs = try await repo.run(["show-ref"]).stdout
        let suite = "TurtleGit.Sync.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(["café", "cafe\u{301}", "café"], forKey: "TurtleGit.Sync." + root.path + ".urls")
        DialogGeometry.install(preferences: preferences)
        let controller = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        let window = controller.window!; window.alphaValue = 0
        defer { controller.close() }
        controller.showWindow(nil); window.contentView!.layoutSubtreeIfNeeded()
        let model = controller.model
        precondition(model.remoteChoices.count == 2)
        try await settle { !model.busy && model.outgoing != nil }
        precondition(model.error == nil && model.localBranch == "main" && model.remote == "origin" && model.remoteBranch == "review")
        precondition(model.outgoing!.commits.count == 1 && model.graph.count == 1)
        try await settle { views(window.contentView!).contains { $0 is NSTableView } }
        let table = views(window.contentView!).compactMap { $0 as? NSTableView }.first!
        precondition(table.tableColumns.first?.identifier.rawValue == "graph" && table.numberOfRows == 1)
        let graph = table.delegate!.tableView!(table, viewFor: table.tableColumns[0], row: 0) as! GraphCell
        precondition(graph.graph == model.graph[0] && graph.accessibilityLabel() != nil)
        window.appearance = NSAppearance(named: .darkAqua); window.contentView!.layoutSubtreeIfNeeded()
        precondition(graph.graph != nil)
        window.appearance = NSAppearance(named: .aqua)
        model.tab = 1
        try await settle { views(window.contentView!).compactMap { $0 as? NSTableView }.contains { $0.tableColumns.contains { $0.title == "Path" } } }
        precondition(model.comparison.snapshot!.files.map(\.path) == [path])
        model.fileSelection = [path]
        let viewer = PatchWindowController(repository: repo, access: nil)
        model.comparison.unifiedWindows["quit-probe"] = viewer
        model.confirmingQuit = true; model.reload(); model.compareFiles(unified: true)
        precondition(!model.busy && model.comparison.confirmingQuit && viewer.model.confirmingQuit && model.comparison.unifiedWindows.count == 1)
        model.confirmingQuit = false
        precondition(!model.comparison.confirmingQuit && !viewer.model.confirmingQuit)
        viewer.close(); model.comparison.unifiedWindows.removeValue(forKey: "quit-probe")
        let retained = model.outgoing!
        let tree = String(decoding: try await repo.run(["rev-parse", base + "^{tree}"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let divergent = String(decoding: try await repo.run(["commit-tree", tree, "-p", base, "-m", "remote divergence"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/review", divergent])
        model.reload(); try await settle { !model.busy }
        precondition(model.outgoing?.disposition == .needsForce && model.comparison.snapshot == nil)
        model.force = true; model.reload(); try await settle { !model.busy }
        precondition(model.outgoing?.disposition == .outgoing && model.outgoing?.mergeBase == base && model.comparison.snapshot!.files.map(\.path) == [path])
        precondition(retained.remoteHash == base)
        _ = try await repo.run(["update-ref", "refs/remotes/origin/review", base])
        model.remote = "https://example.invalid/repo"; model.reload()
        try await settle { !model.busy }
        precondition(model.outgoing?.disposition == .unknownURL && model.graph.isEmpty && model.comparison.snapshot == nil && model.fileSelection.isEmpty)
        model.remote = "origin"; model.remoteBranch = "missing"; model.reload()
        try await settle { !model.busy }
        precondition(model.outgoing?.disposition == .unknownRemoteBranch)
        model.remoteBranch = "review"; model.reload(); model.invalidate()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.closed && !model.busy && model.outgoing == nil)
        model.reload(initial: true); precondition(!model.busy)
        let after = try await repo.run(["show-ref"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(after == refs && afterIndex == index)
        print("PASS: native Sync tracking controls, exact Unicode choices, graph-first table, changes and pinned comparison snapshot, divergence/Force, unknown states, Quit fences, owner invalidation and read-only preservation")
    }
}
