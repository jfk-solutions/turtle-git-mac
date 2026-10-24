// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

extension NSWindow {
    @objc func lookupFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func lookupOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;lookupOrder(place,relativeTo:number)}
}
@MainActor @main struct RevisionLookupVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Revision lookup native timeout at \(line)")}
    static func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    static func drained()->Bool{BranchTagWindowModel.activeReads==0 && BranchTagWindowModel.activeCreations==0 && SwitchWindowModel.activeReads==0 && SwitchProgressWindowModel.activeOperations==0 && RebaseWindowModel.activePreparationReads==0 && PushWindowModel.activePreparationReads==0 && PushWindowModel.activePushWorkflows==0 && FetchWindowModel.activePreparationReads==0 && FetchProgressWindowModel.activeOperations==0 && PullProgressWindowModel.activeOperations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.RevisionLookup.Native."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var remote:URL{base.appendingPathComponent("origin.git")}
        var trace:URL{base.appendingPathComponent("lookup-trace")};var gitTrace:URL{base.appendingPathComponent("git-trace")}
        var helper:URL{base.appendingPathComponent("lookup-helper")};var wrapper:URL{base.appendingPathComponent("git-wrapper")}
        var postPullFailure:URL{base.appendingPathComponent("post-pull-failure")}
        var pullHeadReceipt:URL{base.appendingPathComponent("post-pull-head")};var pullIndexReceipt:URL{base.appendingPathComponent("post-pull-index")}
        var hold:URL{base.appendingPathComponent("hold")};var started:URL{base.appendingPathComponent("started")};var release:URL{base.appendingPathComponent("release")};var malformed:URL{base.appendingPathComponent("malformed")}
        var cli:GitRepository!,repo:GitRepository!,origin:GitRepository!,head="",tree="",blob=""
        var owners:[NSWindowController]=[],workspace:RepositoryModel?,host:NSWindow?
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(true,forKey:"UseLibgit2");prefs.set(0,forKey:"UseLibgit2_mask");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"AskSetTrackedBranch");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(false,forKey:"EnableLogCache")}
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.window?.isReleasedWhenClosed=false;owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.window?.orderFront(nil);return owner}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            cli=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await cli.run(["init","--template=","-b","main"])
            for(k,v)in[("user.name","Revision Lookup QA"),("user.email","lookup@example.invalid"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true"),("commit.gpgsign","false")] {_=try await cli.run(["config",k,v])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await cli.stage(["."]);_=try await cli.commit(message:"base")
            head=try await cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);tree=try await cli.run(["rev-parse","HEAD^{tree}"]).text.trimmingCharacters(in:.newlines);blob=try await cli.run(["rev-parse","HEAD:file.txt"]).text.trimmingCharacters(in:.newlines)
            try FileManager.default.createDirectory(at:remote,withIntermediateDirectories:true)
            origin=GitRepository(root:remote,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false));_=try await origin.run(["init","--bare","--template=","-b","main"])
            _=try await cli.run(["remote","add","origin",remote.path]);_=try await cli.run(["push","--set-upstream","origin","main"])
            let runtime=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/libgit2-runtime/LibGit2/bin/turtlegit-libgit2")
            let script="""
            #!/bin/sh
            printf '%s\\n' "$*" >> \(quote(trace.path))
            case "$*" in
              *turtlegit-revision-lookup*)
                request=\(quote(base.path+"/request-"))$$
                cat > "$request"
                exec 9< "$request"
                if test -f \(quote(hold.path)); then
                  : > \(quote(started.path))
                  while ! test -f \(quote(release.path)); do /bin/sleep .02; done
                fi
                if test -f \(quote(malformed.path)); then printf 'invalid protocol\\n'; exit 0; fi
                exec \(quote(runtime.path)) "$@" < "$request"
                ;;
            esac
            exec \(quote(runtime.path)) "$@"
            """
            try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
            let gitScript="""
            #!/bin/sh
            printf '%s\\n' "$*" >> \(quote(gitTrace.path))
            lookup_command=''
            identify_command() {
              while test "$#" -gt 0; do
                case "$1" in
                  --literal-pathspecs|--no-literal-pathspecs) shift ;;
                  -C|-c) shift; test "$#" -gt 0 || return; shift ;;
                  *) lookup_command="$1"; return ;;
                esac
              done
            }
            identify_command "$@"
            if test "$lookup_command" = pull && test -f \(quote(postPullFailure.path)); then
              \(quote(git.path)) "$@"
              status=$?
              if test "$status" -eq 0; then
                /bin/cp \(quote(root.appendingPathComponent(".git/HEAD").path)) \(quote(pullHeadReceipt.path))
                /bin/cp \(quote(root.appendingPathComponent(".git/index").path)) \(quote(pullIndexReceipt.path))
                : > \(quote(malformed.path))
              fi
              exit "$status"
            fi
            exec \(quote(git.path)) "$@"
            """
            try Data(gitScript.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
            repo=GitRepository(root:root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0,helperURL:helper))
        }
        func calls()->String{(try? String(contentsOf:trace,encoding:.utf8)) ?? ""}
        func clear()throws{try Data().write(to:trace);try Data().write(to:gitTrace)}
        func branch(_ name:String,tag:Bool=false,revision:String="HEAD")async throws->BranchTagWindowController {
            let owner=own(BranchTagWindowController(repository:repo,access:RepositoryAccessLease(url:root),isTag:tag,preferences:prefs))
            owner.model.load(revision:revision,name:name)
            try await wait{!owner.model.busy && !owner.model.hasPendingWork && !owner.model.chooser.busy}
            try require(owner.model.error==nil && owner.model.chooser.error==nil,"Reference form failed to load")
            return owner
        }
        func clean()async {
            try? Data().write(to:release)
            for owner in owners.reversed(){if let window=owner.window{window.makeFirstResponder(nil);if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()}};owner.close()}
            workspace?.stopMonitoringForTermination();host?.close()
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.abort)};window.close()}
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func references(_ c:Context)async throws {
        let nfc="caf\u{e9}",nfd="cafe\u{301}"
        // A packed name keeps literal Git identity independent of the host
        // filesystem's normalization of loose reference filenames.
        try Data(("# pack-refs with: peeled fully-peeled sorted\n"+c.head+" refs/tags/"+nfc+"\n").utf8).write(to:c.root.appendingPathComponent(".git/packed-refs"))
        let owner=try await c.branch(nfd),model=owner.model
        let prepare=model.prepareForm
        model.prepareForm={options,token in let form=try await prepare(options,token);c.prefs.set(false,forKey:"UseLibgit2");return form}
        try c.clear();model.create();try await wait{!model.hasPendingWork && !model.busy}
        try require(model.completedSuccessfully && model.operationRepository.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Accepted Branch settings snapshot was replaced between form and plan")
        let created=try await c.cli.run(["-c","core.precomposeunicode=false","rev-parse","refs/heads/"+nfd]).text.trimmingCharacters(in:.newlines)
        try require(created==c.head,"Exact branch identity selected canonical tag sibling")
        for(name,target)in[("blob-tag",c.blob),("tree-tag",c.tree)] {
            c.prefs.set(true,forKey:"UseLibgit2");let tag=try await c.branch(name,tag:true,revision:target)
            tag.model.create();try await wait{!tag.model.hasPendingWork && !tag.model.busy}
            let actual=try await c.cli.run(["rev-parse","refs/tags/"+name]).text.trimmingCharacters(in:.newlines)
            try require(tag.model.completedSuccessfully && actual==target,"Native Tag rejected or peeled legal raw object target")
        }
        let invalid=try await c.branch("not-a-commit",revision:c.blob);invalid.model.create();try await wait{!invalid.model.hasPendingWork && !invalid.model.busy}
        let exists=try await c.cli.referenceExists("refs/heads/not-a-commit")
        try require(invalid.model.error != nil && !exists,"Native Branch accepted a blob target")
        c.prefs.set(false,forKey:"UseLibgit2");let cliOnly=try await c.branch("cli-only");try c.clear();cliOnly.model.create();try await wait{!cliOnly.model.hasPendingWork && !cliOnly.model.busy}
        try require(cliOnly.model.completedSuccessfully && !c.calls().contains("turtlegit-revision-lookup"),"Disabled master still dispatched revision helper")
    }
    static func operations(_ c:Context)async throws {
        let owner=c.own(SwitchWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),preferences:c.prefs)),model=owner.model
        model.load();try await wait{!model.busy && !model.hasPendingReferenceReads}
        try require(model.error==nil,"Switch catalog failed")
        model.options.target = .commit;model.commitRevision=c.head;model.options.createBranch=true;model.options.branchName="switched"
        try c.clear();model.checkout();c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{model.progress?.busy==false && !model.hasPendingReferenceReads}
        let result=try unwrap(model.progress,"Native Switch progress missing")
        try require(result.success && result.repository.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Switch validation and progress changed accepted engine")
        let current=try await c.cli.branch();try require(current=="switched","Actual Switch transport did not run")
        owner.close();try await wait{SwitchWindowModel.activeReads==0}
        c.prefs.set(true,forKey:"UseLibgit2")
        let push=c.own(PushWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),preferences:c.prefs))
        push.model.load(source:"switched");try await wait{!push.model.busy && !push.model.preparing}
        try require(push.model.error==nil,"Push preparation failed")
        push.model.options.remote="origin";push.model.options.source="switched";push.model.options.destination="delivered"
        try c.clear();push.model.push();c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{push.model.progress?.busy==false && !push.model.transportRunning}
        try require(push.model.progress?.success==true && c.calls().contains("turtlegit-revision-lookup"),"Push lost accepted lookup engine")
        let remote=try await c.origin.run(["rev-parse","refs/heads/delivered"]).text.trimmingCharacters(in:.newlines)
        let commands=(try? String(contentsOf:c.gitTrace,encoding:.utf8)) ?? ""
        try require(remote==c.head && commands.contains(" push "),"Push failed to retain ordinary CLI transport with master-only helper selection")
    }
    static func fetchsync(_ c:Context)async throws {
        // Use the ordinary workspace dispatch and its real Fetch→Rebase callback.
        let store=try RepositoryAccessStore(storageURL:c.base.appendingPathComponent("access.json"))
        let repository=c.repo!
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in repository},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:c.prefs,publishCachePersistence:{_ in})
        c.workspace=workspace;workspace.fileComparisonPreferences=c.prefs;workspace.notifyFinder={}
        let host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);c.host=host;host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
        workspace.open(c.root);try await wait{!workspace.busy && workspace.root != nil}
        workspace.activate(.fetch)
        try await wait{NSApp.windows.contains{($0.windowController as? FetchWindowController) != nil}}
        let fetch=try unwrap(NSApp.windows.compactMap{$0.windowController as? FetchWindowController}.first,"Workspace Fetch owner missing");c.owners.append(fetch)
        try await wait{!fetch.model.busy && !fetch.model.preparing && fetch.model.remotes.contains("origin")}
        fetch.model.options.remote="origin";fetch.model.options.branch="main";fetch.model.options.namedRemoteFetchAll=false;fetch.model.launchRebase=true
        let present=fetch.model.onFetchProgress
        fetch.model.onFetchProgress={result in present?(result);result.presentRebasePrompt={prompt in .init(value:prompt == .fastForward ? 2:6,suppress:false)}}
        try c.clear();fetch.model.fetch();c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{fetch.model.fetchProgress?.busy==false}
        let result=try unwrap(fetch.model.fetchProgress,"Actual Fetch progress missing")
        try require(result.success && result.backend.enabled && c.calls().contains("turtlegit-revision-lookup"),"Fetch/Rebase preparation lost selected lookup engine")
        result.close()
        try await wait{NSApp.windows.contains{($0.windowController as? RebaseWindowController) != nil}}
        let rebase=try unwrap(NSApp.windows.compactMap{$0.windowController as? RebaseWindowController}.first,"Actual workspace Rebase handoff missing");c.owners.append(rebase)
        try await wait{!rebase.model.busy && rebase.model.pendingBatchWorkers==0}
        try require(rebase.model.inheritedOperationRepository === fetch.model.acceptedOperationRepository && rebase.model.inheritedOperationRepository?.libgit2Configuration?.enabled==true,"Workspace automatic Rebase handoff recaptured changed backend settings")
        rebase.close();try await wait{rebase.model.pendingBatchWorkers==0 && rebase.window?.sheetParent==nil}
        c.prefs.set(true,forKey:"UseLibgit2")
        let pull=c.own(FetchWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),isPull:true,preferences:c.prefs))
        pull.model.load();try await wait{!pull.model.busy && !pull.model.preparing}
        pull.model.options.remote="origin";pull.model.options.branch="main";pull.model.launchRebase=false
        try c.clear();pull.model.fetch();c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{pull.model.progress?.busy==false}
        try require(pull.model.progress?.success==true && pull.model.progress?.repository.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Pull preflight/result inspection recaptured changed backend")
        pull.close();try await wait{!pull.serviceWorkPending}
        // Fail only after the real CLI Pull has succeeded. The helper marker
        // cannot affect the initial HEAD lookup or form/catalog preparation.
        c.prefs.set(true,forKey:"UseLibgit2");c.prefs.set(2,forKey:"AutoCloseGitProgress")
        let warned=c.own(FetchWindowController(repository:c.repo,access:RepositoryAccessLease(url:c.root),isPull:true,preferences:c.prefs))
        warned.model.load();try await wait{!warned.model.busy && !warned.model.preparing}
        warned.model.options.remote="origin";warned.model.options.branch="main";warned.model.launchRebase=false
        try Data().write(to:c.postPullFailure);try c.clear();warned.model.fetch()
        try await wait{warned.model.progress?.busy==false}
        let warning=try unwrap(warned.model.progress,"Successful Pull with failed inspection lost its result")
        let diagnostic=try unwrap(warning.completionWarning,"Post-transport helper failure was silently swallowed")
        try require(warning.success && !warning.cancelled && !diagnostic.isEmpty && warning.output.contains(diagnostic),"Pull inspection warning replaced successful transport or disappeared from output")
        try require(!warning.postActions.contains(.diff) && !warning.postActions.contains(.log),"Failed HEAD inspection offered unavailable Log/Diff receipts")
        try require(warned.progressController?.model === warning && warned.progressController?.window?.sheetParent === warned.window && !warned.model.closed,"Auto-close hid a successful Pull's helper inspection warning")
        let actualHead=try Data(contentsOf:c.root.appendingPathComponent(".git/HEAD")),actualIndex=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let settledHead=try Data(contentsOf:c.pullHeadReceipt),settledIndex=try Data(contentsOf:c.pullIndexReceipt)
        try require(actualHead==settledHead && actualIndex==settledIndex,"Post-transport helper failure changed HEAD/index beyond actual Pull")
        let settledHash=try await c.cli.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(settledHash==c.head && c.calls().contains("turtlegit-revision-lookup"),"Private real-branch Pull or selected post-transport lookup did not execute")
        warning.close();try await wait{!warned.serviceWorkPending}
        for marker in [c.postPullFailure,c.malformed]{try FileManager.default.removeItem(at:marker)}
        c.prefs.set(0,forKey:"AutoCloseGitProgress")
        c.prefs.set(true,forKey:"UseLibgit2");workspace.activate(.synchronize)
        try await wait{NSApp.windows.contains{($0.windowController as? SynchronizationWindowController) != nil}}
        let sync=try unwrap(NSApp.windows.compactMap{$0.windowController as? SynchronizationWindowController}.first,"Actual workspace Sync owner missing");c.owners.append(sync)
        sync.model.reload(initial:true);try await wait{!sync.model.busy && sync.model.outgoing != nil}
        try c.clear();sync.model.refresh();c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{!sync.model.busy}
        try require(sync.model.error==nil && c.calls().contains("turtlegit-configured-remotes") && c.calls().contains("turtlegit-revision-lookup"),"Sync refresh bypassed master catalog or changed accepted lookup engine")
        c.prefs.set(true,forKey:"UseLibgit2");sync.model.presentRebasePrompt={prompt in .init(value:prompt == .fastForward ? 2:6,suppress:false)}
        try c.clear();sync.model.fetch(.fetchAndRebase);c.prefs.set(false,forKey:"UseLibgit2")
        try await wait{NSApp.windows.contains{($0.windowController as? RebaseWindowController)?.model.retired==false}}
        let syncRebase=try unwrap(NSApp.windows.compactMap{$0.windowController as? RebaseWindowController}.first{$0.model.retired==false},"Actual Sync Rebase handoff missing");c.owners.append(syncRebase)
        try await wait{!syncRebase.model.busy && syncRebase.model.pendingBatchWorkers==0}
        try require(syncRebase.model.inheritedOperationRepository === sync.model.acceptedOperationRepository && syncRebase.model.inheritedOperationRepository?.libgit2Configuration?.enabled==true,"Actual workspace Sync Rebase handoff recaptured changed backend")
        syncRebase.close();try await wait{!sync.model.busy && !sync.model.transportRunning}
        try require(sync.model.commandSucceeded && sync.model.acceptedOperationRepository?.libgit2Configuration?.enabled==true && c.calls().contains("turtlegit-revision-lookup"),"Sync transport did not retain selected preparation/continuation engine")
    }
    static func ownership(_ c:Context)async throws {
        let malformed=try await c.branch("malformed-target")
        try Data().write(to:c.malformed);try c.clear();malformed.model.create();try await wait{!malformed.model.hasPendingWork && !malformed.model.busy}
        let absent=try await c.cli.referenceExists("refs/heads/malformed-target")
        try require(malformed.model.error != nil && !absent && c.calls().contains("turtlegit-revision-lookup"),"Malformed helper result silently fell back to CLI mutation")
        try FileManager.default.removeItem(at:c.malformed)
        let held=try await c.branch("closed-target");try Data().write(to:c.hold);held.model.create()
        try await wait{FileManager.default.fileExists(atPath:c.started.path) && held.model.hasPendingWork}
        held.close();try Data().write(to:c.release);try await wait{!held.model.hasPendingWork}
        let changed=try await c.cli.referenceExists("refs/heads/closed-target")
        try require(!changed && !held.model.active,"Closed owner published a late prepared reference")
        let trace=c.calls();try require(trace.contains("turtlegit-revision-lookup"),"Owned cancellation did not exercise actual selected helper")
        for marker in [c.hold,c.started,c.release]{if FileManager.default.fileExists(atPath:marker.path){try FileManager.default.removeItem(at:marker)}}
        try await RevisionLookupQueuedVerification.verify(c)
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.lookupFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.lookupOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {try await c.prepare();let mode=CommandLine.arguments[3];switch mode{case "references":try await references(c);case "operations":try await operations(c);case "fetchsync":try await fetchsync(c);default:try await ownership(c)};await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil && $0.attachedSheet==nil},"Owned revision lookup windows/work survived cleanup");print("PASS: revision lookup "+mode)}
        catch {await c.clean();fputs("Revision lookup failure: \(error)\n",stderr);exit(1)}
    }
}
