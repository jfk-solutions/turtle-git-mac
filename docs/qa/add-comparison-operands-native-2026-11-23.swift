// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietAddOperandOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));quietAddOperandOrder(mode,relativeTo:number)}
    @objc func quietAddOperandSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));quietAddOperandSheet(sheet,completionHandler:completionHandler)}
}

@MainActor @main enum AddComparisonOperandsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {if !value {throw Failure(description:"Add operands \(line): "+text)}}
    static func unwrap<T>(_ value:T?,_ text:String)throws->T {guard let value else{throw Failure(description:text)};return value}
    static func wait(_ text:String,_ predicate:()->Bool)async throws {for _ in 0..<2000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:text)}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {AddWindowModel.activeOperations==0 && FileListComparisonSession.activeOperations==0 && ResolveWindowController.activeReleases==0}
    struct Delivery {let snapshot:RevisionComparisonSnapshot,file:CommitFile}
    @MainActor final class Context {
        let base:URL,folder:URL,repo:GitRepository,prefs:UserDefaults,suite:String
        let added="a added 雪.txt",deleted="b retained deleted.txt",renamed="c renamed\n?.txt",old="old rename\t雪.txt",conflict="d conflict.txt",modified="e ordinary.txt",untracked="f untracked.txt",ignored="g ignored.txt"
        var owners:[AddWindowController]=[],roots:[RepositoryModel]=[],unblock:[()->Void]=[],head=""
        var expectedIndex=Data(),expectedHead=Data(),working:[String:Data]=[:]
        init(base:URL,git:URL)throws {
            self.base=base.standardizedFileURL;folder=self.base.appendingPathComponent("repository")
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.AddOperands."+UUID().uuidString;prefs=try unwrap(UserDefaults(suiteName:suite),"Private preferences unavailable")
            prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(3,forKey:"NumDiffWarning")
        }
        var explicitPaths:[String] {[added,deleted,renamed,conflict,modified]}
        var scope:[String] {explicitPaths+[untracked,ignored,"selected-folder"]}
        func setup()async throws {
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Add Operand QA"),("user.email","add-operands@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            for(path,text)in[(deleted,"deleted historical\n"),(old,"exact historical rename\n"),(conflict,"historical conflict base\n"),(modified,"ordinary historical\n")] {try Data(text.utf8).write(to:folder.appendingPathComponent(path))}
            try await repo.stage(["."]);_=try await repo.commit(message:"Add operand base")
            head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            _=try await repo.run(["rm","--cached","--",deleted]);_=try await repo.run(["mv","--",old,renamed])
            try Data("added working\n".utf8).write(to:folder.appendingPathComponent(added));try await repo.stage([added])
            try Data("ordinary working\n".utf8).write(to:folder.appendingPathComponent(modified))
            try Data("untracked working\n".utf8).write(to:folder.appendingPathComponent(untracked))
            try Data("ignored working\n".utf8).write(to:folder.appendingPathComponent(ignored))
            try FileManager.default.createDirectory(at:folder.appendingPathComponent(".git/info"),withIntermediateDirectories:true)
            try Data((ignored+"\n").utf8).write(to:folder.appendingPathComponent(".git/info/exclude"))
            try FileManager.default.createDirectory(at:folder.appendingPathComponent("selected-folder"),withIntermediateDirectories:true)
            let ancestor=try await repo.run(["rev-parse","HEAD:"+conflict]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let mine=try await repo.run(["hash-object","-w","--stdin"],input:Data("mine\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let theirs=try await repo.run(["hash-object","-w","--stdin"],input:Data("theirs\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let records="0 "+String(repeating:"0",count:ancestor.count)+"\t"+conflict+"\0"+"100644 \(ancestor) 1\t\(conflict)\0"+"100644 \(mine) 2\t\(conflict)\0"+"100644 \(theirs) 3\t\(conflict)\0"
            _=try await repo.run(["update-index","-z","--index-info"],input:Data(records.utf8))
            try Data("<<<<<<< mine\nmine\n=======\ntheirs\n>>>>>>> theirs\n".utf8).write(to:folder.appendingPathComponent(conflict))
            try MergeToolPreferences.load(from:prefs).save(to:prefs)
        }
        func root()->RepositoryModel {
            let value=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:base.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            value.fileComparisonPreferences=prefs;roots.append(value);return value
        }
        func source()async throws->Surface {
            let owner=AddWindowController(repository:repo,access:nil,defaults:prefs);owners.append(owner)
            owner.model.setScope(scope);owner.model.includeIgnored=true
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);owner.model.reload()
            let surface=Surface(owner);try await surface.ready(expected:scope.filter{$0 != "selected-folder"})
            return surface
        }
        func checkpoint()async throws {
            expectedHead=try await repo.run(["rev-parse","HEAD"]).stdout
            expectedIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"));working=[:]
            for path in scope where path != "selected-folder" {working[path]=try Data(contentsOf:folder.appendingPathComponent(path))}
        }
        func preserved()async throws {
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==expectedHead,"Read-only Add comparison changed HEAD")
            try require(try Data(contentsOf:folder.appendingPathComponent(".git/index"))==expectedIndex,"Read-only Add comparison changed exact index")
            for(path,bytes)in working {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Read-only Add comparison changed "+path)}
        }
        func cleanup()async throws {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[];roots.forEach{$0.stopMonitoringForTermination()}
            try await wait("Add source/Root/child ownership did not drain") {
                drained() && self.roots.allSatisfy{!$0.hasPendingRepositoryWork} && self.owners.allSatisfy{!$0.model.primaryActivationPending && $0.window?.isVisible != true && $0.window?.attachedSheet==nil}
            }
            prefs.removePersistentDomain(forName:suite)
        }
    }
    @MainActor final class Surface {
        let owner:AddWindowController
        init(_ owner:AddWindowController){self.owner=owner}
        var model:AddWindowModel {owner.model}
        var window:NSWindow {owner.window!}
        func table()throws->AddNativeTable {try unwrap(views(window.contentView).compactMap{$0 as? AddNativeTable}.first,"Actual native Add report absent")}
        func report()throws->AddFileTable.Coordinator {try unwrap(try table().dataSource as? AddFileTable.Coordinator,"Actual Add report coordinator absent")}
        func ready(expected:[String])async throws {
            do {try await wait("Actual Add projection did not settle") {
                self.window.contentView?.layoutSubtreeIfNeeded()
                guard !self.model.busy,!self.model.primaryActivationPending,let table=try? self.table(),let report=try? self.report() else{return false}
                return table.isEnabled && !table.isHiddenOrHasHiddenAncestor && table.numberOfRows==report.rows.count && GitPathSet(expected).isSubset(of:GitPathSet(report.rows.map(\.path)))
            }} catch {
                print("ADD MOUNT busy=\(model.busy),pending=\(model.primaryActivationPending),error=\(String(describing:model.error)),entries=\(model.entries.map{String(reflecting:$0.path)+":"+String([$0.status.index,$0.status.worktree])})")
                throw error
            }
        }
        func select(_ paths:[String],mark:String?=nil)async throws->[String] {
            let table=try table(),report=try report(),wanted=GitPathSet(paths)
            let ordered=report.rows.filter{wanted.contains($0.path)}.map(\.path)
            try require(GitPathSet(ordered)==wanted,"Native Add projection omitted requested row")
            CommitFileInteraction.replaceSelection(in:table,with:IndexSet(report.rows.indices.filter{wanted.contains(report.rows[$0].path)}))
            try await wait("Native Add selection did not settle"){self.model.highlighted==wanted && table.selectedRowIndexes.count==paths.count}
            if let mark {model.selectionMark=mark}
            return ordered
        }
        func menuItem()->NSMenuItem? {
            guard let table=try? table(),let menu=table.menu else{return nil}
            menu.delegate?.menuNeedsUpdate?(menu)
            return menu.items.first{$0.title==String(localized:"Compare with base")}
        }
        func invoke(_ item:NSMenuItem,alternate:Bool=false)throws {
            try require(item.isEnabled && item.image != nil,"Native Compare menu lost eligibility/icon")
            let action=try unwrap(item.action,"Native Compare action missing")
            try require(ComparisonToolInvocation.$alternate.withValue(alternate){NSApp.sendAction(action,to:item.target,from:item)},"Native captured Compare menu did not dispatch")
        }
        func compare(alternate:Bool=false)throws {try invoke(try unwrap(menuItem(),"Native Compare with base menu missing"),alternate:alternate)}
        func enter(alternate:Bool=false)throws {
            let table=try table();table.commandKeyWindow={[weak self] in self?.window}
            try require(window.makeFirstResponder(table),"Ready Add report refused actual native focus")
            let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:alternate ? .shift:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"Add Return event missing")
            try require(window.performKeyEquivalent(with:event),"Actual Add window failed focused Return routing")
        }
        func idle()async throws {try await wait("Owned Add comparison did not finish"){!self.model.busy && !self.model.primaryActivationPending}}
    }
    static func cleanupPreservingFailure(_ c:Context,_ failure:Error)async throws {
        do {try await c.cleanup()} catch {throw Failure(description:"\(failure); cleanup: \(error)")};throw failure
    }
    static func operands(_ c:Context)async throws {
        let s=try await c.source(),root=c.root(),table=try s.table()
        table.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)]
        let ordered=try await s.select(c.explicitPaths,mark:c.added),checked=s.model.checked,selection=s.model.highlighted
        let acceptedRows=try s.report().selectedRows
        let retained=try unwrap(acceptedRows.first{$0.path==c.deleted},"Actual retained deletion absent")
        try require(retained.status.hasUnversionedCopy && retained.status.index=="D","Expected natural removed-and-present D metadata absent")
        let rename=try unwrap(acceptedRows.first{$0.path==c.renamed},"Actual direct Rename absent")
        try require(rename.status.originalPath==c.old && rename.status.index=="R","Natural Rename lost exact old path")
        let oldHeader=table.headerView,columns=table.tableColumns
        var plan:StatusListPrimaryActivation?,deliveries:[(RevisionComparisonSnapshot,CommitFile)]=[],warnings:[Int]=[],answer:CheckedContinuation<Bool,Never>?
        c.unblock.append{answer?.resume(returning:false);answer=nil}
        root.fileComparisonPresentation={deliveries.append(($0,$1))}
        s.model.onPrimaryFileActivation={value,token in plan=value;try await root.showStatusListPrimaryFiles(value,access:nil,cancellation:token)}
        s.model.confirmPrimaryFileActivation={count in warnings.append(count);return await withCheckedContinuation{answer=$0}}
        var generic=0;s.model.onCompare={_ in generic += 1}
        try s.compare(alternate:true);try await wait("Add explicit comparison did not own its one warning"){answer != nil}
        try require(deliveries.isEmpty && s.model.primaryActivationPending && s.model.busy && AddWindowModel.activeOperations>0,"Add comparison escaped source activity")
        // Change disk and HEAD only after accepted metadata/base admission. The
        // Source window is deliberately not refreshed during this operation.
        try Data("replaced retained disk after admission\n".utf8).write(to:c.folder.appendingPathComponent(c.deleted))
        try Data("rename disk after admission\n".utf8).write(to:c.folder.appendingPathComponent(c.renamed))
        let moved=try await c.repo.run(["commit-tree",c.head+"^{tree}","-p",c.head],input:Data("Moved private HEAD\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
        _=try await c.repo.run(["update-ref","HEAD",moved]);try await c.checkpoint()
        answer?.resume(returning:true);answer=nil
        try await s.idle();try await wait("Actual Root comparison operations did not drain"){!root.hasPendingRepositoryWork}
        let accepted=try unwrap(plan,"Actual native Compare bypassed typed request")
        try require(generic==0 && warnings==[ordered.count] && accepted.selectedCount==ordered.count,"Explicit Add warning or fallback count changed")
        try require(accepted.base == .revision(c.head) && accepted.alternateTool && accepted.window === s.window && accepted.preferences === c.prefs,"Add accepted base/Shift/settings/source changed")
        try require(accepted.actions.map{$0.file.entry.path}==ordered && accepted.actions.allSatisfy{if case .comparison = $0{return true};return false},"Add explicit Compare became primary conflict/current-file activation")
        try require(accepted.actions.map{$0.file.entry}==acceptedRows.map(\.status),"Accepted status/origin/retained flags replaced before Root")
        try require(deliveries.map{$0.1.path}==ordered,"Root explicit Compare lost native selected order")
        for (snapshot,file) in deliveries {
            let document=try await c.repo.comparisonFile(snapshot,path:file.path)
            let expected=file.path==c.added ? "A":file.path==c.deleted ? "D":file.path==c.renamed ? "R":"M"
            try require(file.action==expected,"Accepted Add action reclassified: "+file.path)
            if file.path==c.added {try require(snapshot.from == .emptyTree && document.base.bytes.isEmpty && document.base.mode==nil,"Added operand was not null")}
            else {try require(snapshot.from == .revision(c.head),"Required old base followed moved HEAD")}
            if file.path==c.deleted {try require(snapshot.to == .emptyTree && document.destination.bytes.isEmpty && document.destination.mode==nil && document.base.bytes==Data("deleted historical\n".utf8),"Retained Deleted explicit comparison inspected replacement disk")}
            if file.path==c.renamed {try require(file.oldPath==c.old && document.base.path==c.old && document.base.bytes==Data("exact historical rename\n".utf8) && document.destination.bytes==Data("rename disk after admission\n".utf8),"Rename lost exact accepted origin/current destination")}
            if file.path==c.conflict {try require(document.base.bytes==Data("historical conflict base\n".utf8),"Explicit conflict Compare used stage-1 or ConflictEdit")}
        }
        try require(s.model.checked==checked && s.model.highlighted==selection && s.model.selectionMark==c.added,"Comparison changed checks/highlights/mark")
        try require(table.headerView === oldHeader && table.tableColumns.count==columns.count && zip(table.tableColumns,columns).allSatisfy{pair in pair.0 === pair.1},"Comparison replaced native headers/columns")
        try await c.preserved()
    }
    static func primary(_ c:Context)async throws {
        let s=try await c.source(),root=c.root(),selected=[c.conflict,c.modified,c.untracked,c.deleted,c.ignored]
        let ordered=try await s.select(selected,mark:c.modified),checked=s.model.checked
        var accepted:StatusListPrimaryActivation?,warnings:[Int]=[],files:[(RevisionComparisonSnapshot,CommitFile)]=[],conflicts:[String]=[]
        s.model.confirmPrimaryFileActivation={warnings.append($0);return true}
        s.model.onPrimaryFileActivation={value,token in accepted=value;try await root.showStatusListPrimaryFiles(value,access:nil,cancellation:token)}
        root.fileComparisonPresentation={files.append(($0,$1))}
        root.conflictEditorPresentation={_,_,path,_ in conflicts.append(path)}
        try await c.checkpoint();try s.enter(alternate:true);try await s.idle()
        try await wait("Primary Root preparations did not drain"){!root.hasPendingRepositoryWork}
        let plan=try unwrap(accepted,"Native Return skipped Add primary request")
        try require(plan.actions.map{$0.file.entry.path}==ordered && plan.alternateTool && warnings==[ordered.count],"Primary native selected order/Shift/warning lost")
        for action in plan.actions {
            let path=action.file.entry.path
            switch action {
            case .conflict:try require(path==c.conflict,"Ordinary row became conflict activation")
            case .workingFile:try require([c.untracked,c.deleted,c.ignored].contains(path),"Tracked row became current-file preview")
            case .comparison:try require(path==c.modified,"Primary retained/conflict row became explicit comparison")
            case .skipMissing:throw Failure(description:"Reachable present Add row skipped as missing")
            }
        }
        try require(conflicts==[c.conflict],"Actual Root primary conflict route absent")
        try require(files.map{$0.1.path}==ordered.filter{$0 != c.conflict},"Primary Root file routes lost selected order")
        for(snapshot,file)in files where [c.untracked,c.deleted,c.ignored].contains(file.path) {
            let document=try await c.repo.comparisonFile(snapshot,path:file.path)
            try require(snapshot.from == .workingTree && snapshot.to == .workingTree && document.base.bytes==document.destination.bytes,"Primary StartDiffWC did not compare retained/unversioned current file to itself")
        }
        try require(s.model.checked==checked,"Primary file activation changed Add checks")
        try await c.preserved()
    }
    static func stale(_ c:Context)async throws {
        let s=try await c.source();_ = try await s.select(c.explicitPaths,mark:c.added)
        var launches=0;s.model.onPrimaryFileActivation={_,_ in launches += 1}
        // Source mark controls menu eligibility, while every highlighted row
        // remains in the accepted invocation when the mark permits Compare.
        s.model.selectionMark=c.deleted
        let disabled=try unwrap(s.menuItem(),"Marked Add Compare item absent")
        try require(!disabled.isEnabled && disabled.isHidden,"Removed-and-present mark wrongly offers explicit Compare")
        s.model.selectionMark=c.added
        let stale=try unwrap(s.menuItem(),"Fresh Add Compare absent")
        _ = try await s.select([c.modified],mark:c.modified)
        let action=try unwrap(stale.action,"Retained menu action absent")
        _=NSApp.sendAction(action,to:stale.target,from:stale)
        try require(launches==0 && !s.model.primaryActivationPending,"Retained menu used replacement selection")
        for mutation in ["selection","settings","backend","projection","quit"] {
            _ = try await s.select(c.explicitPaths,mark:c.added)
            var answer:CheckedContinuation<Bool,Never>?
            c.unblock.append{answer?.resume(returning:false);answer=nil}
            s.model.confirmPrimaryFileActivation={_ in await withCheckedContinuation{answer=$0}}
            let originalTools=c.prefs.data(forKey:"TurtleGit.DiffTools")
            let originalRows=s.model.entries
            try s.compare();try await wait("Held Add warning missing for "+mutation){answer != nil}
            switch mutation {
            case "selection":s.model.highlighted=[c.modified]
            case "settings":c.prefs.set(Data("changed tool receipt".utf8),forKey:"TurtleGit.DiffTools")
            case "backend":c.prefs.set(true,forKey:"UseLibgit2")
            case "projection":s.model.entries=Array(originalRows.reversed())
            default:s.model.confirmingQuit=true
            }
            answer?.resume(returning:true);answer=nil;try await s.idle()
            try require(launches==0,"Stale "+mutation+" request delivered selected files")
            if let originalTools {c.prefs.set(originalTools,forKey:"TurtleGit.DiffTools")} else {c.prefs.removeObject(forKey:"TurtleGit.DiffTools")}
            c.prefs.set(false,forKey:"UseLibgit2");s.model.confirmingQuit=false;s.model.entries=originalRows
        }
        _ = try await s.select(c.explicitPaths,mark:c.added)
        s.model.confirmPrimaryFileActivation={_ in false};try s.compare();try await s.idle()
        try require(launches==0,"Declined Add warning delivered files")
        _ = try await s.select([c.modified],mark:c.modified)
        s.model.confirmPrimaryFileActivation={_ in true}
        let once=try unwrap(s.menuItem(),"One-use Compare item absent")
        try s.invoke(once);try await wait("Single Add callback did not launch"){launches==1 && !s.model.primaryActivationPending}
        try s.invoke(once);try require(launches==1,"Same captured menu invoked twice")
    }
    static func ownership(_ c:Context)async throws {
        let s=try await c.source(),root=c.root()
        _ = try await s.select(c.explicitPaths,mark:c.added)
        var release:CheckedContinuation<Void,Never>?,token:OperationCancellation?,deliveries=0,closed=0
        c.unblock.append{release?.resume();release=nil}
        s.owner.onClosed={closed += 1}
        root.fileComparisonPresentation={_,_ in deliveries += 1}
        s.model.confirmPrimaryFileActivation={_ in true}
        s.model.onPrimaryFileActivation={plan,operation in
            token=operation;await withCheckedContinuation{release=$0}
            try operation.check();try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:operation)
        }
        try await c.checkpoint();try s.compare()
        try await wait("Accepted Add child launch was not held"){release != nil}
        try require(s.model.primaryActivationPending && s.model.busy && AddWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Accepted Add launch lost source/global Quit ownership")
        var reads=0
        s.model.querySelection={paths,ignored,cancellation in
            reads += 1
            return try await c.repo.addDialogSelection(paths:paths,includeIgnored:ignored,cancellation:cancellation)
        }
        s.model.reload()
        try require(reads==0 && s.model.primaryActivationPending,"Refresh replaced an accepted Add launch before drain")
        release?.resume();release=nil;try await s.idle()
        try await wait("Deferred Add refresh did not occur exactly once"){reads==1 && !s.model.busy}
        try require(deliveries==c.explicitPaths.count,"Deferred refresh lost accepted ordered comparison")
        try await c.preserved()
        // A second real launch retains its source close callback and the global
        // operation counter until the held launch acknowledges cancellation.
        _ = try await s.select(c.explicitPaths,mark:c.added)
        try s.compare();try await wait("Forced-close launch was not held"){release != nil}
        let before=deliveries;s.window.close()
        try require(token?.isCancelled==true && closed==0 && s.model.primaryActivationPending && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced source close released a live Add launch")
        release?.resume();release=nil
        try await wait("Forced Add launch/source did not drain"){closed==1 && !s.model.primaryActivationPending && !root.hasPendingRepositoryWork && AddWindowModel.activeOperations==0 && FileListComparisonSession.activeOperations==0}
        try require(deliveries==before && !s.window.isVisible,"Closed source delivered a late comparison")
        try await c.preserved()
    }
    static func nativeWarning(_ c:Context)async throws {
        let s=try await c.source(),root=c.root()
        let ordered=try await s.select(c.explicitPaths,mark:c.added)
        var delivered:[String]=[],question:NSWindow?,pairedDrain=true
        root.fileComparisonPresentation={_,file in
            pairedDrain = pairedDrain && question?.sheetParent==nil && s.window.attachedSheet !== question
            delivered.append(file.path)
        }
        s.model.onPrimaryFileActivation={plan,token in try await root.showStatusListPrimaryFiles(plan,access:nil,cancellation:token)}
        s.model.confirmPrimaryFileActivation=nil
        try await c.checkpoint();try s.compare(alternate:true)
        try await wait("Actual Add multi-file question was not presented"){s.window.attachedSheet != nil}
        question=s.window.attachedSheet
        let sheet=try unwrap(question,"Actual Add warning sheet absent")
        try require(sheet.sheetParent === s.window && s.model.primaryActivationPending,"Native question was not source-owned")
        let yes=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==String(localized:"Yes")},"Actual Yes button absent")
        yes.performClick(nil)
        try await s.idle();try await wait("Accepted native Add warning or Root did not drain"){sheet.sheetParent==nil && s.window.attachedSheet !== sheet && !root.hasPendingRepositoryWork}
        try require(pairedDrain && delivered==ordered,"Native Yes delivered before paired detach or lost selection")
        try await c.preserved()
        // Cancel/close the actual question, including both AppKit sheet links.
        let cancel=try await c.source();_ = try await cancel.select(c.explicitPaths,mark:c.added)
        var launches=0,closed=0;cancel.owner.onClosed={closed += 1}
        cancel.model.onPrimaryFileActivation={_,_ in launches += 1};cancel.model.confirmPrimaryFileActivation=nil
        try cancel.compare();try await wait("Cancelable Add native question absent"){cancel.window.attachedSheet != nil}
        let cancelled=try unwrap(cancel.window.attachedSheet,"Cancellation sheet missing")
        try require(!cancel.owner.windowShouldClose(cancel.window),"Source close bypassed pending native Add question")
        try await wait("Cancelled Add native question/source did not drain"){!cancel.model.primaryActivationPending && closed==1 && cancelled.sheetParent==nil && cancel.window.attachedSheet !== cancelled}
        try require(launches==0 && !cancel.window.isVisible,"Cancelled native Add question launched files")
        try await c.preserved()
    }
    static func legacy(_ c:Context)async throws {
        let s=try await c.source(),table=try s.table()
        table.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)]
        let ordered=try await s.select([c.added,c.renamed,c.modified],mark:c.added),checks=s.model.checked
        var fallback:[[String]]=[],preview:[String]=[],conflicts:[String]=[]
        s.model.onPrimaryFileActivation=nil;s.model.onCompare={fallback.append($0)}
        s.model.onPreview={preview.append($0)};s.model.onEditConflict={conflicts.append($0)}
        try s.compare(alternate:true)
        try require(fallback==[ordered] && !s.model.primaryActivationPending,"Independent consumer legacy explicit callback changed")
        _ = try await s.select([c.conflict],mark:c.conflict);try s.enter()
        _ = try await s.select([c.untracked],mark:c.untracked);try s.enter()
        try require(conflicts==[c.conflict] && preview==[c.untracked] && s.model.checked==checks,"Legacy primary conflict/preview/check behavior changed")
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietAddOperandOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietAddOperandSheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer {method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let base=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL,git=URL(fileURLWithPath:CommandLine.arguments[2])
        let selected=Set(CommandLine.arguments.dropFirst(3)),cohorts=["operands","primary","stale","ownership","native-warning","legacy"]
        try require(selected.isSubset(of:Set(cohorts)),"Unknown Add comparison cohort")
        for name in cohorts where selected.isEmpty || selected.contains(name) {
            let c=try Context(base:base.appendingPathComponent(name),git:git)
            do {
                try await c.setup()
                switch name {
                case "operands":try await operands(c)
                case "primary":try await primary(c)
                case "stale":try await stale(c)
                case "ownership":try await ownership(c)
                case "native-warning":try await nativeWarning(c)
                default:try await legacy(c)
                }
                try await c.cleanup();print("PASS ADD COMPARISON COHORT: "+name)
            } catch {try await cleanupPreservingFailure(c,error)}
        }
        print("PASS: Add explicit comparison operands through actual native menu and Root; direct A/R/conflict/removed-and-present rows, exact origins/null sides/native order/Shift, primary distinction, stale receipts, one warning, paired native Yes/Cancel, deferred refresh/Close/Quit ownership and private cleanup")
    }
}
