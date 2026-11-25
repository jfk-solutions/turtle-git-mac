// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@MainActor enum AddResolvePrimaryVerification {
    typealias Prior=StatusPrimaryActivationVerification
    typealias Context=StatusPrimarySelectionVerification.Context
    static func require(_ value:Bool,_ message:String)throws {try Prior.require(value,"Add/Resolve: "+message)}
    static func wait(_ message:String,_ ready:()->Bool)async throws {try await Prior.wait(message,ready)}
    static func views(_ owner:NSWindowController)->[NSView] {Prior.views(owner.window?.contentView)}
    static func drained()->Bool {Prior.drained() && AddWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0}
    enum Kind:CaseIterable {case add,resolve}
    @MainActor final class Surface {
        let kind:Kind,owner:NSWindowController,add:AddWindowController?,resolve:ResolveWindowController?
        var closed=0
        init(_ kind:Kind,_ c:Context,paths:[String]) {
            self.kind=kind
            switch kind {
            case .add:
                let controller=AddWindowController(repository:c.repository,access:nil,defaults:c.prefs)
                add=controller;resolve=nil;owner=controller;controller.model.setScope(paths);controller.model.includeIgnored=true
            case .resolve:
                let controller=ResolveWindowController(repository:c.repository,access:nil,paths:paths,preferences:c.prefs)
                resolve=controller;add=nil;owner=controller
            }
            c.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            add?.onClosed={[weak self] in self?.closed += 1};resolve?.onClosed={[weak self] in self?.closed += 1}
            add?.model.reload();resolve?.model.loadInitial()
        }
        var window:NSWindow {owner.window!}
        var pending:Bool {add?.model.primaryActivationPending ?? resolve!.model.primaryActivationPending}
        var busy:Bool {add?.model.busy ?? resolve!.model.busy}
        var selection:GitPathSet {add?.model.highlighted ?? resolve!.model.selection}
        var checked:GitPathSet {add?.model.checked ?? resolve!.model.checked}
        func ready()async throws {
            try await wait("source did not mount") {
                self.window.contentView?.layoutSubtreeIfNeeded()
                guard !self.busy,self.rows.count>=4,let table=try? self.table(),table.isEnabled,
                      table.window === self.window,!table.isHiddenOrHasHiddenAncestor,table.numberOfRows==self.rows.count else{return false}
                if let resolve=self.resolve,let report=table.dataSource as? ConflictReportTable.Coordinator {
                    return resolve.model.canInteract && report.owner.enabled && report.owner.rows.map{Data($0.path.utf8)}==resolve.model.sortedReportEntries.map{Data($0.path.utf8)}
                }
                return (table.dataSource as? AddFileTable.Coordinator)?.canPresentFileMenu==true
            }
        }
        func table()throws->AddNativeTable {try Prior.unwrap(views(owner).compactMap{$0 as? AddNativeTable}.first,"Native source table missing")}
        var rows:[String] {
            if add != nil,let table=try? table(),let report=table.dataSource as? AddFileTable.Coordinator {return report.rows.map(\.path)}
            return resolve?.model.sortedReportEntries.map(\.path) ?? []
        }
        func select(_ paths:[String])async throws->[String] {
            try await ready()
            let table=try table(),wanted=GitPathSet(paths),ordered=rows.filter{wanted.contains($0)}
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(rows.indices.filter{wanted.contains(rows[$0])}))
            try await wait("native selected rows not accepted"){self.selection==GitPathSet(ordered)}
            return ordered
        }
        func event(_ flags:NSEvent.ModifierFlags=[],code:UInt16=36)throws->NSEvent {
            try Prior.unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:code),"Native Return missing")
        }
        func enter(_ flags:NSEvent.ModifierFlags=[],code:UInt16=36)async throws {
            try await ready()
            let table=try table();table.commandKeyWindow={[weak self] in self?.window}
            try require(window.makeFirstResponder(table),"Source report refused focus")
            try require(window.performKeyEquivalent(with:event(flags,code:code)),"Source window did not retain Return before default button")
        }
        func confirm(_ answer:((Int) async->Bool)?) {add?.model.confirmPrimaryFileActivation=answer;resolve?.model.confirmPrimaryFileActivation=answer}
        func clearCallbacks() {add?.model.onPrimaryFileActivation=nil;resolve?.model.onPrimaryFileActivation=nil;resolve?.model.onWorkingFileComparison=nil;confirm(nil)}
        func reload() {add?.model.reload();resolve?.model.load()}
        func closeRequest()->Bool {if let add{return add.windowShouldClose(window)};return resolve!.windowShouldClose(window)}
    }
    /// Paired real AppKit mouse tracking, with public key state injected only
    /// for this private offscreen owner, as in the retained Log pointer case.
    static func click(_ source:Surface,path:String,column:Int=1,alternate:Bool=false)async throws {
        try await source.ready()
        let table=try source.table(),row=try Prior.unwrap(source.rows.firstIndex{GitReferenceName.equal($0,path)},"Pointer row absent"),window=source.window
        table.scrollRowToVisible(row);table.scrollColumnToVisible(column);window.contentView?.layoutSubtreeIfNeeded();window.makeFirstResponder(table)
        let rect=table.frameOfCell(atColumn:column,row:row).intersection(table.visibleRect)
        try require(!rect.isEmpty,"Pointer cell clipped")
        let point=table.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil),stamp=ProcessInfo.processInfo.systemUptime
        let flags:NSEvent.ModifierFlags=alternate ? .shift:[]
        let down=try Prior.unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:flags,timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:31,clickCount:2,pressure:1),"Pointer down missing")
        let up=try Prior.unwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:flags,timestamp:stamp+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:32,clickCount:2,pressure:0),"Pointer up missing")
        let selector=#selector(getter:NSWindow.isKeyWindow),method=try Prior.unwrap(class_getInstanceMethod(NSWindow.self,#selector(getter:NSWindow.isKeyWindow)),"Key state getter missing")
        let original=method_getImplementation(method)
        let block:@convention(block)(NSWindow)->Bool={candidate in
            if candidate === window{return true}
            typealias Getter=@convention(c)(NSWindow,Selector)->Bool
            return unsafeBitCast(original,to:Getter.self)(candidate,selector)
        }
        let injected=imp_implementationWithBlock(block)
        class_replaceMethod(NSWindow.self,selector,injected,method_getTypeEncoding(method))
        defer{class_replaceMethod(NSWindow.self,selector,original,method_getTypeEncoding(method));imp_removeBlock(injected)}
        NSApp.postEvent(up,atStart:true);ComparisonToolInvocation.$alternate.withValue(alternate){table.mouseDown(with:down)}
    }
    static func guards(_ source:Surface)async throws {
        let table=try source.table();table.commandKeyWindow={[weak source] in source?.window};source.window.makeFirstResponder(table)
        try require(!table.performSelectedReturn(source.event(.command)) && !table.performSelectedReturn(source.event(.control)),"Accept shortcuts stolen")
        table.commandKeyWindow={nil};try require(!table.performSelectedReturn(source.event()),"Foreign key owner activated report")
        table.commandKeyWindow={[weak source] in source?.window}
        let field=NSTextField(frame:.init(x:4,y:4,width:120,height:22));source.window.contentView?.addSubview(field)
        source.window.makeFirstResponder(field)
        try require(!table.performSelectedReturn(source.event()),"Field editor Return stolen")
        field.removeFromSuperview();_ = try await source.select([]);try await source.enter(code:76)
        try require(!source.pending,"Empty Return activated source")
    }
    static func exercise(_ kind:Kind,_ c:Context,paths:[String])async throws {
        let source=Surface(kind,c,paths:paths);try await source.ready();defer{source.clearCallbacks()}
        try await guards(source)
        let ordered=try await source.select(paths),checks=source.checked
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        var counts:[Int]=[],launches=0,seen:[String]=[],alternate=false,ownerCurrent:(()->Bool)?
        source.confirm{counts.append($0);return false}
        if let add=source.add {add.model.onPrimaryFileActivation={_,_ in launches += 1}}
        else {source.resolve!.model.onPrimaryFileActivation={_,_ in launches += 1}}
        try await source.enter();try await wait("declined warning did not drain"){!source.pending && !source.busy}
        try require(counts==[ordered.count] && launches==0,"One source warning did not decline whole selection")
        var answer:CheckedContinuation<Bool,Never>?
        c.unblock.append{answer?.resume(returning:false);answer=nil}
        source.confirm{_ in await withCheckedContinuation{answer=$0}}
        try await source.enter();try await wait("held tool-identity question absent"){answer != nil}
        let previousTools=c.prefs.data(forKey:"TurtleGit.MergeTools")
        c.prefs.set(Data("{}".utf8),forKey:"TurtleGit.MergeTools")
        try await Task.sleep(nanoseconds:30_000_000)
        try require(source.pending && !drained(),"Stale injected question released an unacknowledged source")
        answer?.resume(returning:true);answer=nil
        try await wait("stale tool-identity question did not retire"){!source.pending && !source.busy}
        if let previousTools {c.prefs.set(previousTools,forKey:"TurtleGit.MergeTools")} else {c.prefs.removeObject(forKey:"TurtleGit.MergeTools")}
        try require(launches==0 && source.closed==0 && source.window.isVisible,"Changed tool intent delivered a stale request or closed its source")
        source.confirm{counts.append($0);return true}
        if let add=source.add {add.model.onPrimaryFileActivation={plan,_ in seen=plan.actions.map{$0.file.entry.path};alternate=plan.alternateTool;ownerCurrent=plan.ownerIsCurrent;launches += 1;source.reload()}}
        else {source.resolve!.model.onPrimaryFileActivation={plan,_ in seen=plan.entries.map(\.path);alternate=plan.alternateTool;ownerCurrent=plan.ownerIsCurrent;launches += 1;source.reload()}}
        try await source.enter(.shift,code:76);try await wait("selected keypad Return did not drain"){!source.pending && !source.busy}
        try require(seen==ordered && alternate && launches==1 && counts==[ordered.count,ordered.count] && source.checked==checks,"Selected Return lost order/Shift/checkbox separation")
        try require(ownerCurrent?()==false,"Completed source token remained reusable")
        let oldCount=counts.count
        let clicked=c.conflict
        if let add=source.add {add.model.onPrimaryFileActivation={plan,_ in seen=plan.actions.map{$0.file.entry.path};launches += 1}}
        else {source.resolve!.model.onPrimaryFileActivation={plan,_ in seen=plan.entries.map(\.path);launches += 1}}
        try await click(source,path:clicked);try await wait("clicked primary did not drain"){!source.pending && !source.busy}
        try require(seen==[clicked] && launches==2 && counts.count==oldCount,"Pointer used selected set or warned for unrelated highlights")
        try await click(source,path:clicked,column:0);try require(launches==2,"Checkbox pointer launched default action")
        _=try await source.select(paths)
        let root=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:c.root.appendingPathComponent("\(kind)-finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("\(kind)-marks.json")),cachePersistenceDefaults:c.prefs)
        c.roots.append(root);root.fileComparisonPreferences=c.prefs
        var delivered:[String]=[],nested=0,comparisons:[(String,ComparisonRevision,ComparisonRevision)]=[]
        root.fileComparisonQuestion={_ in nested += 1;return false}
        root.openExternalConflict={_,_,_,_,_,_,_,prepared,_ in prepared();return false}
        root.conflictEditorPresentation={_,_,path,_ in delivered.append(path)}
        root.fileComparisonPresentation={snapshot,file in delivered.append(file.path);comparisons.append((file.path,snapshot.from,snapshot.to))}
        let addPrimary:StatusListPrimaryActivationSession.Launch={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
        if let add=source.add {add.model.onPrimaryFileActivation=addPrimary}
        else {source.resolve!.model.onPrimaryFileActivation={plan,token in try await root.showConflictListPrimaryFiles(plan,access:nil,cancellation:token)}}
        try await source.enter();try await wait("real Root selected dispatch did not drain"){!source.pending && !source.busy && !root.hasPendingRepositoryWork}
        try require(delivered==ordered && nested==0,"Root reordered/dropped selected rows or warned twice")
        try await c.preserved()
        let explicit=[c.conflict,c.other],beforeExplicit=delivered,beforeComparisons=comparisons.count,nestedBefore=nested
        let explicitOrder=try await source.select(explicit),base=String(decoding:c.head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        var explicitPlans:[StatusListPrimaryActivation]=[]
        let explicitLaunch:StatusListPrimaryActivationSession.Launch={plan,token in
            try require(plan.selectedCount==explicitOrder.count && plan.actions.map{$0.file.entry.path}==explicitOrder,"Explicit Compare changed native accepted order/count")
            try require(plan.window === source.window && plan.preferences === c.prefs && plan.repository.executable==c.repository.executable && plan.repository.libgit2Configuration?.enabled==false && plan.ownerIsCurrent() && !plan.alternateTool && !plan.amendToParent,"Explicit Compare recaptured owner/preferences/backend/Shift")
            try require(plan.base == .revision(base) && plan.actions.allSatisfy{if case .comparison = $0{return true};return false},"Explicit Compare was split into default/conflict actions")
            explicitPlans.append(plan)
            try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)
        }
        if let add=source.add {
            add.model.onPrimaryFileActivation=explicitLaunch
            var acceptedReport:AddFileTable.Coordinator?
            try await wait("Explicit Add menu projection not ready") {
                source.window.contentView?.layoutSubtreeIfNeeded()
                guard let report=(try? source.table())?.dataSource as? AddFileTable.Coordinator,
                      report.canCompareBase,report.selectedRows.map({$0.path})==explicitOrder else{return false}
                acceptedReport=report;return true
            }
            let report=try Prior.unwrap(acceptedReport,"Explicit Add menu coordinator absent")
            report.compareBase()
        } else {
            let resolve=source.resolve!.model
            // Match the real workspace's distinct HEAD→working callback. The
            // default selected-conflict dispatcher stays independently installed.
            resolve.onWorkingFileComparison=explicitLaunch
            let menu=resolve.fileMenu(explicitOrder,markedPath:explicitOrder.first)
            try require(menu.entries.map(\.path)==explicitOrder && resolve.canFileCommand(.compareBase,menu:menu),"Explicit Resolve menu receipt was stale or changed selection")
            resolve.fileCommand(.compareBase,menu:menu)
        }
        try await wait("Explicit Add/Resolve typed Compare did not drain"){!source.pending && !source.busy && !root.hasPendingRepositoryWork}
        let newComparisons=Array(comparisons.dropFirst(beforeComparisons))
        let explicitDiagnostic="kind=\(kind),plans=\(explicitPlans.count),delivered=\(delivered),comparisonPaths=\(newComparisons.map{$0.0}),nested=\(nested),pending=\(source.pending),busy=\(source.busy),error=\(source.add?.model.error ?? source.resolve?.model.error ?? "none")"
        try require(explicitPlans.count==1 && Array(delivered.prefix(beforeExplicit.count))==beforeExplicit && Array(delivered.dropFirst(beforeExplicit.count))==explicitOrder && newComparisons.count==explicitOrder.count && newComparisons.map{$0.0}==explicitOrder && newComparisons.allSatisfy{$0.1 == .revision(base) && $0.2 == .workingTree} && nested==nestedBefore,"Explicit Compare entered the selected default dispatcher, dropped/reordered paths or changed prior deliveries; "+explicitDiagnostic)
        try await c.preserved()
        source.add?.model.onPrimaryFileActivation=addPrimary
        if let resolve=source.resolve {
            // Preserve the ancestor/stage-1 aggregate oracle separately: this
            // explicit API is deliberately different from Compare with base.
            let deliveredBeforeAncestor=delivered.count,plansBeforeAncestor=explicitPlans.count
            resolve.model.viewConflictBase(explicit)
            try await wait("explicit Resolve ancestor aggregate Compare did not finish"){!source.busy && resolve.model.patch != nil}
            resolve.model.patch=nil
            try await wait("explicit Resolve ancestor aggregate viewer did not detach"){source.window.attachedSheet==nil}
            try require(delivered.count==deliveredBeforeAncestor && explicitPlans.count==plansBeforeAncestor,"Ancestor aggregate entered a default/working comparison dispatcher")
        }
        _=try await source.select(paths)
        // Cancel the actual owned conflict-preparation progress, rather than
        // replacing cancellation with a model callback. Its held real Git read
        // must acknowledge retirement before any later selected row can run.
        var release:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?
        c.unblock.append{release?.resume();release=nil}
        root.readConflictEditorEntry={repository,path,token in
            let value=try await repository.conflictEditorEntry(path:path,cancellation:token)
            readToken=token;await withCheckedContinuation{release=$0};return value
        }
        let previous=delivered.count
        try await source.enter();try await wait("orientation-check conflict read not held"){release != nil}
        let rebaseMarker=c.root.appendingPathComponent(".git/rebase-merge",isDirectory:true)
        try FileManager.default.createDirectory(at:rebaseMarker,withIntermediateDirectories:false)
        release?.resume();release=nil
        try await wait("changed orientation did not drain"){!source.pending && !source.busy && !root.hasPendingRepositoryWork}
        try FileManager.default.removeItem(at:rebaseMarker)
        try require(delivered.count==previous && source.closed==0 && source.window.isVisible && (source.add?.model.error ?? source.resolve?.model.error) != nil,"Changed rebase orientation delivered a viewer or closed its source")
        source.add?.model.error=nil;source.resolve?.model.error=nil
        try await wait("stale orientation error presentation did not detach"){source.window.attachedSheet==nil}
        try await source.enter();try await wait("actual conflict preparation not held"){release != nil && source.window.attachedSheet != nil}
        let progress=source.window.attachedSheet!
        let cancel=try Prior.unwrap(Prior.views(progress.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Cancel"},"Actual conflict progress Cancel control absent")
        cancel.performClick(nil)
        try require(readToken?.isCancelled==true && source.pending && !drained(),"Progress Cancel released a live selected worker")
        release?.resume();release=nil
        try await wait("progress Cancel did not drain source/Root"){!source.pending && !source.busy && !root.hasPendingRepositoryWork && progress.sheetParent==nil}
        try require(delivered.count==previous && source.closed==0 && source.window.isVisible,"Progress Cancel continued to later selected files or closed its source")
        // A second actual worker is retired by forced source closure. Source
        // onClosed and global Quit stay leased until that read acknowledges.
        try await source.enter();try await wait("forced-close conflict read not held"){release != nil}
        source.window.close()
        try require(readToken?.isCancelled==true && source.closed==0 && source.pending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced source closure released worker/Quit ownership")
        release?.resume();release=nil
        try await wait("forced source/Root worker did not drain"){source.closed==1 && !source.pending && !root.hasPendingRepositoryWork && drained()}
        try require(delivered.count==previous,"Closed source delivered a late selected child")
        source.clearCallbacks()
        // A real native warning can be cancelled from its source even though
        // the alert owns an attached sheet; both links remain source-owned.
        let question=Surface(kind,c,paths:paths);defer{question.clearCallbacks()};try await question.ready()
        _=try await question.select(paths)
        var unexpectedLaunches=0
        if let add=question.add {add.model.onPrimaryFileActivation={_,_ in unexpectedLaunches += 1}}
        else {question.resolve!.model.onPrimaryFileActivation={_,_ in unexpectedLaunches += 1}}
        question.confirm(nil);try await question.enter();try await wait("native warning absent"){question.window.attachedSheet != nil}
        let sheet=question.window.attachedSheet!
        try require(!question.closeRequest(),"Close bypassed source warning")
        try await wait("cancelled warning did not detach"){!question.pending && !question.busy && sheet.sheetParent==nil && question.window.attachedSheet !== sheet}
        try require(unexpectedLaunches==0,"Source close accepted its cancelled question")
        if kind == .add {try await wait("Add cancelled source did not close"){question.closed==1}}
        else {question.window.close();try await wait("Resolve closed callback absent"){question.closed==1}}
        try await wait("closed source/Root work leaked"){drained() && !root.hasPendingRepositoryWork}
        try await c.preserved()
    }
    static func verify(base:URL,git:URL)async throws {
        let c=try Context(base:base.standardizedFileURL,git:git)
        do {
            try await c.setup()
            let conflicts=try await c.repository.conflicts(paths:[c.conflict])
            let entry=try Prior.unwrap(conflicts.first,"Original conflict stage identity absent")
            let extra=["extra-conflict-1.txt","extra-conflict-2.txt"]
            var records=""
            for path in extra {
                for stage in entry.stages {records += "\(stage.mode) \(stage.object) \(stage.number)\t\(path)\0"}
                let bytes=Data("extra conflicting working bytes\n".utf8);try bytes.write(to:c.root.appendingPathComponent(path));c.working[path]=bytes
            }
            _=try await c.repository.run(["update-index","-z","--index-info"],input:Data(records.utf8))
            let ignored="ignored-private.txt",ignoredBytes=Data("ignored working preview\n".utf8)
            try Data((ignored+"\n").utf8).write(to:c.root.appendingPathComponent(".git/info/exclude"))
            try ignoredBytes.write(to:c.root.appendingPathComponent(ignored));c.working[ignored]=ignoredBytes
            let paths=[c.conflict,c.other,c.normal,c.untracked,c.retained,ignored]+extra
            for kind in Kind.allCases {try await exercise(kind,c,paths:paths)}
            await c.cleanup();try await wait("all owned Add/Resolve work did not drain"){drained()}
        } catch {await c.cleanup();throw error}
        print("PASS: Add/Resolve actual native selected Return/keypad Enter and clicked-row split, one warning, real ordered Root previews/conflict editors, checkbox/default-key separation, original bytes and source warning drainage")
    }
}
