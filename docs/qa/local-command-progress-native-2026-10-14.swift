import AppKit
import TurtleGitCore

@main struct LocalCommandProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line,phase:String="local operation",diagnostic:()->String={""}, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Local command progress timeout at line \(line), phase=\(phase): "+diagnostic())
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Local command progress failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
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
        fixture_git_command=
        fixture_skip_global=0
        for fixture_arg in "$@"; do
          if [ "$fixture_skip_global" = 1 ]; then fixture_skip_global=0; continue; fi
          case "$fixture_arg" in
            -C|-c|--git-dir|--work-tree|--namespace|--config-env) fixture_skip_global=1 ;;
            --literal-pathspecs|--no-literal-pathspecs|--no-optional-locks|--no-pager|--paginate|--bare|--no-replace-objects|--no-lazy-fetch) ;;
            -C?*|-c?*|--git-dir=*|--work-tree=*|--namespace=*|--config-env=*) ;;
            -*) break ;;
            *) fixture_git_command=$fixture_arg; break ;;
          esac
        done
        if [ "$fixture_git_command" = "$TG_LOCAL_MATCH" ]; then
          printf 'Work: 10%%\rWork: 20%%\r\nUnicode '
          printf '\351\233'
          /bin/sleep 0.06
          printf '\252\n'
          printf 'warning: temporary fixture output\n' >&2
          if [ "$TG_LOCAL_BIG" = 1 ]; then
            row_count=0
            while [ "$row_count" -lt 32 ]; do printf '%1024s\n' X; row_count=$((row_count+1)); done
          fi
          : > "$TG_LOCAL_MARKER"
          while [ ! -e "$TG_LOCAL_RELEASE" ]; do /bin/sleep 0.05; done
        fi
        exec "$TG_LOCAL_REAL_GIT" "$@"
        """#
        try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        setenv("TG_LOCAL_REAL_GIT", git.path, 1)
        setenv("TG_LOCAL_MARKER",marker.path,1);setenv("TG_LOCAL_RELEASE",release.path,1)
        defer { unsetenv("TG_LOCAL_REAL_GIT"); unsetenv("TG_LOCAL_MATCH"); unsetenv("TG_LOCAL_BIG");unsetenv("TG_LOCAL_MARKER");unsetenv("TG_LOCAL_RELEASE") }
        // This actor is an argv-controlled CLI witness, not backend coverage.
        prefs.set(false,forKey:"UseLibgit2")
        let wrapped = GitRepository(root: root, executable: helper,libgit2Configuration:.init(enabled:false))
        @MainActor func gate(_ command: String, big: Bool = false) {
            try? FileManager.default.removeItem(at: marker); try? FileManager.default.removeItem(at: release)
            setenv("TG_LOCAL_MATCH", command, 1); setenv("TG_LOCAL_BIG", big ? "1" : "0", 1)
        }
        @MainActor func live(_ phase:String,_ text: String, _ busy: Bool) async throws {
            let expected=DockProgressState(.running,percentage:20)
            @MainActor func diagnostic()->String {"phase=\(phase),busy=\(busy),expected=\(String(reflecting:expected)),actual=\(String(reflecting:DockProgressRegistry.shared.current)),owners=\(DockProgressRegistry.shared.ownerCount),active=\(LocalGitCommandProgress.activeOperations),output=\(String(reflecting:text))"}
            try require(busy && text.contains("Unicode 雪") && text.contains("Work: 20%") && !text.contains("Work: 10%"), "Output was delayed, duplicated or damaged by CR/UTF-8 boundaries; "+diagnostic())
            try require(LocalGitCommandProgress.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Live command lacks global ownership; "+diagnostic())
            do {try await wait {DockProgressRegistry.shared.current==expected}}
            catch {throw Failure(description:"Streamed local command lost real Dock progress; "+diagnostic())}
            try require(DockProgressRegistry.shared.current==expected,"Native Dock progress did not settle; "+diagnostic())
        }
        gate("reset")
        let resetPlan = try await repo.prepareReset(to: base, mode: .hard)
        let reset = ResetProgressWindowModel(repository: wrapped, plan: resetPlan, preferences: prefs), resetController = ResetProgressWindowController(model: reset)
        defer { resetController.close() }
        var resetCallbacks = 0; reset.onChanged = { _ in resetCallbacks += 1 }
        reset.start(); try await wait { FileManager.default.fileExists(atPath: marker.path) && reset.output.contains("Unicode 雪") }
        try await live("Reset",reset.output, reset.busy); try require(reset.percentage == 20, "Reset progress percentage missing")
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
        try await wait { DockProgressRegistry.shared.current == nil }
        var checkout = CheckoutOptions(); checkout.revision = "refs/heads/target"
        gate("switch")
        let switched = SwitchProgressWindowModel(repository: wrapped, access: nil, options: checkout, preferences: prefs)
        // Switch's native progress host owns Dock publication; a model alone
        // intentionally has no SwiftUI Dock modifier lifetime.
        let switchedController=SwitchProgressWindowController(model:switched)
        defer{switchedController.close()}
        switchedController.window?.alphaValue=0;switchedController.window?.setFrameOrigin(.init(x:-24000,y:-24000));switchedController.window?.orderFront(nil)
        switched.start(); do {try await wait { FileManager.default.fileExists(atPath: marker.path) && switched.output.contains("Unicode 雪") }}
        catch {fputs("Local Switch admission: busy=\(switched.busy),output=\(String(reflecting:switched.output)),active=\(LocalGitCommandProgress.activeOperations),marker=\(FileManager.default.fileExists(atPath:marker.path)),CLI=\(wrapped.libgit2Configuration?.enabled==false)\n",stderr);throw error}
        try await live("Switch",switched.output, switched.busy); let switchShown = switched.output; switched.invalidate();switchedController.close()
        try await wait { LocalGitCommandProgress.activeOperations == 0 }
        try require(switched.output == switchShown, "Retired Switch published late state")
        try await wait {DockProgressRegistry.shared.current==nil}
        @MainActor func remainingDiagnostic(_ state:String,_ output:String)->String {
            "\(state),marker=\(FileManager.default.fileExists(atPath:marker.path)),release=\(FileManager.default.fileExists(atPath:release.path)),match=\(getenv("TG_LOCAL_MATCH").map{String(cString:$0)} ?? "<unset>"),outputBytes=\(output.utf8.count),outputTail=\(String(reflecting:String(output.suffix(1024)))),active=\(LocalGitCommandProgress.activeOperations),dock=\(String(reflecting:DockProgressRegistry.shared.current)),dockOwners=\(DockProgressRegistry.shared.ownerCount)"
        }
        @MainActor func stashState(_ model:StashSaveProgressWindowModel)->String {
            remainingDiagnostic("Stash Save busy=\(model.busy),success=\(model.success),cancelled=\(model.cancelled),commandFinished=\(model.commandFinished),commandSucceeded=\(model.commandSucceeded),confirming=\(model.confirmingCancellation),pending=\(model.hasPendingWork),percent=\(String(describing:model.percentage))",model.output)
        }
        gate("stash", big: true)
        let save = StashSaveProgressWindowModel(repository: wrapped, access: nil, options: StashSaveOptions(), followUp: StashSaveFollowUp(), preferences: prefs)
        save.start(); try await wait(phase:"Stash Save flood admission",diagnostic:{stashState(save)}) { FileManager.default.fileExists(atPath: marker.path) && save.output.contains("Output truncated") }
        try require(save.busy && save.output.utf8.count < 17000, "Stash display exceeded its private output cap; "+stashState(save))
        save.invalidate(); try await wait(phase:"Stash Save flood retirement",diagnostic:{stashState(save)}) { LocalGitCommandProgress.activeOperations == 0 }
        let afterCancelledHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterCancelledIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        try require(afterCancelledHead == originalHead && afterCancelledIndex == originalIndex, "Cancelled pre-command dialogs changed HEAD/index")
        // Apply/Pop keeps its existing question flow while showing live output.
        try Data("stashed\n".utf8).write(to: file); _ = try await repo.saveStash(StashSaveOptions())
        gate("stash")
        let restoreController = StashRestoreWindowController(repository: wrapped, access: nil, pop: false, showChanges: 0, preferences: prefs), restore = restoreController.model
        defer { restoreController.close() }
        restore.start(); try await wait(phase:"Stash Restore stream admission",diagnostic:{remainingDiagnostic("Restore busy=\(restore.busy)",restore.output)}) { FileManager.default.fileExists(atPath: marker.path) && restore.output.contains("Unicode 雪") }
        try await live("Stash Restore",restore.output, restore.busy); let restoreShown = restore.output; restoreController.close()
        try await wait(phase:"Stash Restore retirement",diagnostic:{remainingDiagnostic("Restore busy=\(restore.busy),restoreActive=\(StashRestoreWindowModel.activeOperations)",restore.output)}) { LocalGitCommandProgress.activeOperations == 0 && StashRestoreWindowModel.activeOperations == 0 }
        try require(restore.output == restoreShown, "Retired restore progress changed output")
        // Normal completion delivers original command text; display keeps only the last CR update.
        gate("switch")
        let success = SwitchProgressWindowModel(repository: wrapped, access: nil, options: checkout, preferences: prefs)
        let successController=SwitchProgressWindowController(model:success)
        defer{successController.close()}
        successController.window?.alphaValue=0;successController.window?.setFrameOrigin(.init(x:-24000,y:-24000));successController.window?.orderFront(nil)
        var callback = ""; success.onFinished = { raw, _ in callback = raw }
        success.start(); try await wait(phase:"successful Switch stream admission",diagnostic:{remainingDiagnostic("Switch busy=\(success.busy),success=\(success.success)",success.output)}) { FileManager.default.fileExists(atPath: marker.path) && success.output.contains("Unicode 雪") }
        try await live("Switch successful completion",success.output,success.busy)
        try Data().write(to: release); try await wait(phase:"successful Switch completion",diagnostic:{remainingDiagnostic("Switch busy=\(success.busy),success=\(success.success),callbackBytes=\(callback.utf8.count)",success.output)}) { !success.busy && LocalGitCommandProgress.activeOperations == 0 }
        try require(success.success && callback.contains("Work: 10%") && !success.output.contains("Work: 10%"), "Completion callback lost original result or display repeated CR frames")
        try await wait(phase:"successful Switch native Dock release",diagnostic:{remainingDiagnostic("Switch success=\(success.success)",success.output)}) {DockProgressRegistry.shared.current==nil}
        successController.close()
        // A remembered kill question must not auto-close or execute twice after completion.
        prefs.set(true, forKey: "ConfirmKillProcess"); prefs.set(2, forKey: "AutoCloseGitProgress")
        try Data("save success\n".utf8).write(to: file); gate("stash")
        let confirmed = StashSaveProgressWindowModel(repository: wrapped, access: nil, options: StashSaveOptions(), followUp: StashSaveFollowUp(), preferences: prefs)
        var answer: ((Bool) -> Void)?, closes = 0
        confirmed.confirmCancellation = { answer = $0 }; confirmed.close = { closes += 1 }
        confirmed.start(); try await wait(phase:"confirmed Stash Save stream admission",diagnostic:{stashState(confirmed)}) { FileManager.default.fileExists(atPath: marker.path) && confirmed.output.contains("Unicode 雪") }
        confirmed.cancel(); try require(confirmed.confirmingCancellation && answer != nil, "Stash Save omitted source kill question; "+stashState(confirmed))
        try Data().write(to: release); try await wait(phase:"confirmed Stash Save completion with pending answer",diagnostic:{stashState(confirmed)+",closes=\(closes),hasAnswer=\(answer != nil)"}) { !confirmed.busy && LocalGitCommandProgress.activeOperations == 0 }
        try require(confirmed.success && closes == 0, "Completed command auto-closed through a pending kill question; "+stashState(confirmed)+",closes=\(closes)")
        answer?(false); answer?(true)
        try require(closes == 1 && !confirmed.cancelled && !confirmed.confirmingCancellation, "Duplicate late kill response changed completion; "+stashState(confirmed)+",closes=\(closes)")
        confirmed.invalidate(); success.invalidate()
        print("Local progress: live Reset/Switch/Stash Save/Restore output, CR and split UTF-8, native colored/copy menu, bounded display, original result callbacks, forced-close/Quit process lifetime and once-only kill/auto-close settlement passed. Private repos/preferences/clipboard/action log; owned windows closed.")
    }
}
