// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum ReplayInspectionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Replay inspection native deadline at \(line)")
    }
    static func drained()->Bool {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activeColumnReads==0 && ResolveWindowModel.activeOperations==0 && MergeProgressWindowModel.activeOperations==0 && FetchProgressWindowModel.activeOperations==0 && SwitchProgressWindowModel.activeOperations==0 && SynchronizationProgressModel.activeOperations==0 && SVNWindowModel.activeOperations==0 && LocalGitCommandProgress.activeOperations==0}
    @MainActor final class Context {
        let root:URL,git:URL,helper:URL,editor:URL,prefs:UserDefaults,suite:String,wrapper:URL,calls:URL,hold:URL,ready:URL
        var cleanup:[()->Void]=[]
        init(root:URL,git:URL,helper:URL,editor:URL)throws {
            self.root=root;self.git=git;self.helper=helper;self.editor=editor
            suite="TurtleGit.ReplayInspection.QA."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress")
            prefs.set(true,forKey:MergeProgressWindowModel.conflictHintPreference)
            wrapper=root.appendingPathComponent("inspection-helper");calls=root.appendingPathComponent("inspection-helper.calls");hold=root.appendingPathComponent("inspection-helper.hold");ready=root.appendingPathComponent("inspection-helper.ready")
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="""
            #!/bin/sh
            printf '%s\\n' "$@" >> "$0.calls"
            if [ -f "$0.hold" ]; then
              IFS= read -r wanted < "$0.hold"
              for arg in "$@"; do
                if [ "$arg" = "$wanted" ]; then
                  /bin/sh -c 'while [ -f "$1" ]; do /bin/sleep 0.1; done' hold "$0.hold" &
                  child=$!
                  trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
                  printf '%s %s\\n' "$$" "$child" > "$0.ready.tmp"
                  /bin/mv "$0.ready.tmp" "$0.ready"
                  wait "$child"
                fi
              done
            fi
            exec \(quote(helper.path)) "$@"
            """
            try script.write(to:wrapper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        }
        func retire(){cleanup.reversed().forEach{$0()};cleanup=[];prefs.removePersistentDomain(forName:suite)}
        func use(_ enabled:Bool){prefs.set(enabled,forKey:"UseLibgit2");prefs.set((UInt32(1)<<7)|(1<<12)|(1<<13)|(1<<17),forKey:"UseLibgit2_mask")}
        func clear()throws{try Data().write(to:calls)}
        func log()throws->String{FileManager.default.fileExists(atPath:calls.path) ? try String(contentsOf:calls):""}
        func owns(_ repo:GitRepository)->GitRepository {GitRepository(root:repo.root,executable:repo.executable,askpass:repo.askpass,diffDetection:repo.diffDetection,libgit2Configuration:.init(helperURL:wrapper))}
        func fixture(_ name:String,conflict:Bool=false)async throws -> GitRepository {
            let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo=GitRepository(root:path,executable:git,libgit2Configuration:.init(enabled:false))
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Inspection QA"),("user.email","inspection@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            for file in ["one","two"]{try Data("base\n".utf8).write(to:path.appendingPathComponent(file))}
            try await repo.stage(["one","two"]);_ = try await repo.commit(message:"base")
            _ = try await repo.run(["checkout","-b","side"])
            if conflict {for file in ["one","two"]{try Data("theirs\n".utf8).write(to:path.appendingPathComponent(file))};try await repo.stage(["one","two"])}
            else {try Data("side\n".utf8).write(to:path.appendingPathComponent("side"));try await repo.stage(["side"])}
            _ = try await repo.commit(message:"side")
            _ = try await repo.run(["checkout","main"])
            if conflict {for file in ["one","two"]{try Data("mine\n".utf8).write(to:path.appendingPathComponent(file))};try await repo.stage(["one","two"])}
            else {try Data("main\n".utf8).write(to:path.appendingPathComponent("main"));try await repo.stage(["main"])}
            _ = try await repo.commit(message:"main")
            return repo
        }
        func conflicted(_ name:String)async throws->GitRepository {
            let repo=try await fixture(name,conflict:true)
            let result=try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
            let conflicts=try await repo.conflicts()
            try require(result.exitCode==1 && conflicts.count==2,"Private conflict fixture failed")
            return repo
        }
        func rebase(_ repo:GitRepository)->RebaseWindowController {
            let owner=RebaseWindowController(repository:owns(repo),access:RepositoryAccessLease(url:repo.root),preferences:prefs)
            cleanup.append{owner.model.retire();owner.close()};owner.model.editorExecutable=editor;owner.window?.orderFront(nil);return owner
        }
        func resolve(_ repo:GitRepository)->ResolveWindowController {
            let owner=ResolveWindowController(repository:owns(repo),access:RepositoryAccessLease(url:repo.root),paths:[],preferences:prefs)
            cleanup.append{owner.model.invalidate();owner.close()};owner.window?.orderFront(nil);return owner
        }
    }
    static func verify(caseName:String,root:URL,git:URL,helper:URL,editor:URL)async throws {
        let context=try Context(root:root,git:git,helper:helper,editor:editor)
        defer{context.retire()}
        switch caseName {
        case "replay":try await replay(context)
        case "resolve":try await resolve(context)
        case "completion":try await completion(context)
        case "fetch":try await fetch(context)
        case "svn":try await svn(context)
        case "ownership":try await ownership(context)
        default:throw Failure(description:"Unknown native inspection case")
        }
    }
    static func replay(_ c:Context)async throws {
        for enabled in [false,true] {
            let repo=try await c.fixture("replay-\(enabled)"),head=try await repo.run(["rev-parse","HEAD"]).stdout
            c.use(enabled);try c.clear();let owner=c.rebase(repo),model=owner.model
            model.load(upstream:"refs/heads/side");try await wait{!model.busy && !model.loadingPlan && model.plan != nil}
            try require(model.plan?.disposition == .ready && (try c.log()).contains("turtlegit-merge-base")==enabled,"Rebase plan selected wrong inspection engine: \(model.error ?? "none")")
            let comparison=RevisionComparisonWindowModel(repository:c.owns(repo),access:RepositoryAccessLease(url:repo.root),from:.revision("HEAD~1"),to:.revision("side"),preferences:c.prefs)
            c.cleanup.append{comparison.invalidate()};comparison.options.commonAncestor=true;try c.clear();comparison.load();try await wait{!comparison.busy}
            try require(comparison.error==nil && comparison.snapshot?.files.map(\.path)==["side"] && (try c.log()).contains("turtlegit-merge-base")==enabled,"Changed Files common-ancestor option lost source7 or diff result")
            try Data("dirty\n".utf8).write(to:repo.root.appendingPathComponent("one"));var prompts=0
            model.chooseStashBeforeReplay={prompts += 1;c.use(!enabled);return false}
            model.execute("start");try await wait{!model.busy && RebaseWindowModel.activeReplayOperations==0}
            let after=try await repo.run(["rev-parse","HEAD"]).stdout,untracked=try await repo.run(["status","--porcelain"]).text
            try require(prompts==1 && after==head && untracked.contains("one") && (try c.log()).contains("turtlegit-check-clean")==enabled,"Dirty replay readiness mutated repository or changed accepted engine")
            model.retire();owner.close()
        }
        // Source1568 ordinary Edit uses workdir-only readiness. Staged-only
        // edits belong to the normal amend; unstaged edits need checked Commit.
        for enabled in [false,true] {for stagedOnly in [true,false] {
            let repo=try await c.fixture("edit-\(enabled)-\(stagedOnly)")
            var options=RebaseOptions();options.branch="refs/heads/main";options.upstream="refs/heads/side"
            var plan=try await repo.rebasePlan(options)
            try require(plan.entries.count==1,"Edit readiness fixture expected one replay occurrence")
            plan.entries[0].action = .edit
            let stopped=try await repo.startRebase(plan,editorExecutable:c.editor)
            try require(stopped.state.isEditPause,"Actual Git did not stop for Edit")
            c.use(enabled);let owner=c.rebase(repo),model=owner.model
            model.load();try await wait{!model.busy && model.state?.isEditPause==true && RebaseWindowModel.activePreparationReads==0}
            let paused=try await repo.rebaseCommit("HEAD"),payload=Data((stagedOnly ? "approved staged edit\n":"unselected worktree edit\n").utf8)
            try payload.write(to:repo.root.appendingPathComponent("one"))
            if stagedOnly {try await repo.stage(["one"])}
            // Source readiness may refresh index stat data; compare exact stage records.
            let index=try await repo.run(["ls-files","--stage","-z"]).stdout
            var children=0,selection:CommitWindowModel?
            model.configureCommitSelection={children += 1;selection=$0}
            let draft=stagedOnly ? "Approved staged-only amendment":"Unstaged edit requires selection"
            model.amendMessage=draft;try c.clear()
            var readinessLog:String?
            if enabled {
                try? FileManager.default.removeItem(at:c.ready)
                try Data("turtlegit-check-clean\n".utf8).write(to:c.hold)
            }
            model.request("continue")
            if enabled {
                try await wait{FileManager.default.fileExists(atPath:c.ready.path) && model.preparingMessageSelection}
                readinessLog=try c.log()
                try require(readinessLog?.contains("turtlegit-check-clean")==true,"Held Edit readiness did not request selected12")
                try c.clear();c.use(false);try FileManager.default.removeItem(at:c.hold)
            }
            if stagedOnly {
                try await wait{!model.busy && !model.active && RebaseWindowModel.activeReplayOperations==0 && RebaseWindowModel.activePreparationReads==0}
                let amended=try await repo.rebaseCommit("HEAD"),bytes=try await repo.run(["show","HEAD:one"]).stdout
                let work=try Data(contentsOf:repo.root.appendingPathComponent("one")),status=try await repo.status(refreshIndex:false)
                try require(children==0 && owner.window?.attachedSheet==nil && amended.subject==draft && amended.parents==paused.parents && bytes==payload && work==payload && status.isEmpty,"Staged-only Edit opened extra Commit selection or omitted approved index bytes: \(model.error ?? model.output)")
            } else {
                try await wait{selection?.canCommit==true && model.selectingSplit && !model.preparingMessageSelection && owner.window?.attachedSheet != nil}
                try require(children==1 && selection?.amend==true && selection?.replaySplit?.conflictRecovery==true && selection?.message==draft && owner.window?.attachedSheet?.alphaValue==0,"Unstaged Edit did not open the owned hidden checked-amend dialog")
                let still=try await repo.rebaseCommit("HEAD"),bytes=try Data(contentsOf:repo.root.appendingPathComponent("one"))
                try require(still.hash==paused.hash && bytes==payload,"Edit handoff mutated the unapproved worktree before Commit")
                selection?.close();try await wait{!model.selectingSplit && !model.busy && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeReplayOperations==0}
                let canceled=try await repo.rebaseState(),after=try await repo.rebaseCommit("HEAD"),afterIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
                try require(canceled.isEditPause && canceled.split==nil && after.hash==paused.hash && afterIndex==index && model.amendMessage==draft,"Canceling Edit selection lost paused state/index/draft")
                model.retire();owner.close();_ = try await repo.abortRebase()
            }
            let followingLog=try c.log()
            try require((readinessLog ?? followingLog).contains("turtlegit-check-clean")==enabled,"Edit readiness changed accepted source12 engine while pending")
            if enabled {try require(followingLog.contains("turtlegit-check-conflicts"),"Edit continuation/handoff switched selected13 off after held12 completed")}
            model.retire();owner.close()
        }}
    }
    static func resolve(_ c:Context)async throws {
        for enabled in [false,true] {for choice in [ResolveChoice.mine,.theirs,.current] {
            let repo=try await c.conflicted("resolve-\(enabled)-\(choice.rawValue)"),head=try await repo.run(["rev-parse","HEAD"]).stdout
            c.use(enabled);let owner=c.resolve(repo),model=owner.model;model.load();try await wait{!model.busy && model.entries.count==2}
            let original=try Data(contentsOf:repo.root.appendingPathComponent("one"));try c.clear();model.apply(model.entries,using:choice)
            try await wait{!model.busy && ResolveWindowModel.activeOperations==0}
            let actual=try Data(contentsOf:repo.root.appendingPathComponent("one")),pending=try await repo.run(["ls-files","-u"]).stdout,after=try await repo.run(["rev-parse","HEAD"]).stdout
            let expected=choice == .current ? original:Data((choice == .mine ? "mine\n":"theirs\n").utf8)
            try require(model.success && actual==expected && pending.isEmpty && head==after,"Native Resolve changed wrong stage or committed: \(model.output)")
            try require((try c.log()).contains("turtlegit-conflict-info")==((enabled && choice != .current)),"Current used17 or Mine/Theirs omitted accepted engine")
            model.invalidate();owner.close()
        }}
        // Missing requested rows are source Skip; the unchanged next row resolves.
        let repo=try await c.conflicted("resolve-skip");c.use(true);let owner=c.resolve(repo),model=owner.model
        model.load();try await wait{!model.busy && model.entries.count==2};let old=model.entries
        _ = try await repo.resolveConflicts([old[0]],using:.current);try c.clear();model.apply(old,using:.theirs)
        try await wait{!model.busy && ResolveWindowModel.activeOperations==0}
        try require(model.success && model.progress.rows.contains{$0.action=="Skip" && $0.path==old[0].path} && model.progress.rows.contains{$0.action=="Resolved" && $0.path==old[1].path},"Missing-stage Skip was lost in actual progress rows")
        let resolved=try await repo.run(["ls-files","-u"]).stdout;try require(resolved.isEmpty,"Skipped and resolved batch left unexpected conflict")
        owner.close()
    }
    static func completion(_ c:Context)async throws {
        for enabled in [false,true] {
            let repo=try await c.fixture("merge-\(enabled)",conflict:true);c.use(enabled);try c.clear()
            var options=MergeOptions();options.revision="refs/heads/side"
            let merge=MergeProgressWindowModel(repository:c.owns(repo),access:RepositoryAccessLease(url:repo.root),options:options,target:.branch,showStashPop:false,preferences:c.prefs)
            c.cleanup.append{merge.invalidate()};merge.presentConflictHint={false};await merge.run()
            try require(!merge.success && merge.postActions.contains(.resolve) && merge.postActions.contains(.commit) && !merge.postActions.contains(.mergeUnrelated),"Merge conflict post-actions wrong: \(merge.output)")
            try require((try c.log()).contains("turtlegit-check-conflicts")==enabled && (try c.log()).contains("turtlegit-merge-base")==enabled,"Merge completion lost selected13/7")
            // Dismissal is a new accepted action, so its fresh conflict read
            // captures the then-current preference independently of completion.
            var dismissed=0,aborts=0;merge.close={dismissed += 1};merge.onAbortRequested={aborts += 1}
            c.use(!enabled);try c.clear();merge.cancelResult();try await wait{!merge.hasPendingWork && !merge.busy}
            try require(dismissed==1 && aborts==1 && (try c.log()).contains("turtlegit-check-conflicts")==(!enabled),"Fresh dismissal inspection failed its separate capture boundary")
            c.use(enabled)
            _ = try await repo.run(["merge","--abort"])
            // Switch-with-merge applies real checkout and then selected13 inspection.
            try Data("local edit\n".utf8).write(to:repo.root.appendingPathComponent("one"));var checkout=CheckoutOptions();checkout.revision="refs/heads/side";checkout.merge=true
            let switching=SwitchProgressWindowModel(repository:c.owns(repo),access:RepositoryAccessLease(url:repo.root),options:checkout,preferences:c.prefs)
            c.cleanup.append{switching.invalidate()};try c.clear();await switching.run()
            try require(switching.postActions.contains(.resolve) && (try c.log()).contains("turtlegit-check-conflicts")==enabled,"Switch completion lost selected conflict inspection: \(switching.output)")
            let conflicts=try await repo.conflicts();try require(!conflicts.isEmpty,"Switch-with-merge did not retain actual unmerged stages")
            // Sync's merge-progress owner uses the same accepted engine snapshot.
            let state=try await repo.synchronizationRebaseState(target:"refs/heads/main")
            let sync=SynchronizationProgressModel(repository:c.owns(repo),operation:.merge(state),cancellation:OperationCancellation(),preferences:c.prefs,access:RepositoryAccessLease(url:repo.root))
            c.cleanup.append{sync.invalidate()};try c.clear();sync.start();try await wait{!sync.busy && SynchronizationProgressModel.activeOperations==0}
            try require(!sync.success && sync.recoveryAvailable && (try c.log()).contains("turtlegit-check-conflicts")==enabled,"Sync failed merge recovery omitted source13")
        }
    }
    static func fetch(_ c:Context)async throws {
        for enabled in [false,true] {
            let source=try await c.fixture("fetch-source-\(enabled)"),clone=c.root.appendingPathComponent("fetch-clone-\(enabled)")
            _ = try await source.run(["clone","--",source.root.path,clone.path])
            let local=GitRepository(root:clone,executable:c.git,libgit2Configuration:.init(enabled:false))
            _ = try await local.run(["config","user.name","Inspection QA"]);_ = try await local.run(["config","user.email","inspection@example.invalid"])
            try Data("remote change\n".utf8).write(to:source.root.appendingPathComponent("remote"));try await source.stage(["remote"]);_ = try await source.commit(message:"remote next")
            let expected=try await source.run(["rev-parse","HEAD"]).stdout
            c.use(enabled);try c.clear();var options=FetchOptions();options.remote="origin";options.branch="main"
            let model=FetchProgressWindowModel(repository:c.owns(local),access:RepositoryAccessLease(url:clone),options:options,preferences:c.prefs,rebaseMode:.manual)
            c.cleanup.append{model.invalidate()};var prompts=[FetchRebasePrompt]()
            model.presentRebasePrompt={prompt in prompts.append(prompt);c.use(!enabled);return .init(value:prompt == .fastForward ? 1:6,suppress:false)}
            await model.run();let actual=try await local.run(["rev-parse","HEAD"]).stdout
            try require(model.success && actual==expected && prompts.contains(.fastForward) && (try c.log()).contains("turtlegit-merge-base")==enabled,"Fetch/Rebase fast-forward lost captured12 or failed mutation: \(model.output)")
        }
    }
    static func svn(_ c:Context)async throws {
        for enabled in [false,true] {
            let repo=try await c.fixture("svn-\(enabled)");_ = try await repo.run(["config","svn-remote.svn.url","file:///private-uncontacted"]);_ = try await repo.run(["config","svn-remote.svn.fetch",":refs/remotes/git-svn"])
            try FileManager.default.createDirectory(at:repo.root.appendingPathComponent(".git/svn"),withIntermediateDirectories:true)
            try Data().write(to:repo.root.appendingPathComponent(".git/svn/.metadata"))
            let adapter=c.root.appendingPathComponent("svn-version-\(enabled)")
            func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
            let script="#!/bin/sh\nfor value in \"$@\"; do if [ \"$value\" = svn ]; then printf 'git-svn version private fixture\\n'; exit 0; fi; done\nexec "+quote(c.git.path)+" \"$@\"\n"
            try script.write(to:adapter,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adapter.path)
            let wrapped=GitRepository(root:repo.root,executable:adapter,libgit2Configuration:.init(helperURL:c.wrapper));try Data("dirty SVN\n".utf8).write(to:repo.root.appendingPathComponent("one"))
            let head=try await repo.run(["rev-parse","HEAD"]).stdout;c.use(enabled);try c.clear()
            let model=SVNWindowModel(repository:wrapped,access:RepositoryAccessLease(url:repo.root),operation:.rebase,preferences:c.prefs)
            c.cleanup.append{model.retire()};var questions=0;model.confirmStash={questions += 1;c.use(!enabled);return false};model.load();try await wait{!model.busy && SVNWindowModel.activeOperations==0}
            let after=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(questions==1 && head==after && model.status.contains("Aborted") && (try c.log()).contains("turtlegit-check-clean")==enabled,"SVN readiness lost12 or ignored owned decline")
        }
    }
    static func ownership(_ c:Context)async throws {
        let repo=try await c.fixture("held-replay");c.use(true);try Data("turtlegit-merge-base\n".utf8).write(to:c.hold)
        let owner=c.rebase(repo);owner.model.load(upstream:"refs/heads/side")
        try await wait{FileManager.default.fileExists(atPath:c.ready.path) && owner.model.busy}
        let pids=try String(contentsOf:c.ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Inspection helper lost Quit lifetime")
        owner.model.retire();owner.close();try await wait{drained() && pids.allSatisfy{kill($0,0) != 0}}
        try require(owner.model.plan==nil,"Retired readiness published late plan")
        try FileManager.default.removeItem(at:c.hold)
        // Late read callback cannot replace retired native session state.
        let late=c.rebase(repo);var reply:CheckedContinuation<RebaseSessionSnapshot,Error>?
        defer{reply?.resume(throwing:OperationCancellationFailure.cancelled)}
        late.model.readSession={_,_ in try await withCheckedThrowingContinuation{reply=$0}};late.model.load()
        try await wait{reply != nil};late.model.retire();late.close();let snapshot=try await repo.rebaseSessionSnapshot()
        reply?.resume(returning:snapshot);reply=nil;try await wait{drained()}
        try require(late.model.plan==nil,"Retired session callback replaced native state")
        // Fresh post-failure inspection is independent of the canceled command,
        // but still belongs to the window and is canceled by forced retirement.
        let resultOwner=c.rebase(repo);resultOwner.model.load(upstream:"refs/heads/side")
        try await wait{!resultOwner.model.busy && resultOwner.model.plan != nil && !resultOwner.model.loadingPlan}
        try Data("dirty result inspection\n".utf8).write(to:repo.root.appendingPathComponent("one"))
        var resultReply:CheckedContinuation<RebaseSessionSnapshot,Error>?,inspection:OperationCancellation?
        defer{resultReply?.resume(throwing:OperationCancellationFailure.cancelled)}
        resultOwner.model.chooseStashBeforeReplay={false}
        resultOwner.model.readSession={_,token in inspection=token;return try await withCheckedThrowingContinuation{resultReply=$0}}
        resultOwner.model.execute("start");try await wait{resultReply != nil}
        try require(inspection?.isCancelled==false && RebaseWindowModel.activeReplayOperations>0,"Fresh result inspection lost owned lifetime")
        resultOwner.model.retire();resultOwner.close();try require(inspection?.isCancelled==true,"Forced retirement did not cancel fresh result inspection")
        resultReply?.resume(returning:snapshot);resultReply=nil;try await wait{drained()}
    }
}
