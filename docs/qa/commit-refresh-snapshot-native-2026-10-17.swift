import AppKit
import Darwin
import Combine
import TurtleGitCore

@main struct CommitRefreshSnapshotVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static var ownedPreferenceSuites:[String]=[]
    static func require(_ condition:Bool,_ message:String)throws {if !condition {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {for _ in 0..<3000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    struct ReportGeometry {
        let table:ObjectIdentifier,header:ObjectIdentifier,window:NSRect,viewport:NSRect,heading:NSRect
        func matches(_ other:Self)->Bool {
            func near(_ a:NSRect,_ b:NSRect)->Bool {abs(a.minX-b.minX)<0.5 && abs(a.minY-b.minY)<0.5 && abs(a.width-b.width)<0.5 && abs(a.height-b.height)<0.5}
            // AppKit can reposition an offscreen parent when attaching its
            // native alert. Keep actual window size and window-coordinate
            // report/header geometry invariant; screen origin is not a list jump.
            let sameWindowSize=abs(window.width-other.window.width)<0.5 && abs(window.height-other.window.height)<0.5
            return table==other.table && header==other.header && sameWindowSize && near(viewport,other.viewport) && near(heading,other.heading)
        }
    }
    @MainActor static func reportGeometry(_ owner:CommitWindowController)async throws->ReportGeometry {
        await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            guard let window=owner.window,let table=owner.model.fileListTable(key:"checkbox"),let header=table.headerView,let scroll=table.enclosingScrollView else{return false}
            return table.window===window && header.window===window && scroll.window===window && table.numberOfRows==owner.model.visibleFileRowIDs.count && header.bounds.width>0 && header.bounds.height>0 && scroll.bounds.width>0 && scroll.bounds.height>0
        }
        guard let window=owner.window,let table=owner.model.fileListTable(key:"checkbox"),let header=table.headerView,let scroll=table.enclosingScrollView else {throw Failure.assertion("Mounted Commit report/header missing")}
        return .init(table:ObjectIdentifier(table),header:ObjectIdentifier(header),window:window.frame,viewport:scroll.convert(scroll.bounds,to:nil),heading:header.convert(header.bounds,to:nil))
    }
    @MainActor static func acknowledgeError(_ owner:CommitWindowController)async throws {
        @MainActor func buttons(_ view:NSView)->[NSButton] {(view as? NSButton).map{[$0]} ?? view.subviews.flatMap(buttons)}
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        if let sheet=owner.window?.attachedSheet,let view=sheet.contentView,let ok=buttons(view).first(where:{$0.title=="OK"}) {ok.performClick(nil)}
        else {owner.model.error=nil}
        try await wait {owner.model.error==nil && owner.window?.attachedSheet==nil}
    }
    @MainActor static func main()async throws {NSApplication.shared.setActivationPolicy(.prohibited);try await verify();print("PASS Commit refresh snapshot: complete deferred publication, late Git failure, accepted LFS warning/acknowledgement/recovery, stable mounted report/header, scoped Retry, initial preferences/template/preview and retained draft/HEAD/index")}
    @MainActor static func verify()async throws {
        var failure:Error?
        do {try await verifyBody()} catch {failure=error}
        for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.abort)};window.close()}
        try await wait {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeFileDrops==0 && CommitWindowModel.activeIssueProviderOperations==0 && CommitWindowModel.activeCommitPreflights==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil}}
        for suite in ownedPreferenceSuites {UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite)}
        ownedPreferenceSuites=[]
        if let failure {throw failure}
    }
    @MainActor static func verifyBody()async throws {
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
        ownedPreferenceSuites.append(suite)
        prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(false,forKey:"Autocompletion")
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs),model=owner.model;defer {owner.close()}
        guard let window=owner.window else{throw Failure.assertion("Commit window missing")}
        window.alphaValue=0;window.setContentSize(.init(width:1280,height:980));window.orderFront(nil)
        var reportedErrors:[String]=[]
        let reporting=model.$error.compactMap{$0}.sink{reportedErrors.append($0)}
        defer{withExtendedLifetime(reporting){}}
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
        try require(model.fileListReadError?.contains("injected late statistics failure") == true && reportedErrors.contains{$0.contains("injected late statistics failure")},"Late Git error hidden")
        try await acknowledgeError(owner)
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
        let beforeWarning=try await reportGeometry(owner)
        let lockFailure=NSError(domain:"TurtleGit.CommitSnapshot.LFS",code:1,userInfo:[NSLocalizedDescriptionKey:"lock lookup unavailable"])
        let lockWarning="Could not get LFS locks: lock lookup unavailable"
        model.queryLFSOwners={_ in throw lockFailure};model.reload(paths:["a"]);try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.branch == "third" && model.scopePaths == ["a"] && model.lfsOwners.isEmpty && !model.lfsOwnershipKnown && model.fileListReadWarnings == [lockWarning] && model.feedbackMessages.contains(lockWarning) && reportedErrors.contains(lockWarning),"Optional LFS warning retained stale ownership or rejected new rows: branch=\(model.branch) scope=\(model.scopePaths) owners=\(model.lfsOwners) known=\(model.lfsOwnershipKnown) acceptedWarnings=\(model.fileListReadWarnings) alert=\(model.error ?? "nil")")
        try require(model.lfsActions(model.visibleEntries).isEmpty,"Failed visible LFS lookup granted a lock/unlock command")
        let warnedGeometry=try await reportGeometry(owner)
        try require(beforeWarning.matches(warnedGeometry),"Optional LFS warning moved or replaced the mounted Commit report/header: before=\(beforeWarning) after=\(warnedGeometry)")
        try await acknowledgeError(owner)
        try require(model.fileListReadWarnings == [lockWarning] && model.feedbackMessages.contains(lockWarning),"Acknowledging the LFS alert erased its accepted ownership warning")
        let acknowledgedGeometry=try await reportGeometry(owner)
        try require(beforeWarning.matches(acknowledgedGeometry),"LFS acknowledgement moved or replaced the mounted Commit report/header")
        model.queryLFSOwners={_ in try await withCheckedThrowingContinuation {locks=$0}};model.reload(paths:["b"]);try await wait {locks != nil}
        try require(model.scopePaths == ["a"] && model.fileListReadWarnings == [lockWarning] && !model.lfsOwnershipKnown,"Pending lock Retry discarded accepted warning/ownership state")
        locks?.resume(returning:[]);locks=nil;try await wait {!model.busy && CommitWindowModel.activeReloads == 0}
        try require(model.scopePaths == ["b"] && model.lfsOwnershipKnown && model.lfsOwners.isEmpty && model.fileListReadWarnings.isEmpty && !model.feedbackMessages.contains(lockWarning),"Accepted healthy lock Retry retained stale warning/unknown ownership")
        let recoveredGeometry=try await reportGeometry(owner)
        try require(beforeWarning.matches(recoveredGeometry),"Healthy lock Retry moved or replaced the mounted Commit report/header")
        let lastRows=model.entries,lastBranch=model.branch,lastScope=model.scopePaths,lastWarnings=model.fileListReadWarnings
        model.queryLFSOwners={_ in try await withCheckedThrowingContinuation {locks=$0}};model.reload(paths:["b"]);try await wait {locks != nil};owner.close()
        try require(CommitWindowModel.activeReloads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired full read lost Quit lifetime")
        locks?.resume(returning:[]);locks=nil;try await wait {CommitWindowModel.activeReloads == 0}
        try require(model.entries == lastRows && model.branch == lastBranch && model.scopePaths == lastScope && model.fileListReadWarnings == lastWarnings,"Retired snapshot published")
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
        // A separate action's unacknowledged diagnostic is not a read warning.
        // Use the live headless model here so native alert acknowledgement is
        // not mistaken for the read transaction clearing an unrelated error.
        fresh.fileColumns.visible.insert(.lfsOwner)
        let unrelated="An unrelated command needs review"
        fresh.error=unrelated;fresh.queryLFSOwners={_ in throw lockFailure};fresh.reload()
        try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.error==unrelated && fresh.fileListReadWarnings == [lockWarning] && !fresh.lfsOwnershipKnown,"Optional lock warning replaced an unrelated action diagnostic")
        fresh.setFileColumn(.lfsOwner,visible:false)
        try require(!fresh.visibleFileColumns.contains(.lfsOwner) && fresh.fileListReadWarnings.isEmpty && fresh.error==unrelated && !fresh.lfsOwnershipKnown,"Hiding LFS ownership retained its warning or discarded another action's diagnostic")
        fresh.setFileColumn(.lfsOwner,visible:true);try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.visibleFileColumns.contains(.lfsOwner) && fresh.fileListReadWarnings == [lockWarning] && fresh.error==unrelated && !fresh.lfsOwnershipKnown,"Showing LFS ownership did not request fresh locks and retain independent diagnostics")
        fresh.queryLFSOwners={_ in []};fresh.reload();try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.error==unrelated && fresh.fileListReadWarnings.isEmpty && fresh.lfsOwnershipKnown,"Healthy read cleared an unrelated action diagnostic or retained its own warning")
        fresh.queryLFSOwners={_ in throw lockFailure};fresh.reload();try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.fileListReadWarnings == [lockWarning] && fresh.resetFileColumns(),"Direct column Reset was not accepted against the LFS warning")
        try require(!fresh.visibleFileColumns.contains(.lfsOwner) && fresh.fileListReadWarnings.isEmpty && fresh.lfsOwners.isEmpty && fresh.lfsLockedPaths.isEmpty && !fresh.lfsOwnershipKnown && fresh.error==unrelated,"Direct column Reset retained LFS state or cleared another diagnostic")
        fresh.queryLFSOwners={_ in [LFSLock(id:"recovered",path:"a",owner:"confirmed owner")]}
        fresh.setFileColumn(.lfsOwner,visible:true);try await wait {!fresh.busy && CommitWindowModel.activeReloads == 0}
        try require(fresh.lfsOwners == ["a":"confirmed owner"] && fresh.lfsOwnershipKnown,"Column Reset owner fixture did not recover actual ownership")
        let reviewedColumns=fresh.fileColumns
        var resetChoice:CheckedContinuation<Bool,Never>?,resetAccepted=0
        fresh.requestResetFileColumns(choose:{await withCheckedContinuation{resetChoice=$0}},onAccepted:{resetAccepted += 1})
        try await wait {resetChoice != nil};resetChoice?.resume(returning:false);resetChoice=nil;try await wait {!fresh.busy}
        try require(resetAccepted==0 && fresh.fileColumns==reviewedColumns && fresh.lfsOwners == ["a":"confirmed owner"] && fresh.lfsOwnershipKnown && fresh.error==unrelated,"Declined column Reset changed accepted ownership/settings")
        fresh.requestResetFileColumns(choose:{true},onAccepted:{resetAccepted += 1});try await wait {!fresh.busy}
        try require(resetAccepted==1 && !fresh.visibleFileColumns.contains(.lfsOwner) && fresh.lfsOwners.isEmpty && fresh.lfsLockedPaths.isEmpty && !fresh.lfsOwnershipKnown && fresh.error==unrelated,"Confirmed column Reset retained LFS ownership or cleared another diagnostic")
        // The LFS column owns only its lookup notice, not another optional
        // first-read failure such as an unavailable message template.
        _=try await real.run(["config","commit.template",".git/missing-template"])
        let seeded=CommitWindowModel(repository:repo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        defer{seeded.invalidateForClose()}
        seeded.fileColumns.visible.insert(.lfsOwner);seeded.queryLFSOwners={_ in throw lockFailure};seeded.reload(paths:["a"])
        try await wait {!seeded.busy && CommitWindowModel.activeReloads == 0}
        guard let templateWarning=seeded.fileListReadWarnings.first(where:{$0.contains("Could not open and load commit.template file")}) else {throw Failure.assertion("Unavailable template warning missing")}
        try require(seeded.fileListReadWarnings.count==2 && seeded.fileListReadWarnings.contains(lockWarning),"Independent template/LFS read warnings were not retained")
        var seededResetAccepted=0
        seeded.requestResetFileColumns(choose:{true},onAccepted:{seededResetAccepted += 1});try await wait {!seeded.busy}
        try require(seededResetAccepted==1 && !seeded.visibleFileColumns.contains(.lfsOwner) && seeded.fileListReadWarnings == [templateWarning] && seeded.error==templateWarning && seeded.feedbackMessages.contains(templateWarning),"Confirmed column Reset erased another accepted read warning")
        seeded.invalidateForClose()
        _=try await real.run(["config","commit.template",".git/message-template"])
        let afterHead=try await real.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head == afterHead && index == afterIndex,"Read pipeline changed HEAD/index")
    }
}
