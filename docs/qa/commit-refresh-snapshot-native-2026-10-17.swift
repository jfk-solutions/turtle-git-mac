import AppKit
import Darwin
import TurtleGitCore

@main struct CommitRefreshSnapshotVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {for _ in 0..<3000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Commit refresh snapshot: complete deferred publication, late Git failure, LFS cancellation/refusal, scoped Retry, initial preferences/template/preview and retained draft/HEAD/index")}catch {fputs("Commit refresh failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),fm=FileManager.default
        for (key,value) in GitRuntime.environment(executable:git) {setenv(key,value,1)}
        let real=GitRepository(root:root,executable:git,askpass:nil)
        _=try await real.run(["init","-b","main"])
        for (key,value) in [("user.name","Snapshot QA"),("user.email","snapshot@example.invalid"),("commit.gpgsign","false"),("commit.template",".git/message-template")] {_=try await real.run(["config",key,value])}
        let a=root.appendingPathComponent("a"),b=root.appendingPathComponent("b"),template=root.appendingPathComponent(".git/message-template")
        try Data("base\n".utf8).write(to:a);try await real.stage(["a"]);_=try await real.commit(message:"base")
        try Data("changed\n".utf8).write(to:a);try Data("initial template".utf8).write(to:template)
        try fm.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let head=try await real.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let wrapper=root.appendingPathComponent(".git/checked-git"),mode=root.appendingPathComponent(".git/fail-mode"),ready=root.appendingPathComponent(".git/ready"),release=root.appendingPathComponent(".git/release")
        try Data(#"""
        #!/bin/sh
        for argument in "$@"; do
          if [ "$argument" = --numstat ] && [ -f "$TG_COMMIT_MODE" ]; then
            echo "$$" > "$TG_COMMIT_READY"
            while [ ! -f "$TG_COMMIT_RELEASE" ]; do /bin/sleep 0.02; done
            echo 'injected late statistics failure' >&2; exit 98
          fi
        done
        exec "$TG_COMMIT_REAL_GIT" "$@"
        """#.utf8).write(to:wrapper);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        for (key,value) in [("TG_COMMIT_MODE",mode.path),("TG_COMMIT_READY",ready.path),("TG_COMMIT_RELEASE",release.path),("TG_COMMIT_REAL_GIT",git.path)] {setenv(key,value,1)}
        defer {for key in ["TG_COMMIT_MODE","TG_COMMIT_READY","TG_COMMIT_RELEASE","TG_COMMIT_REAL_GIT"] {unsetenv(key)}}
        let repo=GitRepository(root:root,executable:wrapper,askpass:nil),suite="TurtleGit.CommitSnapshot."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation");defer {prefs.removePersistentDomain(forName:suite)}
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs),model=owner.model;defer {owner.close()}
        model.fileColumns.visible.insert(.lfsOwner);model.queryLFSOwners={_ in [LFSLock(id:"old",path:"a",owner:"old owner")]}
        model.reload(paths:["a"]);try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.error == nil && model.branch == "main" && model.message == "initial template\n" && model.checked == ["a"] && model.lfsOwners == ["a":"old owner"],"Initial snapshot failed: error=\(model.error ?? "nil") branch=\(model.branch) message=\(String(reflecting:model.message)) checked=\(model.checked) owners=\(model.lfsOwners) loadedLFS=\(model.hasLFS)")
        model.message="retained draft";model.selection=["a"]
        let rows=model.entries,stats=model.statistics,metadata=model.fileMetadata,lists=model.changelists
        func unchanged()throws {
            try require(model.entries == rows && model.statistics == stats && model.fileMetadata == metadata && model.changelists == lists && model.changelistsLoaded && model.branch == "main" && model.scopePaths == ["a"] && !model.showWholeProject && model.checked == ["a"] && model.selection == ["a"] && model.lfsOwners == ["a":"old owner"] && model.lfsOwnershipKnown && model.message == "retained draft","Pending/failed refresh changed accepted display")
        }
        _=try await real.run(["switch","-c","next"]);try Data("changed\nmore\n".utf8).write(to:a);try Data("new\n".utf8).write(to:b);_=try await real.assignChangelist(paths:["b"],name:"next group")
        try Data().write(to:mode);model.reload(paths:["b"]);try await wait {fm.fileExists(atPath:ready.path)};try unchanged()
        try require(model.busy && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pending full read lost Quit")
        let pid=Int32(try String(contentsOf:ready).trimmingCharacters(in:.whitespacesAndNewlines))
        try Data().write(to:release);try await wait {!model.busy && CommitWindowModel.activeReloads == 0};try unchanged()
        try require(model.error?.contains("injected late statistics failure") == true,"Late Git error hidden")
        try require(pid.map {kill($0,0) != 0 && errno == ESRCH} == true,"Gate Git process not reaped")
        for file in [mode,ready,release] {try fm.removeItem(at:file)}
        var locks:CheckedContinuation<[LFSLock],Error>?
        model.queryLFSOwners={_ in try await withCheckedThrowingContinuation {locks=$0}}
        model.reload(paths:["b"]);try await wait {locks != nil};try unchanged()
        model.message="newer typed draft";model.issueID="typed issue"
        locks?.resume(returning:[LFSLock(id:"new",path:"b",owner:"new owner")]);locks=nil
        try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.error == nil && model.branch == "next" && model.scopePaths == ["b"] && model.checked == ["b"] && model.changelists.assignments["b"] == "next group" && model.lfsOwners == ["b":"new owner"] && model.message == "newer typed draft" && model.issueID == "typed issue","Accepted Retry snapshot/draft mismatched")
        let acceptedRows=model.entries,acceptedStats=model.statistics
        _=try await real.run(["switch","-c","third"]);try Data("latest\n".utf8).write(to:a)
        model.reload(paths:["a"]);try await wait {locks != nil};model.cancel(closeWindow:false)
        try require(model.busy && CommitWindowModel.activeReloads > 0,"Cancelled ignored reader lost drain ownership")
        locks?.resume(returning:[LFSLock(id:"late",path:"a",owner:"late owner")]);locks=nil
        try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.entries == acceptedRows && model.statistics == acceptedStats && model.branch == "next" && model.scopePaths == ["b"] && model.lfsOwners == ["b":"new owner"],"Cancellation published partial snapshot")
        // Optional LFS failure accepts new rows without granting stale ownership.
        model.queryLFSOwners={_ in throw Failure.assertion("lock lookup unavailable")};model.reload(paths:["a"]);try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.branch == "third" && model.scopePaths == ["a"] && model.lfsOwners.isEmpty && !model.lfsOwnershipKnown && model.error?.contains("Could not get LFS locks") == true,"Optional LFS warning retained stale ownership or rejected new rows")
        let lastRows=model.entries,lastBranch=model.branch
        model.queryLFSOwners={_ in try await withCheckedThrowingContinuation {locks=$0}};model.reload(paths:["b"]);try await wait {locks != nil};owner.close()
        try require(CommitWindowModel.activeReloads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired full read lost Quit lifetime")
        locks?.resume(returning:[]);locks=nil;try await wait {CommitWindowModel.activeReloads == 0}
        try require(model.entries == lastRows && model.branch == lastBranch && model.scopePaths == ["a"],"Retired snapshot published")
        // An unsuccessful first load must not consume preferences or message seed.
        let fresh=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs);defer {fresh.invalidateForClose()}
        var previews=0;fresh.showPartial={_ in previews += 1};fresh.showViewPatch={previews += 1}
        try Data().write(to:mode);fresh.reload(paths:["a"]);try await wait {fm.fileExists(atPath:ready.path)}
        try require(fresh.entries.isEmpty && fresh.branch.isEmpty && fresh.message.isEmpty && !fresh.stagingEnabled && previews == 0,"First failed load published state")
        try Data().write(to:release);try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        for file in [mode,ready,release] {try fm.removeItem(at:file)}
        _=try await real.run(["config","tgit.commitstagingsupport","true"]);_=try await real.run(["config","tgit.commitshowpatch","true"]);try Data("retry template".utf8).write(to:template)
        fresh.reload(paths:["a"]);try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.stagingEnabled && fresh.message == "retry template\n" && previews == 1 && fresh.branch == "third","Failed first load consumed preference/template/preview state")
        fresh.reload();try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0};try require(previews == 1,"Refresh repeated initial preview")
        let afterHead=try await real.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head == afterHead && index == afterIndex,"Read pipeline changed HEAD/index")
    }
}
