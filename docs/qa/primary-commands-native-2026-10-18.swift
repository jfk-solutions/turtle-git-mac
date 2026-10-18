import AppKit
import TurtleGitCore

@main struct PrimaryCommandsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Primary command native state did not settle at \(line)")
    }
    @MainActor static func verifyNetwork() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let roots=[container.appendingPathComponent("first"),container.appendingPathComponent("second")]
        for root in roots {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Network launch QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
            _ = try await repo.run(["branch","topic"])
            let tip=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["update-ref","refs/remotes/origin/main",tip.hash])
            try Data("next\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"next")
            _ = try await repo.run(["remote","add","origin",root.path]);_ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/main"])
        }
        let repo=GitRepository(root:roots[0],executable:git),base=try await repo.rebaseCommit("topic")
        let refsBefore=try await repo.run(["show-ref"]).stdout,index=try Data(contentsOf:roots[0].appendingPathComponent(".git/index"))
        let suite="TurtleGit.NetworkLaunch."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.transportClipboardText={nil}
        workspace.commandLineRepositoryPermission={paths in RepositoryAccessLease(url:paths[0])}
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ args:[String]) {workspace.handleCommandLine(arguments:args,currentDirectory:roots[0].path)}
        let cloneDestination=container.appendingPathComponent("exact-destination")
        invoke(["--command=clone","--path",cloneDestination.path,"--url",roots[0].path,"--exactpath"])
        let clone=try requireOne(windows(CloneWindowController.self))
        try require(clone.model.source==roots[0].path && clone.model.directory==cloneDestination.path && clone.model.exactDestination,"Clone exact path/source presets were lost")
        clone.model.source=roots[1].path;clone.model.sourceChanged()
        try require(clone.model.directory==cloneDestination.path && !FileManager.default.fileExists(atPath:cloneDestination.path),"Exact Clone path changed on URL edit or launched Git")
        clone.close()
        invoke(["/command:fetch","/remote:origin"])
        try await wait {!workspace.busy && windows(FetchWindowController.self).first?.model.busy == false}
        let fetch=windows(FetchWindowController.self).first!
        try require(fetch.model.options.remote=="origin" && !fetch.model.isPull,"Fetch preset did not reach editable options");fetch.close()
        invoke(["/command:pull"])
        try await wait {!workspace.busy && windows(FetchWindowController.self).first?.model.busy == false}
        let pull=windows(FetchWindowController.self).first!
        try require(pull.model.isPull,"Pull opened Fetch mode");pull.close()
        invoke(["/command:push","/branch:topic"])
        try await wait {!workspace.busy && windows(PushWindowController.self).first?.model.busy == false}
        let push=windows(PushWindowController.self).first!
        try require(push.model.options.source=="topic","Push did not retain requested source branch");push.close()
        for (command,name) in [("branch","new-branch"),("tag","new-tag")] {
            invoke(["/command:"+command,"/rev:"+base.hash,"/name:"+name])
            try await wait {!workspace.busy && windows(BranchTagWindowController.self).first?.model.busy == false && windows(BranchTagWindowController.self).first?.model.chooser.busy == false}
            let owner=windows(BranchTagWindowController.self).first!
            try require(owner.model.options.name==name && owner.model.chooser.revision==base.hash && owner.model.isTag==(command=="tag"),"Branch/Tag name/base preset was replaced by metadata suggestions");owner.close()
        }
        invoke(["/command:switch","/rev:topic"])
        try await wait {!workspace.busy && windows(SwitchWindowController.self).first?.model.busy == false}
        let checkout=windows(SwitchWindowController.self).first!
        try require(checkout.model.revision=="topic","Switch revision preset lost");checkout.close()
        invoke(["/command:refbrowse"])
        try await wait {!workspace.busy && windows(ReferenceBrowserWindowController.self).first?.model.busy == false}
        windows(ReferenceBrowserWindowController.self).first!.close()
        invoke(["/command:repobrowser","/rev:"+base.hash])
        try await wait {!workspace.busy && windows(RepositoryBrowserWindowController.self).first?.model.busy == false}
        let browser=windows(RepositoryBrowserWindowController.self).first!
        try require(browser.model.revision==base.hash,"Repository Browser revision preset lost");browser.close()
        invoke(["/command:reflog","/ref:refs/heads/topic"])
        try await wait {!workspace.busy && windows(ReferenceLogWindowController.self).first?.model.busy == false}
        let reflog=windows(ReferenceLogWindowController.self).first!
        try require(reflog.model.reference=="refs/heads/topic","RefLog reference preset lost");reflog.close()
        invoke(["/command:rebase","/upstream:"+base.hash,"/force"])
        try await wait {!workspace.busy && windows(RebaseWindowController.self).first?.model.busy == false}
        let replay=windows(RebaseWindowController.self).first!
        try require(replay.model.options.upstream==base.hash && replay.model.options.force && !replay.model.active,"Rebase lost source Force/upstream or auto-started")
        replay.close()
        let queued=RebaseWindowController(repository:repo,access:nil,preferences:prefs),queuedModel=queued.model
        var gate:CheckedContinuation<Void,Never>?,sessionReads=0
        let readSession=queuedModel.readSession
        queuedModel.readSession={identity,token in
            sessionReads += 1
            if sessionReads==1 {await withCheckedContinuation {gate=$0}}
            return try await readSession(identity,token)
        }
        defer {gate?.resume();queued.close()}
        queuedModel.load(upstream:base.hash)
        try await wait {gate != nil}
        queuedModel.load(force:true)
        gate?.resume();gate=nil
        try await wait {!queuedModel.busy && sessionReads>=2}
        try require(queuedModel.options.force && queuedModel.options.upstream=="refs/remotes/origin/main","Force-only deferred Rebase load lost its preset")
        queued.close()
        // Each transport root gets its own owned form; no operation is accepted.
        for command in ["fetch","pull","push"] {
            invoke(["--command="+command,"--path",roots[0].path,"--path",roots[1].path])
            try await wait {!workspace.busy && RepositoryModel.activeCommandFileOperations==0}
            print("Batch launch diagnostic: command=\(command), fetch=\(windows(FetchWindowController.self).map {($0.model.repository.root.path,$0.model.busy,$0.model.error ?? "none")}), push=\(windows(PushWindowController.self).count), error=\(workspace.error ?? "none")")
            if command=="push" {
                try await wait {windows(PushWindowController.self).count==2 && windows(PushWindowController.self).allSatisfy {!$0.model.busy}}
                let all=windows(PushWindowController.self)
                try require(Set(all.map {$0.model.repository.root.resolvingSymlinksInPath().path})==Set(roots.map {$0.resolvingSymlinksInPath().path}),"Multi-root Push reused one repository model");all.forEach {$0.close()}
            } else {
                try await wait {windows(FetchWindowController.self).count==2 && windows(FetchWindowController.self).allSatisfy {!$0.model.busy}}
                let all=windows(FetchWindowController.self)
                try require(Set(all.map {$0.model.repository.root.resolvingSymlinksInPath().path})==Set(roots.map {$0.resolvingSymlinksInPath().path}) && all.allSatisfy {$0.model.isPull==(command=="pull")},"Multi-root transport reused root or wrong mode");all.forEach {$0.close()}
            }
        }
        invoke(["--command=fetch","--path",roots[0].appendingPathComponent("file").path,"--path",roots[1].path])
        try await wait {!workspace.busy && RepositoryModel.activeCommandFileOperations==0}
        try require(windows(FetchWindowController.self).isEmpty && workspace.error != nil,"Batch transport accepted a file instead of a repository root")
        let cancelled=RepositoryModel(startMonitoring:false,initializePreferences:false)
        cancelled.commandLineRepositoryPermission={_ in cancelled.stopMonitoringForTermination();return nil}
        cancelled.handleCommandLine(arguments:["--command=fetch","--path",roots[0].path,"--path",roots[1].path],currentDirectory:roots[0].path)
        try await wait {RepositoryModel.activeCommandFileOperations==0}
        try require(windows(FetchWindowController.self).isEmpty,"Cancelled root authorization continued the command batch");cancelled.stopMonitoringForTermination()
        try require(try await repo.run(["show-ref"]).stdout==refsBefore && Data(contentsOf:roots[0].appendingPathComponent(".git/index"))==index,"Opening network/reference options changed refs or index")
        try require(!FileManager.default.fileExists(atPath:cloneDestination.path),"Clone ran without acceptance")
        print("PASS: network/reference command family: eleven native dialog routes; Clone exact-path URL edits; Fetch/Pull/Push mode/source; Branch/Tag base/name; Switch, browsers, RefLog and Force Rebase; three two-repository transport batches; cancelled grants; no implicit clone/transport/ref mutation; owned windows closed")
    }
    static func requireOne<T>(_ values:[T]) throws -> T {guard values.count==1,let value=values.first else {throw Failure(description:"Expected one native launch dialog")};return value}
    @MainActor static func verifyIO() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Command IO QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_ = try await repo.run(["config",key,value])}
        let path="line 雪[*].txt",file=FileTransferPaths.fileURL(root.path+"/"+path)
        try Data("first\nsecond base\nlast\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
        let base=try await repo.rebaseCommit("HEAD")
        try Data("first\nsecond committed 🦎\nlast\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"second")
        let head=try await repo.rebaseCommit("HEAD")
        try Data("first\nsecond working 🦎\nlast\n".utf8).write(to:file)
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.CommandIO."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:container.appendingPathComponent("marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        workspace.commitWindowFactory={CommitWindowController(repository:$0,access:$1,defaults:prefs)}
        let historyCache=HistoryFileCache(root:container.appendingPathComponent("history-cache"))
        workspace.commandLineSelectionWindowFactory={repository,access,completion in LogWindowController(repository:repository,access:access,onChoose:completion,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,historyFileCache:historyCache,loadsImmediately:false)}
        var listGrants=0,repositoryGrants=0,outputGrants=0
        workspace.commandLinePathListPermission={_,_ in listGrants += 1;return RepositoryAccessLease(url:container)}
        workspace.commandLineRepositoryPermission={_ in repositoryGrants += 1;return RepositoryAccessLease(url:root)}
        workspace.commandLineOutputPermission={_ in outputGrants += 1;return RepositoryAccessLease(url:container)}
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        func invoke(_ args:[String]) {workspace.handleCommandLine(arguments:args,currentDirectory:root.path)}
        let list=container.appendingPathComponent("paths.list")
        try Data((file.path+"\n").utf8).write(to:list)
        invoke(["/command:commit","/pathfile:"+list.path,"/deletepathfile","/logmsg:from list"])
        try await wait {!workspace.busy && windows(CommitWindowController.self).first?.model.busy == false && RepositoryModel.activeCommandFileOperations==0}
        let commit=windows(CommitWindowController.self).first!
        try require(commit.model.scopePaths==[path] && commit.model.message=="from list" && listGrants==1 && repositoryGrants==1,"Path-list selection did not enter authorized Commit")
        try require(!FileManager.default.fileExists(atPath:list.path),"Accepted deletepathfile did not remove its owned input")
        commit.close()
        // Accepted Log result is exactly UTF-8 hex, without a newline or BOM.
        let output=container.appendingPathComponent("selected.hash")
        invoke(["--command=log","--path",file.path,"--outfile",output.path,"--rev",head.hash])
        try await wait {!workspace.busy && windows(LogWindowController.self).first?.model.busy == false}
        let log=windows(LogWindowController.self).first!
        try require(log.model.selecting && !log.model.selectingMultiple && log.model.historyPaths==[path],"outfile did not create the ordinary scoped single-commit picker")
        log.model.select([head.hash]);try await wait {log.model.canAcceptSelection}
        log.model.accept();log.model.accept()
        try await wait {RepositoryModel.activeCommandFileOperations==0 && FileManager.default.fileExists(atPath:output.path)}
        try require(try Data(contentsOf:output)==Data(head.hash.utf8),"Accepted Log output changed hash bytes or duplicated completion")
        // Cancel follows upstream's empty-output protocol, including overwrite.
        invoke(["--command=log","--path",file.path,"--outfile",output.path])
        try await wait {!workspace.busy && windows(LogWindowController.self).first?.model.busy == false}
        windows(LogWindowController.self).first!.close()
        try await wait {RepositoryModel.activeCommandFileOperations==0}
        try require(try Data(contentsOf:output).isEmpty && outputGrants==2,"Cancelled Log did not write exactly one empty result")
        // Real built-in historical and working unified document routes.
        invoke(["--command=diff","--path",file.path,"--startrev",base.hash,"--endrev",head.hash,"--unified"])
        try await wait {!workspace.busy && !windows(PatchWindowController.self).isEmpty}
        let historical=windows(PatchWindowController.self).first!
        let historicalText=String(decoding:historical.model.exportDocument.bytes,as:UTF8.self)
        try require(historicalText.contains("+second committed") && !historicalText.contains("+second working"),"Unified revision request lost its captured pair")
        historical.close()
        invoke(["--command=diff","--path",file.path,"--unified"])
        try await wait {!workspace.busy && !windows(PatchWindowController.self).isEmpty}
        let working=windows(PatchWindowController.self).first!
        try require(String(decoding:working.model.exportDocument.bytes,as:UTF8.self).contains("+second working"),"Working unified request lost its patch bytes");working.close()
        // One-based /line reaches the actual destination source line after alignment.
        invoke(["--command=diff","--path",file.path,"--line=2"])
        try await wait {!workspace.busy && windows(FileComparisonWindowController.self).first?.model.filtering == false && windows(FileComparisonWindowController.self).first?.model.document != nil}
        let compare=windows(FileComparisonWindowController.self).first!
        func editors(_ view:NSView?)->[NSTextView] {guard let view else{return []};return (view as? NSTextView).map {[$0]} ?? view.subviews.flatMap {editors($0)}}
        try await wait {editors(compare.window?.contentView).contains {view in view.selectedRange().length>0 && (view.string as NSString).substring(with:view.selectedRange())=="second working 🦎"}}
        try require(compare.model.requestedSourceLine==2,"Diff line was not retained for the selected tool");compare.close()
        // Cancelled list preparation cannot delete input or start another dialog.
        let cancelled=RepositoryModel(startMonitoring:false,initializePreferences:false)
        cancelled.commandLinePathListPermission={_,_ in RepositoryAccessLease(url:container)}
        defer {cancelled.stopMonitoringForTermination()}
        try Data((file.path+"\n").utf8).write(to:list)
        cancelled.handleCommandLine(arguments:["/command:commit","/pathfile:"+list.path,"/deletepathfile"],currentDirectory:root.path)
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored an owned command-file worker")
        cancelled.stopMonitoringForTermination();try await wait {RepositoryModel.activeCommandFileOperations==0 && !cancelled.busy}
        try require(FileManager.default.fileExists(atPath:list.path) && windows(CommitWindowController.self).isEmpty,"Cancelled path preparation deleted input or launched Commit")
        // A picker can reenter the run loop. Cancelling its initiating work
        // before a late positive grant must prevent the next dialog/write.
        for outputPicker in [false,true] {
            let late=RepositoryModel(startMonitoring:false,initializePreferences:false)
            late.commandLinePathListPermission={_,_ in RepositoryAccessLease(url:container)}
            var presentations=0
            late.commitWindowFactory={presentations += 1;return CommitWindowController(repository:$0,access:$1,defaults:prefs)}
            late.commandLineRepositoryPermission={_ in late.stopMonitoringForTermination();return RepositoryAccessLease(url:root)}
            late.commandLineOutputPermission={_ in late.stopMonitoringForTermination();return RepositoryAccessLease(url:container)}
            let lateOutput=container.appendingPathComponent("late.hash")
            let args=outputPicker ? ["--command=log","--pathfile",list.path,"--outfile",lateOutput.path] : ["--command=commit","--pathfile",list.path]
            late.handleCommandLine(arguments:args,currentDirectory:root.path)
            try await wait {RepositoryModel.activeCommandFileOperations==0 && !late.busy}
            try require(presentations==0 && windows(LogWindowController.self).isEmpty && !FileManager.default.fileExists(atPath:lateOutput.path),"A late positive file/repository grant bypassed cancellation")
            late.stopMonitoringForTermination()
        }
        workspace.commandLineOutputPermission={_ in nil}
        let refused=container.appendingPathComponent("refused.hash")
        invoke(["/command:log","/outfile:"+refused.path])
        try require(windows(LogWindowController.self).isEmpty && !FileManager.default.fileExists(atPath:refused.path),"Cancelled output authorization launched/wrote Log")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Command file/diff/picker routes changed real index")
        try require(try await repo.rebaseCommit("HEAD").hash==head.hash,"Command file/diff/picker routes changed HEAD")
        try require(try String(contentsOf:file,encoding:.utf8)=="first\nsecond working 🦎\nlast\n","Command file/diff/picker routes changed source bytes")
        try await wait {RepositoryModel.activeCommandFileOperations==0 && LogWindowModel.activeHistoryLoads==0 && CommitWindowModel.activeReloads==0}
        print("PASS: command file IO family: authorized exact path-list Commit and explicit input deletion; single-picker hash/Cancel output; real revision/working unified documents; native source-line selection; cancelled permissions/preparation and Quit drain; unchanged Git/source state; owned windows closed")
    }
    @MainActor static func verifyBare() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","--bare","-b","main"])
        let suite="TurtleGit.PrimaryBare."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root)}
        var created=0
        workspace.commitWindowFactory={created += 1;return CommitWindowController(repository:$0,access:$1,defaults:prefs)}
        defer {workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        workspace.handleCommandLine(arguments:["/command:commit","/logmsg:bare"],currentDirectory:root.path)
        try await wait {!workspace.busy}
        try require(created==0 && workspace.error?.contains("requires a working tree")==true,"Bare repository bypassed ordinary Commit eligibility: \(workspace.error ?? "none")")
        for command in ["blame","prevdiff","add","rename","remove","cleanup","ignore","merge","stashsave","stashapply","stashpop","stashlist"] {
            workspace.error=nil
            workspace.handleCommandLine(arguments:["--command="+command],currentDirectory:root.path)
            try await wait {!workspace.busy}
            try require(workspace.error?.contains("requires a working tree")==true,"Bare source-file command bypassed working-tree guard: "+command)
        }
        workspace.error=nil
        workspace.handleCommandLine(arguments:["--command=merge","--abort"],currentDirectory:root.path)
        try await wait {!workspace.busy}
        try require(workspace.error?.contains("requires a working tree")==true,"Bare Abort Merge bypassed working-tree guard")
        print("PASS: bare command eligibility preserves the ordinary native working-tree guard; no Commit window created")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "integration" { try await verifyIntegration(); return }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "maintenance" { try await verifyMaintenance(); return }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "files" { try await verifyFiles(); return }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "network" { try await verifyNetwork(); return }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "io" { try await verifyIO(); return }
        if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "bare" { try await verifyBare(); return }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let repo = GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Command QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let path = "-space 雪[*].txt", file = FileTransferPaths.fileURL(root.path + "/" + path)
        try Data("base\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base")
        let base = try await repo.rebaseCommit("HEAD")
        try Data("second\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"second")
        let head = try await repo.rebaseCommit("HEAD")
        try Data("working\n".utf8).write(to:file)
        let index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.PrimaryCommands." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"UseGravatar");prefs.set(false,forKey:"Commit.Staging");prefs.set(false,forKey:"ConfirmKillProcess")
        defer { prefs.removePersistentDomain(forName:suite) }
        let workspace = RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("private-marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs
        var permissions=0
        workspace.commandLineRepositoryPermission={_ in permissions += 1;return RepositoryAccessLease(url:root)}
        workspace.commitWindowFactory={CommitWindowController(repository:$0,access:$1,defaults:prefs)}
        workspace.logWindowFactory={LogWindowController(repository:$0,access:$1,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false)}
        defer { workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()} }
        func invoke(_ args:[String]) {workspace.handleCommandLine(arguments:args,currentDirectory:root.path)}
        func windows<T>(_ type:T.Type)->[T] {NSApp.windows.filter(\.isVisible).compactMap {$0.delegate as? T}}
        // Startup delivery occurs exactly once in either SwiftUI/delegate order.
        for modelFirst in [false,true] {
            let delegate=TurtleGitApplicationDelegate();var calls=0
            delegate.startupArguments=["/command:log"];delegate.startupDirectory=root.path
            delegate.startupCommandHandler={model,args,cwd in precondition(model === workspace && args==["/command:log"] && cwd==root.path);calls += 1}
            if modelFirst {delegate.repositoryModel=workspace;try require(calls==0,"Premature startup delivery")}
            delegate.startupDidFinishLaunching()
            if !modelFirst {try require(calls==0,"Startup lost model readiness");delegate.repositoryModel=workspace}
            delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching()
            try require(calls==1 && delegate.startupDelivered,"Startup command delivered twice")
        }
        invoke(["--command=commit","--path",file.path,"--logmsg","subject\n\nbody","--bugid","42"])
        try await wait {!workspace.busy && windows(CommitWindowController.self).first?.model.busy == false}
        let commit=windows(CommitWindowController.self).first!
        try require(commit.model.message=="subject\n\nbody" && commit.model.issueID=="42" && commit.model.scopePaths==[path],"Commit presets/scope were overwritten by initial loading")
        invoke(["/command:commit","/logmsg:replacement"])
        try await wait {!workspace.busy}
        try require(commit.model.message=="subject\n\nbody" && workspace.error?.contains("already open")==true,"Second launch overwrote an open draft")
        commit.close();workspace.error=nil
        let message = root.appendingPathComponent("message.txt");try Data("from file\n雪".utf8).write(to:message)
        var messageGrants=0
        workspace.commandLineMessagePermission={url in messageGrants += 1;return RepositoryAccessLease(url:url)}
        invoke(["--command=commit","--path",file.path,"--logmsgfile",message.path,"--wholeproject"])
        try await wait {!workspace.busy && windows(CommitWindowController.self).first?.model.busy == false}
        let fileCommit=windows(CommitWindowController.self).first!
        try require(messageGrants==1 && fileCommit.model.message=="from file\n雪" && fileCommit.model.showWholeProject && fileCommit.model.scopePaths.isEmpty,"Message-file/whole-project launch failed: grants=\(messageGrants), message=\(fileCommit.model.message.debugDescription), whole=\(fileCommit.model.showWholeProject), scope=\(fileCommit.model.scopePaths), workspace=\(workspace.error ?? "none")")
        fileCommit.close()
        invoke(["--command=repostatus","--path",file.path])
        try await wait {!workspace.busy && windows(StatusWindowController.self).first?.model.busy == false}
        let status=windows(StatusWindowController.self).first!
        try require(status.model.filter.paths==[path],"Working Tree launch lost exact file scope");status.close()
        invoke(["--command=log","--path",file.path,"--range",base.hash+".."+head.hash,"--rev","HEAD","--limit","1","--findstring","second","--findtype","64","--findtext"])
        try await wait {!workspace.busy && windows(LogWindowController.self).first?.model.busy == false}
        let log=windows(LogWindowController.self).first!
        try require(log.model.error==nil && log.model.entries.contains {$0.hash==head.hash},"Configured Log did not load selected range: "+(log.model.error ?? ""))
        try require(log.model.historyPaths==[path] && !log.model.showWholeProject && log.model.revisionRange?.expression==base.hash+".."+head.hash && log.model.selected.contains(head.hash),"Log launch lost range/path or symbolic selected revision: paths=\(log.model.historyPaths), whole=\(log.model.showWholeProject), range=\(log.model.revisionRange?.expression ?? "nil"), selected=\(log.model.selected), expected=\(head.hash), workspace=\(workspace.error ?? "none")")
        try require(log.model.historyLimit.scale == .commits && log.model.historyLimit.number==1 && log.model.search=="second" && log.model.searchFields == .subject && !log.model.searchRegex,"Log limit/search presets failed")
        log.close()
        var compared:[RevisionComparisonSnapshot]=[]
        workspace.fileComparisonPresentation={snapshot,_ in compared.append(snapshot)}
        invoke(["--command=diff","--path",file.path,"--startrev",base.hash,"--endrev",head.hash])
        try await wait {!workspace.busy && !compared.isEmpty}
        try require(compared.count==1,"Revision Diff did not use the existing comparison pipeline")
        // Directory Diff uses Working Tree; file pair uses the standalone viewer.
        invoke(["/command:diff","/path:"+root.path])
        try await wait {!workspace.busy && windows(StatusWindowController.self).first?.model.busy == false}
        windows(StatusWindowController.self).first!.close()
        let other=root.appendingPathComponent("other.txt");try Data("other\n".utf8).write(to:other)
        invoke(["--command=diff","--path",file.path,"--path2",other.path])
        try await wait { !windows(FileComparisonWindowController.self).isEmpty }
        windows(FileComparisonWindowController.self).first!.close()
        invoke(["--command=revert","--path",file.path])
        try await wait {!workspace.busy && windows(RevertWindowController.self).first?.model.busy == false}
        let revert=windows(RevertWindowController.self).first!
        try require(revert.model.entries.contains {$0.path==path},"Revert review did not load requested change")
        revert.close()
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Dialog launches modified real index")
        try require(try await repo.rebaseCommit("HEAD").hash==head.hash,"Dialog launches changed HEAD")
        try require(try String(contentsOf:file,encoding:.utf8)=="working\n","Dialog launches changed working content")
        // Resolve opens the review model without staging a conflict.
        _ = try await repo.run(["checkout","--",path]);_ = try await repo.run(["checkout","-b","side",base.hash])
        try Data("side\n".utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"side")
        _ = try await repo.run(["checkout","main"])
        do {_ = try await repo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected conflict")} catch is GitFailure {}
        let conflictIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        invoke(["--command=resolve","--path",file.path])
        try await wait {!workspace.busy && windows(ResolveWindowController.self).first?.model.busy == false}
        let resolve=windows(ResolveWindowController.self).first!
        try require(resolve.model.entries.count==1 && resolve.model.entries.first?.path==path,"Resolve launch lost requested conflict")
        resolve.close()
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==conflictIndex,"Resolve launch staged without review")
        invoke(["/command:resolve","/silent"])
        try require(workspace.error?.contains("Unsupported")==true,"Unsupported mutation shortcut was silently accepted")
        let cancelled = RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        defer {cancelled.stopMonitoringForTermination()}
        cancelled.commandLineRepositoryPermission={_ in nil}
        cancelled.handleCommandLine(arguments:["/command:commit"],currentDirectory:root.path)
        try require(!cancelled.busy && windows(CommitWindowController.self).isEmpty,"Cancelled authorization launched Commit")
        cancelled.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:root.deletingLastPathComponent().appendingPathComponent("outside"))}
        cancelled.handleCommandLine(arguments:["/command:commit"],currentDirectory:root.path)
        try require(cancelled.error != nil && !cancelled.busy,"Unrelated grant was accepted")
        let noMessage = RepositoryModel(startMonitoring:false,initializePreferences:false)
        defer {noMessage.stopMonitoringForTermination()}
        noMessage.commandLineMessagePermission={_ in nil}
        noMessage.handleCommandLine(arguments:["/command:commit","/logmsgfile:"+message.path],currentDirectory:root.path)
        try require(!noMessage.busy && windows(CommitWindowController.self).isEmpty,"Cancelled message authorization launched Commit")
        try require(permissions==1,"Authorized repository session was not reused")
        try await wait {CommitWindowModel.activeReloads==0 && LogWindowModel.activeHistoryLoads==0 && ResolveWindowModel.activeOperations==0}
        print("PASS: once-only startup in both readiness orders; all six primary command dialogs; literal scope; Commit presets, file permissions and draft refusal; configured Log; revision/file-pair/directory Diff; unchanged Git state before acceptance; cancelled and unrelated grants refused; owned windows closed")
    }
}
