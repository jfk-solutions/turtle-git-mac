import AppKit
import TurtleGitCore

@main struct LocalCommandProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Local command progress timeout at line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Local command progress failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Progress QA"), ("user.email", "progress@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = root.appendingPathComponent("file")
        try Data("base\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        let base = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        _ = try await repo.run(["branch", "target", base])
        try Data("head\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "head")
        let originalHead = try await repo.run(["rev-parse", "HEAD"]).stdout, originalIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.LocalProgress." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "ConfirmKillProcess"); prefs.set(0, forKey: "AutoCloseGitProgress"); prefs.set(true, forKey: "ShowAppContextMenuIcons"); prefs.set(16, forKey: "GitOutputLimitinKiB")
        defer { prefs.removePersistentDomain(forName: suite) }
        ProgressActionLog.install(store: ActionLogStore(storageURL: root.appendingPathComponent("private-actions.log")), preferences: prefs)
        let helper = root.appendingPathComponent("stream-git"), marker = root.appendingPathComponent("local-ready"), release = root.appendingPathComponent("local-release")
        let script = #"""
        #!/bin/sh
        if [ "$4" = "$TG_LOCAL_MATCH" ]; then
          printf 'Work: 10%%\rWork: 20%%\r\nUnicode '
          printf '\351\233'
          /bin/sleep 0.06
          printf '\252\n'
          printf 'warning: temporary fixture output\n' >&2
          if [ "$TG_LOCAL_BIG" = 1 ]; then
            row_count=0
            while [ "$row_count" -lt 32 ]; do printf '%1024s\n' X; row_count=$((row_count+1)); done
          fi
          : > "$3/local-ready"
          while [ ! -e "$3/local-release" ]; do /bin/sleep 0.05; done
        fi
        exec "$TG_LOCAL_REAL_GIT" "$@"
        """#
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_LOCAL_REAL_GIT", git.path, 1)
        defer { unsetenv("TG_LOCAL_REAL_GIT"); unsetenv("TG_LOCAL_MATCH"); unsetenv("TG_LOCAL_BIG") }
        let wrapped = GitRepository(root: root, executable: helper)
        @MainActor func gate(_ command: String, big: Bool = false) {
            try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: release)
            setenv("TG_LOCAL_MATCH", command, 1); setenv("TG_LOCAL_BIG", big ? "1" : "0", 1)
        }
        @MainActor func live(_ text: String, _ busy: Bool) throws {
            try require(busy && text.contains("Unicode 雪") && text.contains("Work: 20%") && !text.contains("Work: 10%"), "Output was delayed, duplicated or damaged by CR/UTF-8 boundaries")
            try require(LocalGitCommandProgress.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Live command lacks global ownership")
        }
        gate("reset")
        let resetPlan = try await repo.prepareReset(to: base, mode: .hard)
        let reset = ResetProgressWindowModel(repository: wrapped, plan: resetPlan, preferences: prefs), resetController = ResetProgressWindowController(model: reset)
        defer { resetController.close() }
        var resetCallbacks = 0; reset.onChanged = { _ in resetCallbacks += 1 }
        reset.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && reset.output.contains("Unicode 雪") }
        try live(reset.output, reset.busy); try require(reset.percentage == 20, "Reset progress percentage missing")
        resetController.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(resetController.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text = descendants(resetController.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        try await wait { text.string == reset.output }
        let clipboard = NSPasteboard.withUniqueName(); defer { clipboard.releaseGlobally() }; text.clipboard = clipboard
        text.copyAllInformation(nil); try require(clipboard.string(forType: .string) == reset.output && text.outputMenu().items.last?.image != nil, "Native original-icon copy-all progress menu missing")
        let shown = reset.output; resetController.close()
        try require(LocalGitCommandProgress.activeOperations > 0, "Forced Reset close released live operation")
        try await wait { LocalGitCommandProgress.activeOperations == 0 }
        try require(reset.output == shown && resetCallbacks == 0, "Retired Reset published output/completion")
        var checkout = CheckoutOptions(); checkout.revision = "refs/heads/target"
        gate("switch")
        let switched = SwitchProgressWindowModel(repository: wrapped, access: nil, options: checkout, preferences: prefs)
        switched.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && switched.output.contains("Unicode 雪") }
        try live(switched.output, switched.busy); let switchShown = switched.output; switched.invalidate()
        try await wait { LocalGitCommandProgress.activeOperations == 0 }
        try require(switched.output == switchShown, "Retired Switch published late state")
        gate("stash", big: true)
        let save = StashSaveProgressWindowModel(repository: wrapped, access: nil, options: StashSaveOptions(), followUp: StashSaveFollowUp(), preferences: prefs)
        save.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && save.output.contains("Output truncated") }
        try require(save.busy && save.output.utf8.count < 17000, "Stash display exceeded its private output cap")
        save.invalidate(); try await wait { LocalGitCommandProgress.activeOperations == 0 }
        let afterCancelledHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterCancelledIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(afterCancelledHead == originalHead && afterCancelledIndex == originalIndex, "Cancelled pre-command dialogs changed HEAD/index")
        // Apply/Pop keeps its existing question flow while showing live output.
        try Data("stashed\n".utf8).write(to: file); _ = try await repo.saveStash(StashSaveOptions())
        gate("stash")
        let restoreController = StashRestoreWindowController(repository: wrapped, access: nil, pop: false, showChanges: 0, preferences: prefs), restore = restoreController.model
        defer { restoreController.close() }
        restore.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && restore.output.contains("Unicode 雪") }
        try live(restore.output, restore.busy); let restoreShown = restore.output; restoreController.close()
        try await wait { LocalGitCommandProgress.activeOperations == 0 && StashRestoreWindowModel.activeOperations == 0 }
        try require(restore.output == restoreShown, "Retired restore progress changed output")
        // Normal completion delivers original command text; display keeps only the last CR update.
        gate("switch")
        let success = SwitchProgressWindowModel(repository: wrapped, access: nil, options: checkout, preferences: prefs)
        var callback = ""; success.onFinished = { raw, _ in callback = raw }
        success.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && success.output.contains("Unicode 雪") }
        try Data().write(to: release); try await wait { !success.busy && LocalGitCommandProgress.activeOperations == 0 }
        try require(success.success && callback.contains("Work: 10%") && !success.output.contains("Work: 10%"), "Completion callback lost original result or display repeated CR frames")
        // A remembered kill question must not auto-close or execute twice after completion.
        prefs.set(true, forKey: "ConfirmKillProcess"); prefs.set(2, forKey: "AutoCloseGitProgress")
        try Data("save success\n".utf8).write(to: file); gate("stash")
        let confirmed = StashSaveProgressWindowModel(repository: wrapped, access: nil, options: StashSaveOptions(), followUp: StashSaveFollowUp(), preferences: prefs)
        var answer: ((Bool) -> Void)?, closes = 0
        confirmed.confirmCancellation = { answer = $0 }; confirmed.close = { closes += 1 }
        confirmed.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && confirmed.output.contains("Unicode 雪") }
        confirmed.cancel(); try require(confirmed.confirmingCancellation && answer != nil, "Stash Save omitted source kill question")
        try Data().write(to: release); try await wait { !confirmed.busy && LocalGitCommandProgress.activeOperations == 0 }
        try require(confirmed.success && closes == 0, "Completed command auto-closed through a pending kill question")
        answer?(false); answer?(true)
        try require(closes == 1 && !confirmed.cancelled && !confirmed.confirmingCancellation, "Duplicate late kill response changed completion")
        confirmed.invalidate(); success.invalidate()
        print("Local progress: live Reset/Switch/Stash Save/Restore output, CR and split UTF-8, native colored/copy menu, bounded display, original result callbacks, forced-close/Quit process lifetime and once-only kill/auto-close settlement passed. Private repos/preferences/clipboard/action log; owned windows closed.")
    }
}
