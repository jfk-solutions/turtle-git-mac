import AppKit
import TurtleGitCore

@main struct WorktreeProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Worktree progress timeout at line \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Worktree progress failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath: CommandLine.arguments[1]), git=URL(fileURLWithPath: CommandLine.arguments[2]), repo=GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Worktree QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout, index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.WorktreeProgress."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer { prefs.removePersistentDomain(forName:suite) }
        ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log")),preferences:prefs)
        let helper=root.appendingPathComponent("stream-git"), marker=root.appendingPathComponent("ready"), release=root.appendingPathComponent("release")
        let script = #"""
        #!/bin/sh
        if [ "$4" = worktree ] && [ "$5" = "$TG_WORKTREE_MATCH" ]; then
          printf 'Work: 10%%\rWork: 35%%\r\nUnicode '
          printf '\351\233'; /bin/sleep 0.06; printf '\252\n'
          printf 'warning: private fixture\n' >&2
          if [ "$TG_WORKTREE_BIG" = 1 ]; then
            row=0; while [ "$row" -lt 32 ]; do printf '%1024s\n' X; row=$((row+1)); done
          fi
          : > "$3/ready"
          while [ ! -e "$3/release" ]; do /bin/sleep 0.05; done
        fi
        exec "$TG_WORKTREE_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_WORKTREE_GIT",git.path,1)
        defer { unsetenv("TG_WORKTREE_GIT");unsetenv("TG_WORKTREE_MATCH");unsetenv("TG_WORKTREE_BIG") }
        let wrapped=GitRepository(root:root,executable:helper)
        @MainActor func gate(_ command:String,big:Bool=false) { try? FileManager.default.removeItem(at:marker);try? FileManager.default.removeItem(at:release);setenv("TG_WORKTREE_MATCH",command,1);setenv("TG_WORKTREE_BIG",big ? "1":"0",1) }
        @MainActor func live(_ text:String,_ busy:Bool) throws { try require(busy && text.contains("Unicode 雪") && text.contains("Work: 35%") && !text.contains("Work: 10%"),"Live CR/UTF-8 output missing");try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost live worktree ownership") }
        let destination=root.appendingPathComponent("created")
        gate("add")
        let controller=WorktreeCreateWindowController(repository:wrapped,access:nil,preferences:prefs), create=controller.model
        defer { controller.close() }
        try await wait { !create.busy && !create.chooser.busy }
        create.directory=destination.path;var callback="";create.onCreated={callback=$0};create.create()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && create.output.contains("Unicode 雪") }
        try live(create.output,create.busy);try require(create.percentage == 35,"Creation percentage missing")
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait { descendants(controller.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text=descendants(controller.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        try await wait { text.string == create.output }
        let clipboard=NSPasteboard.withUniqueName();defer { clipboard.releaseGlobally() };text.clipboard=clipboard;text.copyAllInformation(nil)
        try require(clipboard.string(forType:.string) == create.output && text.outputMenu().items.last?.image != nil,"Native copy menu missing")
        try Data().write(to:release);try await wait { !create.busy }
        try require(create.success && callback.contains("Work: 10%") && !create.output.contains("Work: 10%"),"Creation replaced original callback with presentation")
        controller.close()
        prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(2,forKey:"AutoCloseGitProgress");gate("add")
        let confirmed=WorktreeCreateWindowModel(repository:wrapped,access:nil,preferences:prefs)
        confirmed.directory=root.appendingPathComponent("confirmed").path
        var createAnswer:((Bool)->Void)?, closes=0;confirmed.confirmCancellation={createAnswer=$0};confirmed.close={closes += 1}
        confirmed.create();try await wait { FileManager.default.fileExists(atPath:marker.path) && confirmed.output.contains("Unicode 雪") }
        confirmed.cancel();try require(confirmed.confirmingCancellation && createAnswer != nil,"Creation kill question missing")
        try Data().write(to:release);try await wait { !confirmed.busy }
        try require(confirmed.success && closes == 0,"Creation auto-closed through pending question")
        createAnswer?(false);createAnswer?(true);try require(closes == 1 && !confirmed.cancelled,"Creation late answer changed success")
        confirmed.invalidate();prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
        let list=WorktreeListWindowModel(repository:wrapped,access:nil,preferences:prefs);list.reload();try await wait { !list.busy }
        let id=list.rows.first { $0.path.lastPathComponent == "created" }!.id
        for (command, action) in [("lock",WorktreeListWindowModel.Action.lock),("unlock",.unlock)] {
            gate(command);list.modify(action,ids:[id]);try await wait { FileManager.default.fileExists(atPath:marker.path) && list.output.contains("Unicode 雪") };try live(list.output,list.busy)
            try Data().write(to:release);try await wait { !list.busy };try require(!list.failed,"Lock/unlock failed");list.closeProgress()
        }
        // Cancel stops before mutation and prevents remaining removal work.
        gate("remove");list.confirmRemoval={_,_ in true};list.modify(.remove,ids:[id]);try await wait { FileManager.default.fileExists(atPath:marker.path) && list.output.contains("Unicode 雪") };try live(list.output,list.busy)
        list.cancel();try await wait { !list.busy && LocalGitCommandProgress.activeOperations == 0 }
        try require(list.cancelled && FileManager.default.fileExists(atPath:destination.appendingPathComponent(".git").path),"Cancelled removal changed checkout")
        list.closeProgress()
        gate("prune");list.prune();try await wait { FileManager.default.fileExists(atPath:marker.path) && list.output.contains("Unicode 雪") }
        list.cancel();try await wait { !list.busy };try require(list.cancelled && list.result == "Cancelled" && list.showProgress,"Cancelled Prune was treated as success")
        list.closeProgress()
        // A completed Prune waits for its question; duplicate late Yes cannot cancel it.
        prefs.set(true,forKey:"ConfirmKillProcess");prefs.set(2,forKey:"AutoCloseGitProgress");gate("prune")
        var answer:((Bool)->Void)?;list.confirmCancellation={answer=$0};list.prune();try await wait { FileManager.default.fileExists(atPath:marker.path) && list.output.contains("Unicode 雪") }
        list.cancel();try require(list.confirmingCancellation && answer != nil,"Missing kill question")
        try Data().write(to:release);try await wait { !list.busy };try require(list.showProgress && !list.cancelled,"Pending question lost natural success")
        answer?(false);answer?(true);try require(!list.showProgress && !list.cancelled,"Duplicate answer changed completed prune")
        // Forced retirement freezes display while the process remains accounted until reaped.
        prefs.set(false,forKey:"ConfirmKillProcess");gate("remove",big:true);list.modify(.remove,ids:[id]);try await wait { FileManager.default.fileExists(atPath:marker.path) && list.output.contains("Output truncated") }
        try require(list.output.utf8.count < 17000,"Batch display cap exceeded");let before=list.output;list.invalidate()
        try require(WorktreeListWindowModel.activeOperations > 0,"Retirement dropped operation before reap");try await wait { WorktreeListWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0 }
        try require(list.output == before && FileManager.default.fileExists(atPath:destination.appendingPathComponent(".git").path),"Retired batch published state or mutated checkout")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout, afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head == afterHead && index == afterIndex,"Worktree operations changed main HEAD/index")
        print("Worktree progress: live add/lock/unlock/remove/prune, CR/split UTF-8, native copy icons, original callbacks, bounded batch output, cancellation/forced retirement, Quit and once-only kill/autoclose passed. Private repositories/preferences/clipboard; owned window closed.")
    }
}
