// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum RemoteReferenceBackendVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value {throw Failure(description:message)} }
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Remote-reference backend timeout at \(line)")
    }
    static func drained()->Bool {RemoteReferenceWindowModel.activeOperations==0 && RemoteTagWindowModel.activeOperations==0 && ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && SynchronizationProgressModel.activeOperations==0}
    static func verify()async throws {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3]),fm=FileManager.default
        let root=base.appendingPathComponent("repository"),server=base.appendingPathComponent("server.git")
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git,askpass:nil)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Remote UI QA"),("user.email","remote@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("private source\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"source")
        _ = try await repo.run(["branch","delete-me"])
        for name in ["alpha","beta","gamma"] {_ = try await repo.run(["tag",name])}
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,server.path]);_ = try await repo.run(["remote","add","origin",server.path]);_ = try await repo.run(["fetch","origin"])
        let remote=GitRepository(root:server,executable:git,askpass:nil)
        _ = try await remote.run(["config","core.hooksPath","/dev/null"])
        let suite="TurtleGit.RemoteReference.Backend."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        ProgressActionLog.install(store:ActionLogStore(storageURL:base.appendingPathComponent("private/action-log.txt")),preferences:prefs)
        let grant=RepositoryAccessLease(url:root),recording=base.appendingPathComponent("record-helper"),calls=base.appendingPathComponent("record-helper.calls")
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        printf '%s\\n' "$@" >> "$0.calls"
        if [ -f "$0.hold" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
          /bin/mv "$0.ready.tmp" "$0.ready"
          wait "$task_child"
        fi
        exec \(quote(helper.path)) "$@"
        """
        try script.write(to:recording,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:recording.path)
        func captured()->GitLibGit2Configuration {.load(from:prefs,helperURL:recording)}
        func use(_ mask:UInt32) {prefs.set(true,forKey:"UseLibgit2");prefs.set(mask,forKey:"UseLibgit2_mask")}
        func off() {prefs.set(false,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask")}
        func log()throws->String {fm.fileExists(atPath:calls.path) ? try String(contentsOf:calls):""}
        var refsOwners:[RemoteReferenceWindowController]=[],tagOwners:[RemoteTagWindowController]=[],browserOwners:[ReferenceBrowserWindowController]=[],progress:[SynchronizationProgressModel]=[],progressOwners:[SynchronizationProgressController]=[]
        var confirmation:CheckedContinuation<Bool,Never>?
        defer {confirmation?.resume(returning:false);refsOwners.forEach{$0.close()};tagOwners.forEach{$0.close()};browserOwners.forEach{$0.close()};progressOwners.forEach{$0.abortPresentation()};progress.forEach{$0.invalidate()};prefs.removePersistentDomain(forName:suite)}
        let refs=RemoteReferenceWindowController(repository:repo,access:grant,remote:"origin",preferences:prefs){_ in};refsOwners.append(refs)
        refs.model.captureBackend=captured
        refs.model.refresh();refs.window?.orderFront(nil);try await wait{!refs.model.busy}
        try require(refs.model.refs.contains("main") && !refs.model.refs.contains("HEAD") && !refs.model.operationBackend.requests(.fetch) && (try log()).isEmpty,"Source-default native remote list did not use Git CLI")
        use(4);let stale=refs.model.formContext;refs.model.refresh();off()
        try await wait{!refs.model.busy}
        try require(refs.model.operationBackend.requests(.fetch) && refs.model.refs.contains("HEAD") && refs.model.error==nil && (try log()).contains("ls-remote"),"Remote list lost private accepted backend")
        let branch=refs.model.branch;refs.model.setBranch("late",context:stale);try require(refs.model.branch==branch,"Stale list callback replaced branch")
        // Delete and refill share the backend accepted before the source warning.
        use(0x804)
        let tags=RemoteTagWindowController(repository:repo,access:grant,remote:"origin",preferences:prefs);tagOwners.append(tags)
        tags.model.captureBackend=captured;tags.model.load();tags.window?.orderFront(nil);try await wait{!tags.model.busy}
        try require(tags.model.tags.count==3,"Actual helper tag listing failed: \(tags.model.error ?? "none")")
        tags.model.select([GitReferenceName("alpha")]);let oldForm=tags.model.formContext
        tags.model.confirm={_ in await withCheckedContinuation{confirmation=$0}}
        tags.model.delete();try await wait{confirmation != nil};off();confirmation?.resume(returning:true);confirmation=nil
        try await wait{!tags.model.busy}
        try require(tags.model.operationBackend.requests(.push) && tags.model.operationBackend.requests(.fetch) && tags.model.tags.map(\.name.rawValue)==["beta","gamma"] && (try log()).contains("push"),"Remote tag delete/refill switched backend or selection")
        let count=try log().count;tags.model.delete(context:oldForm);try require(!tags.model.busy && (try log()).count==count,"Stale tag action repeated mutation")
        // Browse References must capture the source remote-deletion choice
        // before its asynchronous preflight and default-Abort warning.
        use(0x804)
        let browser=ReferenceBrowserWindowController(repository:repo,access:grant,initial:"refs/remotes/origin/delete-me",preferences:prefs,picking:false){_ in};browserOwners.append(browser)
        browser.model.captureRemoteBackend=captured;browser.model.load();browser.window?.orderFront(nil);try await wait{!browser.model.busy && browser.model.snapshot != nil}
        browser.model.setFolder(GitReferenceName("refs/remotes/origin"));browser.model.select([GitReferenceName("refs/remotes/origin/delete-me")],last:GitReferenceName("refs/remotes/origin/delete-me"))
        browser.model.confirmDeletion={_ in await withCheckedContinuation{confirmation=$0}}
        try require(browser.model.canDelete,"Remote-tracking delete missing")
        browser.model.deleteChosen();try await wait{confirmation != nil};off();confirmation?.resume(returning:true);confirmation=nil
        try await wait{!browser.model.busy && ReferenceBrowserWindowModel.activeMutations==0 && ReferenceBrowserWindowModel.activeReads==0}
        let remaining=try await remote.run(["for-each-ref","--format=%(refname)","refs/heads/"]).text
        try require(!remaining.contains("refs/heads/delete-me") && browser.model.error==nil,"Browse References did not delete actual remote branch: \(browser.model.error ?? "none")")
        // Main Sync captures before await; real child engines list/delete/refill
        // using that same snapshot despite settings changes during the warning.
        use(0x804)
        let sync=SynchronizationWindowModel(repository:repo,access:grant,preferences:prefs);sync.remote="origin";sync.captureTagBackend=captured
        sync.performTagOperation={ [weak sync] operation,token in
            guard let sync else {return .failure(OperationCancellationFailure.cancelled)}
            let child=SynchronizationProgressController(repository:repo,operation:operation,cancellation:token,preferences:prefs,access:grant,backend:sync.tagBackend){_ in}
            progress.append(child.model);progressOwners.append(child);child.window?.orderFront(nil);child.model.start()
            do {try await wait{!child.model.busy};let result=child.model.result ?? .failure(OperationCancellationFailure.cancelled);child.close();return result}
            catch {child.abortPresentation();return .failure(error)}
        }
        sync.compareTags();off();try await wait{!sync.busy}
        guard let snapshot=sync.tagSnapshot,let row=snapshot.rows.first(where:{$0.name.rawValue=="beta"}) else {throw Failure(description:"Actual Sync helper tag rows missing: \(sync.error ?? "none")")}
        try require(sync.tagBackend?.requests(.fetch)==true && progress.last?.backend.requests(.fetch)==true,"Sync compare ignored originating backend")
        use(0x804);sync.confirmTagDeletion={_,_,_ in await withCheckedContinuation{confirmation=$0}}
        sync.performTag(.deleteRemote,row:row);try await wait{confirmation != nil};off();confirmation?.resume(returning:true);confirmation=nil
        try await wait{!sync.busy && SynchronizationProgressModel.activeOperations==0}
        try require(sync.tagSnapshot?.rows.first(where:{$0.name.rawValue=="beta"})?.remoteHash==nil && sync.error==nil && progress.last?.backend.requests(.push)==true,"Sync delete/refill lost accepted engine: \(sync.error ?? "none")")
        sync.invalidate()
        // Native cancellation owns the actual selected-engine process group
        // until its child is reaped; Cancel closes only after that drain.
        use(4)
        let hold=base.appendingPathComponent("record-helper.hold"),ready=base.appendingPathComponent("record-helper.ready")
        try Data().write(to:hold)
        let cancelling=RemoteReferenceWindowController(repository:repo,access:grant,remote:"origin",preferences:prefs){_ in};refsOwners.append(cancelling)
        cancelling.model.captureBackend=captured;cancelling.model.refresh();cancelling.window?.orderFront(nil)
        try await wait{fm.fileExists(atPath:ready.path) && cancelling.model.busy}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Native remote reader lost Quit/process ownership")
        cancelling.model.requestClose();try await wait{RemoteReferenceWindowModel.activeOperations==0 && cancelling.model.retired && pids.allSatisfy{kill($0,0) != 0}}
        try require(cancelling.model.refs.isEmpty,"Canceled engine published refs")
        try fm.removeItem(at:hold)
        // A held remote query which ignores cancellation cannot publish a late
        // selection after its actual native owner has closed.
        let late=RemoteReferenceWindowController(repository:repo,access:grant,remote:"origin",preferences:prefs){_ in};refsOwners.append(late)
        var reply:CheckedContinuation<[String],Error>?,token:OperationCancellation?
        late.model.query={_,request in token=request;return try await withCheckedThrowingContinuation{reply=$0}}
        late.model.refresh();late.window?.orderFront(nil);try await wait{reply != nil};late.close()
        try require(token?.isCancelled==true && RemoteReferenceWindowModel.activeOperations==1,"Retirement lost outstanding list ownership")
        reply?.resume(returning:["refs/heads/late"]);reply=nil;try await wait{RemoteReferenceWindowModel.activeOperations==0}
        try require(late.model.retired && late.model.refs.isEmpty,"Retired list published late helper output")
        refsOwners.forEach{$0.close()};tagOwners.forEach{$0.close()};browserOwners.forEach{$0.close()};progress.forEach{$0.invalidate()};try await wait{drained()}
        print("PASS: native remote-reference helper listing/deletion/Sync snapshot and cancellation family")
    }
}
