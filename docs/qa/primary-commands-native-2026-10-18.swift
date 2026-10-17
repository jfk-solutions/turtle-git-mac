import AppKit
import TurtleGitCore

@main struct PrimaryCommandsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Primary command native state did not settle")
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
        print("PASS: bare command eligibility preserves the ordinary native working-tree guard; no Commit window created")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
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
