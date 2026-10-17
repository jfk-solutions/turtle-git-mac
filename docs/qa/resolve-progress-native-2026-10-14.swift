import AppKit
import TurtleGitCore

@main struct ResolveProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<2000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Resolve progress wait timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Resolve progress failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Resolve QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let paths = ["-first 雪\n[*].txt", "second.txt"]
        func write(_ text: String) throws { for path in paths { try Data(text.utf8).write(to: root.appendingPathComponent(path)) } }
        try write("base\n"); try await repo.stage(paths); _ = try await repo.commit(message: "base")
        _ = try await repo.run(["checkout", "-b", "side"]); try write("theirs\n"); try await repo.stage(paths); _ = try await repo.commit(message: "theirs")
        _ = try await repo.run(["checkout", "main"]); try write("mine\n"); try await repo.stage(paths); _ = try await repo.commit(message: "mine")
        do { _ = try await repo.run(["merge", "--no-edit", "side"]); throw Failure(description:"Expected conflicts") } catch is GitFailure {}
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.ResolveProgress." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"ConfirmKillProcess"); prefs.set(0,forKey:"AutoCloseGitProgress"); prefs.set(16,forKey:"GitOutputLimitinKiB")
        defer { prefs.removePersistentDomain(forName:suite) }
        ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("private-actions.log")),preferences:prefs)
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release")
        let script = #"""
        #!/bin/sh
        if [ "$4" = add ]; then
          printf 'Work: 10%%\rWork: 35%%\r\nUnicode '
          printf '\351\233'; /bin/sleep 0.06; printf '\252\n'
          printf 'warning: private fixture\n' >&2
          : > "$3/ready"
          while [ ! -e "$3/release" ]; do /bin/sleep 0.05; done
        fi
        exec "$TG_RESOLVE_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_RESOLVE_GIT",git.path,1);defer { unsetenv("TG_RESOLVE_GIT") }
        let wrapped=GitRepository(root:root,executable:helper)
        let controller=ResolveWindowController(repository:wrapped,access:nil,paths:[],preferences:prefs), model=controller.model
        defer { controller.close() }
        model.load();try await wait { !model.busy && model.entries.count == 2 }
        model.checked=GitPathSet([paths[0]]);var changed="",finished=0
        model.onChanged={changed=$0};model.onFinished={finished=$0}
        model.resolveChecked();try await wait { FileManager.default.fileExists(atPath:marker.path) && model.output.contains("Unicode 雪") }
        try require(model.output.contains("Work: 35%") && !model.output.contains("Work: 10%"),"Live CR output missing")
        try require(model.showingProgress && model.busy,"Progress not active")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit lost Resolve lifetime")
        model.cancel();try await wait { !model.busy && ResolveWindowModel.activeOperations == 0 }
        try require(model.cancelled && !model.success && finished == 0 && model.entries.count == 2,"Cancellation incorrectly completed resolution")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Pre-mutation cancel changed index")
        try require(model.output.contains("Resolution aborted") && !changed.isEmpty,"Cancellation omitted outcome/refresh callback")
        model.closeProgress();try await wait { !model.busy && !model.showingProgress }
        try Data().write(to:release);model.checked=GitPathSet([paths[0]]);model.resolveChecked();try await wait { !model.busy && model.success }
        try require(finished == 1 && model.resolvedCount == 1 && model.entries.map(\.path) == [paths[1]],"Checked completion/count/refresh incorrect")
        try require(changed.contains("Work: 10%") && model.output.contains("Resolved: " + paths[0]),"Raw callback or silent-Git notification missing")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(head == after,"Resolve committed unexpectedly")
        try require(try String(contentsOf:root.appendingPathComponent(paths[0])) == "<<<<<<< HEAD\nmine\n=======\ntheirs\n>>>>>>> side\n","Current mode changed workfile")
        // Closing a controller while its context question is pending must settle
        // the continuation once and ignore duplicate/late affirmative callbacks.
        let late=ResolveWindowController(repository:repo,access:nil,paths:[],quick:.theirs,preferences:prefs)
        var answer: ((NSApplication.ModalResponse)->Void)?;var mutations=0
        late.presentQuestion={ _,_,reply in answer=reply;return true }
        late.model.executeResolution={ _,_,_,_,_ in mutations += 1;return "unexpected" }
        late.model.load();try await wait { answer != nil && late.model.hasQuestion }
        late.close();answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await Task.sleep(nanoseconds:100_000_000)
        try require(mutations == 0 && !late.model.active,"Retired affirmative resumed a mutation")
        // A non-cooperative read still keeps Quit blocked and cannot publish
        // stale rows after the owner closes.
        let read=ResolveWindowController(repository:repo,access:nil,paths:[],preferences:prefs)
        var released=false,readStarted=false
        read.model.readConflicts={ token in readStarted=true;while !released { try await Task.sleep(nanoseconds:10_000_000) };return (try await repo.conflicts(),false) }
        read.model.load();try await wait { readStarted }
        read.close();try require(ResolveWindowModel.activeOperations > 0,"Retirement dropped live reader count")
        released=true;try await wait { ResolveWindowModel.activeOperations == 0 }
        try require(read.model.entries.isEmpty && !read.model.active,"Retired read published rows")
        print("Resolve streamed real checked staging/cancellation, unchanged HEAD/index, actual conflict refresh, raw callbacks, pending-question retirement/duplicate replies and late-reader Quit ownership passed.")
    }
}
