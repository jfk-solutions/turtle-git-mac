import AppKit
import TurtleGitCore

@main struct SynchronizationVerification {
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func settle(_ condition: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Synchronization did not settle at fixture line \(line)")
    }
    @MainActor static func verifyTransport(repo: GitRepository, root: URL, preferences: UserDefaults) async throws {
        let server = root.appendingPathComponent("qa server 雪.git"), authorRoot = root.appendingPathComponent("qa-author")
        _ = try await repo.run(["clone", "--bare", "--template=", "--", root.path, server.path])
        let executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let bare = GitRepository(root: server, executable: executable)
        _ = try await bare.run(["config", "core.hooksPath", "/dev/null"])
        let originalHead = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = try await bare.run(["update-ref", "refs/heads/review", originalHead])
        _ = try await repo.run(["remote", "set-url", "origin", server.path])
        _ = try await repo.run(["clone", "--template=", "--", server.path, authorRoot.path])
        let author = GitRepository(root: authorRoot, executable: executable)
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("incoming\n".utf8).write(to: authorRoot.appendingPathComponent("incoming")); try await author.stage(["incoming"]); _ = try await author.commit(message: "incoming")
        let incoming = String(decoding: try await author.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        _ = try await author.run(["push", "origin", "main:review", "main:topic"])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil)
        defer { owner.close() }
        let model = owner.model; model.sshSettings.enabled = false
        try await settle { !model.busy && model.outgoing != nil }
        var completions = 0; model.onTransportFinished = { _ in completions += 1 }
        model.fetch(); precondition(model.busy && model.transportRunning && model.tab == 2)
        precondition(!owner.windowShouldClose(owner.window!))
        model.reload(); precondition(model.transportRunning)
        try await settle { !model.busy }
        precondition(model.commandCompleted && model.commandSucceeded && !model.commandOutput.isEmpty && completions == 1)
        let fetched = String(decoding: try await repo.run(["rev-parse", "refs/remotes/origin/review"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        precondition(fetched == incoming && model.outgoing?.remoteHash == incoming)
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.contains { $0.string == model.commandOutput } }
        let outputView = views(owner.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        precondition(!outputView.isEditable && outputView.isSelectable && outputView.outputMenu().items.first?.image != nil)
        owner.window!.appearance = NSAppearance(named: .darkAqua); owner.window!.contentView!.layoutSubtreeIfNeeded()
        owner.window!.appearance = NSAppearance(named: .aqua)
        model.remoteBranch = "does-not-exist"; model.fetch()
        try await settle { !model.busy }
        precondition(model.commandCompleted && !model.commandSucceeded && model.commandOutput.contains("Git command failed") && completions == 2)
        model.remoteBranch = "review"
        preferences.set(true, forKey: "ConfirmKillProcess")
        var completionAnswer: ((Bool) -> Void)?
        model.confirmCancellation = { completionAnswer = $0 }
        model.fetch(.fetchAllBranches); model.cancelTransport()
        precondition(model.confirmingCancellation)
        try await settle { !model.busy }; precondition(model.commandSucceeded)
        completionAnswer?(true)
        precondition(!model.confirmingCancellation && !model.cancelling && !model.transportRunning)
        let topic = try await repo.run(["rev-parse", "refs/remotes/origin/topic"]).stdout
        precondition(String(decoding: topic, as: UTF8.self).trimmingCharacters(in: .newlines) == incoming)
        _ = try await repo.run(["remote", "add", "second", server.path])
        model.fetch(.remoteUpdate); try await settle { !model.busy }; precondition(model.commandSucceeded)
        _ = try await repo.run(["rev-parse", "refs/remotes/second/topic"])
        _ = try await bare.run(["update-ref", "-d", "refs/heads/topic"])
        model.fetch(.prune); try await settle { !model.busy }; precondition(model.commandSucceeded)
        let gone = try await repo.run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/topic"], successfulExitCodes: 0...1)
        precondition(gone.exitCode == 1)
        _ = try await repo.run(["rev-parse", "refs/remotes/second/topic"])
        let finalHead = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let finalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(finalHead == originalHead && finalIndex == index)

        // A private transport shim blocks only Fetch. All metadata reads use
        // real Git; cancellation must reap the owned child without moving refs.
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let marker = root.appendingPathComponent("qa-fetch-started"), wrapper = root.appendingPathComponent("qa-git")
        let script = "#!/bin/sh\nif [ \"$4\" = fetch ]; then\n  echo 'Receiving objects: 1% (1/100)' >&2\n  touch " + quoted(marker.path) + "\n  while :; do sleep 1; done\nfi\nexec " + quoted(executable.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let blocked = SynchronizationWindowController(repository: GitRepository(root: root, executable: wrapper), access: nil, preferences: preferences)
        blocked.window!.alphaValue = 0; blocked.showWindow(nil)
        defer { blocked.close() }
        let blockedModel = blocked.model; blockedModel.sshSettings.enabled = false
        try await settle { !blockedModel.busy && blockedModel.outgoing != nil }
        preferences.set(true, forKey: "ConfirmKillProcess")
        var answer: ((Bool) -> Void)?
        blockedModel.confirmCancellation = { answer = $0 }
        let refs = try await repo.run(["show-ref"]).stdout
        blockedModel.fetch(); try await settle { FileManager.default.fileExists(atPath: marker.path) && blockedModel.percentage == 1 }
        blockedModel.cancelTransport(); precondition(blockedModel.confirmingCancellation && !blockedModel.cancelling)
        answer?(false); precondition(!blockedModel.confirmingCancellation && blockedModel.transportRunning)
        blockedModel.cancelTransport(); answer?(true)
        try await settle { !blockedModel.busy }
        precondition(blockedModel.commandCompleted && !blockedModel.commandSucceeded && blockedModel.commandOutput.contains("Synchronization cancelled."))
        let preservedRefs = try await repo.run(["show-ref"]).stdout
        precondition(preservedRefs == refs)
        try FileManager.default.removeItem(at: marker)
        blockedModel.fetch(); try await settle { FileManager.default.fileExists(atPath: marker.path) }
        blockedModel.cancelTransport(); let lateAnswer = answer
        blocked.close(); let closedOutput = blockedModel.commandOutput
        lateAnswer?(true)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(blockedModel.closed && !blockedModel.busy && !blockedModel.confirmingCancellation && blockedModel.commandOutput == closedOutput)
        let closedRefs = try await repo.run(["show-ref"]).stdout
        precondition(closedRefs == refs)
        print("PASS: native Sync Fetch/Fetch All/Remote Update/Prune, retained selectable command log, refresh, HEAD/index preservation, close guard, cancellation reply fences and forced-owner closure")
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
        try await verifyTransport(repo: repo, root: root, preferences: preferences)
        print("PASS: native Sync tracking controls, exact Unicode choices, graph-first table, changes and pinned comparison snapshot, divergence/Force, unknown states, Quit fences, owner invalidation and read-only preservation")
    }
}
