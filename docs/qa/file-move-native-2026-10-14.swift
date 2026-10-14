import AppKit
import TurtleGitCore

@main struct FileMoveVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"File move timeout at line \(line)")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("File move failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Move QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let destination=root.appendingPathComponent("target 雪",isDirectory:true),source="src/-file 雪\n[*].txt",second="src/second.txt",third="src/third.txt"
        try FileManager.default.createDirectory(at:root.appendingPathComponent("src"),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        for path in [source,second,third] { try Data("base\n".utf8).write(to:root.appendingPathComponent(path)) };try await repo.stage([source,second,third]);_ = try await repo.commit(message:"base")
        try Data("staged\n".utf8).write(to:root.appendingPathComponent(source));try await repo.stage([source]);try Data("working\n".utf8).write(to:root.appendingPathComponent(source))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.FileMove."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(16,forKey:"GitOutputLimitinKiB");defer { prefs.removePersistentDomain(forName:suite) }
        ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log")),preferences:prefs)
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready")
        let script = #"""
        #!/bin/sh
        if [ "$4" = mv ];then
          printf 'Move: 10%%\rMove: 35%%\r\nUnicode ';printf '\351\233';/bin/sleep 0.06;printf '\252\n'
          : > "$3/ready"
          while :;do /bin/sleep 0.05;done
        fi
        exec "$TG_MOVE_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path);setenv("TG_MOVE_GIT",git.path,1);defer {unsetenv("TG_MOVE_GIT")}
        let wrapped=GitRepository(root:root,executable:helper),slow=FileMoveWindowController(repository:wrapped,access:nil,paths:[source],preferences:prefs)
        defer {slow.close()};slow.model.setFolder(destination);try await wait {!slow.model.busy};slow.model.move()
        try await wait {FileManager.default.fileExists(atPath:marker.path) && slow.model.output.contains("Unicode 雪")}
        try require(slow.model.output.contains("Move: 35%") && !slow.model.output.contains("Move: 10%") && FileMoveWindowModel.activeOperations > 0,"Live move output/ownership missing")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost live move")
        slow.model.cancel();try await wait {!slow.model.busy && FileMoveWindowModel.activeOperations == 0}
        try require(slow.model.cancelled && slow.model.moved == 0 && Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Pre-mutation cancellation changed index")
        slow.close()
        // Collision uses the real Rename-style name controller and keeps invalid
        // input in the same sheet. Accepted plan preserves staged/working bytes.
        try Data("existing\n".utf8).write(to:destination.appendingPathComponent((source as NSString).lastPathComponent))
        let moving=FileMoveWindowController(repository:repo,access:nil,paths:[source],preferences:prefs);defer {moving.close()}
        moving.model.setFolder(destination);try await wait {!moving.model.busy};var events:[(String,String)]=[];moving.model.onMoved={old,new,_ in events.append((old,new))}
        moving.model.move();try await wait {moving.namePicker != nil}
        let name=moving.namePicker!;name.accept();try await wait {!name.busy && !name.errorLabel.stringValue.isEmpty}
        try require(moving.namePicker === name && events.isEmpty,"Occupied name did not retain validation sheet")
        let renamed="renamed 雪\n.txt";name.nameField.stringValue=renamed;name.accept();try await wait {!moving.model.busy}
        let target="target 雪/"+renamed,staged=try await repo.run(["show",":"+target]).text
        try require(moving.model.moved == 1 && events.first?.0 == source && events.first?.1 == target && staged == "staged\n" && String(contentsOf:root.appendingPathComponent(target)) == "working\n","Move/Rename lost bytes/captured callbacks")
        try require(try String(contentsOf:destination.appendingPathComponent((source as NSString).lastPathComponent)) == "existing\n","Collision overwrote existing destination")
        moving.close()
        // Ignore/Abort operates in source order and does not roll back successes.
        let batch=FileMoveWindowController(repository:repo,access:nil,paths:["not-versioned",second],preferences:prefs);defer {batch.close()}
        batch.model.setFolder(destination);try await wait {!batch.model.busy};var ignored:[String]=[]
        batch.model.continueAfterError={path,_ in ignored.append(path);return true};batch.model.move();try await wait {!batch.model.busy}
        try require(ignored == ["not-versioned"] && batch.model.skipped == 1 && batch.model.moved == 1 && FileManager.default.fileExists(atPath:destination.appendingPathComponent("second.txt").path),"Ignore failed to continue ordered batch")
        batch.close()
        // A held noncooperative command still counts for Quit after forced close;
        // its supplied token rejects the real mutation when released.
        let late=FileMoveWindowController(repository:repo,access:nil,paths:[third],preferences:prefs);var release:(()->Void)?,lateEvents=0
        late.model.setFolder(destination);try await wait {!late.model.busy}
        late.model.onMoved={_,_,_ in lateEvents += 1}
        late.model.executeMove={plan,token,emit in await withCheckedContinuation {continuation in release={continuation.resume()}};return try await repo.executeFileMove(plan,cancellation:token,onOutput:emit)}
        late.model.move();try await wait {release != nil};late.close();try require(FileMoveWindowModel.activeOperations > 0,"Retirement dropped active command lifetime")
        release?();try await wait {FileMoveWindowModel.activeOperations == 0}
        try require(late.model.retired && lateEvents == 0 && FileManager.default.fileExists(atPath:root.appendingPathComponent(third).path),"Retired callback moved or published")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after == head,"Move created a commit")
        try require(RepositoryAction.move.requiresWorkingTree && FinderMenuEntry.entry(for:.move) == nil,"Native Move changed ordinary Finder source mask")
        print("File Move: owned destination read, real streamed Git cancellation, native collision validation/rename, staged/working byte retention, ordered Ignore recovery and late command retirement/Quit passed. No commit/overwrite; owned windows closed.")
    }
}
