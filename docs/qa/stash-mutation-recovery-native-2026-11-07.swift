// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@MainActor enum StashMutationRecoveryVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ text:String)throws{if !value{throw Failure(description:text)}}
    static func wait(_ text:String,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:text)}
    static func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    final class Gate {
        var entered=false
        private var reply:CheckedContinuation<Void,Never>?
        func wait()async{entered=true;await withCheckedContinuation{reply=$0}}
        func open(){let done=reply;reply=nil;done?.resume()}
    }
    static func repository(_ name:String)async throws->GitRepository {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true).appendingPathComponent(name,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:URL(fileURLWithPath:CommandLine.arguments[2]),askpass:nil,libgit2Configuration:.init(enabled:false))
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Stash mutation QA"),("user.email","stash@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:folder.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        return repo
    }
    static func verifySave()async throws {
        let repo=try await repository("save-recovery"),base=repo.root.deletingLastPathComponent()
        let suite="TurtleGit.StashMutation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite)}
        let wrapper=base.appendingPathComponent("stash-lookup-git")
        let script="""
        #!/bin/sh
        task_command=
        task_lookup=no
        task_push=no
        for task_argument in "$@"; do
          [ "$task_argument" = refs/stash ] && task_lookup=yes
          [ "$task_argument" = push ] && task_push=yes
        done
        task_parse() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -C|-c|--git-dir|--work-tree|--config-env) shift 2;;
              --) shift;task_command=${1-};return;;
              -*) shift;;
              *) task_command=$1;return;;
            esac
          done
        }
        task_parse "$@"
        if [ "$task_lookup" = yes ] && [ -f "$0.before" ]; then printf 'QA stash prelookup refused\\n' >&2;exit 73;fi
        if [ "$task_lookup" = yes ] && [ -f "$0.pushed" ]; then
          if [ -f "$0.after" ]; then printf 'QA stash postlookup refused\\n' >&2;exit 74;fi
          if [ -f "$0.hold" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null;wait "$task_child" 2>/dev/null;exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started.tmp"
            mv "$0.started.tmp" "$0.started"
            wait "$task_child"
          fi
        fi
        if [ "$task_command" = stash ] && [ "$task_push" = yes ]; then
          printf 'push\\n' >> "$0.pushes"
          \(quote(repo.executable.path)) "$@"
          task_status=$?
          [ "$task_status" = 0 ] && touch "$0.pushed"
          exit "$task_status"
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let captured=GitRepository(root:repo.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        var owners=[StashSaveProgressWindowController]()
        defer{owners.forEach{$0.close()}}
        func flag(_ suffix:String)->URL{URL(fileURLWithPath:wrapper.path+suffix)}
        func make()->StashSaveProgressWindowController {
            var options=StashSaveOptions();options.message="native mutation receipt"
            let model=StashSaveProgressWindowModel(repository:captured,access:nil,options:options,followUp:.init(),preferences:prefs)
            let owner=StashSaveProgressWindowController(model:model);owners.append(owner);owner.window?.alphaValue=0;owner.window?.orderFront(nil);return owner
        }
        func dirty(_ text:String)throws{try Data(text.utf8).write(to:repo.root.appendingPathComponent("file"))}
        try dirty("prelookup must preserve\n")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),working=try Data(contentsOf:repo.root.appendingPathComponent("file"))
        try Data().write(to:flag(".before"))
        let refused=make();var refusedMutations=0
        refused.model.onMutationStopped={_ in refusedMutations += 1};refused.model.start()
        try await wait("Prelookup failure did not drain"){!refused.model.hasPendingWork && !refused.model.busy}
        try require(refusedMutations==0 && !refused.model.commandSucceeded && refused.model.result==nil && refused.model.output.contains("QA stash prelookup refused") && !FileManager.default.fileExists(atPath:flag(".pushes").path),"Prelookup error launched stash or fabricated mutation receipt")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:repo.root.appendingPathComponent("file")))==working,"Prelookup refusal changed HEAD/index/worktree")
        refused.close();try FileManager.default.removeItem(at:flag(".before"))

        try Data().write(to:flag(".after"))
        let incomplete=make();var mutations=0,stoppedText="",drainedAtMutation=false
        incomplete.model.onMutationStopped={ [weak model=incomplete.model] text in mutations += 1;stoppedText=text;drainedAtMutation = model?.hasPendingWork==false && LocalGitCommandProgress.activeOperations==0}
        incomplete.model.start();try await wait("Postlookup failure did not notify after drain"){mutations==1 && !incomplete.model.hasPendingWork}
        try require(drainedAtMutation && incomplete.model.commandSucceeded && incomplete.model.currentWork=="Success" && incomplete.model.completionRange != nil && incomplete.model.result==nil && !incomplete.model.postActions.contains(.pop) && !incomplete.model.postActions.contains(.apply),"Successful stash command lost footer, invented stash identity/actions or notified before drain")
        try require(incomplete.model.output.contains("QA stash postlookup refused") && stoppedText.contains("Saved working directory"),"Postlookup warning replaced original successful command output")
        let saved=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
        try require(!saved.isEmpty && (try String(contentsOf:repo.root.appendingPathComponent("file"),encoding:.utf8))=="base\n","Actual successful stash was hidden by failed identity lookup")
        incomplete.model.start();try require(mutations==1,"Repeated Start republished mutation receipt")
        incomplete.close();try FileManager.default.removeItem(at:flag(".after"));try FileManager.default.removeItem(at:flag(".pushed"))

        try dirty("retired actual stash\n");try Data().write(to:flag(".hold"))
        let retired=make();var originalNotifications=0,replacementNotifications=0,lateUI=0
        retired.model.onMutationStopped={_ in originalNotifications += 1;precondition(!retired.model.hasPendingWork)}
        retired.model.onFinished={_,_ in lateUI += 1};retired.model.start()
        try await wait("Actual stash post-read did not enter held process"){FileManager.default.fileExists(atPath:flag(".started").path) && retired.model.commandFinished}
        let pids=try String(contentsOf:flag(".started"),encoding:.utf8).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        try require(pids.count==2 && pids.allSatisfy{kill($0,0)==0},"Held post-read process receipt missing")
        retired.model.onMutationStopped={_ in replacementNotifications += 1}
        let beforeOutput=retired.model.output;retired.close()
        try require(retired.model.hasPendingWork && originalNotifications==0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed actual stash work lost ownership before drain")
        try await wait("Retired actual stash did not release captured mutation receipt"){originalNotifications==1 && !retired.model.hasPendingWork && pids.allSatisfy{kill($0,0) != 0}}
        try require(replacementNotifications==0 && lateUI==0 && retired.model.result==nil && retired.model.output==beforeOutput,"Retired stash republished UI or replaced captured refresh callback")
        let retiredHash=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
        try require(retiredHash != saved && (try String(contentsOf:repo.root.appendingPathComponent("file"),encoding:.utf8))=="base\n","Closed presentation implied an actual stash mutation rolled back")
        try require(try String(contentsOf:flag(".pushes"),encoding:.utf8)=="push\npush\n","Recovery repeated the actual stash command")
        print("PASS Stash mutation recovery: prelookup refusal/no mutation; actual push success with failed identity read retains footer/output and refresh/no invented Apply; retired actual command refresh captured once after full process drain without late UI")
    }
    static func verifyRestore()async throws {
        let repo=try await repository("restore-mutation")
        try Data("saved changes\n".utf8).write(to:repo.root.appendingPathComponent("file"));_=try await repo.saveStash(.init())
        let saved=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
        let suite="TurtleGit.StashRestoreMutation."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"ConfirmKillProcess")
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=StashRestoreWindowController(repository:repo,access:nil,pop:false,showChanges:0,preferences:prefs)
        owner.window?.alphaValue=0;owner.window?.orderFront(nil);defer{owner.close()}
        let gate=Gate();defer{gate.open()}
        var mutations=0,replacement=0,changed=0,closed=0,capturedBackend:GitLibGit2Configuration?
        owner.model.restoreStreaming={pop,reference,token,backend,emit,receipt in
            capturedBackend=backend
            let actual=try await repo.restoreStash(pop:pop,reference:reference,cancellation:token,backend:backend,onOutput:emit,onCommandFinished:receipt)
            await gate.wait();try token.check();return actual
        }
        owner.onMutationStopped={_ in mutations += 1;precondition(StashRestoreWindowModel.activeOperations==0 && LocalGitCommandProgress.activeOperations==0)}
        owner.onChanged={_ in changed += 1};owner.onClosed={closed += 1};owner.start()
        try await wait("Actual Apply did not reach retained completion boundary"){gate.entered}
        try require(capturedBackend?.enabled==false && (try String(contentsOf:repo.root.appendingPathComponent("file"),encoding:.utf8))=="saved changes\n","Restore lost captured backend or actual Apply mutation")
        prefs.set(true,forKey:"UseLibgit2");owner.onMutationStopped={_ in replacement += 1};owner.close()
        try require(closed==0 && mutations==0 && StashRestoreWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed Restore released its actual worker or notification early")
        gate.open();try await wait("Closed Restore did not notify/drain"){mutations==1 && closed==1 && StashRestoreWindowModel.activeOperations==0 && StashWindowController.activeChildReleases==0}
        try require(replacement==0 && changed==0 && owner.model.result==nil && owner.model.error==nil && owner.model.prompt==nil,"Retired Apply published late success/question/error")
        try require(try await repo.run(["rev-parse","--verify","refs/stash"]).stdout==saved,"Retired Apply dropped its actual saved stash")
        let refused=StashRestoreWindowModel(repository:repo,access:nil,pop:false,reference:"bad\0reference",preferences:prefs)
        var refusedEvents=0;refused.onMutationStopped={_ in refusedEvents += 1};refused.start()
        try await wait("Invalid restore reference did not drain"){StashRestoreWindowModel.activeOperations==0 && !refused.busy}
        try require(refusedEvents==0 && refused.result==nil && refused.error != nil,"Invalid prelaunch Restore fabricated mutation receipt")
        refused.invalidate()
        print("PASS Stash Restore mutation: actual Apply/backend capture; immutable refresh notification after closed worker drain, no late UI, unchanged saved stash; prelaunch invalid reference has no mutation notification")
    }
    static func verifyReplay()async throws {
        let repo=try await repository("replay-stash-identity")
        let base=try await repo.rebaseCommit("HEAD").hash
        _=try await repo.run(["checkout","-b","upstream"])
        try Data("upstream\n".utf8).write(to:repo.root.appendingPathComponent("upstream"));try await repo.stage(["upstream"]);_=try await repo.commit(message:"upstream")
        _=try await repo.run(["checkout","-b","topic",base])
        try Data("topic\n".utf8).write(to:repo.root.appendingPathComponent("topic"));try await repo.stage(["topic"]);_=try await repo.commit(message:"topic")
        let wrapper=repo.root.deletingLastPathComponent().appendingPathComponent("replay-stash-git")
        let script="""
        #!/bin/sh
        task_lookup=no;task_push=no;task_stash=no
        for task_argument in "$@";do
          [ "$task_argument" = refs/stash ] && task_lookup=yes
          [ "$task_argument" = stash ] && task_stash=yes
          [ "$task_argument" = push ] && task_push=yes
          if [ "$task_argument" = pop ] || [ "$task_argument" = apply ];then printf '%s\\n' "$task_argument" >> "$0.restores";fi
        done
        if [ "$task_lookup" = yes ] && [ -f "$0.pushed" ];then printf 'QA Replay stash identity unreadable\\n' >&2;exit 74;fi
        if [ "$task_stash" = yes ] && [ "$task_push" = yes ];then
          printf 'push\\n' >> "$0.pushes"
          \(quote(repo.executable.path)) "$@";task_status=$?
          [ "$task_status" = 0 ] && touch "$0.pushed"
          exit "$task_status"
        fi
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let captured=GitRepository(root:repo.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false))
        let suite="TurtleGit.ReplayStashIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar")
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=RebaseWindowController(repository:captured,access:nil,preferences:prefs);defer{owner.close()}
        owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        let model=owner.model;model.load(upstream:"upstream")
        try await wait("Replay plan did not become ready"){!model.busy && model.canStart}
        try Data("unsaved user change\n".utf8).write(to:repo.root.appendingPathComponent("file"))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        model.chooseStashBeforeReplay={true};model.execute("start")
        try await wait("Replay failed stash identity did not settle"){!model.busy && RebaseWindowModel.activeReplayOperations==0 && model.unresolvedReplayStash != nil}
        try require(model.hasReplayStash && !model.canStart && !model.active && model.unresolvedReplayStash?.command.exitCode==0 && model.error?.contains("QA Replay stash identity unreadable")==true,"Replay lost actual stash obligation or allowed Start with unknown stash identity")
        let stash=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
        model.execute("start");await Task.yield()
        try require(try String(contentsOf:URL(fileURLWithPath:wrapper.path+".pushes"),encoding:.utf8)=="push\n","Replay retry stashed a second time while identity unresolved")
        var closes=0,restores=0,reviews=0
        model.close={closes += 1};model.restoreReplayStash={_ in restores += 1}
        model.chooseUnresolvedReplayStash={2};model.finishReplay()
        try await wait("Cancel unknown stash review did not settle"){!model.busy && RebaseWindowModel.activeStashRestorations==0}
        try require(closes==0 && model.hasReplayStash && model.unresolvedReplayStash != nil && restores==0,"Cancel discarded unknown stash obligation or popped unknown identity")
        model.revisionMenuLog.onContainingLog={revision,_,_ in if revision=="refs/stash"{reviews += 1}}
        model.chooseUnresolvedReplayStash={0};model.finishReplay()
        try await wait("Unknown stash review did not settle"){!model.busy && RebaseWindowModel.activeStashRestorations==0}
        try require(reviews==1 && closes==0 && model.hasReplayStash && restores==0,"Review lost stash obligation or restored unknown identity")
        model.chooseUnresolvedReplayStash={1};model.finishReplay()
        try await wait("Explicit Leave stash did not finish"){closes==1 && !model.busy && RebaseWindowModel.activeStashRestorations==0}
        try require(!model.hasReplayStash && model.unresolvedReplayStash==nil && restores==0 && !FileManager.default.fileExists(atPath:wrapper.path+".restores"),"Explicit Leave ran automatic Pop/Apply or retained fulfilled obligation")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterStash=try await repo.run(["rev-parse","--verify","refs/stash"]).stdout
        try require(afterHead==head && afterStash==stash && (try String(contentsOf:repo.root.appendingPathComponent("file"),encoding:.utf8))=="base\n","Unknown stash recovery mutated replay HEAD or discarded saved user changes")
        print("PASS Replay stash identity: real successful push plus failed lookup blocks Start/retry; Cancel/Review retain obligation, explicit Leave preserves stash without automatic Pop/Apply")
    }

}
