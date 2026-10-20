import AppKit
import Darwin
import TurtleGitCore

@main struct SynchronizationVerification {
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func settle(_ condition: () -> Bool, line: UInt = #line) async throws {
        // Parent waits include Fetch, owned Rebase load/replay and result refresh.
        // Use a monotonic deadline rather than assuming those Git stages fit 10s.
        let started = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - started < 60_000_000_000 {
            if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Synchronization did not settle at fixture line \(line)")
    }
    struct StashPreparationFailure:Error,CustomStringConvertible {let description:String}
    @MainActor static func awaitStashForm(_ owner:StashWindowController)async throws {
        if !owner.model.prepared && !owner.model.preparing {owner.model.prepare()}
        for _ in 0..<6000 {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            if owner.model.canEditForm {return}
            if owner.model.closed || owner.model.error != nil {throw StashPreparationFailure(description:"Stash form preparation failed: \(owner.model.error ?? "owner closed")")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw StashPreparationFailure(description:"Stash identity preparation did not settle")
    }
    @MainActor static func awaitStashProgress(_ owner:StashWindowController)async throws->StashSaveProgressWindowModel {
        for _ in 0..<6000 {
            if let progress=owner.model.progress {return progress}
            if owner.model.closed || owner.model.error != nil {throw StashPreparationFailure(description:"Stash submission preparation failed: \(owner.model.error ?? "owner closed")")}
            try await Task.sleep(nanoseconds:5_000_000)
        }
        throw StashPreparationFailure(description:"Stash submission did not produce progress after identity preparation")
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
        for index in menu.items.indices {
            let current = refsTable.menu(for: event)!.items[index]
            _ = NSApp.sendAction(current.action!, to: current.target, from: current)
        }
        let consumed = refsTable.menu(for: event)!.items[0]
        _ = NSApp.sendAction(consumed.action!, to: consumed.target, from: consumed)
        let shownBeforeReuse = shown
        _ = NSApp.sendAction(consumed.action!, to: consumed.target, from: consumed)
        precondition(shown == shownBeforeReuse)
        shown.removeLast()
        precondition(shown == [changed.oldHash!, incoming] && compared?.0 == changed.oldHash && compared?.1 == incoming && reflog == "refs/remotes/origin/review")
        let hideMenu = refsTable.headerView!.menu(for: event)!, hide = hideMenu.items.first!
        precondition(hide.state == .off)
        _ = NSApp.sendAction(hide.action!, to: hide.target, from: hide)
        precondition(model.hideUnchangedReferences && model.referenceRows.allSatisfy { $0.kind != .same } && !preferences.bool(forKey: "RefCompareHideUnchanged"))
        let freshHide = refsTable.headerView!.menu(for: event)!.items.first!
        _ = NSApp.sendAction(freshHide.action!, to: freshHide.target, from: freshHide)
        precondition(!model.hideUnchangedReferences && !preferences.bool(forKey:"RefCompareHideUnchanged"))
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
        defer { try? FileManager.default.removeItem(at: directory) }
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
    @MainActor static func verifyTags(root: URL, preferences: UserDefaults) async throws {
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), directory = root.deletingLastPathComponent().appendingPathComponent("qa-tags-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = GitRepository(root: directory, executable: git), serverRoot = directory.appendingPathComponent("server 雪.git"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["clone", "--bare", "--template=", "--", root.path, serverRoot.path])
        _ = try await parent.run(["clone", "--template=", "--", serverRoot.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git), server = GitRepository(root: serverRoot, executable: git)
        for (key, value) in [("user.name", "Tag UI QA"), ("user.email", "qa@example.invalid"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await server.run(["config", "core.hooksPath", "/dev/null"])
        func hash(_ repository: GitRepository, _ ref: String) async throws -> String { String(decoding: try await repository.run(["rev-parse", "--verify", ref]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        let head = try await hash(repo, "HEAD"), previous = try await hash(repo, "HEAD^")
        for name in ["v2", "v10", "same"] { _ = try await repo.run(["tag", name, head]) }
        _ = try await server.run(["update-ref", "refs/tags/same", head]); _ = try await server.run(["update-ref", "refs/tags/different", head])
        _ = try await repo.run(["tag", "different", previous])
        _ = try await repo.run(["tag", "-a", "-m", "remote annotation", "remote", head]); _ = try await repo.run(["push", "origin", "refs/tags/remote"]); _ = try await repo.run(["tag", "-d", "remote"])
        let refs = try await repo.run(["show-ref"]).stdout, index = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index")), config = try Data(contentsOf: clientRoot.appendingPathComponent(".git/config"))
        preferences.set(true, forKey: "SortTagsReversed"); preferences.set(false, forKey: "TagCompareHideEqual")
        defer { preferences.removeObject(forKey: "SortTagsReversed"); preferences.removeObject(forKey: "TagCompareHideEqual") }
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; model.sshSettings.enabled = false
        preferences.set(0, forKey: "AutoCloseGitProgress")
        defer { preferences.removeObject(forKey: "AutoCloseGitProgress") }
        var errors = [String](), operations = [String](), compactSizes = [NSSize](), deletionOutput = [String]()
        let realErrorPresenter = model.presentTagError
        model.presentTagError = { errors.append($0) }
        let originalOperation = model.performTagOperation
        model.performTagOperation = { operation, token in
            switch operation {
            case .tags: operations.append("load")
            case .tag(let action, _, _, _): operations.append(action.title)
            default: preconditionFailure("unexpected tag operation")
            }
            var observer: Task<Void, Never>?
            var observed: SynchronizationProgressController?
            if case .tag(.deleteRemote, _, _, _) = operation {
                observer = Task { @MainActor in
                    do {
                        try await settle { owner.commandProgress != nil }
                        let child = owner.commandProgress!; observed = child
                        precondition(child.model.operation.compactProgress && !child.model.operation.loadingTags && !child.window!.styleMask.contains(.resizable))
                        compactSizes.append(child.window!.contentLayoutRect.size)
                    } catch { preconditionFailure("compact deletion observation failed") }
                }
            }
            let result = await originalOperation(operation, token)
            await observer?.value
            if let observed { deletionOutput.append(observed.model.output) }
            return result
        }
        try await settle { !model.busy && model.outgoing != nil }
        model.compareTags(shift: true)
        precondition(model.compareTagsSelected && !model.busy && !model.comparingTags && preferences.integer(forKey: "TurtleGit.Sync." + clientRoot.path + ".pullAction") == 6)
        model.performPullAction(shift: false); try await settle { !model.busy }
        precondition(model.error == nil && model.comparingTags && model.tab == 7 && model.tagSnapshot!.remote == "origin")
        let refsAfterRead = try await repo.run(["show-ref"]).stdout; precondition(refsAfterRead == refs)
        try await settle { views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.contains { $0.tableColumns.first?.title == "Tag" } }
        let table = views(owner.window!.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.first?.title == "Tag" }!
        precondition(table.tableColumns.map(\.title) == ["Tag", "Status", "Local hash", "Local message", "Remote hash", "Remote message"])
        func field(_ row: Int, _ column: Int) -> NSTextField {
            let view=table.delegate!.tableView!(table, viewFor:table.tableColumns[column],row:row)!
            return (view as? NSTableCellView)?.textField ?? (view as! NSTextField)
        }
        func settleTable() async throws {
            try await settle {
                table.numberOfRows == model.tagRows.count && (0..<table.numberOfRows).allSatisfy { index in
                    guard let row = model.tagRows.first(where: { $0.name.rawValue == field(index, 0).stringValue }) else { return false }
                    return field(index, 2).toolTip == (row.localHash ?? "") && field(index, 4).toolTip == (row.remoteHash ?? "")
                }
            }
        }
        try await settleTable()
        func rowIndex(_ name: String) -> Int { (0..<table.numberOfRows).first { field($0, 0).stringValue == name }! }
        precondition(rowIndex("v10") < rowIndex("v2"))
        table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: true)]; precondition(rowIndex("v2") < rowIndex("v10"))
        func menu(_ name: String) -> NSMenu {
            let point = table.convert(NSPoint(x: 8, y: table.rect(ofRow: rowIndex(name)).midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            return table.menu(for: event)!
        }
        func send(_ item: NSMenuItem) { precondition(NSApp.sendAction(item.action!, to: item.target, from: item)) }
        let different = menu("different"), items = different.items.filter { !$0.isSeparatorItem }
        precondition(Array(items.map(\.title).suffix(4)) == ["Fetch", "Push", "Delete local tag", "Delete tag on remote"] && items.allSatisfy { $0.image != nil && $0.isEnabled })
        precondition(field(rowIndex("different"), 2).stringValue == String(previous.prefix(8)) && field(rowIndex("different"), 2).toolTip == previous)
        var logs = [String](), comparison: (String, String)?, changed = 0
        model.onTagsChanged = { changed += 1 }
        model.onLog = { logs.append($0) }; model.onReferenceCompare = { comparison = ($0, $1) }
        for index in 0..<3 {send(menu("different").items.filter{!$0.isSeparatorItem}[index])}
        let consumedLog=menu("different").items.first!;send(consumedLog)
        let logsBeforeReuse=logs;send(consumedLog);precondition(logs==logsBeforeReuse);logs.removeLast()
        precondition(logs == [previous, head] && comparison?.0 == previous && comparison?.1 == head)
        precondition(menu("same").items.filter { !$0.isSeparatorItem }.count == 3)
        preferences.set(false, forKey: "ShowAppContextMenuIcons"); precondition(menu("different").items.filter { !$0.isSeparatorItem }.allSatisfy { $0.image == nil }); preferences.removeObject(forKey: "ShowAppContextMenuIcons")
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: owner.window!.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let hide = table.headerView!.menu(for: event)!.items.first!; send(hide)
        try await settleTable()
        precondition(model.hideEqualTags && model.tagRows.allSatisfy { $0.kind != .same } && !preferences.bool(forKey: "TagCompareHideEqual"))
        send(table.headerView!.menu(for:event)!.items.first!);try await settleTable()
        precondition(!model.hideEqualTags && !preferences.bool(forKey:"TagCompareHideEqual"))
        owner.window!.appearance = NSAppearance(named: .darkAqua); owner.window!.contentView!.layoutSubtreeIfNeeded(); owner.window!.appearance = NSAppearance(named: .aqua)
        func closeCommand() async throws {
            try await settle { owner.commandProgress != nil && !owner.commandProgress!.model.busy && !owner.commandProgress!.model.operation.loadingTags }
            precondition(model.busy && !owner.windowShouldClose(owner.window!))
            owner.commandProgress!.model.close(); try await settle { !model.busy }
            try await settleTable()
        }
        let oldRemoteMenu = menu("remote^{}"), fetch = oldRemoteMenu.items.first { $0.title == "Fetch" }!; send(fetch)
        try await closeCommand(); precondition(model.error == nil && model.tagSnapshot!.rows.first { $0.name.rawValue == "remote^{}" }!.kind == .same)
        send(fetch); precondition(!model.busy) // stale represented row cannot run again
        let failedFetch = menu("different").items.first { $0.title == "Fetch" }!; send(failedFetch)
        try await closeCommand(); precondition(model.error != nil && model.tagSnapshot!.rows.first { $0.name.rawValue == "different" }!.kind == .differ)
        send(menu("v2").items.first { $0.title == "Push" }!); try await closeCommand()
        let pushed = try await hash(server, "refs/tags/v2"); precondition(pushed == head)
        var confirmed = false, confirmationName = "", confirmationRemote = ""
        model.confirmTagDeletion = { _, row, snapshot in confirmationName = row.tag.rawValue; confirmationRemote = snapshot.remote; return confirmed }
        operations.removeAll()
        send(menu("remote^{}").items.first { $0.title == "Delete local tag" }!); try await settle { !model.busy }
        precondition(operations.isEmpty && owner.commandProgress == nil)
        let stillPresent = try await hash(repo, "refs/tags/remote"); precondition(!stillPresent.isEmpty && confirmationName == "remote" && confirmationRemote == "origin")
        confirmed = true
        send(menu("remote^{}").items.first { $0.title == "Delete local tag" }!); try await settle { !model.busy }
        precondition(model.tagSnapshot!.rows.first { $0.name.rawValue == "remote" }!.kind == .onlyRemote && operations.isEmpty && owner.commandProgress == nil)
        try await settleTable()
        let beforeFailedDelete = model.tagSnapshot!.rows
        let hooks = directory.appendingPathComponent("reject-hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-receive")
        try Data("#!/bin/sh\nprintf 'Tag QA rejects deletion\\n' >&2\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
        _ = try await server.run(["config", "core.hooksPath", hooks.path])
        // The system Git local receiver caches the client's hook configuration
        // before entering the bare server. Pin the receive command's hook path
        // explicitly so this fixture exercises a real server rejection.
        func quoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let receiveCommand = quoted(git.path) + " -c core.hooksPath=" + quoted(hooks.path) + " receive-pack"
        _ = try await repo.run(["config", "remote.origin.receivepack", receiveCommand])
        let hookConfig = try await server.run(["config", "--show-origin", "core.hooksPath"]).text.trimmingCharacters(in: .newlines)
        let remoteURL = try await repo.run(["remote", "get-url", "origin"]).text.trimmingCharacters(in: .newlines)
        send(menu("v2").items.first { $0.title == "Delete tag on remote" }!); try await settle { !model.busy }
        precondition(model.error != nil && errors.count == 1 && model.tagSnapshot!.rows == beforeFailedDelete && operations == ["Delete tag on remote"], "remote deletion: error=\(model.error ?? "nil"); alerts=\(errors.count); snapshotSame=\(model.tagSnapshot?.rows == beforeFailedDelete); operations=\(operations); hooks=\(hookConfig); remote=\(remoteURL); expected=\(server.root.path); output=\(deletionOutput)")
        _ = try await server.run(["config", "core.hooksPath", "/dev/null"])
        _ = try await repo.run(["config", "--unset", "remote.origin.receivepack"])
        operations.removeAll()
        send(menu("v2").items.first { $0.title == "Delete tag on remote" }!); try await settle { !model.busy }
        let deleted = try await server.run(["for-each-ref", "refs/tags/v2"]).stdout; precondition(deleted.isEmpty && operations == ["Delete tag on remote"] && compactSizes.count == 2 && compactSizes.allSatisfy { $0.width < 600 && $0.height < 250 })
        let finalHead = try await hash(repo, "HEAD"), finalIndex = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: clientRoot.appendingPathComponent(".git/config"))
        precondition(finalHead == head && index == finalIndex && config == finalConfig && changed == 6)
        model.refresh(); try await settle { !model.busy }; precondition(model.tab == 7 && model.tagSnapshot != nil)
        // Source AutoCloseGitProgress 1/2 closes a successful tag command with
        // no post-actions, but still retains failed Fetch output for Close.
        for policy in [1, 2] {
            preferences.set(policy, forKey: "AutoCloseGitProgress")
            let tag = "auto-" + String(policy)
            _ = try await repo.run(["tag", tag, head]); model.refresh(); try await settle { !model.busy }; try await settleTable()
            send(menu(tag).items.first { $0.title == "Push" }!); try await settle { !model.busy }; try await settleTable()
            let pushed = try await hash(server, "refs/tags/" + tag)
            precondition(pushed == head && owner.commandProgress == nil)
        }
        send(menu("different").items.first { $0.title == "Fetch" }!); try await closeCommand()
        precondition(model.error != nil && errors.count == 1 && changed == 9)
        model.remote = directory.appendingPathComponent("missing-server.git").path; model.compareTags(); try await settle { !model.busy }
        precondition(model.error != nil && model.tagSnapshot == nil && errors.count == 2 && owner.commandProgress == nil)
        model.remote = "origin"; model.refresh(); try await settle { !model.busy }; precondition(model.error == nil && model.tagSnapshot != nil)
        preferences.set(0, forKey: "AutoCloseGitProgress")
        let restored = SynchronizationWindowModel(repository: repo, access: nil, preferences: preferences); precondition(restored.compareTagsSelected && restored.pullActionTitle == "Compare Tags")
        model.reload(); try await settle { !model.busy }; precondition(model.tab == 0 && !model.comparingTags && model.tagSnapshot == nil)
        // Both loading and a write own their cancellation/process group, and
        // force-closing the root must suppress late results and reap the shim.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for writing in [false, true] {
            let shim = directory.appendingPathComponent(writing ? "blocked-push" : "blocked-load"), marker = directory.appendingPathComponent(writing ? "push-pid" : "load-pid")
            let condition = writing ? "[ \"$6\" = push ]" : "[ \"$4\" = ls-remote ]"
            let script = "#!/bin/sh\nif " + condition + "; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\nexec " + quote(git.path) + " \"$@\"\n"
            try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            let blockedOwner = SynchronizationWindowController(repository: GitRepository(root: clientRoot, executable: shim), access: nil, preferences: preferences)
            blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
            let blocked = blockedOwner.model; blocked.sshSettings.enabled = false
            try await settle { !blocked.busy && blocked.outgoing != nil }
            blocked.compareTags()
            if writing { try await settle { !blocked.busy }; blocked.performTag(.push, row: blocked.tagSnapshot!.rows.first { $0.name.rawValue == "v10" }!) }
            try await settle { FileManager.default.fileExists(atPath: marker.path) }
            let progress = blockedOwner.commandProgress!, pid = pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!
            precondition(progress.model.busy && progress.window?.sheetParent === blockedOwner.window)
            let refsBeforeClose = try await repo.run(["show-ref"]).stdout
            blockedOwner.close(); try await settle { kill(pid, 0) == -1 && errno == ESRCH }
            let refsAfterClose = try await repo.run(["show-ref"]).stdout
            precondition(blocked.closed && !blocked.busy && !progress.model.busy && progress.window?.sheetParent == nil && blockedOwner.commandProgress == nil && refsAfterClose == refsBeforeClose)
        }
        // Exercise the actual owned native error sheet and force-close fence.
        model.presentTagError = realErrorPresenter
        model.remote = directory.appendingPathComponent("missing-error-owner.git").path; model.compareTags()
        try await settle { owner.window!.attachedSheet != nil && owner.commandProgress == nil }
        let alertWindow = owner.window!.attachedSheet!
        precondition(model.busy && alertWindow.alphaValue == 0 && !owner.windowShouldClose(owner.window!))
        owner.close(); try await settle { alertWindow.sheetParent == nil && !alertWindow.isVisible }
        precondition(model.closed && !model.busy && owner.commandProgress == nil)
        print("PASS: native Compare Tags six columns, raw/friendly entries, natural/reversed sorting, full-hash Log/Compare routes, source icon menus and visibility settings, Hide unchanged, Shift persistence, real non-force failure/Fetch/Push/confirmed friendly deletions, manual/automatic output close, inline local deletion, compact remote deletion with same-window refill/error, loading error handoff and actual owned error-sheet cleanup, HEAD/index/config preservation and forced load/write cleanup")
    }

    @MainActor static func verifyPush(root: URL, preferences sharedPreferences: UserDefaults) async throws {
        let suite = "TurtleGit.Sync.Push.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); DialogGeometry.install(preferences: sharedPreferences) }
        DialogGeometry.install(preferences: preferences)
        let git = URL(fileURLWithPath: CommandLine.arguments[2])
        let directory = root.deletingLastPathComponent().appendingPathComponent("qa-push-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = GitRepository(root: directory, executable: git), serverRoot = directory.appendingPathComponent("server 雪.git"), clientRoot = directory.appendingPathComponent("client")
        _ = try await parent.run(["clone", "--bare", "--template=", "--", root.path, serverRoot.path])
        _ = try await parent.run(["clone", "--template=", "--", serverRoot.path, clientRoot.path])
        let repo = GitRepository(root: clientRoot, executable: git), server = GitRepository(root: serverRoot, executable: git)
        for (key, value) in [("user.name", "Push QA"), ("user.email", "qa@example.invalid"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await server.run(["config", "core.hooksPath", "/dev/null"])
        for key in ["branch.main.remote", "branch.main.merge"] { _ = try await repo.run(["config", "--unset", key], successfulExitCodes: 0...5) }
        func hash(_ repository: GitRepository, _ ref: String) async throws -> String { try await repository.run(["rev-parse", "--verify", ref]).text.trimmingCharacters(in: .newlines) }
        func refs() async throws -> Data { try await server.run(["show-ref"]).stdout }
        let head = try await hash(repo, "HEAD"), previous = try await hash(repo, "HEAD^"), initialRefs = try await refs()
        let index = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index"))
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; model.sshSettings.enabled = false
        preferences.set(0, forKey: "AutoCloseGitProgress")
        defer { preferences.removeObject(forKey: "AutoCloseGitProgress"); preferences.removeObject(forKey: "AskSetTrackedBranch") }
        try await settle { !model.busy && model.outgoing != nil }
        model.localBranch = "main"; model.remote = "origin"; model.remoteBranch = "push-new"
        let key = "TurtleGit.Sync." + clientRoot.path + ".pushAction"
        var questions = [(String, String, String)](), finished = 0
        model.onTransportFinished = { _ in finished += 1 }
        model.askTracking = { local, remote, destination in questions.append((local, remote, destination)); return SynchronizationTrackingAnswer(choice: .cancel) }
        model.push(.push, shift: false); try await settle { !model.busy }
        let cancelledRefs = try await refs()
        precondition(cancelledRefs == initialRefs && !model.commandSucceeded && preferences.object(forKey: key) == nil && questions.count == 1)
        precondition(questions[0].0 == "main" && questions[0].1 == "origin" && questions[0].2 == "push-new")
        model.askTracking = { local, remote, destination in questions.append((local, remote, destination)); return SynchronizationTrackingAnswer(choice: .no, suppress: true) }
        model.push(.push, shift: false); try await settle { !model.busy }
        let firstPush = try await hash(server, "refs/heads/push-new")
        precondition(model.commandSucceeded && firstPush == head && preferences.integer(forKey: key) == 0 && !preferences.bool(forKey: "AskSetTrackedBranch"))
        let noTracking = try await repo.synchronizationBranches(localBranch: "main"); precondition(noTracking.trackedBranch.isEmpty)
        preferences.removeObject(forKey: "AskSetTrackedBranch")
        model.remoteBranch = "refs/heads/tracked-雪"
        model.askTracking = { local, remote, destination in questions.append((local, remote, destination)); return SynchronizationTrackingAnswer(choice: .yes) }
        model.push(.push, shift: false); try await settle { !model.busy }
        let tracking = try await repo.synchronizationBranches(localBranch: "main"), trackedPush = try await hash(server, "refs/heads/tracked-雪")
        precondition(model.commandSucceeded && tracking.trackedRemote == "origin" && tracking.trackedBranch == "tracked-雪" && trackedPush == head)
        for config in ["branch.main.remote", "branch.main.merge"] { _ = try await repo.run(["config", "--unset", config]) }
        model.remoteBranch = ""; model.askTracking = { local, remote, destination in questions.append((local, remote, destination)); return SynchronizationTrackingAnswer(choice: .no) }
        model.push(.push, shift: false); try await settle { !model.busy }
        precondition(model.commandSucceeded && questions.last!.2 == "main")
        let questionCount = questions.count
        _ = try await repo.run(["tag", "sync-tag", head]); model.remoteBranch = "tag-target"
        model.push(.pushTags, shift: false); try await settle { !model.busy }
        let tag = try await hash(server, "refs/tags/sync-tag"), tagBranch = try await hash(server, "refs/heads/tag-target")
        precondition(model.commandSucceeded && tag == head && tagBranch == head && questions.count == questionCount && preferences.integer(forKey: key) == 1)
        _ = try await repo.run(["config", "core.notesRef", "refs/notes/sync-qa"]); _ = try await repo.run(["notes", "add", "-m", "source notes", "HEAD"])
        model.remoteBranch = "ignored for notes"; model.push(.pushNotes, shift: false); try await settle { !model.busy }
        let localNotes = try await hash(repo, "refs/notes/sync-qa"), remoteNotes = try await hash(server, "refs/notes/sync-qa")
        precondition(model.commandSucceeded && localNotes == remoteNotes && questions.count == questionCount && preferences.integer(forKey: key) == 2)
        let restored = SynchronizationWindowModel(repository: repo, access: nil, preferences: preferences)
        precondition(restored.pushAction == .pushNotes && restored.pushActionTitle == "Push notes")
        _ = try await repo.run(["branch", "older", previous]); _ = try await server.run(["update-ref", "refs/heads/forced", head])
        model.localBranch = "older"; model.remoteBranch = "forced"; preferences.set(false, forKey: "AskSetTrackedBranch")
        model.push(.push, shift: false); try await settle { !model.busy }
        let rejected = try await hash(server, "refs/heads/forced"); precondition(!model.commandSucceeded && model.error != nil && rejected == head)
        model.force = true; model.push(.push, shift: false); try await settle { !model.busy }
        let forced = try await hash(server, "refs/heads/forced"); precondition(model.commandSucceeded && forced == previous)
        model.force = false; model.localBranch = "main"; model.remote = serverRoot.path; model.remoteBranch = "url-雪"
        preferences.removeObject(forKey: "AskSetTrackedBranch")
        model.askTracking = { _, _, _ in preconditionFailure("URL Push must not ask tracking") }
        model.push(.push, shift: false); try await settle { !model.busy }
        let urlPush = try await hash(server, "refs/heads/url-雪"); precondition(model.commandSucceeded && urlPush == head)
        model.localBranch = ""; var deletionAllowed = false, deletionQuestions = 0
        model.confirmPushDeletion = { destination in precondition(destination == "url-雪"); deletionQuestions += 1; return deletionAllowed }
        model.push(.push, shift: false); try await settle { !model.busy }
        let retained = try await hash(server, "refs/heads/url-雪"); precondition(!model.commandSucceeded && retained == head)
        deletionAllowed = true; model.push(.push, shift: false); try await settle { !model.busy }
        let removed = try await server.run(["show-ref", "--verify", "--quiet", "refs/heads/url-雪"], successfulExitCodes: 0...1)
        precondition(model.commandSucceeded && removed.exitCode == 1 && deletionQuestions == 2)
        let beforeShift = try await refs(), outputBeforeShift = model.commandOutput
        model.push(.pushTags, shift: true); precondition(!model.busy && owner.pushOptionsController == nil && preferences.integer(forKey: key) == 0)
        model.push(.pushNotes, shift: true); precondition(!model.busy && owner.pushOptionsController == nil && preferences.integer(forKey: key) == 0)
        model.remote = ""; model.localBranch = "refs/heads/main"
        let realPushOptions = model.runPushOptions
        var pending: CheckedContinuation<Void, Error>?
        model.runPushOptions = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        model.push(.push, shift: true); try await settle { pending != nil }
        model.cancelTransport(); pending!.resume(throwing: OperationCancellationFailure.cancelled); pending = nil
        try await settle { !model.busy }
        precondition(!model.cancelling && !model.transportRunning && preferences.integer(forKey: key) == 0)
        model.runPushOptions = realPushOptions
        model.push(.push, shift: true)
        try await settle { owner.pushOptionsController != nil && !owner.pushOptionsController!.model.busy }
        let options = owner.pushOptionsController!
        precondition(model.busy && !owner.windowShouldClose(owner.window!) && options.window!.sheetParent === owner.window && options.window!.alphaValue == 0 && options.model.options.source == "main" && options.model.options.remote == "origin")
        options.model.close(); try await settle { !model.busy }
        let afterShiftCancel = try await refs(); precondition(afterShiftCancel == beforeShift && model.commandOutput == outputBeforeShift && preferences.integer(forKey: key) == 0)
        model.push(.push, shift: true); try await settle { owner.pushOptionsController != nil && !owner.pushOptionsController!.model.busy }
        let runningOptions = owner.pushOptionsController!
        runningOptions.model.sshSettings.enabled = false; runningOptions.model.options.destination = "full-options"
        runningOptions.model.push(confirmed: true)
        try await settle { runningOptions.model.progress != nil && !runningOptions.model.progress!.busy }
        let progress = runningOptions.model.progress!
        precondition(progress.success && model.busy && runningOptions.window!.attachedSheet?.alphaValue == 0 && owner.pushOptionsController === runningOptions)
        progress.close(); try await settle { !model.busy }
        let fullPush = try await hash(server, "refs/heads/full-options")
        precondition(fullPush == head && owner.pushOptionsController == nil && owner.window!.attachedSheet == nil && preferences.integer(forKey: key) == 0)
        let finalHead = try await hash(repo, "HEAD"), finalBranch = try await repo.branch(), finalIndex = try Data(contentsOf: clientRoot.appendingPathComponent(".git/index"))
        precondition(finalHead == head && finalBranch == "main" && index == finalIndex && finished > 0 && model.incomingCommits == nil)
        // Root force-close reaps both direct and owned full-options Push.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for shift in [false, true] {
            let shim = directory.appendingPathComponent(shift ? "blocked-options" : "blocked-push"), marker = directory.appendingPathComponent(shift ? "options-pid" : "push-pid")
            let script = "#!/bin/sh\nfor argument; do\nif [ \"$argument\" = push ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nexec " + quote(git.path) + " \"$@\"\n"
            try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            let blockedOwner = SynchronizationWindowController(repository: GitRepository(root: clientRoot, executable: shim), access: nil, preferences: preferences)
            blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
            let blocked = blockedOwner.model; blocked.sshSettings.enabled = false
            try await settle { !blocked.busy && blocked.outgoing != nil }
            blocked.remote = "origin"; blocked.localBranch = "main"; blocked.remoteBranch = "blocked"
            blocked.push(shift ? .push : .pushTags, shift: shift)
            if shift {
                try await settle { blockedOwner.pushOptionsController != nil && !blockedOwner.pushOptionsController!.model.busy }
                let child = blockedOwner.pushOptionsController!; child.model.sshSettings.enabled = false; child.model.options.destination = "blocked"; child.model.push(confirmed: true)
            }
            try await settle { FileManager.default.fileExists(atPath: marker.path) }
            let pid = pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!, refsBeforeClose = try await refs()
            blockedOwner.close(); try await settle { kill(pid, 0) == -1 && errno == ESRCH }
            let refsAfterClose = try await refs()
            precondition(blocked.closed && !blocked.busy && !blocked.transportRunning && !blocked.cancelling && blockedOwner.pushOptionsController == nil && refsAfterClose == refsBeforeClose)
        }
        print("PASS: native Sync Push/Push tags/Push notes, tracking Yes/No/Cancel/suppression/default destination, Force rejection/success, configured notes ref, URL/no-tracking, confirmed deletion, source-index persistence, ignored Shift variants, actual owned Shift Push options/progress/cancel/refill and direct/owned forced process cleanup; HEAD/branch/index preserved")
    }

    @MainActor static func verifySubmodules(root: URL, preferences: UserDefaults) async throws {
        let directory = root.deletingLastPathComponent().appendingPathComponent("qa-sync-submodule-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = URL(fileURLWithPath: CommandLine.arguments[2]), shim = directory.appendingPathComponent("fixture-git")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let environment = GitRuntime.environment(executable: selected).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        try Data(("#!/bin/sh\n" + environment + "\nexec " + quote(selected.path) + " -c protocol.file.allow=always \"$@\"\n").utf8).write(to: shim)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let repo = GitRepository(root: directory, executable: shim), path = "child 雪"
        _ = try await repo.run(["init", "-b", "main", "--template="])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        _ = try await repo.run(["submodule", "add", "--name", "child-雪", "--", root.path, path])
        _ = try await repo.run(["commit", "-am", "submodule fixture"])
        _ = try await repo.run(["submodule", "deinit", "--force", "--all"])
        let index = try Data(contentsOf: directory.appendingPathComponent(".git/index")), head = try await repo.run(["rev-parse", "HEAD"]).stdout
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); owner.window!.contentView!.layoutSubtreeIfNeeded()
        defer { owner.close() }
        let model = owner.model
        try await settle { !model.busy && model.outgoing != nil }
        let outgoing = model.outgoing!.remoteReference, key = "TurtleGit.Sync." + directory.path + ".submoduleAction"
        var completed = 0, children: [SynchronizationSubmoduleAction] = []
        model.onTransportFinished = { _ in completed += 1 }
        model.onSubmoduleOptions = { children.append($0) }
        model.remote = "invalid remote ignored by submodule commands"; model.remoteBranch = "invalid branch"; model.force = true
        model.submodule(.initialize, shift: false)
        precondition(model.busy && model.transportRunning && model.tab == 2)
        try await settle { !model.busy }
        precondition(model.commandSucceeded && model.commandCompleted && completed == 1 && preferences.integer(forKey: key) == 1)
        precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(path + "/.git").path))
        model.submodule(.update, shift: false); try await settle { !model.busy }
        precondition(model.commandSucceeded && completed == 2 && FileManager.default.fileExists(atPath: directory.appendingPathComponent(path + "/.git").path))
        let newURL = directory.appendingPathComponent("new remote.git").path
        _ = try await repo.run(["config", "--file", ".gitmodules", "submodule.child-雪.url", newURL])
        model.submodule(.sync, shift: false); try await settle { !model.busy }
        let registered = try await repo.run(["config", "--get", "submodule.child-雪.url"]).text.trimmingCharacters(in: .newlines)
        precondition(model.commandSucceeded && completed == 3 && registered == newURL && model.tab == 2 && model.outgoing!.remoteReference == outgoing)
        for action in SynchronizationSubmoduleAction.allCases { model.submodule(action, shift: true); precondition(!model.busy && !model.transportRunning && preferences.integer(forKey: key) == 2) }
        precondition(children == [.update, .update, .sync] && completed == 3)
        let restored = SynchronizationWindowModel(repository: repo, access: nil, preferences: preferences)
        precondition(restored.submoduleAction == .sync); restored.invalidate()
        for action in SynchronizationSubmoduleAction.allCases { precondition(action.icon.image() != nil) }
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let finalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
        precondition(finalHead == head && finalIndex == index)
        owner.close(); model.submodule(.initialize, shift: true)
        precondition(model.closed && children.count == 3 && !model.busy)
        let blockedShim = directory.appendingPathComponent("blocked-git"), marker = directory.appendingPathComponent("blocked-pid")
        let blockedScript = "#!/bin/sh\nfor argument; do\nif [ \"$argument\" = submodule ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nexec " + quote(shim.path) + " \"$@\"\n"
        try Data(blockedScript.utf8).write(to: blockedShim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedShim.path)
        let blockedOwner = SynchronizationWindowController(repository: GitRepository(root: directory, executable: blockedShim), access: nil, preferences: preferences)
        blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
        let blocked = blockedOwner.model; try await settle { !blocked.busy && blocked.outgoing != nil }
        var lateCompletions = 0; blocked.onTransportFinished = { _ in lateCompletions += 1 }
        blocked.submodule(.update, shift: false); try await settle { FileManager.default.fileExists(atPath: marker.path) }
        let pid = pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!
        blockedOwner.close(); try await settle { kill(pid, 0) == -1 && errno == ESRCH }
        precondition(blocked.closed && !blocked.busy && !blocked.transportRunning && !blocked.cancelling && lateCompletions == 0)
        // Exercise the actual standalone controller lifetimes. RepositoryModel's
        // production callbacks are inspected separately; this fixture injects
        // private preferences and retains only its own child controllers.
        preferences.set(0, forKey: "AutoCloseGitProgress")
        var saved = SubmoduleUpdateOptions(); saved.initialize = true; saved.recursive = false; saved.force = false
        preferences.set(try JSONEncoder().encode(saved), forKey: "SubmoduleUpdate." + directory.path + ".options")
        let optionsOwner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        optionsOwner.window!.alphaValue = 0; optionsOwner.showWindow(nil); defer { optionsOwner.close() }
        try await settle { !optionsOwner.model.busy && optionsOwner.model.outgoing != nil }
        optionsOwner.model.force = true
        var optionsChild: SubmoduleUpdateWindowController?, progressChild: SubmoduleUpdateProgressWindowController?
        optionsOwner.model.onSubmoduleOptions = { action in
            precondition(action == .update)
            let child = SubmoduleUpdateWindowController(repository: repo, access: nil, scope: [], preferences: preferences)
            child.window!.alphaValue = 0
            child.model.onSubmit = { paths, options in
                precondition(paths == [path] && options.initialize && !options.recursive && !options.force)
                let progress = SubmoduleUpdateProgressWindowController(repository: repo, access: nil, paths: paths, options: options, preferences: preferences)
                progress.window!.alphaValue = 0; progressChild = progress; progress.showWindow(nil); progress.model.start()
            }
            optionsChild = child; child.showWindow(nil); child.window!.contentView!.layoutSubtreeIfNeeded()
        }
        optionsOwner.model.submodule(.initialize, shift: true)
        try await settle { optionsChild?.model.canApply == true }
        optionsOwner.close(); precondition(optionsChild!.window!.isVisible && optionsChild!.model.canApply)
        optionsChild!.model.apply(); try await settle { progressChild != nil && !progressChild!.model.busy }
        precondition(progressChild!.model.success && !optionsChild!.window!.isVisible)
        progressChild!.close(); optionsChild!.close()

        try FileManager.default.removeItem(at: marker)
        let syncOwner = SynchronizationWindowController(repository: GitRepository(root: directory, executable: blockedShim), access: nil, preferences: preferences)
        syncOwner.window!.alphaValue = 0; syncOwner.showWindow(nil); defer { syncOwner.close() }
        try await settle { !syncOwner.model.busy && syncOwner.model.outgoing != nil }
        var syncChild: SubmoduleSyncWindowController?, synced = 0
        syncOwner.model.onSubmoduleOptions = { action in
            precondition(action == .sync)
            let child = SubmoduleSyncWindowController(repository: GitRepository(root: directory, executable: blockedShim), access: nil, scope: [], preferences: preferences)
            child.window!.alphaValue = 0; child.model.onSynced = { _ in synced += 1 }
            syncChild = child; child.showWindow(nil); child.model.start()
        }
        syncOwner.model.submodule(.sync, shift: true)
        try await settle { FileManager.default.fileExists(atPath: marker.path) }
        let childPID = pid_t(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .newlines))!
        syncOwner.close(); precondition(syncChild!.window!.isVisible && syncChild!.model.busy && kill(childPID, 0) == 0 && !syncOwner.model.busy)
        syncChild!.close(); try await settle { kill(childPID, 0) == -1 && errno == ESRCH && !syncChild!.model.busy }
        precondition(synced == 0 && syncChild!.model.output.contains("git submodule sync\n"))
        print("PASS: native Sync Submodule Init/Update/Sync, ignored transport fields, Command Log completion without outgoing refill, Force, persisted selection, Shift routes without parent busy/persistence, closed-owner refusal, forced process cleanup and actual standalone Update options/progress and running Sync lifetimes after parent closure; HEAD/index preserved")
    }

    @MainActor static func verifyStash(root: URL, preferences: UserDefaults) async throws {
        // This fixture's explicit Cancel requires the direct no-question policy,
        // independent of the prior transport fixture's private Kill preference.
        let savedKillPreference=preferences.object(forKey:"ConfirmKillProcess")
        preferences.set(false,forKey:"ConfirmKillProcess")
        defer {if let savedKillPreference {preferences.set(savedKillPreference,forKey:"ConfirmKillProcess")} else {preferences.removeObject(forKey:"ConfirmKillProcess")}}
        let directory = root.deletingLastPathComponent().appendingPathComponent("qa-sync-stash-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = URL(fileURLWithPath: CommandLine.arguments[2]), parent = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await parent.run(["clone", "--template=", "--", root.path, directory.path])
        let repo = GitRepository(root: directory, executable: git), file = directory.appendingPathComponent("file")
        for (key,value) in [("user.name","Stash QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        try await settle { !owner.model.busy && owner.model.outgoing != nil }
        let model = owner.model, projection = model.outgoing!.remoteReference
        var shifted = 0, finished = 0
        model.onStashOptions = { shifted += 1 }; model.onTransportFinished = { _ in finished += 1 }
        model.remote = "ignored remote"; model.force = true
        try Data("work to stash\n".utf8).write(to:file)
        try Data("keep untracked\n".utf8).write(to:directory.appendingPathComponent("untracked"))
        model.stash(.save,shift:false); precondition(model.busy && model.transportRunning && model.tab == 2)
        try await settle { !model.busy }
        precondition(model.commandSucceeded && model.commandCompleted && finished == 1 && FileManager.default.fileExists(atPath:directory.appendingPathComponent("untracked").path))
        model.stash(.apply,shift:false); try await settle { !model.busy }
        precondition(model.commandSucceeded && model.tab == 2 && finished == 2)
        _ = try await repo.run(["reset","--hard","HEAD"])
        model.stash(.pop,shift:false); try await settle { !model.busy }
        precondition(model.commandSucceeded && model.tab == 2 && finished == 3)
        model.stash(.pop,shift:false); try await settle { !model.busy }
        precondition(!model.commandSucceeded && model.conflicts.isEmpty && model.tab == 2 && finished == 4)
        _ = try await repo.run(["reset","--hard","HEAD"])
        try Data("stash side\n".utf8).write(to:file); model.stash(.save,shift:false); try await settle { !model.busy }
        try Data("branch side\n".utf8).write(to:file); _ = try await repo.run(["commit","-am","diverge"])
        model.stash(.pop,shift:false); try await settle { !model.busy }
        precondition(!model.commandSucceeded && model.conflicts.map(\.path) == ["file"] && model.tab == 6 && finished == 6 && model.outgoing!.remoteReference == projection && model.incomingCommits == nil)
        let stashBeforeShift = try await repo.run(["rev-parse","refs/stash"]).stdout
        // Showing the real Conflicts tab starts its owned status/metadata read.
        // The transport has finished, but source commands remain gated until
        // that child work drains. Wait for the actual command-availability gate
        // before exercising Shift dispatch; retain every original assertion.
        var idleSamples = 0
        try await settle {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            idleSamples = !model.busy && !model.hasBlockingChild && owner.window?.attachedSheet == nil ? idleSamples + 1 : 0
            return idleSamples >= 2
        }
        for action in [SynchronizationStashAction.pop,.apply] { model.stash(action,shift:true); precondition(!model.busy && shifted == 0 && finished == 6) }
        model.stash(.save,shift:true); precondition(!model.busy && shifted == 1 && finished == 6,"Shift Stash Save dispatch: busy=\(model.busy), child=\(model.hasBlockingChild), shifted=\(shifted), finished=\(finished)")
        let stashAfterShift = try await repo.run(["rev-parse","refs/stash"]).stdout
        precondition(stashBeforeShift == stashAfterShift)
        let fresh = SynchronizationWindowModel(repository:repo,access:nil,preferences:preferences)
        precondition(fresh.stashAction == .save); fresh.invalidate()
        owner.close(); model.stash(.save,shift:true); precondition(shifted == 1 && model.closed)
        _ = try await repo.run(["reset","--hard","HEAD"])
        // Preserve HEAD through the direct stash actions; the deliberate conflict
        // commit above is the sole branch movement in this fixture.
        let parentOfConflict = try await repo.run(["rev-parse","HEAD^"]).stdout; precondition(parentOfConflict == head)
        func quote(_ value:String)->String { "'" + value.replacingOccurrences(of:"'",with:"'\"'\"'") + "'" }
        let shim = directory.appendingPathComponent("blocked-git"), marker = directory.appendingPathComponent("stash-pid")
        let script = "#!/bin/sh\nfor argument; do\nif [ \"$argument\" = stash ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(script.utf8).write(to:shim); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:shim.path)
        let blockedOwner = SynchronizationWindowController(repository:GitRepository(root:directory,executable:shim),access:nil,preferences:preferences)
        blockedOwner.window!.alphaValue = 0; blockedOwner.showWindow(nil); defer { blockedOwner.close() }
        try await settle { !blockedOwner.model.busy && blockedOwner.model.outgoing != nil }
        var late = 0; blockedOwner.model.onTransportFinished = { _ in late += 1 }
        blockedOwner.model.stash(.save,shift:false); try await settle { FileManager.default.fileExists(atPath:marker.path) }
        let pid = pid_t(try String(contentsOf:marker).trimmingCharacters(in:.newlines))!
        blockedOwner.close(); try await settle { kill(pid,0) == -1 && errno == ESRCH }
        precondition(blockedOwner.model.closed && !blockedOwner.model.busy && !blockedOwner.model.transportRunning && late == 0)
        preferences.set(0,forKey:"AutoCloseGitProgress")
        let shiftOwner = SynchronizationWindowController(repository:repo,access:nil,preferences:preferences)
        shiftOwner.window!.alphaValue = 0; shiftOwner.showWindow(nil); defer { shiftOwner.close() }
        try await settle { !shiftOwner.model.busy && shiftOwner.model.outgoing != nil }
        var child: StashWindowController?, childSaves = 0, postActions: [StashSavePostAction] = []
        shiftOwner.model.onStashOptions = {
            let controller = StashWindowController(repository:repo,access:nil,preferences:preferences)
            controller.window!.alphaValue = 0; controller.model.onSaved = { _ in childSaves += 1 }; controller.model.onPostAction = { action, _ in postActions.append(action) }
            child = controller; controller.showWindow(nil)
        }
        shiftOwner.model.stash(.save,shift:true); precondition(child != nil && !shiftOwner.model.busy)
        shiftOwner.close(); precondition(child!.window!.isVisible && !child!.model.busy)
        try await awaitStashForm(child!)
        try Data("full options work\n".utf8).write(to:file)
        child!.model.options.message = "Shift snapshot 雪"; child!.model.save()
        let progress = try await awaitStashProgress(child!)
        try await settle { !progress.busy }
        precondition(progress.success && childSaves == 1 && child!.window!.attachedSheet != nil && child!.model.busy)
        let subject = try await repo.run(["show","-s","--format=%s","refs/stash"]).text
        precondition(subject.contains("Shift snapshot 雪"))
        precondition(progress.postActions == [.pop,.apply]); progress.perform(.apply)
        try await settle { !child!.window!.isVisible && !child!.model.busy && child!.model.progress == nil }
        progress.perform(.pop); precondition(postActions == [.apply])

        try FileManager.default.removeItem(at:marker)
        let blockedChild = StashWindowController(repository:GitRepository(root:directory,executable:shim),access:nil,preferences:preferences)
        blockedChild.window!.alphaValue = 0; blockedChild.showWindow(nil); defer { blockedChild.close() }
        var childReplies = 0; blockedChild.model.onSaved = { _ in childReplies += 1 }; blockedChild.model.onFailed = { _ in childReplies += 1 }
        try await awaitStashForm(blockedChild)
        blockedChild.model.save(); let blockedProgress = try await awaitStashProgress(blockedChild)
        try await settle { FileManager.default.fileExists(atPath:marker.path) && blockedChild.window!.attachedSheet != nil }
        let sheet = blockedChild.window!.attachedSheet!, childPID = pid_t(try String(contentsOf:marker).trimmingCharacters(in:.newlines))!
        blockedChild.close(); try await settle { kill(childPID,0) == -1 && errno == ESRCH && sheet.sheetParent == nil && !sheet.isVisible && blockedChild.window?.attachedSheet == nil }
        precondition(!blockedProgress.busy && blockedProgress.result == nil && blockedProgress.output.isEmpty && childReplies == 0 && !sheet.isVisible && blockedChild.window!.attachedSheet == nil && blockedChild.model.progress == nil && !blockedChild.model.busy)

        for target in [1,2] {
            let referenceShim = directory.appendingPathComponent("reference-git-" + String(target)), referenceMarker = directory.appendingPathComponent("reference-pid-" + String(target)), counter = directory.appendingPathComponent("reference-count-" + String(target))
            let environment = GitRuntime.environment(executable:git).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator:"\n")
            let referenceScript = "#!/bin/sh\n" + environment + "\nseen=\nfor argument; do\nif [ \"$argument\" = rev-parse ]; then seen=yes; fi\nif [ \"$argument\" = refs/stash ] && [ \"$seen\" = yes ]; then\ncount=0\nif [ -f " + quote(counter.path) + " ]; then read count < " + quote(counter.path) + "; fi\ncount=$((count+1))\nprintf '%s\\n' \"$count\" > " + quote(counter.path) + "\nif [ \"$count\" -eq " + String(target) + " ]; then\nprintf '%s\\n' \"$$\" > " + quote(referenceMarker.path) + "\nwhile :; do sleep 1; done\nfi\nfi\ndone\nexec " + quote(git.path) + " \"$@\"\n"
            try Data(referenceScript.utf8).write(to:referenceShim); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:referenceShim.path)
            let work = "reference cancellation " + String(target) + "\n"
            try Data(work.utf8).write(to:file)
            let before = try await repo.run(["rev-parse","refs/stash"]).stdout
            let refChild = StashWindowController(repository:GitRepository(root:directory,executable:referenceShim),access:nil,preferences:preferences)
            refChild.window!.alphaValue = 0; refChild.showWindow(nil); defer { refChild.close() }
            var referenceReplies = 0; refChild.model.onSaved = { _ in referenceReplies += 1 }; refChild.model.onFailed = { _ in referenceReplies += 1 }
            try await awaitStashForm(refChild)
            refChild.model.save(); let refProgress = try await awaitStashProgress(refChild)
            try await settle { FileManager.default.fileExists(atPath:referenceMarker.path) }
            let referencePID = pid_t(try String(contentsOf:referenceMarker).trimmingCharacters(in:.newlines))!
            if target == 1 {
                refChild.close(); try await settle { kill(referencePID,0) == -1 && errno == ESRCH && refChild.window?.attachedSheet == nil && refChild.model.progress == nil && StashWindowController.activeChildReleases == 0 }
                precondition(!refProgress.busy && !refProgress.success && refProgress.result == nil && referenceReplies == 0 && refChild.window!.attachedSheet == nil && refChild.model.progress == nil)
            } else {
                refProgress.cancel(); try await settle { !refProgress.busy && kill(referencePID,0) == -1 && errno == ESRCH }
                precondition(refProgress.cancelled && !refProgress.success && refProgress.result == nil && refProgress.postActions.isEmpty && referenceReplies == 1)
                refProgress.close(); try await settle { !refChild.window!.isVisible && refChild.model.progress == nil }
            }
            let after = try await repo.run(["rev-parse","refs/stash"]).stdout
            if target == 1 {
                let working = try String(contentsOf:file); precondition(before == after && working == work)
            } else {
                let stashed = try await repo.run(["show","refs/stash:file"]).text
                precondition(before != after && stashed == work)
            }
        }
        let failureShim = directory.appendingPathComponent("inspection-failure")
        let failureScript = "#!/bin/sh\nfor argument; do\ncase \"$argument\" in\nstash) printf 'retained stash failure\\n'; exit 1;;\nstatus) printf 'inspection failure\\n' >&2; exit 2;;\nesac\ndone\nexec " + quote(git.path) + " \"$@\"\n"
        try Data(failureScript.utf8).write(to:failureShim); try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:failureShim.path)
        let failing = SynchronizationWindowModel(repository:GitRepository(root:directory,executable:failureShim),access:nil,preferences:preferences)
        failing.stash(.apply,shift:false); try await settle { !failing.busy }
        precondition(failing.commandCompleted && !failing.commandSucceeded && failing.tab == 2 && failing.conflicts.isEmpty && failing.commandOutput.contains("retained stash failure") && failing.commandOutput.contains("Checking for conflicts failed:") && failing.commandOutput.contains("inspection failure"))
        failing.invalidate()
        print("PASS: native Sync Stash direct commands/conflict tab/Shift routes, retained failed command output on inspection failure, actual standalone Shift Save options and progress after Sync closure, private preferences, forced options/progress sheet cleanup, before/after reference-read process reaping and suppressed late replies")
    }

    @MainActor static func verifyBranchPickers(root: URL, preferences: UserDefaults) async throws {
        let directory = root.appendingPathComponent("qa-sync-branches-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = GitRepository(root: root, executable: selected)
        _ = try await source.run(["clone", "--no-hardlinks", "--template=", "--", root.path, directory.path])
        let shim = directory.appendingPathComponent("branch-git"), marker = directory.appendingPathComponent("branch-pid"), enable = directory.appendingPathComponent("branch-stall")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let environment = GitRuntime.environment(executable: selected).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let script = "#!/bin/sh\n" + environment + "\nif [ -f " + quote(enable.path) + " ]; then\nfor argument; do\nif [ \"$argument\" = for-each-ref ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nfi\nexec " + quote(selected.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let repo = GitRepository(root: directory, executable: shim)
        _ = try await repo.run(["config", "core.precomposeunicode", "false"])
        _ = try await repo.run(["branch", "topic/雪"])
        _ = try await repo.run(["config", "branch.topic/雪.remote", "origin"])
        _ = try await repo.run(["config", "branch.topic/雪.merge", "refs/heads/feature/雪"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/feature/雪", "HEAD"])
        _ = try await repo.run(["remote", "add", "mirror", root.path])
        _ = try await repo.run(["update-ref", "refs/remotes/mirror/review/deep/雪", "HEAD"])
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["update-ref", "refs/notes/qa", "HEAD"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: directory.appendingPathComponent(".git/index")), config = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model; var configured = 0
        owner.configureBranchPicker = { _ in configured += 1 }
        try await settle { !model.busy && model.outgoing != nil }
        model.force = true; model.remoteBranch = "typed-before-choice"
        model.confirmingQuit = true; model.browseBranch(.local); precondition(owner.branchPicker == nil)
        model.confirmingQuit = false; model.browseBranch(.local)
        let local = owner.branchPicker!
        precondition(model.choosingBranch && model.hasBlockingChild && !owner.windowShouldClose(owner.window!))
        precondition(local.window!.sheetParent === owner.window && local.window!.alphaValue == 0)
        model.browseBranch(.remote); model.manageRemotes(); model.stash(.save, shift: false)
        precondition(owner.branchPicker === local && owner.remoteSettingsController == nil && !model.transportRunning)
        try await settle { !local.model.busy && local.model.snapshot != nil }
        precondition(local.model.scope == .heads && local.model.snapshot!.references.allSatisfy { $0.name.rawValue.hasPrefix("refs/heads/") })
        local.model.setFolder("refs/heads"); local.model.selected = "refs/heads/topic/雪"; precondition(local.model.canAccept)
        local.model.accept(); try await settle { owner.branchPicker == nil && !model.busy }
        precondition(local.model.closed && !model.choosingBranch && owner.window!.attachedSheet == nil)
        precondition(model.localBranch == "topic/雪" && model.remote == "origin" && model.remoteBranch == "feature/雪" && model.force)
        model.browseBranch(.remote); let remote = owner.branchPicker!
        try await settle { !remote.model.busy && remote.model.snapshot != nil }
        precondition(remote.model.scope == .remotes && remote.model.snapshot!.references.allSatisfy { $0.name.rawValue.hasPrefix("refs/remotes/") })
        remote.model.setFolder("refs/remotes/mirror"); remote.model.selected = "refs/remotes/mirror/review/deep/雪"
        precondition(remote.model.canAccept); remote.model.accept()
        try await settle { owner.branchPicker == nil && !model.busy }
        precondition(model.localBranch == "topic/雪" && model.remote == "mirror" && model.remoteWasSelected && model.remoteBranch == "review/deep/雪" && model.force)
        precondition(model.branchHistory.contains("review/deep/雪") && configured == 2)
        for target in [SynchronizationBranchTarget.local, .remote] {
            let before = [model.localBranch, model.remote, model.remoteBranch]
            model.browseBranch(target); let cancelled = owner.branchPicker!
            try await settle { !cancelled.model.busy }; cancelled.model.cancel()
            try await settle { owner.branchPicker == nil }
            precondition(before == [model.localBranch, model.remote, model.remoteBranch] && !model.busy && cancelled.model.closed)
        }
        model.applyBranchSelection("refs/tags/release", target: .local)
        model.applyBranchSelection("refs/heads/main", target: .remote)
        precondition(model.localBranch == "topic/雪" && model.remote == "mirror" && model.remoteBranch == "review/deep/雪" && !model.busy)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalRefs = try await repo.run(["show-ref"]).stdout
        let finalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index")), finalConfig = try Data(contentsOf: directory.appendingPathComponent(".git/config"))
        precondition(finalHead == head && finalRefs == refs && index == finalIndex && config == finalConfig)
        try Data().write(to: enable); model.browseBranch(.remote); let blocked = owner.branchPicker!
        try await settle { FileManager.default.fileExists(atPath: marker.path) }
        let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
        owner.close(); try await settle { kill(pid, 0) == -1 }
        let state = kill(pid, 0), processError = errno
        precondition(state == -1 && processError == ESRCH && model.closed && blocked.model.closed && !blocked.model.busy)
        precondition(owner.branchPicker == nil && !model.choosingBranch && owner.window!.attachedSheet == nil && blocked.window!.sheetParent == nil)
        blocked.model.accept(); model.browseBranch(.local); precondition(owner.branchPicker == nil)
        print("PASS: native Sync owned local/remote branch pickers, heads/remote scopes, Unicode tracking and split mapping, preserved Force, Cancel without changes, blocked parent/duplicate/Quit routes, read-only refs/index/config and forced reader reaping")
    }
    @MainActor static func verifyManage(root: URL, preferences: UserDefaults) async throws {
        let directory = root.appendingPathComponent("qa-sync-manage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = GitRepository(root: root, executable: selected)
        _ = try await source.run(["clone", "--no-hardlinks", "--template=", "--", root.path, directory.path])
        let shim = directory.appendingPathComponent("manage-git"), marker = directory.appendingPathComponent("manage-pid"), enable = directory.appendingPathComponent("manage-stall")
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        let environment = GitRuntime.environment(executable: selected).sorted { $0.key < $1.key }.map { "export " + $0.key + "=" + quote($0.value) }.joined(separator: "\n")
        let script = "#!/bin/sh\n" + environment + "\nif [ -f " + quote(enable.path) + " ]; then\nfor argument; do\nif [ \"$argument\" = remote ]; then\nprintf '%s\\n' \"$$\" > " + quote(marker.path) + "\nwhile :; do sleep 1; done\nfi\ndone\nfi\nexec " + quote(selected.path) + " \"$@\"\n"
        try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
        let repo = GitRepository(root: directory, executable: shim)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, refs = try await repo.run(["show-ref"]).stdout
        let index = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
        let owner = SynchronizationWindowController(repository: repo, access: nil, preferences: preferences)
        owner.window!.alphaValue = 0; owner.showWindow(nil); defer { owner.close() }
        let model = owner.model
        try await settle { !model.busy && model.outgoing != nil }
        model.confirmingQuit = true; model.manageRemotes(); precondition(owner.remoteSettingsController == nil)
        model.confirmingQuit = false
        model.remoteBranch = "typed-branch"; model.remote = directory.path; model.remoteWasSelected = false; model.force = true
        model.manageRemotes()
        let settings = owner.remoteSettingsController!
        precondition(model.managingRemotes && model.hasBlockingChild && !owner.windowShouldClose(owner.window!))
        precondition(settings.window!.sheetParent === owner.window && settings.window!.alphaValue == 0)
        model.manageRemotes(); precondition(owner.remoteSettingsController === settings)
        model.reload(); model.stash(.save, shift: false); precondition(!model.busy && !model.transportRunning)
        try await settle { !settings.model.busy }
        precondition(settings.model.names.map(\.rawValue) == ["origin"])
        settings.model.confirm = { _ in (false, false) }
        settings.model.edit(.name) { $0.name = "review" }
        settings.model.edit(.url) { $0.url = root.path }
        settings.model.save(); try await settle { !settings.model.busy }
        precondition(settings.model.error == nil && settings.model.names.contains(GitReferenceName("review")))
        settings.close()
        try await settle { owner.remoteSettingsController == nil && !model.busy }
        precondition(!model.managingRemotes && owner.window!.attachedSheet == nil && settings.model.closed)
        precondition(model.remotes == ["origin", "review"] && model.remote == directory.path && model.remoteBranch == "typed-branch" && model.localBranch == "main" && model.force)
        precondition(model.outgoing?.disposition == .unknownURL)
        model.manageRemotes(); let cancelled = owner.remoteSettingsController!
        try await settle { !cancelled.model.busy }
        cancelled.model.select(GitReferenceName("origin")); try await settle { !cancelled.model.busy }
        cancelled.model.edit(.url) { $0.url = "/tmp/unapplied-native-manage" }
        cancelled.model.close()
        try await settle { owner.remoteSettingsController == nil && !model.busy }
        let origin = try await repo.run(["remote", "get-url", "origin"]).text.trimmingCharacters(in: .newlines)
        precondition(origin == root.path)
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalRefs = try await repo.run(["show-ref"]).stdout
        let finalIndex = try Data(contentsOf: directory.appendingPathComponent(".git/index"))
        precondition(finalHead == head && finalRefs == refs && finalIndex == index)
        // Exercise the actual combo delegate distinction: choosing a remote is
        // different from typing the same text, even when redraw matches a choice.
        let combo = NSComboBox(), coordinator = FetchHistoryCombo.Coordinator()
        coordinator.choices = model.remoteChoices; combo.addItems(withObjectValues: coordinator.choices)
        coordinator.selectionState = { model.remoteWasSelected = $0 }
        coordinator.change = { model.remote = $0 }
        combo.selectItem(at: coordinator.choices.firstIndex(of: "review")!)
        coordinator.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification, object: combo))
        precondition(model.remote == "review" && model.remoteWasSelected)
        model.manageRemotes(); let removing = owner.remoteSettingsController!
        try await settle { !removing.model.busy }
        removing.model.select(GitReferenceName("review")); try await settle { !removing.model.busy }
        removing.model.confirm = { _ in (true, false) }; removing.model.remove()
        try await settle { !removing.model.busy && !removing.model.names.contains(GitReferenceName("review")) }
        removing.close(); try await settle { owner.remoteSettingsController == nil && !model.busy }
        precondition(model.remote == model.remoteChoices.first && model.remote == "origin")
        precondition(model.localBranch == "main" && model.remoteBranch == "typed-branch" && model.force)
        combo.stringValue = "review"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo))
        precondition(model.remote == "review" && !model.remoteWasSelected)
        model.manageRemotes(); let typed = owner.remoteSettingsController!
        try await settle { !typed.model.busy }; typed.close()
        try await settle { owner.remoteSettingsController == nil && !model.busy }
        precondition(model.remote == "review" && !model.remoteWasSelected)
        // A selected history URL also falls back when it is not a named remote,
        // exactly as source Refresh; a typed URL is preserved by the earlier case.
        let key = "TurtleGit.Sync." + directory.path + ".urls"
        preferences.set([directory.path], forKey: key)
        model.remote = directory.path; model.remoteWasSelected = true; model.refresh()
        try await settle { !model.busy }
        precondition(model.remote == model.remoteChoices.first && model.remote == directory.path)
        preferences.removeObject(forKey: key)
        model.refresh(); try await settle { !model.busy }
        precondition(model.remote == "origin")
        // Force owner closure while the actual Remote settings reader is stalled.
        try Data().write(to: enable); model.manageRemotes(); let blocked = owner.remoteSettingsController!
        try await settle { FileManager.default.fileExists(atPath: marker.path) }
        let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
        owner.close()
        try await settle { kill(pid, 0) == -1 }
        let processState = kill(pid, 0), processError = errno
        precondition(processState == -1 && processError == ESRCH)
        precondition(model.closed && !model.busy && !model.managingRemotes && blocked.model.closed && !blocked.model.busy)
        precondition(owner.remoteSettingsController == nil && owner.window!.attachedSheet == nil && blocked.window!.sheetParent == nil)
        model.manageRemotes(); precondition(owner.remoteSettingsController == nil)
        print("PASS: native Sync Manage opens owned Remote settings, applies real config, preserves typed branch/URL/Force, refreshes outgoing on dismissal, discards unapplied edits, distinguishes selected/typed remotes and URLs with source Refresh fallback, and reaps blocked reads on forced owner closure")
    }
    @MainActor static func main() async throws {
        if let status = RebaseEditor.handle(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment) { exit(status) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Sync QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_TAGS_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_PUSH_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_SUBMODULES_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_STASH_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_MANAGE_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_BRANCHES_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_APPLY_ONLY"] == "1" || ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_EMAIL_ONLY"] == "1" {
            try Data("second\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "second")
            let suite = "TurtleGit.Tags.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
            defer { preferences.removePersistentDomain(forName: suite) }
            DialogGeometry.install(preferences: preferences)
            if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_EMAIL_ONLY"] == "1" { try await SynchronizationEmailVerification.run(root:root,preferences:preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_APPLY_ONLY"] == "1" { try await SynchronizationApplyVerification.run(root:root,preferences:preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_BRANCHES_ONLY"] == "1" { try await verifyBranchPickers(root:root,preferences:preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_MANAGE_ONLY"] == "1" { try await verifyManage(root:root,preferences:preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_STASH_ONLY"] == "1" { try await verifyStash(root:root,preferences:preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_SUBMODULES_ONLY"] == "1" { try await verifySubmodules(root: root, preferences: preferences) }
            else if ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_PUSH_ONLY"] == "1" { try await verifyPush(root: root, preferences: preferences) }
            else { try await verifyTags(root: root, preferences: preferences) }; return
        }
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
        FileHandle.standardError.write(Data("BEGIN: verifyTransport\n".utf8))
        try await verifyTransport(repo: repo, root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyTransport\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyPull\n".utf8))
        try await verifyPull(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyPull\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyFetchAndRebase\n".utf8))
        try await verifyFetchAndRebase(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyFetchAndRebase\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyShiftOptions\n".utf8))
        try await verifyShiftOptions(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyShiftOptions\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyShiftOwnedRebase\n".utf8))
        try await verifyShiftOwnedRebase(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyShiftOwnedRebase\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyTags\n".utf8))
        try await verifyTags(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyTags\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyPush\n".utf8))
        try await verifyPush(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyPush\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifySubmodules\n".utf8))
        try await verifySubmodules(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifySubmodules\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyStash\n".utf8))
        try await verifyStash(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyStash\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyManage\n".utf8))
        try await verifyManage(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyManage\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: verifyBranchPickers\n".utf8))
        try await verifyBranchPickers(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: verifyBranchPickers\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: SynchronizationApplyVerification.run\n".utf8))
        try await SynchronizationApplyVerification.run(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: SynchronizationApplyVerification.run\n".utf8))
        FileHandle.standardError.write(Data("BEGIN: SynchronizationEmailVerification.run\n".utf8))
        try await SynchronizationEmailVerification.run(root: root, preferences: preferences)
        FileHandle.standardError.write(Data("END: SynchronizationEmailVerification.run\n".utf8))
        print("PASS: native Sync tracking controls, exact Unicode choices, graph-first table, changes and pinned comparison snapshot, divergence/Force, unknown states, Quit fences, owner invalidation and read-only preservation")
    }
}
