import AppKit
import TurtleGitCore

@main struct RebaseSessionRefreshVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Replay refresh timeout at line \(line)")}
    @MainActor static func main() async {do {try await verify()}catch {fputs("Replay refresh failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Replay QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let file=root.appendingPathComponent("file");try Data("base\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["switch","-c","upstream"]);try Data("upstream\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"upstream")
        _ = try await repo.run(["switch","-c","topic",base.hash]);try Data("topic\n".utf8).write(to:file);try await repo.stage(["file"]);_ = try await repo.commit(message:"topic")
        var options=RebaseOptions();options.branch="topic";options.upstream="upstream"
        let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
        _ = try await repo.startRebase(try await repo.rebasePlan(options),editorExecutable:editor)
        let suite="TurtleGit.ReplayRefresh."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");defer {prefs.removePersistentDomain(forName:suite)}
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model;defer {owner.close()};model.load()
        try await wait {!model.busy && model.fileRecovery && RebaseWindowModel.activePreparationReads == 0}
        try require(model.conflicts.map(\.path) == ["file"] && !model.replayRows.isEmpty,"Initial session read did not publish complete conflict/replay data")
        model.checkedConflicts=[];model.refreshState();try await wait {!model.busy};try require(model.checkedConflicts.isEmpty,"Same stopped identity reset checked files")
        // Duplicate busy refresh requests produce one queued fresh read.
        var release:(()->Void)?,reads=0
        model.readSession={identity,token in
            reads += 1;let snapshot=try await repo.rebaseSessionSnapshot(retaining:identity,cancellation:token)
            if reads == 1 {await withCheckedContinuation {continuation in release={continuation.resume()}}}
            return snapshot
        }
        model.refreshState();try await wait {release != nil};model.refreshState();model.refreshState();release?();try await wait {!model.busy && RebaseWindowModel.activePreparationReads == 0}
        try require(reads == 2,"Busy refresh requests were lost or started parallel reads")
        // Cancellation ignores a deliberately held successful reply without replacing prior fields.
        release=nil;let before=model.conflictRows,oldMessage=model.amendMessage
        model.readSession={identity,token in let snapshot=try await repo.rebaseSessionSnapshot(retaining:identity,cancellation:token);await withCheckedContinuation {continuation in release={continuation.resume()}};return snapshot}
        model.refreshState();try await wait {release != nil};try require(model.refreshingSession && model.cancelPreparation(),"Session refresh is not cancellable")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held session read lost Quit ownership");release?();try await wait {!model.busy && RebaseWindowModel.activePreparationReads == 0}
        try require(model.conflictRows == before && model.amendMessage == oldMessage,"Cancelled refresh published its held reply")
        model.readSession={try await repo.rebaseSessionSnapshot(retaining:$0,cancellation:$1)}
        try Data("resolved\n".utf8).write(to:file);try await repo.stage(["file"]);model.refreshState();try await wait {!model.busy}
        try require(model.fileRecovery && model.conflicts.isEmpty && model.checkedConflicts.isEmpty,"Resolved session lost checked-file recovery")
        // Ending externally clears recovered rows and diffs through one publication.
        _ = try await repo.abortRebase();model.refreshState();try await wait {!model.busy}
        try require(!model.active && model.finished && model.conflictRows.isEmpty && model.replayRows.isEmpty && model.files.isEmpty,"Ended external session left stale rows")
        owner.close()
        // A gated conflict diff belongs to the initiating owner; forced close reaps it.
        _ = try await repo.startRebase(try await repo.rebasePlan(options),editorExecutable:editor)
        let helper=root.appendingPathComponent("gated-git"),ready=root.appendingPathComponent("diff-ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = diff ] && [ "$5" = --no-ext-diff ] && [ "$6" = --no-textconv ];then
          : > "$3/diff-ready";/bin/sleep 30
        fi
        exec "$TG_REFRESH_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_REFRESH_GIT",git.path,1);defer {unsetenv("TG_REFRESH_GIT")}
        let wrapped=GitRepository(root:root,executable:helper),diffOwner=RebaseWindowController(repository:wrapped,access:nil,preferences:prefs),diff=diffOwner.model;defer {diffOwner.close()};diff.load();try await wait {!diff.busy && diff.fileRecovery && RebaseWindowModel.activePreparationReads == 0}
        diff.compareConflicts(Set(diff.conflicts.map(\.id)));try await wait {FileManager.default.fileExists(atPath:ready.path)}
        try require(diff.preparingConflictDiff && diff.hasCancellablePreparation && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Conflict diff lacks owned lifetime")
        let conflictBytes=try Data(contentsOf:file);diffOwner.close();try require(RebaseWindowModel.activePreparationReads > 0,"Closed owner released read before process settlement")
        try await wait {RebaseWindowModel.activePreparationReads == 0};let afterConflict=try Data(contentsOf:file);try require(diff.retired && diff.conflictPatch == nil && diff.error == nil && afterConflict == conflictBytes,"Retired diff published state or changed conflict bytes")
        _ = try await repo.abortRebase()
        print("Replay session refresh: coherent initial/state/conflict/replay snapshot, stable unchecked recovery, queued refresh coalescing, cancelled held reply, resolved and external-ended sessions, owned conflict diff cancellation/retirement/Quit passed. Private fixture/preferences; owned windows closed.")
    }
}
