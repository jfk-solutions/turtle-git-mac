import AppKit
import Darwin
import TurtleGitCore

@main struct BranchTagCompletionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners: [BranchTagWindowController] = []
    @MainActor static var models: [BranchTagWindowModel] = []
    @MainActor static var helpers: [pid_t] = []
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<3000 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Branch completion timeout at \(line)")
    }
    static func stopped(_ pids: [pid_t]) -> Bool { pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH } }
    @MainActor static func cleanup() async {
        owners.forEach { $0.close() }; models.forEach { $0.invalidate() }
        for pid in helpers where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) }
        for _ in 0..<300 { if stopped(helpers) { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
        for pid in helpers where kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
    }
    @MainActor static func main() async {
        do { try await verify(); await cleanup(); try require(stopped(helpers), "Owned helper survived cleanup") }
        catch { await cleanup(); fputs("Branch completion failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: git), file = root.appendingPathComponent("file")
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Branch Completion QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = String(decoding: try await repo.run(["rev-parse", "HEAD"]).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try Data("next\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "next")
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, tree = try await repo.run(["write-tree"]).stdout
        try Data("working\n".utf8).write(to: file)
        let suite = "TurtleGit.BranchCompletion.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        prefs.set(false, forKey: "ConfirmKillProcess"); prefs.set(false, forKey: "NewBranchSwitchTo"); prefs.set(false, forKey: "PushTag")
        let helper = root.appendingPathComponent("completion-git"), marker = root.appendingPathComponent("completion-git.started")
        let mode = root.appendingPathComponent("completion-git.mode"), pause = root.appendingPathComponent("completion-git.pause")
        let quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        task_find_command() {
          if [ "$1" = --literal-pathspecs ] || [ "$1" = --no-literal-pathspecs ]; then shift; fi
          if [ "$1" = -C ]; then shift 2; fi
          while [ "$1" = -c ]; do shift 2; done
          task_command=$1
          task_argument=$2
        }
        task_find_command "$@"
        task_mode=$(/bin/cat "$0.mode" 2>/dev/null)
        task_match=no
        if [ "$task_command" = branch ] && [ "$task_argument" != --show-current ]; then
          if [ "$task_mode" = lock-after-branch ]; then
            \(quoted) "$@"
            task_result=$?
            if [ "$task_result" = 0 ]; then printf 'foreign lock' > "$3/.git/config.lock"; fi
            exit "$task_result"
          fi
          if [ "$task_mode" = hold-branch ]; then task_match=yes; fi
        fi
        if [ "$task_command" = tag ] && [ "$task_mode" = hold-tag ]; then task_match=yes; fi
        if [ "$task_command" = config ] && [ "$task_argument" = --local ] && [ "$task_mode" = hold-description ]; then task_match=yes; fi
        if [ "$task_command" = branch ] && [ "$task_argument" = --show-current ] && [ "$task_mode" = hold-load ]; then task_match=yes; fi
        if [ "$task_match" = yes ] && [ -f "$0.pause" ]; then
          /bin/rm "$0.pause"
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null' USR1
          printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
          /bin/mv "$0.started.tmp" "$0.started"
          wait "$task_child"
        fi
        exec \(quoted) "$@"
        """
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let wrapped = GitRepository(root: root, executable: helper)
        func gate(_ value: String, held: Bool = true) throws { try? FileManager.default.removeItem(at: marker); try Data(value.utf8).write(to: mode); if held { try Data().write(to: pause) } }
        func pids() throws -> [pid_t] { let result = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }; try require(result.count == 2, "Incomplete PID publication"); helpers += result; return result }
        func ready(_ model: BranchTagWindowModel) async throws { try await wait { !model.busy && !model.chooser.busy && !model.confirmingCancellation } }
        func make(_ isTag: Bool = false, revision: String? = nil) -> BranchTagWindowModel {
            let model = BranchTagWindowModel(repository: wrapped, access: nil, isTag: isTag, preferences: prefs); models.append(model); model.load(revision: revision); return model
        }
        func exists(_ reference: String) async throws -> Bool { try await repo.run(["show-ref", "--verify", "--quiet", reference], successfulExitCodes: 0...1).exitCode == 0 }
        // Source tracking follows the remote suffix, not just the full suggested
        // local name. Queued suggestions cannot rewrite a picker's owned draft.
        _ = try await repo.run(["update-ref", "refs/remotes/origin/team/topic", "HEAD"])
        let tracking = make(revision: "refs/remotes/origin/team/topic"); try await ready(tracking)
        tracking.options.tracking = .track; tracking.options.name = "topic"; tracking.nameChanged()
        try require(tracking.options.tracking == .track, "Source remote suffix tracking was cleared")
        tracking.options.name = "different"; tracking.nameChanged(); try require(tracking.options.tracking == .noTrack, "Unrelated branch name retained explicit tracking")
        tracking.options.name = ""; try require(tracking.chooser.beginPicker(.branch), "Could not own picker draft")
        tracking.changedBase(); try require(tracking.options.name.isEmpty, "Queued base suggestion overwrote owned picker draft")
        tracking.chooser.finishPicker(); tracking.changedBase(); try require(tracking.options.name == "team/topic", "Deferred remote branch suggestion missing")
        tracking.invalidate()
        // Standalone description failure uses the same recoverable phase as the
        // production Switch presenter; no second branch command on retry.
        let description = make(); try await ready(description)
        description.options.name = "description"; description.options.message = "captured description"; description.switchAfterCreation = false
        var closes = 0, notifications = 0
        description.close = { closes += 1 }; description.onCreated = { _ in notifications += 1 }
        try gate("lock-after-branch", held: false); description.create(); try await ready(description)
        try require(description.retryDescription && description.createdBranch == "description" && description.error != nil && closes == 0 && notifications == 1, "Standalone description failure lost created reference/retry phase: retry=\(description.retryDescription), ref=\(description.createdBranch ?? "nil"), error=\(description.error ?? "nil"), closes=\(closes), notices=\(notifications)")
        let ref = try await repo.run(["rev-parse", "refs/heads/description"]).stdout
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/config.lock")); try gate("idle", held: false)
        // Model-only receiver acknowledges the error before selecting Retry.
        description.error = nil
        description.options.name = "wrong"; description.options.message = "wrong message"; description.create(); try await ready(description)
        let finalRef = try await repo.run(["rev-parse", "refs/heads/description"]).stdout, value = try await repo.run(["config", "--get", "branch.description.description"]).stdout
        try require(finalRef == ref && value == Data("captured description\n".utf8) && closes == 1 && notifications == 1, "Description retry recreated/retargeted branch or repeated notification")
        // A real fallback checkout failure retains its branch and can retry only
        // checkout even after an unrelated edit of the model's old options.
        let checkout = make(revision: base); try await ready(checkout)
        checkout.options.name = "older"; checkout.switchAfterCreation = true; checkout.create(); try await ready(checkout)
        try require(checkout.createdBranch == "older" && checkout.error?.contains("checkout failed") == true, "Fallback checkout recovery missing")
        checkout.options.name = "do-not-create"; checkout.switchAfterCreation = false
        checkout.error = nil; checkout.create(); try await ready(checkout)
        let wrong = try await exists("refs/heads/do-not-create")
        try require(checkout.error?.contains("checkout failed") == true && !wrong, "Retry changed captured checkout/create intent")
        checkout.invalidate()
        // No => keep running, Yes => stop and close after process reaping. Use
        // the actual native alert and Cancel button's model route.
        prefs.set(true, forKey: "ConfirmKillProcess")
        let owner = BranchTagWindowController(repository: wrapped, access: nil, isTag: true, preferences: prefs); owners.append(owner)
        owner.window?.alphaValue = 0; owner.window?.orderFront(nil); owner.model.load(revision: nil); try await ready(owner.model)
        owner.model.options.name = "cancelled-tag"; owner.model.pushAfterCreation = true
        owner.model.onPushTag = { _ in preconditionFailure("Cancelled tag cannot Push") }
        try gate("hold-tag"); owner.model.create(); try await wait { FileManager.default.fileExists(atPath: marker.path) }; let cancelledPIDs = try pids()
        try require(owner.model.canCancel && BranchTagWindowModel.activeCreations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Live creation lost Cancel/Quit ownership")
        owner.model.cancel(); try await wait { owner.cancellationAlert != nil }
        try require(owner.model.confirmingCancellation && BranchTagWindowModel.activeCreations == 2, "Kill question ownership missing")
        owner.cancellationAlert!.buttons[1].performClick(nil); try await wait { !owner.model.confirmingCancellation }
        try require(!stopped(cancelledPIDs) && owner.model.busy, "No cancelled creation")
        owner.model.cancel(); try await wait { owner.cancellationAlert != nil }; owner.cancellationAlert!.buttons[0].performClick(nil)
        try await wait { BranchTagWindowModel.activeCreations == 0 && stopped(cancelledPIDs) && !owner.window!.isVisible }
        let cancelledTag = try await exists("refs/tags/cancelled-tag"); try require(!cancelledTag, "Cancelled tag was created")
        // A naturally completed tag waits for the outstanding kill reply, then
        // closes and hands off captured Push once; a stale Yes cannot repeat it.
        let tag = make(true); try await ready(tag); tag.options.name = "completed-tag"; tag.options.message = "message"; tag.pushAfterCreation = true
        var answer: ((Bool) -> Void)?, pushed: [String] = [], tagCloses = 0
        tag.confirmCancellation = { answer = $0 }; tag.onPushTag = { pushed.append($0) }; tag.close = { tagCloses += 1 }
        try gate("hold-tag"); tag.create(); try await wait { FileManager.default.fileExists(atPath: marker.path) }; let completedPIDs = try pids()
        tag.cancel(); try require(answer != nil, "Captured kill question missing"); _ = kill(completedPIDs[0], SIGUSR1)
        try await wait { tag.createdBranch == "completed-tag" && stopped(completedPIDs) }
        try require(tag.confirmingCancellation && pushed.isEmpty && tagCloses == 0 && BranchTagWindowModel.activeCreations == 2, "Natural success bypassed pending question or lost its owned continuation")
        answer?(false); answer?(true)
        try await wait { !tag.busy && BranchTagWindowModel.activeCreations == 0 }
        try require(pushed == ["refs/tags/completed-tag"] && tagCloses == 1 && BranchTagWindowModel.activeCreations == 0, "Delayed answer lost or repeated captured Push/close")
        // Forced retirement while a description Git process is alive retains
        // the reference, fences callbacks and holds Quit until the worker drains.
        prefs.set(false, forKey: "ConfirmKillProcess")
        let retired = make(); try await ready(retired); retired.options.name = "retired"; retired.options.message = "unsaved description"
        var retiredNotifications=0
        retired.switchAfterCreation = false; retired.onCreated = { _ in retiredNotifications += 1 }; retired.close = { preconditionFailure("Retired description close") }
        try gate("hold-description"); retired.create(); try await wait { FileManager.default.fileExists(atPath: marker.path) }; let retiredPIDs = try pids()
        try require(retired.createdBranch == "retired" && retiredNotifications == 1, "Description did not follow accepted creation and its parent refresh")
        retired.invalidate(); try require(BranchTagWindowModel.activeCreations == 1, "Forced retirement released creation lifetime too early")
        try await wait { BranchTagWindowModel.activeCreations == 0 && stopped(retiredPIDs) }
        let retained = try await exists("refs/heads/retired"); try require(retained && retired.error == nil && retiredNotifications == 1, "Forced close lost completed reference, repeated parent refresh or published late error")
        // A pending Switch acknowledgement settles once when its owner retires.
        // The production adapter supplies the child's independent close/cancel.
        let switching = make(); try await ready(switching); switching.options.name = "handoff"; switching.options.message = "must not write"; switching.switchAfterCreation = true
        var done: (() -> Void)?, stoppedSwitch = 0
        switching.onSwitch = { _, reply in done = reply; switching.cancelSwitchPresentation = { stoppedSwitch += 1 } }
        try gate("idle", held: false); switching.create(); try await wait { done != nil }
        try require(switching.awaitingSwitch && !switching.canCancel && BranchTagWindowModel.activeCreations == 1, "Switch handoff lifetime missing")
        switching.invalidate(); done?(); done?(); try await wait { BranchTagWindowModel.activeCreations == 0 }
        let absentDescription = try await repo.run(["config", "--get", "branch.handoff.description"], successfulExitCodes: 0...1)
        try require(stoppedSwitch == 1 && !switching.awaitingSwitch && absentDescription.exitCode == 1, "Retired handoff repeated child cancellation or saved late description")
        // Initial-read Cancel drains both independent metadata readers.
        try gate("hold-load"); let loading = make(); var loadCloses = 0; loading.close = { loadCloses += 1 }
        try await wait { FileManager.default.fileExists(atPath: marker.path) }; let loadPIDs = try pids()
        loading.cancel(); try await wait { loadCloses == 1 && BranchTagWindowModel.activeReads == 0 && SwitchWindowModel.activeReads == 0 && stopped(loadPIDs) }
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, finalTree = try await repo.run(["write-tree"]).stdout
        try require(finalHead == head && finalTree == tree && Data(contentsOf: file) == Data("working\n".utf8), "Creation/cancellation changed HEAD/index/working bytes")
        try require(stopped(helpers), "Fixture-owned child survived")
        print("PASS: Branch/Tag completion phases, standalone description/checkout retry, native kill No/Yes, delayed Push/close, forced description/Switch retirement, initial cancellation and helper cleanup")
    }
}
