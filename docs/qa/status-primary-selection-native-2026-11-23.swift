// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Mounted source reports and the real owned Root launch API, with private Git,
/// preferences and injected child presentations. No desktop event is posted.
@MainActor enum StatusPrimarySelectionVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {try Prior.require(value,"Selected Return \(line): "+message)}
    static func wait(_ message:String,_ ready:()->Bool)async throws {try await Prior.wait(message,ready)}
    enum Kind:CaseIterable {case commit,status,revert}
    @MainActor final class Context {
        let root:URL,repository:GitRepository,prefs:UserDefaults,suite:String
        let conflict="a conflict 雪.txt",other="b conflict.txt",normal="c ordinary.txt",untracked="d untracked.txt",retained="e retained copy.txt",missing="f missing-added.txt"
        var surfaces:[Surface]=[],roots:[RepositoryModel]=[]
        var owners:[NSWindowController]=[],unblock:[()->Void]=[],head=Data(),index=Data(),working:[String:Data]=[:]
        init(base:URL,git:URL)throws {
            root=base.appendingPathComponent("selected-primary-family",isDirectory:true).standardizedFileURL
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.SelectedPrimary."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit"] {prefs.set(true,forKey:key)}
            for key in ["TurtleGit.Commit.GitGuiInterface","SelectFilesForCommit","UseLibgit2","EnableGravatar"] {prefs.set(false,forKey:key)}
            prefs.set(3,forKey:"NumDiffWarning")
        }
        func setup()async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Selected primary QA"),("user.email","selected-primary@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repository.run(["config",key,value])}
            for path in [conflict,other,normal,retained] {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
            try await repository.stage(["."]);_=try await repository.commit(message:"Selected Return source")
            let base=try await repository.run(["rev-parse","HEAD:"+normal]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let mine=try await repository.run(["hash-object","-w","--stdin"],input:Data("mine\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let theirs=try await repository.run(["hash-object","-w","--stdin"],input:Data("theirs\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            var records=""
            for path in [conflict,other] {
                records += "0 "+String(repeating:"0",count:40)+"\t"+path+"\0"+"100644 \(base) 1\t\(path)\0"+"100644 \(mine) 2\t\(path)\0"+"100644 \(theirs) 3\t\(path)\0"
                try Data("<<<<<<< mine\nmine\n=======\ntheirs\n>>>>>>> theirs\n".utf8).write(to:root.appendingPathComponent(path))
            }
            _=try await repository.run(["update-index","-z","--index-info"],input:Data(records.utf8))
            try Data("modified ordinary\n".utf8).write(to:root.appendingPathComponent(normal))
            try Data("untracked original\n".utf8).write(to:root.appendingPathComponent(untracked))
            try Data("missing index original\n".utf8).write(to:root.appendingPathComponent(missing));try await repository.stage([missing]);try FileManager.default.removeItem(at:root.appendingPathComponent(missing))
            _=try await repository.run(["rm","--cached","--",retained])
            head=try await repository.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            for path in [conflict,other,normal,untracked,retained] {working[path]=try Data(contentsOf:root.appendingPathComponent(path))}
        }
        var all:[String] {[conflict,other,normal,untracked,retained,missing]}
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Primary activation changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Primary activation changed index")
            for(path,bytes)in working {try require(try Data(contentsOf:root.appendingPathComponent(path))==bytes,"Primary activation changed working bytes: "+path)}
            try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(missing).path),"Primary activation restored a missing staged file")
        }
        func cleanup()async {
            owners.forEach{$0.close()};roots.forEach{$0.stopMonitoringForTermination()};unblock.forEach{$0()};unblock=[]
            for _ in 0..<3000 {if Prior.drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            surfaces.forEach{$0.launch(nil);$0.confirm(nil)}
            if !head.isEmpty {_ = try? await repository.run(["update-ref","HEAD",String(decoding:head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)])}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    @MainActor final class Surface {
        let kind:Kind,owner:NSWindowController
        let commit:CommitWindowController?,status:StatusWindowController?,revert:RevertWindowController?
        var closed=0
        init(_ kind:Kind,_ c:Context) {
            self.kind=kind
            switch kind {
            case .commit:
                let controller=CommitWindowController(repository:c.repository,access:nil,defaults:c.prefs)
                commit=controller;status=nil;revert=nil;owner=controller
                controller.model.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
            case .status:
                let controller=StatusWindowController(repository:c.repository,access:nil,defaults:c.prefs)
                status=controller;commit=nil;revert=nil;owner=controller
                controller.model.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
            case .revert:
                let controller=RevertWindowController(repository:c.repository,access:nil,preferences:c.prefs)
                revert=controller;commit=nil;status=nil;owner=controller
                controller.model.commands.missingStagedRecovery.choose={_ in .init(action:.ignore,doSameForRest:true)}
            }
            c.surfaces.append(self);c.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            let completed:()->Void = {[weak self] in self?.closed += 1}
            commit?.onClosed=completed;status?.onClosed=completed;revert?.onClosed=completed
            commit?.model.reload(paths:["."]);status?.model.reload();revert?.model.setScope(["."])
        }
        var window:NSWindow {owner.window!}
        var pending:Bool {commit?.model.primaryActivationPending ?? status?.model.primaryActivationPending ?? revert!.model.commands.primaryActivationPending}
        var busy:Bool {commit?.model.busy ?? status?.model.busy ?? (revert!.model.busy || revert!.model.commands.busy)}
        var selection:GitPathSet {commit?.model.selection ?? status?.model.selection ?? revert!.model.highlighted}
        var revision:UUID {commit?.model.fileReportRevision ?? status?.model.primaryActionRevision ?? revert!.model.commands.primaryActionRevision}
        func ready()async throws {
            try await wait("Mounted \(kind) source did not settle") {
                if let commit {return commit.model.fileListAvailable && !commit.model.busy && !commit.model.savingPreferences && commit.model.commitIdentityPrepared && commit.model.changelistsLoaded && !commit.model.loadingFileMetadata && !commit.model.fileWorkPending && commit.model.visibleEntries.count>=5}
                if let status {return !status.model.busy && status.model.hasStatusSnapshot}
                return revert!.model.canInteract && revert!.model.entries.count>=4
            }
            _=try await Prior.bridge(owner)
        }
        func launch(_ callback:StatusListPrimaryActivationSession.Launch?) {
            commit?.model.onPrimaryFileActivation=callback;status?.model.onPrimaryFileActivation=callback;revert?.model.onPrimaryFileActivation=callback
        }
        func confirm(_ callback:((Int) async -> Bool)?) {
            commit?.model.confirmPrimaryFileActivation=callback;status?.model.confirmPrimaryFileActivation=callback;revert?.model.confirmPrimaryFileActivation=callback
        }
        func select(_ paths:[String])async throws->[String] {
            let bridge=try await Prior.bridge(owner),wanted=GitPathSet(paths)
            let actual=bridge.rows.compactMap{$0}.filter{wanted.contains($0)}
            try await Prior.select(owner,paths:actual){self.selection==GitPathSet(actual)}
            return actual
        }
        func enter(_ flags:NSEvent.ModifierFlags=[],code:UInt16=36)async throws {
            let bridge=try await Prior.bridge(owner),table=try Prior.table(owner)
            try require(window.makeFirstResponder(table) && window.firstResponder === table,"Source report did not own first responder")
            bridge.commandKeyWindow={[weak self] in self?.window}
            let event=try Prior.unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:code),"No owned native Return")
            try require(bridge.observe(event)==nil,"Owned Return escaped to the dialog's default button")
        }
        func closeRequest()->Bool {
            if let commit {return commit.windowShouldClose(window)}
            if let status {return status.windowShouldClose(window)}
            return revert!.windowShouldClose(window)
        }
        func forceClose() {window.close()}
    }
    static func role(_ action:StatusListPrimaryFileAction)->String {
        switch action {case .conflict:return "conflict";case .comparison:return "comparison";case .workingFile:return "working";case .skipMissing:return "skip"}
    }
    static func checkPlan(_ plan:StatusListPrimaryActivation,_ surface:Surface,_ c:Context,_ ordered:[String],alternate:Bool,mode:StatusListPrimaryActivationMode = .primary) throws {
        try require(plan.actions.map{$0.file.entry.path}==ordered,"Selection order changed or a group/checkbox became a path")
        try require(plan.selectedCount==ordered.count && plan.window === surface.window && plan.preferences === c.prefs,"Source count/window/preferences were recaptured")
        try require(plan.repository.executable==c.repository.executable && plan.repository.libgit2Configuration?.enabled==false && plan.alternateTool==alternate && plan.ownerIsCurrent(),"Source runtime/Shift/owner intent changed")
        for action in plan.actions {
            let path=action.file.entry.path,wanted=mode == .compareWithBase ? "comparison":path==c.conflict || path==c.other ? "conflict":path==c.untracked || path==c.retained ? "working":path==c.missing ? "skip":"comparison"
            try require(role(action)==wanted,"Selected row \(path) default was \(role(action)), expected \(wanted)")
        }
    }
    static func keyboardGuards(_ surface:Surface)async throws {
        let probe=try await Prior.bridge(surface.owner),table=try Prior.table(surface.owner)
        probe.commandKeyWindow={[weak surface] in surface?.window}
        let foreign=NSWindow(contentRect:.init(x:-26000,y:-26000,width:180,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.orderFront(nil);defer{foreign.close()}
        func key(_ window:NSWindow,_ flags:NSEvent.ModifierFlags=[])throws->NSEvent {
            try Prior.unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"No private native key")
        }
        try require(surface.window.makeFirstResponder(table),"Source table refused keyboard focus")
        let foreignEvent=try key(foreign),modified=try key(surface.window,.command)
        try require(probe.observe(foreignEvent) === foreignEvent && probe.observe(modified) === modified,"Foreign/modified Return was stolen")
        let field=NSTextField(frame:.init(x:4,y:4,width:120,height:22));surface.window.contentView?.addSubview(field)
        defer{field.removeFromSuperview()}
        try require(surface.window.makeFirstResponder(field) && surface.window.firstResponder !== table,"Private native field did not own editing")
        let editing=try key(surface.window)
        try require(probe.observe(editing) === editing,"Field-editor Return was stolen by the file report")
        try require(surface.window.makeFirstResponder(table),"Table focus did not return")
        let original=probe.rows;probe.rows=Array(original.dropLast())
        let staleProjection=try key(surface.window)
        try require(probe.observe(staleProjection)==nil,"Stale projection Return reached the dialog button")
        probe.rows=original
        _ = try await surface.select([]);try await surface.enter()
        try require(!surface.pending,"Empty selection activated a source operation")
    }
    static func questions(_ surface:Surface,_ c:Context,_ ordered:[String])async throws {
        var launches=[StatusListPrimaryActivation](),counts=[Int]()
        surface.launch{plan,_ in launches.append(plan)}
        surface.confirm{count in counts.append(count);return false}
        try await surface.enter();try await wait("Declined source question did not drain"){!surface.pending && !surface.busy}
        try require(launches.isEmpty && counts==[ordered.count],"Declined warning read or opened a child")
        var answer:CheckedContinuation<Bool,Never>?
        c.unblock.append{answer?.resume(returning:false);answer=nil}
        surface.confirm{count in counts.append(count);return await withCheckedContinuation{answer=$0}}
        try await surface.enter();try await wait("Base-pinning source warning was not held"){answer != nil}
        let original=String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let alternate=try await c.repository.run(["commit-tree",original+"^{tree}","-p",original],input:Data("Private alternate HEAD\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await c.repository.run(["update-ref","HEAD",alternate])
        answer?.resume(returning:true);answer=nil
        try await wait("Pinned source launch did not drain"){!surface.pending && !surface.busy}
        _=try await c.repository.run(["update-ref","HEAD",original])
        try require(launches.count==1 && launches[0].base == .revision(original),"Warning recaptured moved HEAD")
        surface.confirm{_ in await withCheckedContinuation{answer=$0}}
        try await surface.enter();try await wait("Settings source warning was not held"){answer != nil}
        let previous=c.prefs.data(forKey:"TurtleGit.MergeTools")
        c.prefs.set(Data("{}".utf8),forKey:"TurtleGit.MergeTools")
        try await Task.sleep(nanoseconds:30_000_000)
        try require(surface.pending && !Prior.drained() && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held stale question released its source/Quit lease")
        answer?.resume(returning:true);answer=nil
        try await wait("Stale source warning did not drain"){!surface.pending && !surface.busy}
        if let previous {c.prefs.set(previous,forKey:"TurtleGit.MergeTools")} else {c.prefs.removeObject(forKey:"TurtleGit.MergeTools")}
        try require(launches.count==1,"Changed settings delivered a stale source launch")
        // Actual AppKit warning controls and both native sheet links are part
        // of the same source lifetime, including a declined native response.
        surface.confirm(nil)
        try await surface.enter();try await wait("Actual native multi-file warning absent"){surface.window.attachedSheet != nil}
        let sheet=surface.window.attachedSheet!
        let no=try Prior.unwrap(Prior.views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title=="No"},"Actual native warning No button missing")
        no.performClick(nil)
        if sheet.sheetParent != nil || surface.window.attachedSheet === sheet {try require(surface.pending,"Source released before paired warning detachment")}
        try await wait("Native No response did not release actual sheet"){!surface.pending && !surface.busy && sheet.sheetParent==nil && surface.window.attachedSheet !== sheet}
        try require(launches.count==1,"Native No response delivered a child")
        try await c.preserved()
    }
    static func closeQuestion(_ kind:Kind,_ c:Context)async throws {
        let source=Surface(kind,c);try await source.ready();_ = try await source.select(c.all)
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        var launches=0;source.launch{_,_ in launches += 1};source.confirm(nil)
        try await source.enter();try await wait("Owned native close-warning absent"){source.window.attachedSheet != nil}
        let sheet=source.window.attachedSheet!
        try require(!source.closeRequest(),"Source close bypassed its selected-file question")
        try await wait("Source close did not drain warning"){!source.pending && !source.busy && sheet.sheetParent==nil && source.window.attachedSheet !== sheet}
        try require(launches==0,"Cancelled source close opened a child")
        if kind != .revert {source.forceClose()}
        try await wait("Closed source callback did not drain"){source.closed==1 && Prior.drained()}
        try await c.preserved()
    }
    static func exercise(_ kind:Kind,_ c:Context)async throws {
        let surface=Surface(kind,c);try await surface.ready();try await keyboardGuards(surface)
        // Capture after the mounted source's initial status refresh, as the
        // retained clicked-row fixture does; activation itself must keep the
        // exact accepted index bytes throughout every later assertion.
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        let ordered=try await surface.select(c.all);try require(ordered.count>3,"Fixture did not exercise source multi-warning")
        let required=c.all.filter{kind != .revert || $0 != c.untracked}
        try require(GitPathSet(ordered)==GitPathSet(required),"Mounted source omitted a required conflict, ordinary, retained-copy or missing row")
        try await Self.questions(surface,c,ordered)
        var plans:[StatusListPrimaryActivation]=[],questions:[Int]=[]
        surface.confirm{questions.append($0);return true}
        surface.launch{plan,_ in try checkPlan(plan,surface,c,ordered,alternate:true);plans.append(plan)}
        try await surface.enter(.shift);try await wait("\(kind) selected Return did not drain"){!surface.pending && !surface.busy}
        try require(plans.count==1 && questions==[ordered.count],"Return split the accepted selection or warned more than once")
        let expectedBase=String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        try require(plans[0].base == .revision(expectedBase),"Source base was not resolved to the accepted literal HEAD")
        let before=surface.selection
        surface.launch{plan,_ in try checkPlan(plan,surface,c,[c.normal],alternate:false);plans.append(plan)}
        try await Prior.click(surface.owner,path:c.normal);try await wait("Clicked \(kind) source did not drain"){!surface.pending && !surface.busy}
        try require(plans.count==2 && surface.selection==before && questions.count==1,"Double-click used the highlighted set or changed its selection")
        // The real Root dispatch gets one source warning, and every row retains
        // its own renderer/conflict/default meaning without changing Git bytes.
        let root=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:c.root.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("marks.json")),cachePersistenceDefaults:c.prefs)
        c.roots.append(root);root.fileComparisonPreferences=c.prefs
        var deliveries:[(String,String,ComparisonRevision?,ComparisonRevision?)]=[],nestedQuestions=0
        root.fileComparisonQuestion={_ in nestedQuestions += 1;return false}
        root.openExternalConflict={_,_,_,_,owner,_,_,prepared,_ in try require(owner === surface.window,"Conflict progress moved to another source");prepared();return false}
        root.conflictEditorPresentation={_,_,path,_ in deliveries.append(("conflict",path,nil,nil))}
        root.fileComparisonPresentation={snapshot,file in deliveries.append(("comparison",file.path,snapshot.from,snapshot.to))}
        var currentRequest:StatusListPrimaryActivation?
        let primaryLaunch:StatusListPrimaryActivationSession.Launch={plan,token in try checkPlan(plan,surface,c,ordered,alternate:false);currentRequest=plan;try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
        surface.launch(primaryLaunch)
        try await surface.enter();try await wait("Real Root \(kind) dispatch did not drain"){!surface.pending && !surface.busy && !root.hasPendingRepositoryWork}
        let expected=ordered.filter{!GitReferenceName.equal($0,c.missing)}
        try require(deliveries.map{$0.1}==expected && nestedQuestions==0,"Root dropped/reordered a mixed row or asked a second warning")
        for delivery in deliveries where delivery.1==c.retained || delivery.1==c.untracked {
            try require(delivery.2 == .workingTree && delivery.3 == .workingTree,"Unversioned/retained-copy preview inherited tracked deletion/HEAD semantics")
        }
        try await c.preserved()
        // With a typed source launch installed, explicit Compare owns an
        // asynchronous compareWithBase plan rather than a legacy onCompare/
        // onAction callback. Keep the prior mixed delivery oracle intact and
        // exercise this request through the same real Root dispatch.
        let mixedDeliveries=deliveries,questionsBeforeCompare=questions,nestedBeforeCompare=nestedQuestions
        let explicitPaths=[c.conflict,c.normal],explicitSet=GitPathSet(explicitPaths)
        let explicitOrder=ordered.filter{explicitSet.contains($0)}
        var explicitPlans:[StatusListPrimaryActivation]=[]
        surface.launch{plan,token in
            try checkPlan(plan,surface,c,explicitOrder,alternate:false,mode:.compareWithBase)
            try require(plan.base == .revision(expectedBase),"Explicit Compare changed captured HEAD base")
            explicitPlans.append(plan)
            try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)
        }
        if let commit=surface.commit {commit.model.compare(paths:explicitPaths)}
        else if let status=surface.status {status.model.diff(explicitPaths)}
        else if let revert=surface.revert {revert.model.diff(explicitPaths)}
        try await wait("Explicit typed Compare did not drain"){!surface.pending && !surface.busy && !root.hasPendingRepositoryWork}
        let explicitDeliveries=Array(deliveries.dropFirst(mixedDeliveries.count))
        let retainedMixed=Array(deliveries.prefix(mixedDeliveries.count)).elementsEqual(mixedDeliveries){a,b in a.0==b.0 && a.1==b.1 && a.2==b.2 && a.3==b.3}
        let explicitDiagnostic="kind=\(kind),plans=\(explicitPlans.count),roles=\(explicitPlans.flatMap{$0.actions.map{role($0)}}),paths=\(explicitDeliveries.map{$0.1}),questions=\(questions),nested=\(nestedQuestions),pending=\(surface.pending),busy=\(surface.busy),error=\(surface.commit?.model.error ?? surface.status?.model.error ?? surface.revert?.model.error ?? "none")"
        try require(explicitPlans.count==1 && explicitPlans[0].actions.allSatisfy{if case .comparison = $0{return true};return false},"Explicit Compare was changed into a per-row default/conflict action; "+explicitDiagnostic)
        try require(retainedMixed && explicitDeliveries.count==explicitOrder.count && explicitDeliveries.map{$0.1}==explicitOrder && explicitDeliveries.allSatisfy{$0.0=="comparison" && $0.2 == .revision(expectedBase) && $0.3 == .workingTree},"Explicit Compare dropped/reordered operands or changed earlier mixed deliveries; "+explicitDiagnostic)
        try require(questions==questionsBeforeCompare && nestedQuestions==nestedBeforeCompare,"Explicit Compare repeated source/Root warning; "+explicitDiagnostic)
        try await c.preserved()
        surface.launch(primaryLaunch)
        // Hold the real Root conflict read after it has read the actual index;
        // forced closure must cancel delivery but retain the source's close/Quit
        // ownership until this accepted worker acknowledges retirement.
        var release:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?
        root.readConflictEditorEntry={repository,path,token in
            let entry=try await repository.conflictEditorEntry(path:path,cancellation:token)
            readToken=token;await withCheckedContinuation{release=$0};return entry
        }
        c.unblock.append{release?.resume();release=nil}
        let oldDelivery=deliveries.count
        try await surface.enter();try await wait("Real Root conflict read was not held"){release != nil}
        surface.forceClose()
        try require(readToken?.isCancelled==true && currentRequest?.ownerIsCurrent()==false,"Forced source retirement did not revoke its request")
        try require(surface.closed==0 && surface.pending && !Prior.drained() && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced closure released source/counter/Quit before worker acknowledgement")
        release?.resume();release=nil
        try await wait("Forced \(kind) source/Root read did not drain"){!surface.pending && surface.closed==1 && !root.hasPendingRepositoryWork && Prior.drained()}
        try require(deliveries.count==oldDelivery,"Retired source delivered a late viewer")
        root.stopMonitoringForTermination();surface.launch(nil);surface.confirm(nil);try await c.preserved()
        try await closeQuestion(kind,c)
    }
    static func verify(base:URL,git:URL)async throws {
        let c=try Context(base:base,git:git)
        do {try await c.setup();for kind in Kind.allCases {try await exercise(kind,c)};await c.cleanup();try require(Prior.drained(),"Selected Return source workers did not drain")}
        catch {await c.cleanup();throw error}
        print("PASS: Classic Commit/Working Tree/Revert native selected Return and clicked-row split, one warning, exact ordered mixed conflict/untracked/missing/copy intent, real Root handoff, original bytes and forced close/Quit acknowledgement")
    }
}
