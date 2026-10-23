// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func commitScopeFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func commitScopeOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));commitScopeOrder(mode,relativeTo:number)}
}
@MainActor @main enum CommitScopeReportPushVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Commit scope/report/push \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<4000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Commit scope/report/push timeout \(line)")}
    static func drained()->Bool{CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeCommitPreflights==0 && MessageEditorStylingSession.activeOperations==0 && PushWindowModel.activePreparationReads==0 && PushWindowModel.activePushWorkflows==0 && ClientHookProcessPool.shared.activeScripts==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.CommitScopeReportPush."+UUID().uuidString,prefs:UserDefaults
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!,workspace:RepositoryModel!,host:NSWindow!
        var owners:[NSWindowController]=[],commits:[CommitWindowController]=[],pushes:[PushWindowController]=[],results:[PushProgressWindowModel]=[],release:[()->Void]=[]
        var lease:RepositoryAccessLease?,wrapper:URL?,configurePush:((PushWindowController)->Void)?
        let inside="folder/inside 雪.txt",outside="outside.txt",renamed="folder/renamed 🧪.txt"
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["UseLibgit2","EnableLogCache","EnableGravatar","Autocompletion","Spellchecker","ConfirmKillProcess"]{prefs.set(false,forKey:key)};prefs.set(true,forKey:"Commit.SkipCancelConfirmation");prefs.set(true,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint")}
        func write(_ path:String,_ text:String)throws{let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)}
        func prepare()async throws{
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Commit family QA"),("user.email","commit@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("tgit.projectlanguage","-1")] {_=try await repo.run(["config",key,value])}
            for path in [inside,outside,"folder/old.txt","folder/deleted.txt","folder/staged-delete.txt"]{try write(path,"base \(path)\n")};try await repo.stage(["."]);_=try await repo.commit(message:"base files")
            try write(inside,"changed inside\n");try write(outside,"changed outside\n")
        }
        func owner(paths:[String]=["folder"])async throws->CommitWindowController{
            let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner);commits.append(owner)
            owner.showWindow(nil);owner.window?.orderFront(nil)
            try await wait(owner.window){owner.model.messageFocusAvailable && !owner.model.busy && !owner.model.preparingCommitIdentity}
            owner.model.reload(paths:paths)
            try await ready(owner);return owner
        }
        func ready(_ owner:CommitWindowController)async throws{try await wait(owner.window){!owner.model.busy && owner.model.changelistsLoaded && !owner.model.inputsBlocked && owner.model.messageFocusAvailable}}
        func workspaceOwner()async throws->CommitWindowController{
            if workspace==nil {
            let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("access.json"))
            let executable=wrapper ?? git
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[executable] in GitRepository(root:$0,executable:executable,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
            workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
            host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
            let preferences=prefs
            lease=RepositoryAccessLease(url:root)
            workspace.commitWindowFactory={ [weak self] repo,_ in let owner=CommitWindowController(repository:repo,access:self?.lease,defaults:preferences);self?.owners.append(owner);self?.commits.append(owner);return owner}
            workspace.pushWindowFactory={ [weak self] repo,access,defaults in
                let owner=PushWindowController(repository:repo,access:access,preferences:defaults)
                owner.model.clientHooks.continueAfterFailure={_ in false}
                self?.owners.append(owner);self?.pushes.append(owner)
                let present=owner.model.onProgress
                owner.model.onProgress={ [weak self] result in self?.results.append(result);present?(result) }
                self?.configurePush?(owner);return owner
            }
            workspace.open(root);try await wait(host){self.workspace.root?.resolvingSymlinksInPath()==self.root.resolvingSymlinksInPath() && !self.workspace.busy}
            }
            try await wait{!self.workspace.busy}
            workspace.activate(.commit,paths:[inside]);let owner=try unwrap(commits.last,"Normal workspace did not create Commit");try await ready(owner);return owner
        }
        func clean()async{release.forEach{$0()};release=[];for owner in owners{if let window=owner.window{window.makeFirstResponder(nil);window.endEditing(for:nil);if let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()}};owner.close()};workspace?.stopMonitoringForTermination();host?.close();for _ in 0..<4000{if drained() && workspace?.busy != true && pushes.allSatisfy({!$0.serviceWorkPending}){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    static func scope(_ c:Context)async throws{
        let owner=try await c.owner(),m=owner.model
        try require(!m.showWholeProject && GitPathSet(m.visibleEntries.map(\.path))==[c.inside],"Subpath invocation did not use source default scoped rows")
        m.checked=[c.inside];m.selection=[c.inside]
        let original=m.queryCommitStatus;var reads=0
        m.queryCommitStatus={amend,token in reads += 1;return try await original(amend,token)}
        try c.write("fresh.txt","fresh root payload\n")
        m.setFormOption(.wholeProject,value:true,receipt:m.formReceipt);try await c.ready(owner)
        try require(reads==1 && m.showWholeProject && m.visibleEntries.contains{$0.path=="fresh.txt"} && m.visibleEntries.contains{$0.path==c.outside},"Whole-project toggle filtered old rows instead of rereading Git")
        try require(m.checked.contains(c.inside),"Scope reread discarded accepted checked file")
        m.checked.remove(c.outside)
        m.setShowWholeProject(false);try await c.ready(owner)
        try require(!m.showWholeProject && !m.visibleEntries.contains{$0.path==c.outside},"Scoped shrink retained unrelated row")
        m.setShowWholeProject(true);try await c.ready(owner)
        try require(m.checked.contains(c.inside) && !m.checked.contains(c.outside),"Scope cycle lost remembered manual check membership")
        owner.close();let reopened=try await c.owner(),next=reopened.model
        try require(next.showWholeProject && next.visibleEntries.contains{$0.path==c.outside},"Per-repository whole-project setting did not survive reopen")
        let accepted=GitPathSet(next.visibleEntries.map(\.path)),checked=next.checked,scope=next.scopePaths,whole=next.showWholeProject
        var reply:CheckedContinuation<[StatusEntry],Error>?,token:OperationCancellation?
        let rows=next.entries
        next.queryCommitStatus={_,value in token=value;return try await withCheckedThrowingContinuation{reply=$0}}
        c.release.append{reply?.resume(returning:rows);reply=nil}
        next.setFormOption(.wholeProject,value:false,receipt:next.formReceipt);try await wait{reply != nil}
        next.cancel(closeWindow:false);try await wait{token?.isCancelled==true}
        reply?.resume(returning:rows);reply=nil;try await c.ready(reopened)
        try require(next.fileListReadCancelled && next.showWholeProject==whole && next.scopePaths==scope && GitPathSet(next.visibleEntries.map(\.path))==accepted && next.checked==checked,"Cancelled scope read published proposed scope/rows/checks")
        // A source-owned sheet and retirement refuse retained form receipts.
        let stale=next.formReceipt,window=try unwrap(reopened.window,"No scope owner window"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;window.beginSheet(sheet,completionHandler:{_ in})
        next.setFormOption(.wholeProject,value:false,receipt:stale);try require(next.showWholeProject==whole && !next.busy,"Attached sheet admitted scope read")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
        reopened.close();next.setFormOption(.wholeProject,value:false,receipt:stale);try require(!next.messageFocusAvailable && next.showWholeProject==whole,"Retired Commit accepted scope callback")
        let scoped=try await c.owner();scoped.model.setShowWholeProject(false);try await c.ready(scoped)
        try require(!c.prefs.bool(forKey:CommitScopePreference.key(root:c.root)),"Accepted scoped read did not persist owning repository preference")
        scoped.close()
        let rootOwner=try await c.owner(paths:["."])
        try require(rootOwner.model.showWholeProject && !c.prefs.bool(forKey:CommitScopePreference.key(root:c.root)),"Root invocation overwrote saved subpath scope")
        rootOwner.close()
        let staging=try await c.owner();try require(!staging.model.showWholeProject,"Root-only invocation leaked its scope into next subpath owner")
        try await c.repo.stage([c.outside]);staging.model.setStagingEnabled(true);try await c.ready(staging)
        try require(staging.model.stagingEnabled && !staging.model.showWholeProject && staging.model.visibleEntries.contains{$0.path==c.outside && staging.model.isStaged($0)},"Scoped staging hid actual index entries outside requested path")
        let acceptedStaging=GitPathSet(staging.model.visibleEntries.map(\.path)),stagedRows=staging.model.entries
        var closeReply:CheckedContinuation<[StatusEntry],Error>?,closeToken:OperationCancellation?
        staging.model.queryCommitStatus={_,value in closeToken=value;return try await withCheckedThrowingContinuation{closeReply=$0}}
        c.release.append{closeReply?.resume(returning:stagedRows);closeReply=nil}
        staging.model.setShowWholeProject(true);try await wait{closeReply != nil}
        staging.close();try require(closeToken?.isCancelled==true && !staging.model.messageFocusAvailable,"Forced close abandoned scope read ownership")
        closeReply?.resume(returning:stagedRows);closeReply=nil;try await wait{drained()}
        try require(!staging.model.showWholeProject && GitPathSet(staging.model.visibleEntries.map(\.path))==acceptedStaging,"Late closed-owner scope reply published proposed state")
    }
    static func report(_ c:Context)async throws{
        _=try await c.repo.run(["rm","--","folder/staged-delete.txt"])
        _=try await c.repo.run(["mv","--","folder/old.txt",c.renamed]);try FileManager.default.removeItem(at:c.root.appendingPathComponent("folder/deleted.txt"));try c.write("folder/added 雪.txt","new\n")
        let owner=try await c.owner(paths:["."]),m=owner.model
        let head=try await c.repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        m.checked=GitPathSet(m.visibleEntries.map(\.id));m.checked.remove(c.outside);m.selection=[c.outside];m.setFileSortOrder([CommitFileSort(column:.path,order:.reverse)])
        let report=m.checkedFileList
        let ordered=m.displayedFileEntries.filter{m.checked.contains($0.id)}
        try require(!report.isEmpty && report.contains("folder/renamed 🧪.txt (from folder/old.txt)"),"Report omitted native displayed rename path")
        var position=report.startIndex
        for entry in ordered{let path=m.fileListDisplayedPath(entry);guard let match=report.range(of:path,range:position..<report.endIndex) else{throw Failure(description:"Report omitted/reordered "+path)};position=match.upperBound}
        try require(report.contains("Added") && report.contains("Missing") && report.contains("Deleted") && report.contains("Modified") && report.contains("Rename"),"Report omitted source action labels");try require(!report.contains(c.outside),"Report used highlighted selection instead of checked membership")
        try require(m.fileListReportInEnglish,"Absent project report-language policy did not default to English")
        c.prefs.set(true,forKey:"AbbreviateRenamings")
        try require(m.checkedFileList.contains("folder/{old.txt => renamed 🧪.txt}"),"Report ignored displayed rename abbreviation")
        c.prefs.set(false,forKey:"AbbreviateRenamings")
        let editor=try unwrap(views(owner.window?.contentView).compactMap{$0 as? CommitMessageTextView}.first,"Missing actual Commit editor")
        m.message="report:\n";try await wait(owner.window){editor.string==m.message};editor.setSelectedRange(.init(location:editor.string.utf16.count,length:0));editor.performCommitMenuCommand(.pasteFiles)
        try await wait(owner.window){m.message=="report:\n"+report};try require(editor.string==m.message,"Actual Paste file list action lost report")
        _=try await c.repo.run(["config","tsvn.logfilelistenglish","false"]);m.reload();try await c.ready(owner)
        try require(!m.fileListReportInEnglish && !m.checkedFileList.isEmpty,"Accepted reread did not refresh declared report language policy")
        let before=m.message;m.confirmingQuit=true;editor.performCommitMenuCommand(.pasteFiles);try require(m.message==before,"Quit accepted retained report action");m.confirmingQuit=false
        let finalHead=try await c.repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:c.root.appendingPathComponent(".git/index")))==index,"Report display/paste changed Git history or index")
    }
    static func push(_ c:Context)async throws{
        let remote=c.base.appendingPathComponent("origin.git")
        let origin=GitRepository(root:remote,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))
        try FileManager.default.createDirectory(at:remote,withIntermediateDirectories:true)
        _=try await origin.run(["init","--bare","--template=","-b","main"])
        _=try await c.repo.run(["remote","add","origin",remote.path]);_=try await c.repo.run(["push","-u","origin","main"])
        func quote(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let wrapper=c.base.appendingPathComponent("held-helper"),hold=c.base.appendingPathComponent("hold-push"),marker=c.base.appendingPathComponent("push-ready"),release=c.base.appendingPathComponent("release-push")
        let script="#!/bin/sh\nfor arg do\n if [ \"$arg\" = push ] && [ -f "+quote(hold.path)+" ]; then\n  : > "+quote(marker.path)+"\n  while [ ! -f "+quote(release.path)+" ]; do /bin/sleep 0.02; done\n fi\ndone\nexec "+quote(c.git.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path);c.wrapper=wrapper
        c.release.append{try? Data().write(to:release)}
        func prepare(_ text:String,amend:Bool=false)async throws->CommitWindowController{
            try c.write(c.inside,text+"\n")
            let owner=try await c.workspaceOwner(),m=owner.model
            if amend {m.setFormOption(.amend,value:true,receipt:m.formReceipt);try await wait(owner.window){!m.busy && !m.loadingAmendMessage}}
            m.message="private "+text;m.checked=[c.inside]
            try await wait(owner.window){m.canCommit};return owner
        }
        func nextPush(after count:Int)async throws->PushWindowController{try await wait{c.pushes.count==count+1};return try unwrap(c.pushes.last,"No actual Push continuation")}
        func closePush(_ owner:PushWindowController)async throws{owner.model.cancel();try await wait{owner.model.closed && !owner.serviceWorkPending}}
        let warningScript=c.base.appendingPathComponent("post-push-warning.sh")
        try Data("#!/bin/sh\nprintf 'PRIVATE POST PUSH WARNING\\n' >&2\nexit 7\n".utf8).write(to:warningScript)
        let warningHook=ClientHook(type:.postPush,path:c.root.path,command:"/bin/sh "+quote(warningScript.path),show:false)
        c.prefs.set(try ClientHookConfiguration.serialize([warningHook]),forKey:"hooks")
        c.prefs.set(2,forKey:"AutoCloseGitProgress")
        let first=try await prepare("mapped footer")
        let replacementSuite=c.suite+".replacement",replacement=UserDefaults(suiteName:replacementSuite)!
        defer{replacement.removePersistentDomain(forName:replacementSuite)}
        replacement.set(false,forKey:"UseLibgit2");replacement.set("replacement owner",forKey:"QA.Marker");c.workspace.fileComparisonPreferences=replacement
        first.model.commit(.push)
        let direct=try await nextPush(after:0)
        try await wait{direct.model.progress?.busy==false && !direct.model.transportRunning}
        let result=try unwrap(direct.model.progress,"Missing direct actual transport result")
        let committed=try await c.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let delivered=try await origin.run(["rev-parse","refs/heads/main"]).text.trimmingCharacters(in:.newlines)
        try require(result.success && committed==delivered && direct.progressOnly && direct.model.directContinuation && direct.window?.isVisible != true,"Mapped ordinary footer failed direct actual push or showed form")
        try require(direct.model.settingsPreferences === c.prefs && direct.model.repositoryAccess === first.model.access && direct.model.repositoryAccess != nil && !first.model.messageFocusAvailable,"Footer lost captured settings/access or source-close handoff")
        try require(result.hasCompletionWarning && result.output.contains("post-push hook failed") && result.output.contains("PRIVATE POST PUSH WARNING") && direct.progressController != nil,"Streamed successful Push lost post-hook warning or auto-closed it")
        result.close();try await wait{direct.model.closed && !direct.serviceWorkPending}
        c.workspace.fileComparisonPreferences=c.prefs
        c.prefs.removeObject(forKey:"hooks");c.prefs.set(0,forKey:"AutoCloseGitProgress")
        let amend=try await prepare("amended footer",amend:true);amend.model.commit(.push)
        let amended=try await nextPush(after:1);try await wait{!amended.model.busy && !amended.model.preparing}
        try require(!amended.progressOnly && !amended.model.directContinuation && amended.model.progress==nil && amended.window?.isVisible==true,"Amend footer silently bypassed Push form")
        try await closePush(amended)
        let ordinary=try await prepare("progress menu")
        ordinary.model.commit(.commit)
        try await wait{ordinary.model.commitProgress?.busy==false}
        let commitResult=try unwrap(ordinary.model.commitProgress,"Missing actual Commit progress menu")
        try require(commitResult.success && commitResult.postActions.contains(.push),"Successful Commit omitted source Push post-action")
        commitResult.choose(.push)
        let fromMenu=try await nextPush(after:2);try await wait{!fromMenu.model.busy && !fromMenu.model.preparing}
        try require(!fromMenu.progressOnly && !fromMenu.model.directContinuation && fromMenu.model.progress==nil,"Progress-menu Push was mistaken for direct footer")
        try await closePush(fromMenu)
        _=try await c.repo.run(["config","--unset","branch.main.remote"]);_=try await c.repo.run(["config","--unset","branch.main.merge"])
        let unmapped=try await prepare("unmapped footer");unmapped.model.commit(.push)
        let fallback=try await nextPush(after:3);try await wait{!fallback.model.busy && !fallback.model.preparing}
        try require(!fallback.progressOnly && !fallback.model.directContinuation && fallback.model.progress==nil && fallback.window?.isVisible==true,"Sole remote incorrectly supplied missing branch mapping")
        try await closePush(fallback)
        _=try await c.repo.run(["config","branch.main.remote","origin"]);_=try await c.repo.run(["config","branch.main.merge","refs/heads/main"])
        let beforeCancel=try await origin.run(["rev-parse","refs/heads/main"]).stdout
        let failureScript=c.base.appendingPathComponent("pre-push-failure.sh")
        try Data("#!/bin/sh\nprintf 'PRIVATE PREFLIGHT FAILURE\\n' >&2\nexit 9\n".utf8).write(to:failureScript)
        let failureHook=ClientHook(type:.prePush,path:c.root.path,command:"/bin/sh "+quote(failureScript.path),show:false)
        c.prefs.set(try ClientHookConfiguration.serialize([failureHook]),forKey:"hooks")
        let rejected=try await prepare("preflight failure");rejected.model.commit(.push)
        let failed=try await nextPush(after:4)
        try await wait{failed.model.progress?.busy==false && !failed.model.transportRunning}
        let failedResult=try unwrap(failed.model.progress,"Direct preflight failure had no reviewable result")
        try require(!failedResult.success && failedResult.output.contains("PRIVATE PREFLIGHT FAILURE") && failed.progressOnly && failed.progressController != nil && failed.window?.isVisible != true,"Direct preflight failure vanished or opened fallback form")
        let afterFailure=try await origin.run(["rev-parse","refs/heads/main"]).stdout
        try require(afterFailure==beforeCancel,"Failed preflight changed remote")
        failedResult.close();try await wait{failed.model.closed && !failed.serviceWorkPending}
        c.prefs.removeObject(forKey:"hooks")
        try Data().write(to:hold)
        let held=try await prepare("held footer");held.model.commit(.push)
        let pending=try await nextPush(after:5)
        try await wait{FileManager.default.fileExists(atPath:marker.path) && pending.model.transportRunning && pending.model.progress?.busy==true}
        try require(pending.model.settingsPreferences === c.prefs && pending.model.repositoryAccess === held.model.access && !held.model.messageFocusAvailable,"Held transport lost immutable accepted owner")
        pending.close();try await wait{pending.model.closed && !pending.serviceWorkPending && drained()}
        let afterCancel=try await origin.run(["rev-parse","refs/heads/main"]).stdout
        try require(beforeCancel==afterCancel && pending.progressController==nil && pending.window?.isVisible != true,"Closed held Push published transport or leaked standalone result")
        try require(c.pushes.count==6,"Late canceled continuation created another Push form")
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.commitScopeFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.commitScopeOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "scope":try await scope(c);case "report":try await report(c);case "push":try await push(c);default:throw Failure(description:"Unknown Commit case")};await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Commit family windows/work survived cleanup");print("PASS: commit scope report push "+kind);fflush(stdout)}catch{await c.clean();fputs("Commit family failed: \(error)\n",stderr);exit(1)}
    }
}
