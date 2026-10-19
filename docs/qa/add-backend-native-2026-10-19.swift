// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum AddBackendVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Add backend timeout at \(line)")}
    static func drained()->Bool{AddWindowModel.activeOperations==0 && AddProgressWindowModel.activeOperations==0 && AddProgressWindowController.activeReleases==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeReloads==0}
    static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=URL(fileURLWithPath:CommandLine.arguments[3]),fm=FileManager.default
        let repo=GitRepository(root:root,executable:git,askpass:nil)
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Add backend QA"),("user.email","add@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        let clean=root.appendingPathComponent("clean-filter"),hold=root.appendingPathComponent("clean-filter.hold"),ready=root.appendingPathComponent("clean-filter.ready"),fail=root.appendingPathComponent("clean-filter.fail"),log=root.appendingPathComponent("clean-filter.log")
        let script="""
        #!/bin/sh
        printf '%s\\n' "$PWD" >> "$0.log"
        if [ -f "$0.fail" ]; then exit 9; fi
        if [ -f "$0.hold" ]; then
          /bin/sleep 30 &
          task_child=$!
          trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
          printf '%s %s\\n' "$$" "$task_child" > "$0.ready"
          wait "$task_child"
        fi
        exec /usr/bin/sed 's/working/CLEANED/g'
        """
        try script.write(to:clean,atomically:true,encoding:.utf8);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:clean.path)
        let quoted="'"+clean.path.replacingOccurrences(of:"'",with:"'\\''")+"'"
        _ = try await repo.run(["config","filter.qa.clean",quoted]);_ = try await repo.run(["config","filter.qa.required","true"])
        try Data("*.txt filter=qa -text\n".utf8).write(to:root.appendingPathComponent(".gitattributes"))
        try await repo.stage([".gitattributes"]);_ = try await repo.commit(message:"attributes")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.AddBackend."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(true,forKey:"UseLibgit2");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        let backend=GitLibGit2Configuration.load(from:prefs,helperURL:helper),grant=RepositoryAccessLease(url:root)
        var owners:[AddProgressWindowController]=[]
        defer{owners.forEach{$0.close()};clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite);try? fm.removeItem(at:hold)}
        func progress(_ paths:[String],selection:GitLibGit2Configuration?=nil,mode:WorkingFileAddMode = .normal)->AddProgressWindowController{
            let owner=AddProgressWindowController(repository:repo,access:grant,paths:paths,mode:mode,preferences:prefs,backend:selection ?? backend)
            owner.model.progress.publishClipboard={text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            owner.window!.alphaValue=0;owner.window!.orderFront(nil);owners.append(owner);return owner
        }
        let paths=["é.txt","e\u{301}.txt","file with space\n.txt"]
        for path in paths{try Data("working bytes\n".utf8).write(to:root.appendingPathComponent(path))}
        // Dialog submission snapshots the originating private preferences once.
        let options=AddWindowController(repository:repo,access:grant,defaults:prefs);defer{options.close()}
        options.window!.alphaValue=0;options.window!.orderFront(nil);options.model.setScope([paths[2]]);options.model.reload()
        try await wait{!options.model.busy && !options.model.entries.isEmpty}
        options.model.checked=GitPathSet([paths[2]]);var selected:[String]=[],accepts=0
        options.model.onAccepted={selected=$0;accepts += 1};options.model.close={}
        options.model.apply();prefs.set(false,forKey:"UseLibgit2");options.model.apply()
        try require(accepts==1 && selected==[paths[2]] && options.model.acceptedBackend?.requests(.add)==true,"Add dialog lost source default backend or exact accepted selection")
        options.close()
        let added=progress([paths[2]])
        var validation:CheckedContinuation<Void,Error>?
        defer{validation?.resume(throwing:OperationCancellationFailure.cancelled);validation=nil}
        added.model.validateMutation={_,_ in try await withCheckedThrowingContinuation{validation=$0}}
        let operation=Task{await added.model.run()};try await wait{validation != nil}
        prefs.set(0,forKey:"UseLibgit2_mask");validation?.resume();validation=nil;await operation.value
        added.model.validateMutation={_,_ in}
        try require(added.model.success && added.model.backend.requests(.add),"Held Add re-read changed backend preferences")
        try require(try await repo.run(["show",":"+paths[2]]).stdout==Data("CLEANED bytes\n".utf8),"Actual native libgit2 Add did not run clean filter")
        try Data("later disk bytes\n".utf8).write(to:root.appendingPathComponent(paths[2]))
        await added.model.changeMode(.executable)
        let modeText=try await repo.run(["ls-files","--stage","--",paths[2]]).text
        try require(added.model.success && modeText.hasPrefix("100755 "),"Add executable postaction lost mode")
        try require(try await repo.run(["show",":"+paths[2]]).stdout==Data("CLEANED bytes\n".utf8),"Mode postaction re-added changed disk contents")
        await added.model.changeMode(.symlink)
        let symlinkMode=try await repo.run(["ls-files","--stage","--",paths[2]]).text
        let symlinkBytes=try await repo.run(["show",":"+paths[2]]).stdout
        try require(added.model.success && symlinkMode.hasPrefix("120000 ") && symlinkBytes==Data("CLEANED bytes\n".utf8),"Add symlink postaction changed staged bytes or lost captured helper")
        let disabled=GitLibGit2Configuration(enabled:false,helperURL:root.appendingPathComponent("missing-helper"))
        let cli=progress([paths[0]],selection:disabled);await cli.model.run()
        try require(cli.model.success && !cli.model.backend.requests(.add),"Disabled Add unexpectedly required optional helper")
        // A required clean failure preserves the real index and publishes failure.
        try Data().write(to:fail);let before=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let failed=progress([paths[1]]);await failed.model.run()
        try require(!failed.model.success && !failed.model.information.isEmpty && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==before,"Required clean failure replaced index or lost diagnostic")
        try fm.removeItem(at:fail)
        // Optional filter failure retains input, as the source filter contract requires.
        _ = try await repo.run(["config","filter.qa.required","false"]);try Data().write(to:fail)
        let optional=progress([paths[1]]);await optional.model.run()
        let optionalBytes=try await repo.run(["-c","core.precomposeunicode=false","show",":"+paths[1]]).stdout
        try require(optional.model.success && optionalBytes==Data("working bytes\n".utf8),"Optional clean failure did not retain input")
        try fm.removeItem(at:fail);_ = try await repo.run(["config","filter.qa.required","true"])
        // Commit's explicit Add menu uses the same owned source progress dialog;
        // ordinary Commit staging remains a separate operation.
        let commitPaths=["z-commit-menu.txt","a-commit-menu.txt"]
        for path in commitPaths{try Data("working menu\n".utf8).write(to:root.appendingPathComponent(path))}
        prefs.set(true,forKey:"UseLibgit2");prefs.set(Int(GitLibGit2Operation.add.mask),forKey:"UseLibgit2_mask")
        let commit=CommitWindowController(repository:repo,access:grant,defaults:prefs);defer{commit.close()}
        commit.window!.alphaValue=0;commit.window!.orderFront(nil);commit.model.reload(paths:commitPaths)
        try await wait{!commit.model.busy && commitPaths.allSatisfy{path in commit.model.entries.contains{GitReferenceName.equal($0.path,path)}}}
        let menuRows=commitPaths.map{path in commit.model.entries.first{GitReferenceName.equal($0.path,path)}!}
        commit.model.addFiles(menuRows,mode:.normal);prefs.set(false,forKey:"UseLibgit2")
        try await wait{commit.addProgressController != nil}
        let child=commit.addProgressController!
        try require(child.window?.sheetParent === commit.window && child.window?.alphaValue==0 && child.model.backend.requests(.add) && child.model.preservePathOrder && !child.model.allowsCommit,"Commit Add lost owned sheet, captured backend, context order or Commit suppression")
        try await wait{!child.model.busy}
        try require(child.model.success && child.model.progress.rows.filter{$0.action=="Added"}.map{GitReferenceName($0.path)}==commitPaths.map{GitReferenceName($0)},"Commit Add lost exact display-order progress receipts")
        child.model.close();try await wait{commit.addProgressController==nil && !commit.model.busy && child.window?.sheetParent==nil && commit.window?.attachedSheet==nil && AddProgressWindowController.activeReleases==0}
        for path in commitPaths{let menuBytes=try await repo.run(["show",":"+path]).stdout
            try require(menuBytes==Data("CLEANED menu\n".utf8),"Commit explicit Add failed to clean selected bytes")}
        commit.close()
        // Forced native retirement waits for the real clean worker/process tree.
        try Data().write(to:hold);try? fm.removeItem(at:ready)
        let held=progress([paths[2]]),unchanged=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let heldTask=Task{await held.model.run()};try await wait{fm.fileExists(atPath:ready.path)}
        let pids=try String(contentsOf:ready,encoding:.utf8).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2,"Held clean filter did not report its shell and child PIDs")
        held.close();try require(AddProgressWindowModel.activeOperations>0 && AddProgressWindowController.activeReleases>0,"Forced Add close released live clean worker")
        await heldTask.value;try await wait{drained() && pids.allSatisfy{kill($0,0) != 0}}
        try require(held.model.retired && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==unchanged,"Cancelled Add replaced index or retained filter children")
        try fm.removeItem(at:hold)
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && fm.fileExists(atPath:log.path),"Native Add changed HEAD or never ran actual filter")
        owners.forEach{$0.close()};try await wait{drained()}
        print("PASS Add backend: captured source Add selection/default/disabled backend, actual clean bytes, mode-only postaction, required/optional failures and cancelled worker/index ownership")
    }
}
