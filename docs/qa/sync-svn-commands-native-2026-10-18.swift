import AppKit
import TurtleGitCore

extension PrimaryCommandsVerification {
    @MainActor static func verifySyncSVNCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        setenv("TURTLEGIT_SVN_TEST_GIT",git.path,1)
        let (root,repo,old,next)=try await GitSVNFixture.create()
        defer {try? FileManager.default.removeItem(at:root)}
        let suite="TurtleGit.SyncSVNCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard(name:.init(suite))
        defer {prefs.removePersistentDomain(forName:suite);clipboard.clearContents()}
        prefs.set(false,forKey:"DownloadAnimation");prefs.set(true,forKey:"SyncDialogRandomPos")
        prefs.set(1,forKey:"TurtleGit.Sync."+root.path+".pullAction")
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:repo.executable)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        var grants=0,created=0,information=0
        workspace.commandLineRepositoryPermission={_ in grants += 1;return RepositoryAccessLease(url:root)}
        workspace.svnWindowFactory={repository,access,operation in
            created += 1
            let owner=SVNWindowController(repository:repository,access:access,operation:operation,preferences:prefs,clipboard:clipboard)
            owner.model.confirmInformation={_ in information += 1}
            owner.model.confirmStash={false};owner.model.confirmPop={false};return owner
        }
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ arguments:[String]) {workspace.error=nil;workspace.handleCommandLine(arguments:arguments,currentDirectory:root.path)}
        func argvLog() throws -> [[String]] {
            let file=root.appendingPathComponent(".git/svn-qa-log")
            guard FileManager.default.fileExists(atPath:file.path) else {return []}
            return try Data(contentsOf:file).split(separator:10).map {try JSONDecoder().decode([String].self,from:Data($0))}
        }
        @MainActor func cleanup() async {
            workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}
            for _ in 0..<1800 {if !workspace.busy && SVNWindowModel.activeOperations==0 {return};try? await Task.sleep(nanoseconds:10_000_000)}
        }
        do {
            let parentHead=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            invoke(["--command=sync","--seq=0"])
            try await wait {!workspace.busy && windows(SynchronizationWindowController.self).first?.model.localBranch=="main" && windows(SynchronizationWindowController.self).first?.model.busy==false}
            let baseline=try requireOne(windows(SynchronizationWindowController.self)),frame=baseline.window!.frame
            try require(baseline.model.preferences === prefs && baseline.model.pullAction == .fetch,"Synchronization lost owning settings/action persistence")
            baseline.close()
            invoke(["/command:sync","/seq:8"])
            try await wait {!workspace.busy && windows(SynchronizationWindowController.self).first?.model.localBranch=="main" && windows(SynchronizationWindowController.self).first?.model.busy==false}
            let sync=try requireOne(windows(SynchronizationWindowController.self)),window=sync.window!
            let visible=(window.screen ?? NSScreen.main)?.visibleFrame ?? frame
            var expected=frame.origin;expected.y += 90
            if expected.y + frame.height > visible.maxY {expected.y -= 150}
            expected.y=max(visible.minY,min(expected.y,visible.maxY-frame.height));expected.x=max(visible.minX,min(expected.x,visible.maxX-frame.width))
            try require(abs(window.frame.origin.x-expected.x)<1.1 && abs(window.frame.origin.y-expected.y)<1.1,"Source seq modulo-five/clamped native placement was lost: actual=\(window.frame), base=\(frame), expected=\(expected)")
            sync.model.force=true;sync.model.remoteBranch="edited-draft";let retainedFrame=window.frame
            invoke(["--command=sync","--seq=1"]);try await wait {!workspace.busy && !sync.model.busy}
            try require(windows(SynchronizationWindowController.self).count==1 && sync.model.force && sync.model.remoteBranch=="edited-draft" && window.frame==retainedFrame,"Repeated Sync command replaced or moved the current draft")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==parentHead,"Opening Sync changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Opening Sync changed index")
            sync.close()
            invoke(["--command=svnfetch"])
            try await wait {!workspace.busy && windows(SVNWindowController.self).first?.model.phase == .finished && windows(SVNWindowController.self).first?.model.busy==false}
            let fetch=try requireOne(windows(SVNWindowController.self))
            try require(fetch.model.error==nil && fetch.model.fetched?.oldHash==old && fetch.model.fetched?.newHash==next && fetch.model.canShowFetched && !fetch.model.progressPresentation.animateActivity && fetch.model.outputClipboard === clipboard,"SVN Fetch route/result/preferences/private output failed: "+fetch.model.output)
            // A real controller question can outlive the finished operation, with
            // an injected presenter so no user prompt or display is needed.
            var answer:((NSApplication.ModalResponse)->Void)?
            fetch.presentQuestion={_,_,reply in answer=reply}
            let question=Task {await fetch.ask("Retain the current review?",yes:"Yes",no:"No")}
            try await wait {fetch.model.hasQuestion && answer != nil}
            let ownersBefore=created
            invoke(["--command=svnignore"]);try await wait {!workspace.busy}
            try require(created==ownersBefore && windows(SVNWindowController.self).first === fetch && fetch.model.hasQuestion && workspace.error?.contains("Finish")==true,"Another SVN command retired a finished operation's pending question")
            answer?(.alertSecondButtonReturn);answer=nil
            let accepted=await question.value;try require(!accepted && !fetch.model.hasQuestion,"Owned question did not settle once")
            fetch.close();try await wait {!workspace.busy}
            invoke(["/command:svnrebase"])
            try await wait {!workspace.busy && windows(SVNWindowController.self).first?.model.phase == .finished && windows(SVNWindowController.self).first?.model.busy==false}
            let rebase=try requireOne(windows(SVNWindowController.self))
            let afterRebase=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try require(rebase.model.error==nil && rebase.model.success && afterRebase==next && information==1,"SVN Rebase did not run the source fast-forward/information path: "+rebase.model.output)
            rebase.close();try await wait {!workspace.busy}
            invoke(["--command=svndcommit"])
            try await wait {!workspace.busy && windows(SVNWindowController.self).first?.model.canStart==true}
            let dcommit=try requireOne(windows(SVNWindowController.self));dcommit.model.removeEmptyDirectories=true;dcommit.model.remember=true
            let commandCount=try argvLog().filter {$0.count>1 && $0[1]=="dcommit"}.count
            invoke(["/command:svndcommit"]);try await wait {!workspace.busy}
            try require(windows(SVNWindowController.self).first === dcommit && dcommit.model.removeEmptyDirectories && dcommit.model.remember && (try argvLog().filter {$0.count>1 && $0[1]=="dcommit"}.count)==commandCount,"Repeated DCommit replaced/accepted the options draft")
            dcommit.model.start();try await wait {!dcommit.model.busy && dcommit.model.phase == .finished && !workspace.busy}
            try require(dcommit.model.error==nil && dcommit.model.success && (try argvLog()).contains(["svn","dcommit","--rmdir"]),"DCommit did not capture accepted Git Style options: "+dcommit.model.output)
            try require(try await repo.svnCommitType()==true,"DCommit Remember did not persist accepted option")
            dcommit.close();try await wait {!workspace.busy}
            invoke(["--command=svnignore"])
            try await wait {!workspace.busy && windows(SVNWindowController.self).first?.model.canStart==true}
            let ignore=try requireOne(windows(SVNWindowController.self));ignore.model.ignoreDestination = .gitignore
            invoke(["/command:svnignore"]);try await wait {!workspace.busy}
            try require(windows(SVNWindowController.self).first === ignore && ignore.model.ignoreDestination == .gitignore && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".gitignore").path),"Repeated Ignore changed/accepted its destination")
            ignore.model.start();try await wait {!ignore.model.busy && ignore.model.phase == .finished && !workspace.busy}
            try require(ignore.model.error==nil && ignore.model.success && (try Data(contentsOf:root.appendingPathComponent(".gitignore")))==Data("created*\n".utf8),"Import Ignore did not execute selected destination: "+ignore.model.output)
            ignore.close()
            // All five commands preserve ordinary working-tree eligibility.
            let bare=container.appendingPathComponent("bare.git");try FileManager.default.createDirectory(at:bare,withIntermediateDirectories:true)
            _ = try await GitRepository(root:bare,executable:git).run(["init","--bare"])
            let other=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("other-marks.json")))
            other.requiresRepositoryScope=false;other.fileComparisonPreferences=prefs
            defer {other.stopMonitoringForTermination()}
            other.commandLineRepositoryPermission={_ in nil}
            other.handleCommandLine(arguments:["--command=sync"],currentDirectory:bare.path)
            try require(!other.busy && windows(SynchronizationWindowController.self).isEmpty,"Cancelled Sync grant opened a window")
            other.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:bare)}
            for command in ["sync","svnfetch","svnrebase","svndcommit","svnignore"] {
                other.error=nil;other.handleCommandLine(arguments:["--command="+command],currentDirectory:bare.path)
                try await wait {!other.busy}
                try require(other.error?.contains("working tree")==true && windows(SVNWindowController.self).isEmpty && windows(SynchronizationWindowController.self).isEmpty,"Bare command opened a workflow: "+command)
            }
            try require(grants==1,"Authorized Sync/SVN workspace permission was not reused")
            await cleanup();try require(SVNWindowModel.activeOperations==0 && !NSApp.windows.contains(where:{$0.isVisible}),"Command family retained windows/operations")
            print("PASS: Synchronization/SVN command family: source seq placement and persisted settings; retained Sync draft with no mutation; Fetch changed refs and post-actions; finished-operation question guard; Rebase real fast-forward; DCommit/Ignore draft retention, explicit acceptance and persistence; cancelled authorization and all five bare refusals; private transport/output and owned windows closed")
        } catch {fputs("Sync/SVN command state: busy=\(workspace.busy) error=\(workspace.error ?? "nil")\n",stderr);await cleanup();throw error}
    }
}
