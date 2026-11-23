// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Same private receiver cohort as Add/Resolve; no physical desktop events.
@MainActor enum SyncPrimaryActivationVerification {
    typealias Prior=StatusPrimaryActivationVerification
    typealias Context=StatusPrimarySelectionVerification.Context
    static func require(_ value:Bool,_ message:String)throws {try Prior.require(value,"Sync primary: "+message)}
    static func wait(_ message:String,diagnostic:(()->String)?=nil,_ ready:()->Bool)async throws {
        do {try await Prior.wait(message,ready)}
        catch {try require(false,message+(diagnostic.map{"; "+$0()} ?? ""));throw error}
    }
    static func views(_ owner:NSWindowController)->[NSView] {Prior.views(owner.window?.contentView)}
    static func key(_ window:NSWindow,text:String="\r",code:UInt16=36,flags:NSEvent.ModifierFlags=[])throws->NSEvent {
        try Prior.unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code),"Native event missing")
    }
    static func own(_ owner:NSWindowController,_ c:Context) {
        c.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
    }
    static func conflicts(_ c:Context)async throws {
        let seed=try await c.repository.conflicts(paths:[c.conflict])[0]
        let extras=["extra sync conflict 1.txt","extra sync conflict 2.txt"]
        var records=""
        for path in extras {
            for stage in seed.stages {records += "\(stage.mode) \(stage.object) \(stage.number)\t\(path)\0"}
            let bytes=Data("private extra conflict\n".utf8);try bytes.write(to:c.root.appendingPathComponent(path));c.working[path]=bytes
        }
        _=try await c.repository.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let owner=SynchronizationWindowController(repository:c.repository,access:nil,preferences:c.prefs),model=owner.model
        own(owner,c);let window=try Prior.unwrap(owner.window,"Sync window missing")
        try await wait("Sync initial read did not drain"){!model.busy && !model.hasPendingInlineWork}
        model.tab=6;model.refreshConflictFiles()
        try await wait("Sync conflicts did not mount") {
            window.contentView?.layoutSubtreeIfNeeded()
            return !model.conflictFileActions.busy && model.conflictFileActions.sortedRows.count==4 &&
                views(owner).compactMap{$0 as? ConflictReportNativeTable}.first?.numberOfRows==4
        }
        var table=try Prior.unwrap(views(owner).compactMap{$0 as? ConflictReportNativeTable}.first,"Sync native conflict report absent")
        let ordered=model.conflictFileActions.sortedRows.map(\.path)
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<ordered.count))
        try await wait("Sync native selected paths did not settle"){model.conflictFileActions.selection==GitPathSet(ordered)}
        table.commandKeyWindow={[weak window] in window}
        func enter(_ flags:NSEvent.ModifierFlags=[],code:UInt16=36)async throws {
            try await wait("Conflict report not available for native Return"){window.contentView?.layoutSubtreeIfNeeded();return table.isEnabled && window.isVisible && !table.isHiddenOrHasHiddenAncestor && !model.conflictFileActions.busy && model.canUseConflictFiles}
            try require(window.makeFirstResponder(table) && window.firstResponder === table,"Conflict source refused focus")
            try require(window.performKeyEquivalent(with:key(window,code:code,flags:flags)),"Default Close stole selected conflict Return")
        }
        var warnings:[Int]=[],launches=0,seen:[String]=[]
        model.confirmPrimaryConflictActivation={warnings.append($0);return false}
        model.onPrimaryConflictActivation={_,_ in launches += 1}
        try await enter();try await wait("Declined conflict warning did not drain"){!model.primaryConflictActivationPending}
        try require(warnings==[4] && launches==0,"Conflict warning did not decline all four rows together")
        let actual=try await c.repository.conflicts(paths:ordered)
        let actualMap=GitPathMap(uniqueKeysWithValues:actual.map{($0.path,$0)})
        var acceptedOwner:(()->Bool)?
        model.confirmPrimaryConflictActivation={warnings.append($0);return true}
        model.onPrimaryConflictActivation={plan,_ in
            try require(plan.entries==ordered.compactMap{actualMap[$0]},"Real stages/order were truncated or fabricated")
            try require(plan.window === window && plan.preferences === c.prefs && plan.alternateTool && !plan.isRebase,"Originating window/settings/Shift/rebase changed")
            try require(plan.repository.executable==c.repository.executable && plan.repository.libgit2Configuration?.enabled==false && plan.ownerIsCurrent(),"Captured runtime/backend/owner changed")
            seen=plan.entries.map(\.path);acceptedOwner=plan.ownerIsCurrent;launches += 1
        }
        try await enter(.shift,code:76);try await wait("Full selected keypad Return did not drain"){!model.primaryConflictActivationPending}
        try require(seen==ordered && launches==1 && warnings==[4,4] && acceptedOwner?()==false,"Selected conflict ownership/count leaked after completion")
        // Foreign events and text focus may never trigger the dialog default.
        let foreign=NSWindow(contentRect:.init(x:-26000,y:-26000,width:160,height:90),styleMask:[.titled],backing:.buffered,defer:false)
        foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.orderFront(nil);defer{foreign.close()}
        try require(!table.performSelectedReturn(key(foreign)),"Foreign Return acquired Sync selection")
        try require(!table.performSelectedReturn(key(window,flags:.command)),"Command Return was stolen")
        let field=NSTextField(frame:.init(x:1,y:1,width:120,height:22));window.contentView?.addSubview(field);defer{field.removeFromSuperview()}
        try require(window.makeFirstResponder(field),"Private field refused focus")
        try require(!table.performSelectedReturn(key(window)),"Text focus activated conflict rows")
        // The explicit Edit Conflict popup remains singleton-only.
        var popup=0;model.onConflictAction={_,_ in popup += 1}
        model.performConflict(.editConflict,menu:model.conflictMenu(ordered,mark:ordered[0]))
        try require(popup==0,"Multi-row context Edit bypassed singleton mask")
        // Hold a real source warning. Selection replacement retires the whole
        // request but retains worker/Quit ownership until its answer returns.
        var release:CheckedContinuation<Bool,Never>?
        c.unblock.append{release?.resume(returning:false);release=nil}
        model.confirmPrimaryConflictActivation={_ in await withCheckedContinuation{release=$0}}
        try await enter();try await wait("Held warning absent"){release != nil}
        model.tab=0
        try require(model.primaryConflictActivationPending && SynchronizationWindowModel.activeInlineOperations>0,"Live held source worker released early")
        release?.resume(returning:true);release=nil
        try await wait("Replaced warning did not drain"){!model.primaryConflictActivationPending}
        try require(launches==1,"Tab-replaced warning launched late conflict children")
        model.tab=6
        try await wait("Conflict source did not re-enable"){model.canUseConflictFiles && !model.conflictFileActions.busy}
        try await wait("Conflict report did not remount"){window.contentView?.layoutSubtreeIfNeeded();return views(owner).compactMap{$0 as? ConflictReportNativeTable}.first?.numberOfRows==4}
        table=try Prior.unwrap(views(owner).compactMap{$0 as? ConflictReportNativeTable}.first,"Remounted conflict table absent")
        table.commandKeyWindow={[weak window] in window}
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<ordered.count))
        try await wait("Remounted conflict selection did not restore"){model.conflictFileActions.selection==GitPathSet(ordered)}
        // Exercise actual Root preparation and the paired progress boundary.
        let root=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:c.root.appendingPathComponent("sync-finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("sync-marks.json")),cachePersistenceDefaults:c.prefs)
        c.roots.append(root);root.fileComparisonPreferences=c.prefs
        var children:[String]=[],nested=0,parentDetached=true
        root.fileComparisonQuestion={_ in nested += 1;return false}
        root.openExternalConflict={_,_,_,_,_,_,_,prepared,_ in prepared();return false}
        root.conflictEditorPresentation={_,_,path,_ in
            parentDetached = parentDetached && window.attachedSheet==nil
            children.append(path)
        }
        model.confirmPrimaryConflictActivation=nil
        model.onPrimaryConflictActivation={plan,token in try await root.showConflictListPrimaryFiles(plan,access:nil,cancellation:token)}
        try await enter();try await wait("Actual affirmative conflict warning absent"){window.attachedSheet != nil}
        let affirmative=try Prior.unwrap(window.attachedSheet,"Affirmative conflict sheet missing")
        let yes=try Prior.unwrap(Prior.views(affirmative.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"},"Actual conflict Yes button absent")
        yes.performClick(nil)
        try await wait("Root conflict launch did not drain"){!model.primaryConflictActivationPending && !root.hasPendingRepositoryWork}
        try require(children==ordered && nested==0 && parentDetached && affirmative.sheetParent==nil && window.attachedSheet !== affirmative,"Root truncated/reordered conflicts or warned twice")
        model.confirmPrimaryConflictActivation=nil
        try await enter();try await wait("Native selected conflict warning absent"){window.attachedSheet != nil}
        let warning=try Prior.unwrap(window.attachedSheet,"Native warning missing")
        try require(!owner.windowShouldClose(window),"Close bypassed live conflict warning")
        try await wait("Source close did not drain paired conflict warning"){!model.primaryConflictActivationPending && warning.sheetParent==nil && window.attachedSheet !== warning}
        try require(children==ordered,"Cancelled native warning launched children")
        model.confirmPrimaryConflictActivation={_ in true}
        // Actual held preparation keeps both source close and global Quit owned.
        var readRelease:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?
        c.unblock.append{readRelease?.resume();readRelease=nil}
        root.readConflictEditorEntry={repository,path,token in
            let value=try await repository.conflictEditorEntry(path:path,cancellation:token)
            readToken=token;await withCheckedContinuation{readRelease=$0};return value
        }
        var closed=0;owner.onClosed={closed += 1}
        try await enter();try await wait("Actual conflict preparation not held"){readRelease != nil}
        window.close()
        try require(readToken?.isCancelled==true && model.primaryConflictActivationPending && closed==0,"Forced close released actual conflict worker")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped live Sync conflict worker")
        readRelease?.resume();readRelease=nil
        try await wait("Closed source/progress worker did not drain"){!model.primaryConflictActivationPending && closed==1 && !root.hasPendingRepositoryWork}
        try require(children==ordered,"Closed source delivered another conflict child")
        try await c.preserved()
    }
    static func comparisons(_ c:Context)async throws {
        let folder=c.root.deletingLastPathComponent().appendingPathComponent("sync-revision-primary",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repository=GitRepository(root:folder,executable:c.repository.executable,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","-b","main"])
        for(key,value)in[("user.name","Sync revisions QA"),("user.email","sync@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        let paths=["a.swift","b.txt","c.txt","d.txt"]
        for path in paths {try Data("base\n".utf8).write(to:folder.appendingPathComponent(path))}
        try await repository.stage(paths);_=try await repository.commit(message:"base")
        let base=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        // Out Changelist is admitted by the real outgoing projection, not by
        // assigning an embedded snapshot alone. Retain a private tracked base
        // before advancing main, as in the retained native Sync-list fixture.
        let remote=folder.deletingLastPathComponent().appendingPathComponent("sync-primary-origin.git",isDirectory:true)
        _=try await repository.run(["clone","--bare","--template=","--",folder.path,remote.path])
        _=try await repository.run(["remote","add","origin",remote.path])
        _=try await repository.run(["fetch","origin"])
        _=try await repository.run(["branch","--set-upstream-to=origin/main","main"])
        for path in paths {try Data("next\n".utf8).write(to:folder.appendingPathComponent(path))}
        try await repository.stage(paths);_=try await repository.commit(message:"next")
        let head=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let snapshot=try await repository.revisionComparison(from:.revision(base),to:.revision(head))
        let owner=SynchronizationWindowController(repository:repository,access:nil,preferences:c.prefs),model=owner.model
        own(owner,c);let window=try Prior.unwrap(owner.window,"Revision source window missing")
        let diagnostic:()->String={
            "tab=\(model.tab), busy=\(model.busy), pending=\(model.hasPendingInlineWork), error=\(String(reflecting:model.error)), local=\(String(reflecting:model.localBranch)), remote=\(String(reflecting:model.remote)), remoteBranch=\(String(reflecting:model.remoteBranch)), outgoing=\(String(describing:model.outgoing?.disposition)), projectionRows=\(String(describing:model.outgoing?.comparison?.files.count)), outRows=\(String(describing:model.comparison.snapshot?.files.count)), inRows=\(String(describing:model.incomingComparison.snapshot?.files.count)), native=\(views(owner).compactMap{$0 as? SynchronizationFileNativeTable}.map{($0.identifier?.rawValue ?? "nil")+":\($0.numberOfRows)"})"
        }
        // showWindow schedules SwiftUI onAppear. Initial !busy alone is not a
        // receipt that the initial branch/projection read has even started.
        try await wait("Revision Sync initialization did not settle",diagnostic:diagnostic){
            window.contentView?.layoutSubtreeIfNeeded()
            return !model.busy && !model.hasPendingInlineWork && (model.outgoing != nil || model.error != nil)
        }
        try require(model.outgoing?.comparison?.files.count==4,"Actual outgoing projection did not admit four-row Out Changelist; "+diagnostic())
        for incoming in [false,true] {
            model.tab=incoming ? 5:1
            let child=incoming ? model.incomingComparison:model.comparison,state=incoming ? model.incomingFileList:model.outgoingFileList
            child.installEmbeddedSnapshot(snapshot,bare:false)
            let identifier="TurtleGit.Sync.Files."+(incoming ? "In":"Out")
            try await wait("Native Sync revision table absent",diagnostic:diagnostic) {
                window.contentView?.layoutSubtreeIfNeeded()
                return views(owner).compactMap{$0 as? SynchronizationFileNativeTable}.first{$0.identifier?.rawValue==identifier}?.numberOfRows==4
            }
            let table=try Prior.unwrap(views(owner).compactMap{$0 as? SynchronizationFileNativeTable}.first{$0.identifier?.rawValue==identifier},"Revision table missing")
            table.keyOwnerQuery={[weak window] candidate in candidate === window}
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<4))
            try await wait("Native revision selection absent"){state.selection==GitPathSet(paths)}
            try await wait("Revision report not available for Return"){table.contextMenuAvailable() && window.isVisible && !table.isHiddenOrHasHiddenAncestor}
            try require(window.makeFirstResponder(table),"Revision table refused first responder")
            var opened:[String]=[],endpointsCorrect=true,warningDetached=true
            child.confirmManyDiffs=nil
            child.openComparedFile={captured,file in
                opened.append(file.path);warningDetached = warningDetached && window.attachedSheet==nil
                endpointsCorrect = endpointsCorrect && captured.from == .revision(base) && captured.to == .revision(head)
            }
            try require(window.performKeyEquivalent(with:key(window,flags:.shift)),"Revision Return escaped to Close")
            try await wait("Actual affirmative revision warning absent"){window.attachedSheet != nil}
            let affirmative=try Prior.unwrap(window.attachedSheet,"Affirmative revision sheet missing")
            let yes=try Prior.unwrap(Prior.views(affirmative.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"},"Actual revision Yes button absent")
            yes.performClick(nil)
            try await wait("Revision selected operation did not drain"){!child.hasOwnedPreparation && !child.busy}
            try require(opened==state.rows.map(\.path) && endpointsCorrect && warningDetached && affirmative.sheetParent==nil && window.attachedSheet !== affirmative,"Revision endpoint/order/one-warning parity changed")
            let row=0,column=0,rect=table.frameOfCell(atColumn:column,row:row)
            let point=table.convert(.init(x:rect.midX,y:rect.midY),to:nil)
            let event=try Prior.unwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),"Popup event absent")
            let menu=try Prior.unwrap(table.menu(for:event),"Revision popup absent"),defaultItem=try Prior.unwrap(menu.items.first,"Default comparison absent")
            try require(defaultItem.identifier?.rawValue=="Sync.Files.compare" && defaultItem.attributedTitle != nil && defaultItem.image != nil,"Source default Compare menu lacks bold/icon")
            let foreign=NSWindow(contentRect:.init(x:-26000,y:-26000,width:150,height:90),styleMask:[.titled],backing:.buffered,defer:false)
            foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.orderFront(nil);defer{foreign.close()}
            try require(!table.performSelectedReturn(key(foreign)),"Foreign revision Return consumed")
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};state.clipboard=board
            try require(!table.performKeyEquivalent(with:key(foreign,text:"c",code:8,flags:.command)) && board.string(forType:.string)==nil,"Foreign Cmd-C copied source rows")
            var release:CheckedContinuation<Bool,Never>?
            c.unblock.append{release?.resume(returning:false);release=nil}
            child.confirmManyDiffs={_ in await withCheckedContinuation{release=$0}}
            try require(window.performKeyEquivalent(with:key(window)),"Held revision Return escaped")
            try await wait("Revision warning absent"){release != nil}
            state.selection=GitPathSet([paths[0]])
            try require(child.hasOwnedPreparation,"Held warning lost ownership before answer")
            release?.resume(returning:true);release=nil
            try await wait("Replaced revision selection did not drain"){!child.hasOwnedPreparation && !child.busy}
            try require(opened.count==4,"Changed selection launched stale revision children")
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(integersIn:0..<4))
            try await wait("Revision full selection failed to restore"){state.selection==GitPathSet(paths) && table.contextMenuAvailable()}
            child.confirmManyDiffs=nil
            try require(window.makeFirstResponder(table),"Revision warning source refused focus")
            try require(window.performKeyEquivalent(with:key(window)),"Native revision warning Return escaped")
            try await wait("Native revision warning absent"){window.attachedSheet != nil}
            let warning=try Prior.unwrap(window.attachedSheet,"Revision warning missing")
            try require(!owner.windowShouldClose(window),"Close bypassed native revision warning")
            try await wait("Source close did not drain paired revision warning"){!child.hasOwnedPreparation && !child.busy && warning.sheetParent==nil && window.attachedSheet !== warning}
            try require(opened.count==4,"Cancelled native revision warning launched children")
        }
        owner.close()
    }
    static func verify(base:URL,git:URL)async throws {
        let c=try Context(base:base.appendingPathComponent("sync-primary",isDirectory:true),git:git)
        do {
            try await c.setup();c.prefs.set(3,forKey:"NumDiffWarning")
            try MergeToolPreferences.load(from:c.prefs).save(to:c.prefs)
            try await conflicts(c);try await comparisons(c)
            await c.cleanup()
            try await wait("Owned Sync workers did not drain"){SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowController.activeInlineReleases==0 && Prior.drained()}
        } catch {await c.cleanup();throw error}
        print("PASS: Sync ordered conflict/revision selected Return, real stages and captured Root ownership, one warning, strict event/default-button scope and late-worker drain")
    }
}
