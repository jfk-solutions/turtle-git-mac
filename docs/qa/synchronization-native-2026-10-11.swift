import AppKit
import Darwin
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
        try await settle { !model.busy && model.outgoing != nil }
        precondition(model.commandCompleted && model.commandSucceeded && !model.commandOutput.isEmpty && completions == 1)
        let fetched = String(decoding: try await repo.run(["rev-parse", "refs/remotes/origin/review"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        precondition(fetched == incoming && model.outgoing?.remoteHash == incoming)
        precondition(model.tab == 3)
        let changed = model.referenceChanges.first { $0.name == GitReferenceName("refs/remotes/origin/review") }!
        precondition(changed.kind == .forward && changed.count == 2 && changed.newHash == incoming)
        precondition(model.referenceChanges.contains { $0.name == GitReferenceName("refs/heads/main") && $0.kind == .same })
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.contains { $0.tableColumns.contains { $0.title == "Old hash" } } }
        let refsTable = views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.title == "Old hash" } }!
        precondition(refsTable.tableColumns.count == 7 && refsTable.numberOfRows == model.referenceChanges.count)
        let targetRow = (0..<refsTable.numberOfRows).first { index in
            guard let cell = refsTable.delegate!.tableView!(refsTable, viewFor: refsTable.tableColumns[0], row: index) else { return false }
            return views(cell).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "origin/review" }
        }!
        let point = refsTable.convert(NSPoint(x: 8, y: refsTable.rect(ofRow: targetRow).midY), to: nil)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let menu = refsTable.menu(for: event)!
        precondition(menu.items.count == 4 && menu.items.allSatisfy { $0.image != nil && $0.isEnabled })
        var shown: [String] = [], compared: (String, String)?, reflog = ""
        model.onLog = { shown.append($0) }; model.onReferenceCompare = { compared = ($0, $1) }; model.onReferenceLog = { reflog = $0 }
        for item in menu.items { _ = NSApp.sendAction(item.action!, to: item.target, from: item) }
        precondition(shown == [changed.oldHash!, incoming] && compared?.0 == changed.oldHash && compared?.1 == incoming && reflog == "refs/remotes/origin/review")
        let hideMenu = refsTable.headerView!.menu(for: event)!, hide = hideMenu.items.first!
        precondition(hide.state == .off)
        _ = NSApp.sendAction(hide.action!, to: hide.target, from: hide)
        precondition(model.hideUnchangedReferences && model.referenceRows.allSatisfy { $0.kind != .same } && preferences.bool(forKey: "RefCompareHideUnchanged"))
        _ = NSApp.sendAction(hide.action!, to: hide.target, from: hide)
        model.tab = 2
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.contains { $0.string == model.commandOutput } }
        let outputView = views(owner.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        precondition(!outputView.isEditable && outputView.isSelectable && outputView.outputMenu().items.first?.image != nil)
        owner.window!.appearance = NSAppearance(named: .darkAqua); owner.window!.contentView!.layoutSubtreeIfNeeded()
        owner.window!.appearance = NSAppearance(named: .aqua)
        model.remoteBranch = "does-not-exist"; model.fetch()
        try await settle { !model.busy }
        precondition(model.commandCompleted && !model.commandSucceeded && model.commandOutput.contains("Git command failed") && completions == 2 && model.tab == 3)
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
        var chained = 0
        model.onTransportFinished = { _ in chained += 1; if chained == 1 { model.fetch(.prune) } }
        model.fetch(); try await settle { !model.busy }
        precondition(chained == 2 && model.commandSucceeded)
        model.onTransportFinished = { _ in }
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
        precondition(blockedModel.commandCompleted && !blockedModel.commandSucceeded && blockedModel.commandOutput.contains("Synchronization cancelled.") && blockedModel.tab == 3)
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
        print("PASS: native Sync reference results with seven columns, pinned icon actions and Hide unchanged header; Fetch/Fetch All/Remote Update/Prune, retained selectable command log, refresh, HEAD/index preservation, close guard, cancellation reply fences and forced-owner closure")
    }
    @MainActor static func verifyPull(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2])
        let directory = root.appendingPathComponent("pull-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = GitRepository(root: directory, executable: git)
        let server = directory.appendingPathComponent("server 雪.git"), authorRoot = directory.appendingPathComponent("author"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["init", "--template=", "--bare", "-b", "main", server.path])
        _ = try await parent.run(["init", "--template=", "-b", "main", authorRoot.path])
        let author = GitRepository(root: authorRoot, executable: git)
        for (key, value) in [("user.name", "Pull QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "base")
        _ = try await author.run(["remote", "add", "origin", server.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key, value) in [("user.name", "Pull QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("pull.rebase", "false"), ("pull.ff", "only")] { _ = try await repo.run(["config", key, value]) }
        func hash(_ repository: GitRepository) async throws -> String { String(decoding: try await repository.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        _ = try await repo.run(["switch", "-c", "other"])
        try Data("original baseline\n".utf8).write(to: clientRoot.appendingPathComponent("other-file")); try await repo.stage(["other-file"]); _ = try await repo.commit(message: "original baseline")
        let baseline = try await hash(repo)
        try Data("incoming\n".utf8).write(to: authorRoot.appendingPathComponent("incoming 雪")); try await author.stage(["incoming 雪"]); _ = try await author.commit(message: "incoming")
        _ = try await author.run(["push", "origin", "main"]); let incoming = try await hash(author)
        _ = try await repo.run(["config", "--unset", "branch.main.merge"])
        preferences.set(true, forKey: "AskSetTrackedBranch")
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; model.sshSettings.enabled = false
        try await settle { !model.busy }
        model.localBranch = "main"; model.remote = "origin"; model.remoteBranch = "main"
        var confirmations = 0, questions = 0, checkoutCompleted = false
        model.confirmCheckout = { branch in confirmations += 1; precondition(branch == "main"); return true }
        model.askTracking = { branch, remote, destination in questions += 1; precondition(checkoutCompleted && branch == "main" && remote == "origin" && destination == "main"); return SynchronizationTrackingAnswer(choice: .yes) }
        let presentCheckout = model.performCheckout!
        model.performCheckout = { plan, token in
            precondition(plan.oldHead == baseline)
            let result = try await presentCheckout(plan, token)
            precondition(result.command != nil && owner.window?.attachedSheet == nil)
            checkoutCompleted = true; return result
        }
        model.performPullAction(.pull); precondition(model.transportRunning && !owner.windowShouldClose(owner.window!))
        try await settle { !model.busy }
        precondition(confirmations == 1 && questions == 1 && checkoutCompleted && model.commandSucceeded && model.tab == 4)
        precondition(model.incomingCommits?.contains { $0.hash == incoming } == true && model.incomingGraph.count == model.incomingCommits?.count)
        precondition(model.incomingComparison.snapshot?.from == .revision(baseline) && model.incomingComparison.snapshot?.to == .revision(incoming))
        precondition(model.incomingComparison.snapshot?.files.contains { $0.path == "other-file" && $0.action == "D" } == true)
        let head = try await hash(repo), branch = try await repo.branch(); precondition(head == incoming && branch == "main")
        let tracking = try await repo.synchronizationBranches(); precondition(tracking.trackedBranch == "main" && tracking.trackedRemote == "origin")
        owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.contains { $0.tableColumns.first?.title == "Graph" && $0.numberOfRows == model.incomingCommits?.count } }
        model.tab = 5; owner.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.contains { $0.tableColumns.first?.title == "Path" && $0.numberOfRows == model.incomingComparison.snapshot?.files.count } }
        model.performPullAction(.pull); try await settle { !model.busy }
        precondition(model.commandSucceeded && model.tab == 3 && model.incomingCommits?.isEmpty == true)
        _ = try await repo.run(["config", "--unset", "branch.main.merge"])
        model.askTracking = { _, _, _ in SynchronizationTrackingAnswer(choice: .no) }
        model.performPullAction(.pull); try await settle { !model.busy }
        let absent = try await repo.run(["config", "--get", "branch.main.merge"], successfulExitCodes: 0...1); precondition(model.commandSucceeded && absent.exitCode == 1)
        let beforeCancel = try await repo.run(["show-ref"]).stdout
        model.askTracking = { _, _, _ in SynchronizationTrackingAnswer(choice: .cancel, suppress: true) }
        model.performPullAction(.pull); try await settle { !model.busy }
        let afterCancel = try await repo.run(["show-ref"]).stdout
        precondition(!model.commandSucceeded && beforeCancel == afterCancel && !preferences.bool(forKey: "AskSetTrackedBranch"))
        _ = try await repo.run(["config", "branch.main.merge", "refs/heads/main"])
        model.localBranch = "other"; model.confirmCheckout = { _ in false }
        model.performPullAction(.pull); try await settle { !model.busy }
        let afterAbort = try await hash(repo); precondition(afterAbort == incoming && !model.commandSucceeded)
        model.localBranch = "main"
        try Data("second\n".utf8).write(to: authorRoot.appendingPathComponent("second")); try await author.stage(["second"]); _ = try await author.commit(message: "second incoming")
        _ = try await author.run(["push", "origin", "main"]); let second = try await hash(author)
        _ = try await repo.run(["config", "branch.main.rebase", "merges"])
        var handoff = false
        model.runRebase = { target, autoStart, preserve in
            let before = try await hash(repo); precondition(before == incoming && target == second && autoStart && preserve && model.busy)
            handoff = true; _ = try await repo.run(["merge", "--ff-only", "--", target])
        }
        model.performPullAction(.pull); try await settle { !model.busy }
        precondition(handoff && model.commandSucceeded && model.incomingComparison.snapshot?.to == .revision(second))
        _ = try await repo.run(["config", "branch.main.rebase", "false"]); _ = try await repo.run(["config", "pull.ff", "false"])
        try Data("local conflict\n".utf8).write(to: clientRoot.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "local conflict")
        try Data("remote conflict\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "remote conflict"); _ = try await author.run(["push", "origin", "main"])
        var hints = 0
        preferences.removeObject(forKey: MergeProgressWindowModel.conflictHintPreference)
        model.presentConflictHint = { hints += 1; return true }
        model.performPullAction(.pull); try await settle { !model.busy }
        precondition(hints == 1 && preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
        precondition(!model.commandSucceeded && model.tab == 6 && model.conflicts.contains { $0.path == "file" })
        _ = try await repo.run(["merge", "--abort"])
        try Data("dirty checkout work\n".utf8).write(to: clientRoot.appendingPathComponent("file"))
        let fetchHead = try Data(contentsOf: clientRoot.appendingPathComponent(".git/FETCH_HEAD"))
        model.localBranch = "other"; model.confirmCheckout = { _ in true }
        model.performCheckout = presentCheckout
        model.performPullAction(.pull)
        try await settle { owner.window?.attachedSheet?.title.contains("Checkout Progress") == true }
        let progress = owner.window!.attachedSheet!
        let checkoutController = progress.delegate as! SynchronizationProgressController
        try await settle { !checkoutController.model.busy }
        if case .failure = checkoutController.model.result {} else { preconditionFailure("blocked checkout did not retain failure") }
        precondition(views(progress.contentView!).compactMap { $0 as? NSTextView }.contains { $0.string.contains("overwritten") })
        precondition(!owner.windowShouldClose(owner.window!)); checkoutController.model.close()
        try await settle { !model.busy }
        precondition(!model.commandSucceeded && owner.window?.attachedSheet == nil)
        let finalFetchHead = try Data(contentsOf: clientRoot.appendingPathComponent(".git/FETCH_HEAD")), finalWork = try String(contentsOf: clientRoot.appendingPathComponent("file"), encoding: .utf8)
        precondition(finalFetchHead == fetchHead && finalWork == "dirty checkout work\n")
        let shim = directory.appendingPathComponent("qa-checkout-git"), marker = directory.appendingPathComponent("checkout-running")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nif [ \"$4\" = switch ]; then\nprintf 'running\\n' > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let blockedRepo = GitRepository(root: clientRoot, executable: shim)
        let blockedOwner = SynchronizationWindowController(repository: blockedRepo, access: nil, preferences: preferences)
        blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
        let blocked = blockedOwner.model; blocked.sshSettings.enabled = false
        try await settle { !blocked.busy && blocked.outgoing != nil }
        blocked.localBranch = "other"; blocked.remote = "origin"; blocked.remoteBranch = "main"; blocked.confirmCheckout = { _ in true }
        let refsBeforeClose = try await repo.run(["show-ref"]).stdout
        blocked.performPullAction(.pull)
        precondition(blocked.transportRunning)
        try await settle { (FileManager.default.fileExists(atPath: marker.path) && blockedOwner.window?.attachedSheet != nil) || blocked.commandCompleted }
        precondition(FileManager.default.fileExists(atPath: marker.path) && blockedOwner.window?.attachedSheet != nil, "Checkout did not start: \(blocked.commandOutput)")
        let blockedProgress = blockedOwner.window!.attachedSheet!, blockedController = blockedProgress.delegate as! SynchronizationProgressController
        preferences.set(true, forKey: "ConfirmKillProcess")
        var cancellationReply: ((Bool) -> Void)?
        blockedController.model.confirmCancel = { cancellationReply = $0 }
        blockedController.model.cancel(); precondition(blockedController.model.confirmingCancellation && cancellationReply != nil)
        blockedOwner.close(); let closedOutput = blocked.commandOutput
        cancellationReply?(true); cancellationReply?(false)
        // This read queues behind the owned checkout process, so successful
        // return also proves cancellation released the repository actor.
        let refsAfterClose = try await blockedRepo.run(["show-ref"]).stdout
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(blocked.closed && !blocked.busy && blocked.commandOutput == closedOutput && refsAfterClose == refsBeforeClose)
        precondition(blockedProgress.sheetParent == nil && !blockedProgress.isVisible && !blockedController.model.confirmingCancellation)
        print("PASS: native Pull separate checkout, original incoming baseline/graph/files, tracking Yes/No/Cancel suppression, branch Abort, actual preserve-merges handoff callback, conflict results, failed-checkout dismissal and forced running-checkout cleanup with late cancellation replies")
    }
    @MainActor static func verifyShiftOptions(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.appendingPathComponent("shift-options-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = GitRepository(root: directory, executable: git), server = directory.appendingPathComponent("server.git"), authorRoot = directory.appendingPathComponent("author"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["init", "--template=", "--bare", "-b", "main", server.path]); _ = try await parent.run(["init", "--template=", "-b", "main", authorRoot.path])
        let author = GitRepository(root: authorRoot, executable: git)
        for (key, value) in [("user.name", "Shift QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "base")
        _ = try await author.run(["remote", "add", "origin", server.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key, value) in [("user.name", "Shift QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("pull.rebase", "false"), ("pull.ff", "only")] { _ = try await repo.run(["config", key, value]) }
        func hash(_ repository: GitRepository) async throws -> String { String(decoding: try await repository.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        let base = try await hash(repo)
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        var configured = 0
        owner.configureOptions = { child in
            configured += 1
            precondition(child.model.repository === repo)
            child.model.sshSettings.enabled = false
            child.presentFetchProgress = { parent, progress in progress.alphaValue = 0; parent.beginSheet(progress); return true }
            child.presentPullProgress = { parent, progress in progress.alphaValue = 0; parent.beginSheet(progress); return true }
        }
        let model = owner.model; model.sshSettings.enabled = false
        try await settle { !model.busy && model.outgoing != nil }
        model.remote = "origin"; model.remoteBranch = "main"; model.localBranch = "main"
        let before = try await repo.run(["show-ref"]).stdout
        precondition(!model.busy && !model.hasBlockingChild && owner.window?.attachedSheet == nil)
        model.fetch(.fetch, shift: true)
        try await settle { (owner.optionsController != nil && !owner.optionsController!.model.busy) || model.commandCompleted }
        precondition(owner.optionsController != nil, "Options did not open: \(model.commandOutput)")
        let cancelled = owner.optionsController!
        precondition(configured == 1 && !cancelled.model.isPull && cancelled.model.options.remote == "origin" && cancelled.window?.sheetParent === owner.window)
        precondition(!owner.windowShouldClose(owner.window!))
        cancelled.model.cancel()
        try await settle { model.commandCompleted && !model.busy }
        let afterCancel = try await repo.run(["show-ref"]).stdout
        precondition(before == afterCancel && model.incomingUpToDate && owner.optionsController == nil && cancelled.window?.sheetParent == nil)

        _ = try await repo.run(["config", "pull.rebase", "true"])
        model.remoteBranch = ""
        model.fetch(.pull, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let configuredPull = owner.optionsController!
        precondition(configuredPull.model.isPull && configuredPull.model.configuredRebase)
        configuredPull.model.cancel()
        try await settle { model.commandCompleted && !model.busy }
        _ = try await repo.run(["config", "pull.rebase", "false"])
        model.remoteBranch = "main"

        // URL selection is not forwarded; full Fetch uses its own named default.
        model.remote = server.path
        model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let fetch = owner.optionsController!
        precondition(!fetch.model.options.arbitraryURL && fetch.model.options.remote == "origin")
        try Data("incoming\n".utf8).write(to: authorRoot.appendingPathComponent("incoming")); try await author.stage(["incoming"]); _ = try await author.commit(message: "incoming"); _ = try await author.run(["push", "origin", "main"])
        let target = try await hash(author)
        fetch.model.options.branch = "main"; fetch.model.launchRebase = false; fetch.model.fetch()
        try await settle { fetch.fetchProgressController != nil && !fetch.fetchProgressController!.model.busy }
        precondition(fetch.fetchProgressController!.model.success)
        fetch.fetchProgressController!.model.close()
        try await settle { model.commandCompleted && !model.busy }
        let fetchedHead = try await hash(repo)
        precondition(fetchedHead == base && model.incomingUpToDate && model.referenceChanges.contains { $0.name.rawValue == "refs/remotes/origin/main" && $0.newHash == target } && model.commandOutput.isEmpty)

        // Pull switches first, then opens unpreset full options and compares
        // against the original branch's HEAD after the child is dismissed.
        _ = try await repo.run(["switch", "-c", "other"])
        try Data("other\n".utf8).write(to: clientRoot.appendingPathComponent("other")); try await repo.stage(["other"]); _ = try await repo.commit(message: "other baseline")
        let baseline = try await hash(repo)
        model.remote = "origin"; model.localBranch = "main"; model.remoteBranch = "main"
        model.confirmCheckout = { branch in precondition(branch == "main"); return true }
        model.fetch(.pull, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let pull = owner.optionsController!
        let checkedOut = try await hash(repo)
        precondition(checkedOut == base && pull.model.isPull && pull.model.options.remote == "origin")
        pull.model.launchRebase = false; pull.model.options.branch = "main"; pull.model.fastForwardOnly = true; pull.model.fetch()
        try await settle { pull.progressController != nil && !pull.progressController!.model.busy }
        precondition(pull.progressController!.model.success)
        pull.progressController!.model.close()
        try await settle { model.commandCompleted && !model.busy }
        let pulled = try await hash(repo)
        precondition(pulled == target && model.incomingComparison.snapshot?.from == .revision(baseline) && model.incomingComparison.snapshot?.to == .revision(target) && model.incomingCommits?.contains { $0.subject == "incoming" } == true)

        _ = try await repo.run(["config", "pull.ff", "false"])
        try Data("local conflict\n".utf8).write(to: clientRoot.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "local conflict")
        try Data("remote conflict\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "remote conflict"); _ = try await author.run(["push", "origin", "main"])
        model.fetch(.pull, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let conflictPull = owner.optionsController!
        conflictPull.model.launchRebase = false; conflictPull.model.options.branch = "main"; conflictPull.model.fastForwardOnly = false
        conflictPull.model.fetch()
        try await settle { conflictPull.progressController != nil && !conflictPull.progressController!.model.busy }
        precondition(!conflictPull.progressController!.model.success)
        // Child hint suppression was set by the preceding ordinary Pull check.
        precondition(preferences.bool(forKey: MergeProgressWindowModel.conflictHintPreference))
        conflictPull.progressController!.model.close()
        try await settle { model.commandCompleted && !model.busy }
        precondition(model.tab == 6 && model.conflicts.contains { $0.path == "file" } && model.incomingComparison.snapshot == nil)
        _ = try await repo.run(["merge", "--abort"])

        let output = model.commandOutput, refs = model.referenceChanges.count, selectedTab = model.tab
        model.fetch(.fetchAndRebase, shift: true)
        precondition(owner.optionsController == nil && !model.busy && model.commandOutput == output && model.referenceChanges.count == refs && model.tab == selectedTab && preferences.integer(forKey: "TurtleGit.Sync." + clientRoot.path + ".pullAction") == 2)
        // Forced parent closure ends the owned options sheet and resumes exactly
        // once, without publishing a late refresh into the invalidated parent.
        model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let orphan = owner.optionsController!, closedOutput = model.commandOutput
        owner.close()
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(model.closed && !model.busy && model.commandOutput == closedOutput && owner.optionsController == nil && orphan.window?.sheetParent == nil && orphan.window?.isVisible == false)
        let shim = directory.appendingPathComponent("qa-shift-git"), marker = directory.appendingPathComponent("fetch-running")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let script = "#!/bin/sh\nif [ \"$4\" = fetch ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let blockedOwner = SynchronizationWindowController(repository: GitRepository(root: clientRoot, executable: shim), access: nil, preferences: preferences)
        blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
        blockedOwner.configureOptions = { child in
            child.model.sshSettings.enabled = false
            child.presentFetchProgress = { parent, progress in progress.alphaValue = 0; parent.beginSheet(progress); return true }
        }
        let blocked = blockedOwner.model; blocked.sshSettings.enabled = false
        try await settle { !blocked.busy && blocked.outgoing != nil }
        blocked.remote = "origin"; blocked.remoteBranch = "main"; blocked.localBranch = "main"
        let refsBeforeClose = try await repo.run(["show-ref"]).stdout
        blocked.fetch(.fetch, shift: true)
        try await settle { blockedOwner.optionsController != nil && !blockedOwner.optionsController!.model.busy }
        let blockedChild = blockedOwner.optionsController!
        blockedChild.model.options.branch = "main"; blockedChild.model.launchRebase = false; blockedChild.model.fetch()
        try await settle { FileManager.default.fileExists(atPath: marker.path) && blockedChild.fetchProgressController != nil }
        let progress = blockedChild.fetchProgressController!, pid = pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!
        precondition(progress.model.busy)
        blockedOwner.close(); let stoppedOutput = blocked.commandOutput
        try await settle { kill(pid, 0) == -1 && errno == ESRCH }
        let refsAfterClose = try await repo.run(["show-ref"]).stdout
        precondition(blocked.closed && !blocked.busy && blocked.commandOutput == stoppedOutput && refsAfterClose == refsBeforeClose && blockedOwner.optionsController == nil && blockedChild.window?.sheetParent == nil && progress.window?.sheetParent == nil && !progress.model.busy)
        print("PASS: Shift Fetch/Pull real owned options and progress, named remote vs URL defaults, cancelled child, conflict results, reference refresh, original pre-checkout incoming baseline, ignored Shift variants and forced parent cleanup")
    }
    @MainActor static func verifyShiftOwnedRebase(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.appendingPathComponent("shift-owned-rebase-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = GitRepository(root: directory, executable: git), server = directory.appendingPathComponent("server.git"), authorRoot = directory.appendingPathComponent("author"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["init", "--template=", "--bare", "-b", "main", server.path]); _ = try await parent.run(["init", "--template=", "-b", "main", authorRoot.path])
        let author = GitRepository(root: authorRoot, executable: git)
        for (key, value) in [("user.name", "Owned Rebase QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "base")
        _ = try await author.run(["remote", "add", "origin", server.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key, value) in [("user.name", "Owned Rebase QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("branch.main.rebase", "merges")] { _ = try await repo.run(["config", key, value]) }
        func hash(_ repository: GitRepository) async throws -> String { String(decoding: try await repository.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        func advance(_ name: String) async throws -> String {
            try Data((name + "\n").utf8).write(to: authorRoot.appendingPathComponent(name)); try await author.stage([name]); _ = try await author.commit(message: name); _ = try await author.run(["push", "origin", "main"]); return try await hash(author)
        }
        let base = try await hash(repo), first = try await advance("first")
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        owner.configureOptions = { child in
            child.model.onRebase = { _, _, _ in preconditionFailure("owned Rebase fell through to modeless legacy callback") }
            child.presentFetchProgress = { parent, progress in progress.alphaValue = 0; parent.beginSheet(progress); return true }
        }
        let model = owner.model; model.sshSettings.enabled = false
        try await settle { !model.busy && model.outgoing != nil }
        model.remote = "origin"; model.remoteBranch = "main"; model.localBranch = "main"
        var rebaseChild: RebaseWindowController?, lastFlags: (Bool, Bool)?, count = 0
        model.runRebase = { target, autoStart, preserve in
            count += 1; lastFlags = (autoStart, preserve)
            precondition(model.busy && !model.commandCompleted && model.incomingComparison.snapshot == nil && owner.optionsController != nil && owner.window?.attachedSheet == nil)
            let options = owner.optionsController!
            precondition(options.window?.sheetParent == nil && options.window?.isVisible == false && options.fetchProgressController!.window?.sheetParent == nil && options.fetchProgressController!.model.dispatchingAction)
            let child = RebaseWindowController(repository: repo, access: nil, preferences: preferences); rebaseChild = child
            child.window!.alphaValue = 0; child.model.completionAfterFetch = true; child.model.completionAutoStart = autoStart
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var delivered = false
                child.onClosed = { [weak child] in
                    guard !delivered else { return }; delivered = true
                    if let window = child?.window { window.sheetParent?.endSheet(window) }
                    continuation.resume()
                }
                child.model.load(upstream: target, autoStart: autoStart, preserveMerges: preserve); owner.window!.beginSheet(child.window!)
            }
        }
        model.detachRebase = { rebaseChild?.close() }
        model.fetch(.pull, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let automaticOptions = owner.optionsController!
        precondition(automaticOptions.model.configuredRebase)
        automaticOptions.model.options.branch = "main"; automaticOptions.model.fetch()
        try await settle { rebaseChild != nil && !rebaseChild!.model.busy && rebaseChild!.model.finished }
        let automatic = rebaseChild!, automaticProgress = automaticOptions.fetchProgressController!
        precondition(count == 1 && lastFlags!.0 && lastFlags!.1 && automatic.model.completedSuccessfully && automatic.model.options.upstream == first)
        let advanced = try await hash(repo); precondition(advanced == first && model.busy && !model.commandCompleted && model.referenceChanges.isEmpty && model.incomingCommits == nil)
        precondition(!owner.windowShouldClose(owner.window!) && !automaticOptions.windowShouldClose(automaticOptions.window!) && !automaticProgress.windowShouldClose(automaticProgress.window!))
        automatic.model.close()
        try await settle { model.commandCompleted && !model.busy }
        precondition(model.incomingComparison.snapshot?.from == .revision(base) && model.incomingComparison.snapshot?.to == .revision(first) && model.referenceChanges.contains { $0.name.rawValue == "refs/heads/main" && $0.newHash == first } && owner.optionsController == nil && automaticOptions.window?.isVisible == false)

        // Manual full Fetch performs a real divergent replay through the editor.
        _ = try await repo.run(["config", "branch.main.rebase", "false"])
        try Data("local\n".utf8).write(to: clientRoot.appendingPathComponent("local")); try await repo.stage(["local"]); _ = try await repo.commit(message: "local replay")
        let old = try await hash(repo), second = try await advance("second")
        rebaseChild = nil
        model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let manualOptions = owner.optionsController!
        manualOptions.model.options.branch = "main"; manualOptions.model.launchRebase = true; manualOptions.model.fetch()
        try await settle { rebaseChild != nil && !rebaseChild!.model.busy && rebaseChild!.model.plan != nil }
        let manual = rebaseChild!
        precondition(count == 2 && !lastFlags!.0 && !lastFlags!.1 && !manual.model.finished && manual.model.canStart && manual.model.options.upstream == second)
        manual.model.execute("start"); try await settle { !manual.model.busy }
        precondition(manual.model.finished && manual.model.completedSuccessfully, manual.model.error ?? manual.model.output)
        let replayed = try await hash(repo); precondition(replayed != old && replayed != second && model.busy && model.incomingComparison.snapshot == nil)
        manual.model.close(); try await settle { model.commandCompleted && !model.busy }
        precondition(model.incomingComparison.snapshot?.from == .revision(old) && model.incomingComparison.snapshot?.to == .revision(replayed) && model.commandSucceeded)
        let ancestry = try await repo.run(["merge-base", "--is-ancestor", second, "HEAD"], successfulExitCodes: 0...1); precondition(ancestry.exitCode == 0)

        // Ordinary cancellation closes an unstarted Rebase then refreshes actual HEAD.
        let third = try await advance("third")
        preferences.set(2, forKey: FetchRebasePrompt.fastForward.rawValue)
        rebaseChild = nil; model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let cancelledOptions = owner.optionsController!
        cancelledOptions.model.options.branch = "main"; cancelledOptions.model.launchRebase = true; cancelledOptions.model.fetch()
        try await settle { rebaseChild != nil && !rebaseChild!.model.busy && rebaseChild!.model.plan != nil }
        let cancelled = rebaseChild!; precondition(!cancelled.model.finished)
        cancelled.model.close(); try await settle { model.commandCompleted && !model.busy }
        let cancelledHead = try await hash(repo)
        precondition(cancelledHead == replayed && model.incomingUpToDate && model.referenceChanges.contains { $0.name.rawValue == "refs/remotes/origin/main" && $0.newHash == third })

        // Presentation failure retains successful fetch ref updates and reports
        // the handoff error in the parent, with no invisible waiting windows.
        let fourth = try await advance("fourth")
        let presentOwnedRebase = model.runRebase
        model.runRebase = { _, _, _ in throw SynchronizationFailure.invalidInput }
        model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let failedOptions = owner.optionsController!
        failedOptions.model.options.branch = "main"; failedOptions.model.launchRebase = true; failedOptions.model.fetch()
        try await settle { model.commandCompleted && !model.busy }
        precondition(!model.commandSucceeded && model.error != nil && model.referenceChanges.contains { $0.name.rawValue == "refs/remotes/origin/main" && $0.newHash == fourth } && owner.optionsController == nil && owner.window?.attachedSheet == nil)
        let retainedError = model.error!
        precondition(model.commandOutput.contains(retainedError))
        model.reload(); try await settle { !model.busy }
        precondition(model.error == nil && model.commandOutput.contains(retainedError))
        // Force-close during the pending handoff; a late child notification must
        // not publish into the closed owner or resume either continuation twice.
        let fifth = try await advance("fifth")
        model.runRebase = presentOwnedRebase; rebaseChild = nil
        model.fetch(.fetch, shift: true)
        try await settle { owner.optionsController != nil && !owner.optionsController!.model.busy }
        let forcedOptions = owner.optionsController!
        forcedOptions.model.options.branch = "main"; forcedOptions.model.launchRebase = true; forcedOptions.model.fetch()
        try await settle { rebaseChild != nil && !rebaseChild!.model.busy && rebaseChild!.model.plan != nil }
        let forced = rebaseChild!, forcedProgress = forcedOptions.fetchProgressController!, lateDismiss = forced.onClosed
        owner.close(); let closedOutput = model.commandOutput
        lateDismiss(); lateDismiss()
        try await Task.sleep(nanoseconds: 50_000_000)
        let closedHead = try await hash(repo), fetchedRef = String(decoding: try await repo.run(["rev-parse", "refs/remotes/origin/main"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        precondition(model.closed && !model.busy && model.commandOutput == closedOutput && model.referenceChanges.isEmpty && model.incomingComparison.snapshot == nil && owner.optionsController == nil && closedHead == replayed && fetchedRef == fifth)
        precondition(forced.window?.sheetParent == nil && forced.window?.isVisible == false && forcedOptions.window?.isVisible == false && forcedProgress.window?.isVisible == false && !forcedProgress.model.dispatchingAction)

        // The opt-in owned callback must preserve the standalone deferred route.
        var legacyOptions = FetchOptions(); legacyOptions.remote = "origin"; legacyOptions.branch = "main"; legacyOptions.namedRemoteFetchAll = false
        let legacy = FetchProgressWindowModel(repository: repo, access: nil, options: legacyOptions, preferences: preferences, rebaseMode: .automatic, preserveMerges: true)
        var legacyOrder: [String] = []
        legacy.close = { [weak legacy] in legacyOrder.append("close"); legacy?.invalidate() }
        legacy.onRebase = { target, autoStart, preserve in precondition(target == fifth && autoStart && preserve); legacyOrder.append("rebase") }
        await legacy.run()
        precondition(legacyOrder == ["close", "rebase"])
        print("PASS: owned Shift Pull automatic preserve-merges Rebase and manual Fetch divergent replay, no early incoming/ref refresh, ordinary Rebase cancellation, pinned targets, legacy callback exclusion/fallback, handoff failure and forced owner cleanup")
    }
    @MainActor static func verifyFetchAndRebase(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.appendingPathComponent("fetch-rebase-fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let parent = GitRepository(root: directory, executable: git), server = directory.appendingPathComponent("server.git"), authorRoot = directory.appendingPathComponent("author"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["init", "--template=", "--bare", "-b", "main", server.path]); _ = try await parent.run(["init", "--template=", "-b", "main", authorRoot.path])
        let author = GitRepository(root: authorRoot, executable: git)
        for (key, value) in [("user.name", "Rebase QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await author.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: authorRoot.appendingPathComponent("file")); try await author.stage(["file"]); _ = try await author.commit(message: "base")
        _ = try await author.run(["remote", "add", "origin", server.path]); _ = try await author.run(["push", "-u", "origin", "main"])
        _ = try await parent.run(["clone", "--template=", "--", server.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git)
        for (key, value) in [("user.name", "Rebase QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        func hash(_ repository: GitRepository) async throws -> String { String(decoding: try await repository.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        func advance(_ name: String) async throws -> String {
            try Data((name + "\n").utf8).write(to: authorRoot.appendingPathComponent(name)); try await author.stage([name]); _ = try await author.commit(message: name); _ = try await author.run(["push", "origin", "main"]); return try await hash(author)
        }
        for prompt in FetchRebasePrompt.allCases { preferences.removeObject(forKey: prompt.rawValue) }
        let base = try await hash(repo), first = try await advance("first")
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; model.sshSettings.enabled = false
        try await settle { !model.busy && model.outgoing != nil }
        model.localBranch = "main"; model.remote = "origin"; model.remoteBranch = "main"
        var prompts: [FetchRebasePrompt] = [], mergeCount = 0, rebaseCount = 0
        model.presentRebasePrompt = { prompt in prompts.append(prompt); precondition(prompt == .fastForward); return FetchRebaseAnswer(value: 1, suppress: false) }
        let presentMerge = model.performFastForward!
        model.performFastForward = { state, token in
            mergeCount += 1; precondition(state.target == first && state.head == base && state.branch == "main")
            let result = await presentMerge(state, token); precondition(owner.window?.attachedSheet == nil); return result
        }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        let merged = try await hash(repo)
        precondition(merged == first && mergeCount == 1 && prompts == [.fastForward] && model.commandSucceeded && model.tab == 4)
        precondition(model.incomingComparison.snapshot?.from == .revision(base) && model.incomingComparison.snapshot?.to == .revision(first))
        let restored = SynchronizationWindowModel(repository: repo, access: nil, preferences: preferences); precondition(restored.pullAction == .fetchAndRebase)
        prompts = []; model.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 7, suppress: true) }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        precondition(prompts == [.unchanged] && model.commandSucceeded && preferences.integer(forKey: FetchRebasePrompt.unchanged.rawValue) == 7)
        model.presentRebasePrompt = { _ in preconditionFailure("suppressed prompt was shown") }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }; precondition(model.commandSucceeded && mergeCount == 1)
        preferences.removeObject(forKey: FetchRebasePrompt.unchanged.rawValue)
        let second = try await advance("second")
        prompts = []; model.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 3, suppress: false) }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        let abortedHead = try await hash(repo); precondition(abortedHead == first && prompts == [.fastForward] && model.commandSucceeded && model.incomingCommits == nil && model.tab == 3)
        model.runRebase = { target, autoStart, preserve in
            rebaseCount += 1; precondition(!autoStart && !preserve && model.busy && owner.window?.attachedSheet == nil)
            let child = RebaseWindowController(repository: repo, access: nil, preferences: preferences)
            child.window!.alphaValue = 0; child.model.completionAfterFetch = true; child.model.completionAutoStart = false
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var delivered = false
                child.onClosed = { [weak child] in
                    guard !delivered else { return }; delivered = true
                    if let window = child?.window { window.sheetParent?.endSheet(window) }
                    continuation.resume()
                }
                child.model.load(upstream: target, autoStart: false); owner.window!.beginSheet(child.window!)
                Task {
                    do {
                        try await settle { !child.model.busy && child.model.plan != nil }
                        precondition(child.model.options.upstream == target && child.model.canStart && !child.model.finished)
                        precondition(!owner.windowShouldClose(owner.window!))
                        child.model.execute("start"); try await settle { !child.model.busy }
                        precondition(child.model.finished && child.model.completedSuccessfully, child.model.error ?? child.model.output)
                        child.model.close()
                    } catch { child.close(); if !delivered { delivered = true; continuation.resume(throwing: error) } }
                }
            }
            precondition(owner.window?.attachedSheet == nil)
        }
        prompts = []; model.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: prompt == .unchanged ? 6 : 2, suppress: false) }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        let rebasedFF = try await hash(repo)
        precondition(prompts == [.unchanged, .fastForward] && rebaseCount == 1 && rebasedFF == second && model.incomingComparison.snapshot?.to == .revision(second))
        try Data("local\n".utf8).write(to: clientRoot.appendingPathComponent("local")); try await repo.stage(["local"]); _ = try await repo.commit(message: "local replay")
        let original = try await hash(repo), third = try await advance("third")
        prompts = []; model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        let replayed = try await hash(repo)
        precondition(prompts.isEmpty && rebaseCount == 2 && model.commandSucceeded && replayed != original && replayed != third)
        precondition(model.incomingComparison.snapshot?.from == .revision(original) && model.incomingComparison.snapshot?.to == .revision(replayed))
        let ancestry = try await repo.run(["merge-base", "--is-ancestor", third, "HEAD"], successfulExitCodes: 0...1); precondition(ancestry.exitCode == 0)
        prompts = []; model.presentRebasePrompt = { prompt in prompts.append(prompt); return FetchRebaseAnswer(value: 7, suppress: false) }
        model.performPullAction(.fetchAndRebase); try await settle { !model.busy }
        let ahead = try await hash(repo)
        precondition(prompts == [.unchanged] && ahead == replayed && model.commandSucceeded && !model.incomingUpToDate)
        precondition(model.incomingCommits?.isEmpty == true && model.incomingComparison.snapshot?.from == .revision(replayed) && model.incomingComparison.snapshot?.to == .revision(third))
        precondition(model.incomingComparison.snapshot?.files.contains { $0.path == "local" && $0.action == "D" } == true)
        _ = try await repo.run(["reset", "--hard", third])
        let fourth = try await advance("fourth")
        model.performFastForward = presentMerge
        model.presentRebasePrompt = { prompt in
            precondition(prompt == .fastForward)
            _ = try! await repo.run(["switch", "--detach", third])
            return FetchRebaseAnswer(value: 1, suppress: false)
        }
        model.performPullAction(.fetchAndRebase)
        try await settle { owner.window?.attachedSheet?.title.contains("Merge Progress") == true }
        let staleProgress = owner.window!.attachedSheet!, staleController = staleProgress.delegate as! SynchronizationProgressController
        try await settle { !staleController.model.busy }
        precondition(staleController.model.output.contains("repository changed"))
        staleController.model.close(); try await settle { !model.busy }
        let staleHead = try await hash(repo), staleBranch = try await repo.branch()
        precondition(staleHead == third && staleBranch.isEmpty && !model.commandSucceeded && model.incomingUpToDate)
        let mainRef = String(decoding: try await repo.run(["rev-parse", "refs/heads/main"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        precondition(mainRef == third && fourth != third)
        print("PASS: native Sync Fetch & Rebase unchanged No/suppression with ahead HEAD, separate fast-forward Merge, Abort without incoming, unchanged Yes then manual Rebase, actual owned Rebase controller fast-forward/divergent replay, stale Merge refusal, source action persistence and pinned incoming results")
    }
    @MainActor static func main() async throws {
        if let status = RebaseEditor.handle(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) { exit(status) }
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
        try await verifyPull(root: root, preferences: preferences)
        try await verifyFetchAndRebase(root: root, preferences: preferences)
        try await verifyShiftOptions(root: root, preferences: preferences)
        try await verifyShiftOwnedRebase(root: root, preferences: preferences)
        print("PASS: native Sync tracking controls, exact Unicode choices, graph-first table, changes and pinned comparison snapshot, divergence/Force, unknown states, Quit fences, owner invalidation and read-only preservation")
    }
}
