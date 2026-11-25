// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@MainActor enum ReplayRecoveryPrimaryVerification {
    typealias Prior=StatusPrimaryActivationVerification
    static var stateWitness:()->String={""}
    static func trace(_ message:String) {SyncPrimaryActivationVerification.trace("REPLAY "+message)}
    static func require(_ value:Bool,_ message:String)throws {
        if !value {trace("ASSERTION "+message+" "+stateWitness())}
        try Prior.require(value,"Replay recovery: "+message)
    }
    static func wait(_ message:String,_ ready:()->Bool)async throws {
        trace("WAIT "+message)
        do {try await Prior.wait(message,ready);trace("READY "+message)}
        catch {trace("TIMEOUT "+message+" "+stateWitness());throw error}
    }
    static func clickButton(_ button:NSButton) {
        trace("BUTTON begin "+button.title);button.performClick(nil);trace("BUTTON returned "+button.title)
    }
    static func views(_ owner:NSWindowController)->[NSView] {Prior.views(owner.window?.contentView)}
    static func configure(_ root:RepositoryModel,_ owner:RebaseWindowController,_ context:Context) {
        root.configureReplayRecoveryInteractions(owner,access:nil)
        let configured=owner.configureConflictResolution
        owner.configureConflictResolution={ [weak context] child in
            configured(child)
            // Track the actual owned controller for failure cleanup without
            // showWindow/orderFront: its source alone presents the sheet.
            context?.owners.append(child)
            try? context?.recordResolve("created-\(context?.owners.count ?? 0)",child)
        }
    }
    static func table(_ owner:RebaseWindowController)async throws->ConflictReportNativeTable {
        try await wait("Real replay recovery report did not mount") {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            return !owner.model.busy && owner.model.fileRecovery && owner.model.recoveryReportAvailable &&
                owner.model.conflictTableRows.count>=6 && views(owner).compactMap{$0 as? ConflictReportNativeTable}.contains{$0.numberOfRows==owner.model.conflictTableRows.count && $0.isEnabled}
        }
        return try Prior.unwrap(views(owner).compactMap{$0 as? ConflictReportNativeTable}.first,"Native replay recovery table absent")
    }
    static func projectionCurrent(_ owner:RebaseWindowController,_ table:ConflictReportNativeTable)->Bool {
        guard table.window === owner.window,views(owner).contains(where:{$0 === table}),
              let report=table.dataSource as? ConflictReportTable.Coordinator,
              table.isEnabled,!table.isHiddenOrHasHiddenAncestor,!owner.model.busy,
              !owner.model.conflictReportRefresh.hasPendingPosition,
              report.owner.enabled,report.owner.selection==owner.model.selectedConflicts else{return false}
        let rows=owner.model.conflictTableRows.map(\.entry.path)
        let actual=report.owner.rows.map(\.path)
        guard table.numberOfRows==rows.count,actual.map({Data($0.utf8)})==rows.map({Data($0.utf8)}),
              report.owner.sort==owner.model.conflictSortOrder.first?.column,
              report.owner.ascending==(owner.model.conflictSortOrder.first?.order != .reverse) else{return false}
        return table.selectedRowIndexes==IndexSet(actual.indices.filter{owner.model.selectedConflicts.contains(actual[$0])})
    }
    static func selectionDiagnostic(_ owner:RebaseWindowController,_ table:ConflictReportNativeTable)->String {
        let model=owner.model,report=table.dataSource as? ConflictReportTable.Coordinator
        let current=views(owner).compactMap{$0 as? ConflictReportNativeTable}
        return "busy=\(model.busy), retired=\(model.retired), tab=\(model.tab), available=\(model.recoveryReportAvailable), pendingPosition=\(model.conflictReportRefresh.hasPendingPosition), pendingWorkers=\(model.pendingBatchWorkers), requestedTable=\(ObjectIdentifier(table)), currentTables=\(current.map{String(describing:ObjectIdentifier($0))}), attached=\(table.window === owner.window), visible=\(owner.window?.isVisible == true), hidden=\(table.isHiddenOrHasHiddenAncestor), enabled=\(table.isEnabled), indices=\(table.selectedRowIndexes), modelSelected=\(String(reflecting:Array(model.selectedConflicts))), modelEncoded=\(String(reflecting:model.nativeConflictSelection)), modelRows=\(String(reflecting:model.conflictTableRows.map(\.entry.path))), sort=\(model.conflictSortOrder), reportEnabled=\(String(describing:report?.owner.enabled)), reportSelected=\(String(reflecting:report.map{Array($0.owner.selection)})), reportRows=\(String(reflecting:report?.owner.rows.map(\.path))), reportSort=\(String(describing:report?.owner.sort)), reportAscending=\(String(describing:report?.owner.ascending))"
    }
    static func select(_ paths:[String],_ owner:RebaseWindowController,_ table:ConflictReportNativeTable,line:Int = #line)async throws->[String] {
        do {
            try await wait("Native replay projection did not settle at caller \(line)") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                return projectionCurrent(owner,table)
            }
        } catch {try require(false,"Projection admission at \(line): "+selectionDiagnostic(owner,table));throw error}
        let wanted=GitPathSet(paths),rows=owner.model.conflictTableRows.map(\.entry.path)
        try require(rows.filter{wanted.contains($0)}.count==wanted.count,"Selection includes a missing recovery row")
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(rows.indices.filter{wanted.contains(rows[$0])}))
        do {
            try await wait("Native replay selection did not settle at caller \(line)") {
                owner.window?.contentView?.layoutSubtreeIfNeeded()
                return owner.model.selectedConflicts==wanted && projectionCurrent(owner,table)
            }
        } catch {try require(false,"Selection at \(line), wanted=\(String(reflecting:paths)): "+selectionDiagnostic(owner,table));throw error}
        return rows.filter{wanted.contains($0)}
    }
    static func enter(_ owner:RebaseWindowController,_ table:ConflictReportNativeTable,_ flags:NSEvent.ModifierFlags=[],code:UInt16=36)async throws {
        let window=try Prior.unwrap(owner.window,"Native replay event owner missing")
        try await wait("Recovery report not ready for real Return"){window.contentView?.layoutSubtreeIfNeeded();return table.isEnabled && owner.model.recoveryReportAvailable && window.isVisible && !table.isHiddenOrHasHiddenAncestor}
        table.commandKeyWindow={[weak window] in window}
        try require(window.makeFirstResponder(table) && window.firstResponder === table,"Recovery table refused first responder")
        try require(SyncPrimaryActivationVerification.dispatchKey(window,SyncPrimaryActivationVerification.key(window,code:code,flags:flags)),"Default Continue stole report Return")
    }
    @MainActor final class Context {
        let repository:GitRepository,folder:URL,prefs:UserDefaults,suite:String
        let baselineWindows:Set<ObjectIdentifier>
        let conflict="a conflict 雪.txt",other="b conflict.txt",normal="c applied.txt",modified="d modified.txt",retained="e retained.txt",missing="f missing-added.txt"
        var owners:[NSWindowController]=[],roots:[RepositoryModel]=[],unblock:[()->Void]=[]
        var originalHead=Data(),originalIndex=Data(),originalFiles:[String:Data]=[:],originalModified:[String:Date]=[:]
        init(base:URL,git:URL,cherry:Bool)throws {
            baselineWindows=Set(NSApp.windows.map{ObjectIdentifier($0)})
            folder=base.appendingPathComponent(cherry ? "cherry-pick":"rebase",isDirectory:true).standardizedFileURL
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            repository=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.ReplayPrimary."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["EnableLogCache","EnableGravatar","UseLibgit2","ConfirmKillProcess"] {prefs.set(false,forKey:key)}
            prefs.set(3,forKey:"NumDiffWarning");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        }
        func setup(cherry:Bool)async throws {
            _=try await repository.run(["init","-b","main"])
            for(key,value)in[("user.name","Replay Primary QA"),("user.email","replay-primary@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repository.run(["config",key,value])}
            for path in [conflict,other,modified,retained] {try Data("base\n".utf8).write(to:folder.appendingPathComponent(path))}
            try await repository.stage(["."]);_=try await repository.commit(message:"base")
            let base=try await repository.rebaseCommit("HEAD")
            _=try await repository.run(["switch","-c","upstream"])
            for path in [conflict,other] {try Data("upstream\n".utf8).write(to:folder.appendingPathComponent(path))}
            try await repository.stage(["."]);_=try await repository.commit(message:"upstream")
            _=try await repository.run(["switch","-c","topic",base.hash])
            for path in [conflict,other] {try Data("topic\n".utf8).write(to:folder.appendingPathComponent(path))}
            try Data("applied ordinary\n".utf8).write(to:folder.appendingPathComponent(normal))
            try await repository.stage(["."]);_=try await repository.commit(message:"topic")
            let topic=try await repository.rebaseCommit("HEAD")
            let plan:RebasePlan
            if cherry {_=try await repository.run(["switch","upstream"]);plan=try await repository.cherryPickPlan(revisions:[topic.hash])}
            else {var options=RebaseOptions();options.branch="topic";options.upstream="upstream";plan=try await repository.rebasePlan(options)}
            let editor=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/MacOS/TurtleGitMac")
            try require(FileManager.default.isExecutableFile(atPath:editor.path),"Built private sequence editor unavailable")
            _=try await repository.startRebase(plan,editorExecutable:editor)
            try require(try await repository.conflicts().count==2,"Real replay did not stop with two conflicts")
            try Data("ordinary modified\n".utf8).write(to:folder.appendingPathComponent(modified))
            _=try await repository.run(["rm","--cached","--",retained])
            try Data("missing staged\n".utf8).write(to:folder.appendingPathComponent(missing));try await repository.stage([missing]);try FileManager.default.removeItem(at:folder.appendingPathComponent(missing))
            try MergeToolPreferences.load(from:prefs).save(to:prefs)
            originalHead=try await repository.run(["rev-parse","HEAD"]).stdout;originalIndex=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            for path in [conflict,other,normal,modified,retained] {
                originalFiles[path]=try Data(contentsOf:folder.appendingPathComponent(path))
                originalModified[path]=try FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent(path).path)[.modificationDate] as? Date
            }
            try recordIndex("setup-baseline",bytes:originalIndex)
        }
        func own(_ owner:NSWindowController) {
            trace("OPEN begin "+String(describing:type(of:owner)))
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            trace("OPEN returned "+String(describing:type(of:owner)))
        }
        /// Bounded diagnostics for this private SHA-1 index. Raw bytes remain
        /// authoritative; unsupported versions retain their complete copies.
        func indexFields(_ data:Data)->(semantic:[String],stat:[String],extensions:String)? {
            let b=Array(data)
            func hex(_ range:Range<Int>)->String {b[range].map{String(format:"%02x",$0)}.joined()}
            func word(_ offset:Int)->Int {Int(b[offset])<<24 | Int(b[offset+1])<<16 | Int(b[offset+2])<<8 | Int(b[offset+3])}
            guard b.count>=32,Array(b[0..<4])==Array("DIRC".utf8),[2,3].contains(word(4)) else{return nil}
            var offset=12,semantic:[String]=[],stat:[String]=[]
            for _ in 0..<word(8) {
                let start=offset
                guard start+62<=b.count-20 else{return nil}
                let flags=Int(b[start+60])<<8 | Int(b[start+61])
                var extra=0;offset=start+62
                if flags & 0x4000 != 0 {
                    guard offset+2<=b.count-20 else{return nil}
                    extra=Int(b[offset])<<8 | Int(b[offset+1]);offset += 2
                }
                guard let end=b[offset..<(b.count-20)].firstIndex(of:0) else{return nil}
                let path=hex(offset..<end),stage=(flags>>12)&3
                semantic.append("\(path):stage=\(stage):mode=\(word(start+24)):object=\(hex((start+40)..<(start+60))):flags=\(flags):extended=\(extra)")
                stat.append("\(path):stage=\(stage):"+hex(start..<(start+40)))
                offset=start+((end+1-start+7)/8)*8
                guard offset<=b.count-20 else{return nil}
            }
            return (semantic,stat,hex(offset..<(b.count-20)))
        }
        func recordIndex(_ phase:String,bytes:Data?=nil)throws {
            let current=try bytes ?? Data(contentsOf:folder.appendingPathComponent(".git/index"))
            let destination=folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent+"-index-evidence",isDirectory:true)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            try current.write(to:destination.appendingPathComponent(phase+".index"))
            var files:[String:Any]=[:]
            for path in originalFiles.keys.sorted() {
                let attrs=try FileManager.default.attributesOfItem(atPath:folder.appendingPathComponent(path).path)
                let info:[String:Any]=["size":(attrs[.size] as? NSNumber)?.uint64Value ?? 0,"inode":(attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,"mode":(attrs[.posixPermissions] as? NSNumber)?.uint64Value ?? 0,"modified":(attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0]
                files[path]=info
            }
            let fields=indexFields(current)
            let value:[String:Any]=["phase":phase,"bytes":current.count,"semantic":fields?.semantic ?? [],"stat":fields?.stat ?? [],"extensions":fields?.extensions ?? "unparsed","files":files]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:destination.appendingPathComponent(phase+".json"))
        }
        func recordResolve(_ phase:String,_ child:ResolveWindowController)throws {
            let destination=folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent+"-window-evidence",isDirectory:true)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            func identity(_ window:NSWindow?)->String {window.map{String(describing:ObjectIdentifier($0))} ?? "nil"}
            let value:[String:Any]=["phase":phase,"controller":String(describing:ObjectIdentifier(child)),"window":identity(child.window),"visible":child.window?.isVisible ?? false,"parent":identity(child.window?.sheetParent),"sheet":identity(child.window?.attachedSheet),"retired":child.retired,"active":child.model.active,"busy":child.model.busy,"question":child.model.hasQuestion,"success":child.model.success]
            try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:destination.appendingPathComponent(phase+".json"))
        }
        func assertRestoredIndex(_ phase:String)throws {
            let current=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            try recordIndex(phase,bytes:current)
            let old=indexFields(originalIndex),new=indexFields(current)
            try require(current==originalIndex,"Fixture index differs at \(phase); semanticSame=\(old?.semantic==new?.semantic), statSame=\(old?.stat==new?.stat), extensionsSame=\(old?.extensions==new?.extensions). Original raw-byte baseline retained.")
        }
        func preserved(line:Int = #line)async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==originalHead,"Read-only activation changed HEAD at caller \(line)")
            let current=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            try recordIndex("preserved-\(line)",bytes:current)
            let oldFields=indexFields(originalIndex),newFields=indexFields(current)
            let first=zip(originalIndex,current).enumerated().first{$0.element.0 != $0.element.1}?.offset
            try require(current==originalIndex,"Read-only activation changed index at caller \(line); baselineBytes=\(originalIndex.count), currentBytes=\(current.count), firstDifference=\(String(describing:first)), semanticSame=\(oldFields?.semantic==newFields?.semantic), statSame=\(oldFields?.stat==newFields?.stat), extensionsSame=\(oldFields?.extensions==newFields?.extensions). Full private raw/field evidence retained before cleanup.")
            for(path,bytes)in originalFiles {try require(try Data(contentsOf:folder.appendingPathComponent(path))==bytes,"Read-only activation changed "+path)}
        }
        func root()->RepositoryModel {
            let root=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:folder.appendingPathComponent("finder.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:folder.appendingPathComponent("marks.json")),cachePersistenceDefaults:prefs)
            roots.append(root);root.fileComparisonPreferences=prefs;return root
        }
        func cleanup()async throws {
            trace("CLEANUP begin "+stateWitness())
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[];roots.forEach{$0.stopMonitoringForTermination()}
            func liveWindows()->[NSWindow] {
                NSApp.windows.filter{!baselineWindows.contains(ObjectIdentifier($0)) && ($0.isVisible || $0.attachedSheet != nil || $0.sheetParent != nil)}
            }
            func drained()->Bool {
                owners.compactMap{$0 as? RebaseWindowController}.allSatisfy({!$0.transportBatchWorkPending && $0.model.pendingBatchWorkers==0}) &&
                    roots.allSatisfy({!$0.hasPendingRepositoryWork}) && Prior.drained() &&
                    RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 &&
                    ResolveWindowController.activeReleases==0 && ResetWindowModel.activeReads==0 && liveWindows().isEmpty
            }
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            let details="owners=\(owners.compactMap{$0 as? RebaseWindowController}.map{"pending=\($0.model.pendingBatchWorkers), transport=\($0.transportBatchWorkPending), retired=\($0.model.retired)"}), roots=\(roots.map{$0.hasPendingRepositoryWork}), preparation=\(RebaseWindowModel.activePreparationReads), columns=\(RebaseWindowModel.activeColumnReads), resolve=\(ResolveWindowModel.activeOperations), resolveReleases=\(ResolveWindowController.activeReleases), resetReads=\(ResetWindowModel.activeReads), selectedSessions=\(FileListComparisonSession.activeOperations), windows=\(liveWindows().map{"\(ObjectIdentifier($0)) \(String(reflecting:$0.title)) visible=\($0.isVisible), parent=\(String(describing:$0.sheetParent)), sheet=\(String(describing:$0.attachedSheet))"})"
            // Never reset/abort the private repository while an accepted Git
            // worker is still alive. A timeout is a failed cleanup receipt.
            try require(drained(),"Owned cleanup did not drain; "+details)
            _=try? await repository.abortRebase();prefs.removePersistentDomain(forName:suite)
            trace("CLEANUP complete")
        }
    }
    static func invoke(_ menu:NSMenu,_ id:String)throws {
        func find(_ menu:NSMenu)->NSMenuItem? {for item in menu.items {if item.identifier?.rawValue==id{return item};if let sub=item.submenu,let match=find(sub){return match}};return nil}
        let item=try Prior.unwrap(find(menu),"Native command absent: "+id)
        try require(item.isEnabled,"Native command disabled: "+id)
        _=NSApp.sendAction(try Prior.unwrap(item.action,"Native selector missing"),to:item.target,from:item)
    }
    static func click(_ table:ConflictReportNativeTable,window:NSWindow,row:Int,column:Int,alternate:Bool=false)throws {
        table.scrollRowToVisible(row);table.scrollColumnToVisible(column);window.contentView?.layoutSubtreeIfNeeded();window.makeFirstResponder(table)
        let rect=table.frameOfCell(atColumn:column,row:row).intersection(table.visibleRect)
        try require(!rect.isEmpty,"Actual pointer cell clipped")
        let point=table.convert(NSPoint(x:rect.midX,y:rect.midY),to:nil),stamp=ProcessInfo.processInfo.systemUptime
        let flags:NSEvent.ModifierFlags=alternate ? .shift:[]
        let down=try Prior.unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:flags,timestamp:stamp,windowNumber:window.windowNumber,context:nil,eventNumber:71,clickCount:2,pressure:1),"Pointer down missing")
        let up=try Prior.unwrap(NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:flags,timestamp:stamp+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:72,clickCount:2,pressure:0),"Pointer up missing")
        let selector=#selector(getter:NSWindow.isKeyWindow),method=try Prior.unwrap(class_getInstanceMethod(NSWindow.self,#selector(getter:NSWindow.isKeyWindow)),"Native key getter missing")
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
    static func checks(_ owner:RebaseWindowController,_ table:ConflictReportNativeTable)async throws {
        let model=owner.model,original=try Prior.unwrap(model.state,"Stopped replay state missing"),header=try Prior.unwrap(table.headerView,"Report header missing")
        let checked=model.checkedConflicts
        let selected=model.conflictTableRows.map(\.entry.path)
        _=try await select(selected,owner,table)
        var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any]
        value.removeValue(forKey:"stoppedAction")
        // Deliberately exercise the projection's independent check policy; Git
        // remains in the same real stopped occurrence throughout this UI probe.
        model.state=try JSONDecoder().decode(RebaseState.self,from:JSONSerialization.data(withJSONObject:value))
        try await wait("Read-only check policy did not reach native cells") {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            return !model.canCheckConflictFiles && (table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton)?.isEnabled==false
        }
        let button=try Prior.unwrap(table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton,"Native checkbox absent")
        table.commandKeyWindow={[weak window=owner.window] in window};owner.window?.makeFirstResponder(table)
        let space=try SyncPrimaryActivationVerification.key(owner.window!,text:" ",code:49)
        table.keyDown(with:space);clickButton(button)
        try require(model.checkedConflicts==checked && model.recoveryReportAvailable && table.activateSelectedReturn != nil,"Read-only checks disabled row interaction or changed checks")
        model.state=original
        try await wait("Native checkbox did not re-enable in place"){button.isEnabled && table.headerView === header}
        try require(table.view(atColumn:0,row:0,makeIfNecessary:true) === button,"Availability update replaced native checkbox/header")
        for (index,row) in model.conflictTableRows.enumerated() {
            let cell=try Prior.unwrap(table.view(atColumn:1,row:index,makeIfNecessary:true) as? NSTableCellView,"Native mixed Path cell missing")
            try require(cell.imageView?.image != nil && cell.imageView?.image?.tiffRepresentation==row.entry.state.icon.image()?.tiffRepresentation,"Mixed recovery row uses conflict-only icon")
        }
    }
    static func exercise(_ c:Context)async throws {
        let owner=RebaseWindowController(repository:c.repository,access:nil,preferences:c.prefs),model=owner.model,root=c.root()
        c.own(owner);configure(root,owner,c);model.load()
        let table=try await self.table(owner),window=try Prior.unwrap(owner.window,"Replay owner missing")
        try require(model.conflictRebase == (try await c.repository.conflictIsRebase()),"Displayed conflict orientation differs from repository")
        try await checks(owner,table)
        model.setConflictSort([RebaseConflictSort(column:.path,order:.reverse)])
        let ordered=try await select(model.conflictTableRows.map(\.entry.path),owner,table),checked=model.checkedConflicts
        let expectedConflicts=try await c.repository.conflicts(),lookup=GitPathMap(uniqueKeysWithValues:expectedConflicts.map{($0.path,$0)})
        var warnings:[Int]=[],launches=0,seen:[String]=[]
        model.confirmPrimaryConflictFileActivation={warnings.append($0);return false}
        model.onPrimaryConflictFileActivation={_,_ in launches += 1}
        try await enter(owner,table);try await wait("Declined mixed warning did not drain"){!model.busy && !model.primaryConflictActivationPending}
        try require(warnings==[ordered.count] && launches==0,"One warning did not decline whole mixed selection")
        model.confirmPrimaryConflictFileActivation={warnings.append($0);return true}
        model.onPrimaryConflictFileActivation={plan,_ in
            try require(plan.actions.map{$0.file.entry.path}==ordered && plan.selectedCount==ordered.count,"Mixed Return lost display order/count")
            try require(plan.expectedConflicts==ordered.compactMap{lookup[$0]} && plan.isRebase==model.conflictRebase,"Accepted conflict stages/orientation changed")
            try require(plan.window === window && plan.preferences === c.prefs && plan.alternateTool && plan.ownerIsCurrent() && plan.repository.libgit2Configuration?.enabled==false,"Window/settings/Shift/backend not captured")
            try require(plan.actions.contains{if case .skipMissing(let row)=$0{return row.entry.path==c.missing};return false},"Ineligible missing row was compared")
            try require(plan.actions.contains{if case .workingFile(let row)=$0{return row.entry.path==c.retained};return false},"Retained copy did not retain working sentinel")
            seen=plan.actions.map{$0.file.entry.path};launches += 1
        }
        try await enter(owner,table,.shift,code:76);try await wait("Mixed selected keypad Return did not drain"){!model.busy}
        try require(seen==ordered && launches==1 && model.checkedConflicts==checked,"Return changed checks or dropped mixed rows")
        let clicked=try Prior.unwrap(model.conflictTableRows.firstIndex{$0.entry.path==c.conflict},"Clicked conflict absent")
        model.onPrimaryConflictFileActivation={plan,_ in seen=plan.actions.map{$0.file.entry.path};launches += 1}
        try click(table,window:window,row:clicked,column:1)
        try await wait("Actual pointed primary did not drain"){!model.busy && launches==2}
        try require(seen==[c.conflict],"Double-click activated all highlights")
        let count=launches
        try click(table,window:window,row:clicked,column:0)
        try require(launches==count,"Checkbox double-click launched a viewer")
        _=try await select(ordered,owner,table)
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};model.conflictPasteboard=board
        let menu=model.conflictReportMenu(ordered,mark:c.conflict,column:.fileExtension)
        try invoke(menu,"Rebase.Files.copy.extensions")
        let copied=board.string(forType:.string)
        try require(copied==ordered.map{StatusListClipboard.fileExtension($0)}.joined(separator:"\n")+"\n","Extensions clipboard lost selected order")
        try invoke(menu,"Rebase.Files.copy.relative");try require(board.string(forType:.string)==copied,"Native receipt accepted two commands")
        var nativeMenus:[NSMenu]=[]
        table.presentSelectionMenu={menu,_,_ in nativeMenus.append(menu)}
        table.commandKeyWindow={[weak window] in window};window.makeFirstResponder(table)
        let contextKey=try SyncPrimaryActivationVerification.key(window,text:"",code:109,flags:.shift)
        try require(table.performKeyEquivalent(with:contextKey) && table.accessibilityPerformShowMenu() && nativeMenus.count==2,"Native Shift-F10/AX menu unavailable")
        try require(model.selectedConflicts==GitPathSet(ordered),"Keyboard/AX context menu collapsed selection")
        let foreign=NSWindow(contentRect:.init(x:-26000,y:-26000,width:150,height:90),styleMask:[.titled],backing:.buffered,defer:false)
        foreign.isReleasedWhenClosed=false;foreign.alphaValue=0;foreign.orderFront(nil);defer{foreign.close()}
        let foreignCopy=try SyncPrimaryActivationVerification.key(foreign,text:"c",code:8,flags:.command)
        try require(!table.performKeyEquivalent(with:foreignCopy) && board.string(forType:.string)==copied,"Foreign Cmd-C stole replay selection")
        var deletes=0
        let savedDelete=table.deleteSelection;table.deleteSelection={_ in deletes += 1};defer{table.deleteSelection=savedDelete}
        let beforeForeignChecks=model.checkedConflicts
        table.keyDown(with:try SyncPrimaryActivationVerification.key(foreign,text:" ",code:49))
        table.keyDown(with:try SyncPrimaryActivationVerification.key(foreign,text:"",code:51))
        try require(deletes==0 && model.checkedConflicts==beforeForeignChecks,"Foreign keys changed recovery checks/delete callbacks")
        let field=NSTextField(frame:.init(x:1,y:1,width:110,height:22));window.contentView?.addSubview(field);defer{field.removeFromSuperview()}
        try require(window.makeFirstResponder(field),"Private field refused focus")
        let ownedCopy=try SyncPrimaryActivationVerification.key(window,text:"c",code:8,flags:.command)
        try require(!table.performKeyEquivalent(with:ownedCopy),"Report stole Cmd-C from text editor")
        try require(!table.performSelectedReturn(SyncPrimaryActivationVerification.key(window)),"Report stole text-field Return")
        table.keyDown(with:try SyncPrimaryActivationVerification.key(window,text:" ",code:49))
        table.keyDown(with:try SyncPrimaryActivationVerification.key(window,text:"",code:51))
        try require(deletes==0 && model.checkedConflicts==beforeForeignChecks,"Text-field keys changed recovery checks/delete callbacks")
        window.makeFirstResponder(table)
        table.isHidden=true
        try require(!table.performKeyEquivalent(with:ownedCopy),"Hidden report stole Copy")
        table.keyDown(with:try SyncPrimaryActivationVerification.key(window,text:" ",code:49))
        table.keyDown(with:try SyncPrimaryActivationVerification.key(window,text:"",code:51))
        try require(deletes==0 && model.checkedConflicts==beforeForeignChecks,"Hidden report changed checks/delete callbacks")
        table.isHidden=false
        window.orderOut(nil)
        try require(!table.performKeyEquivalent(with:ownedCopy),"Hidden window stole Copy")
        window.orderFront(nil);window.makeFirstResponder(table)
        let single=model.conflictReportMenu([c.conflict],mark:c.conflict,column:.path)
        try require(single.items.first{$0.identifier?.rawValue=="Rebase.Files.conflict.edit"}?.attributedTitle != nil,"Conflict default Edit is not bold")
        let old=model.conflictReportMenu(ordered,mark:c.conflict,column:.path)
        _=try await select([c.normal],owner,table);try invoke(old,"Rebase.Files.copy.relative")
        try require(board.string(forType:.string)==copied,"Stale selection popup copied replacement rows")
        _=try await select(ordered,owner,table)
        var release:CheckedContinuation<Bool,Never>?
        c.unblock.append{release?.resume(returning:false);release=nil}
        model.confirmPrimaryConflictFileActivation={_ in await withCheckedContinuation{release=$0}}
        try await enter(owner,table);try await wait("Held source warning absent"){release != nil}
        model.tab=1;release?.resume(returning:true);release=nil
        try await wait("Replaced tab warning did not drain"){!model.busy}
        try require(launches==2,"Retired replay tab launched late children")
        model.tab=0
        let active=try await self.table(owner)
        _=try await select(ordered,owner,active)
        configure(root,owner,c)
        var delivered:[String]=[],paired=true,nested=0
        root.openExternalConflict={_,_,_,_,_,_,_,prepared,_ in prepared();return false}
        root.conflictEditorPresentation={_,_,path,_ in delivered.append(path);paired = paired && window.attachedSheet==nil}
        root.fileComparisonPresentation={_,file in delivered.append(file.path);paired = paired && window.attachedSheet==nil}
        root.fileComparisonQuestion={_ in nested += 1;return false}
        model.confirmPrimaryConflictFileActivation=nil
        try await enter(owner,active);try await wait("Actual source many-diff warning missing"){window.attachedSheet != nil}
        let warning=try Prior.unwrap(window.attachedSheet,"Native warning missing")
        let yes=try Prior.unwrap(Prior.views(warning.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"},"Actual Yes missing")
        clickButton(yes)
        try await wait("Actual Root mixed launch did not drain"){!model.busy && !root.hasPendingRepositoryWork}
        try require(delivered==ordered.filter{$0 != c.missing} && paired && nested==0 && warning.sheetParent==nil,"Root reordered/skipped mixed rows or launched before sheet drain")
        try await c.preserved()
        // Explicit Compare with base is StartDiff for U too; primary Return
        // remains ConflictEdit. U uses accepted HEAD, never stage 1; the
        // independently applied Added row retains its empty-tree operand.
        let comparePaths=ordered.filter{[c.conflict,c.other,c.normal,c.modified].contains($0)}
        _=try await select(comparePaths,owner,active)
        delivered=[];var compared:[RevisionComparisonSnapshot]=[]
        root.fileComparisonPresentation={snapshot,file in delivered.append(file.path);compared.append(snapshot)}
        model.confirmPrimaryConflictFileActivation={_ in true}
        let acceptedMenu=model.conflictFileMenu(comparePaths,markedPath:c.conflict)
        let acceptedHead=String(decoding:c.originalHead,as:UTF8.self).trimmingCharacters(in:.newlines)
        @MainActor func explicitComparisonDiagnostic()->String {
            let accepted=acceptedMenu.rows.map{"path=\(String(reflecting:$0.path)),XY=\($0.index)\($0.worktree),actions=\($0.reportingActions.rawValue),compare=\($0.comparisonAction),old=\(String(reflecting:$0.reportingOriginalPath))"}
            let outputs=compared.map {snapshot in "from=\(snapshot.from),to=\(snapshot.to),scope=\(String(reflecting:snapshot.scopePaths)),files=\(snapshot.files.map{"\(String(reflecting:$0.path)):\($0.action):old=\(String(reflecting:$0.oldPath))"})"}
            return "expectedOrder=\(String(reflecting:comparePaths)),delivered=\(String(reflecting:delivered)),acceptedHEAD=\(acceptedHead),rows=\(accepted),snapshots=\(outputs),error=\(String(reflecting:model.error)),busy=\(model.busy),RootPending=\(root.hasPendingRepositoryWork),sheet=\(window.attachedSheet != nil)"
        }
        let added=try Prior.unwrap(acceptedMenu.rows.first{GitReferenceName.equal($0.path,c.normal)},"Applied Added row missing")
        try require(added.comparisonAction=="A" && added.reportingOriginalPath==nil,"Authored topic-only path lost its accepted Added/null operand; "+explicitComparisonDiagnostic())
        for path in [c.conflict,c.other] {
            let unmerged=try Prior.unwrap(acceptedMenu.rows.first{GitReferenceName.equal($0.path,path)},"Explicit U row missing")
            try require(unmerged.reportingActions.contains(.unmerged) && unmerged.comparisonAction=="M","Actual conflict did not retain ordinary explicit-Compare policy; "+explicitComparisonDiagnostic())
        }
        model.compareConflictMenu(acceptedMenu)
        do {try await wait("Explicit mixed Compare did not drain"){!model.busy && !root.hasPendingRepositoryWork}}
        catch {fputs("Replay explicit comparison: \(explicitComparisonDiagnostic())\n",stderr);throw error}
        try require(delivered==comparePaths && compared.count==comparePaths.count,"Explicit Compare changed accepted report order or edited conflict; "+explicitComparisonDiagnostic())
        for (path,snapshot) in zip(comparePaths,compared) {
            // StartDiff's Added branch is DiffNull. Only ordinary/U rows use
            // captured HEAD; explicit U Compare must never use stage 1.
            let expectedBase:ComparisonRevision=GitReferenceName.equal(path,c.normal) ? .emptyTree:.revision(acceptedHead)
            let expectedAction=GitReferenceName.equal(path,c.normal) ? "A":"M"
            try require(snapshot.from==expectedBase && snapshot.to == .workingTree && snapshot.scopePaths==[path] && snapshot.files.count==1 && snapshot.files.first?.path==path && snapshot.files.first?.action==expectedAction && snapshot.files.first?.oldPath==nil,"Explicit Compare changed accepted A/null or U/HEAD operands; "+explicitComparisonDiagnostic())
        }
        // Hold the source warning, replace a real U stage, and require Root's
        // post-warning fresh-stage gate to reject the entire explicit compare.
        delivered=[];compared=[]
        model.setConflictSort([RebaseConflictSort(column:.path,order:.forward)])
        let stalePaths=try await select(comparePaths,owner,active)
        try require(stalePaths.first==c.conflict,"Fresh-stage rejection row must be first in actual report order")
        model.confirmPrimaryConflictFileActivation={_ in await withCheckedContinuation{release=$0}}
        model.compareConflictMenu(model.conflictFileMenu(stalePaths,markedPath:c.conflict))
        try await wait("Explicit Compare warning did not hold"){release != nil}
        let changed=try await c.repository.run(["hash-object","-w","--stdin"],input:Data("different accepted-stage bytes\n".utf8)).text.trimmingCharacters(in:.newlines)
        let entry=try Prior.unwrap(lookup[c.conflict],"Expected U stages missing")
        let records=entry.stages.map{"\($0.mode) \($0.number==2 ? changed:$0.object) \($0.number)\t\(entry.path)\0"}.joined()
        _=try await c.repository.run(["update-index","-z","--index-info"],input:Data(records.utf8))
        release?.resume(returning:true);release=nil
        try await wait("Changed-stage explicit Compare did not drain"){!model.busy && !root.hasPendingRepositoryWork}
        try require(delivered.isEmpty && model.error != nil,"Replaced U stage was compared under old receipt")
        try c.originalIndex.write(to:c.folder.appendingPathComponent(".git/index"),options:.atomic)
        try c.assertRestoredIndex("stage-restoration-immediate")
        model.error=nil
        try await wait("Stage-rejection feedback did not detach"){window.attachedSheet==nil && NSApp.modalWindow==nil}
        // Quick Resolve owns the real nested confirmation and does not release
        // the replay source until its sheet, worker and parent links detach.
        let conflictOrder=try await select(ordered.filter{lookup[$0] != nil},owner,active)
        let before=try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))
        try invoke(model.conflictReportMenu(conflictOrder,mark:conflictOrder[0],column:.path),"Rebase.Files.resolve.current")
        try await wait("Owned quick Resolve confirmation absent"){owner.conflictResolutionController?.window?.attachedSheet != nil}
        let child=try Prior.unwrap(owner.conflictResolutionController,"Owned quick Resolve missing"),childWindow=try Prior.unwrap(child.window,"Resolve window missing")
        try require(childWindow.sheetParent === window && model.busy && model.pendingBatchWorkers>0,"Quick Resolve did not retain replay source ownership")
        let question=try Prior.unwrap(childWindow.attachedSheet,"Resolve question missing")
        try c.recordResolve("quick-No-before-answer",child)
        let no=try Prior.unwrap(Prior.views(question.contentView).compactMap{$0 as? NSButton}.first{$0.title=="No"},"Actual Resolve No missing")
        clickButton(no)
        try await wait("Declined owned Resolve did not detach"){!model.busy && owner.conflictResolutionController==nil && childWindow.sheetParent==nil && question.sheetParent==nil && window.attachedSheet !== childWindow}
        try c.recordResolve("quick-No-after-drain",child)
        try require(!childWindow.isVisible,"Declined Resolve remained visible after onClosed; controller=\(ObjectIdentifier(child)), window=\(ObjectIdentifier(childWindow))")
        try require(try Data(contentsOf:c.folder.appendingPathComponent(".git/index"))==before,"Declined quick Resolve mutated index")
        let resolved=c.conflict
        _=try await select([resolved],owner,active)
        try invoke(model.conflictReportMenu([resolved],mark:resolved,column:.path),"Rebase.Files.resolve.current")
        try await wait("Actual affirmative quick Resolve absent"){owner.conflictResolutionController?.window?.attachedSheet != nil}
        let affirmativeChild=try Prior.unwrap(owner.conflictResolutionController,"Affirmative quick Resolve missing")
        let affirmativeQuestion=try Prior.unwrap(affirmativeChild.window?.attachedSheet,"Affirmative Resolve question absent")
        try c.recordResolve("quick-Yes-before-answer",affirmativeChild)
        let resolveYes=try Prior.unwrap(Prior.views(affirmativeQuestion.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Yes"},"Resolve Yes missing")
        clickButton(resolveYes)
        try await wait("Actual Resolve operation did not settle"){!affirmativeChild.model.busy && (affirmativeChild.model.success || affirmativeChild.model.error != nil)}
        try require(affirmativeChild.model.success,"Owned quick Resolve failed: "+(affirmativeChild.model.error ?? "unknown"))
        if !affirmativeChild.retired {affirmativeChild.model.closeProgress()}
        try await wait("Resolved replay report did not refresh"){!model.busy && owner.conflictResolutionController==nil && model.conflicts.count==1 && !model.conflicts.contains{$0.path==resolved}}
        try c.recordResolve("quick-Yes-after-drain",affirmativeChild)
        try require(affirmativeChild.window?.isVisible != true,"Resolved child remained visible after onClosed; controller=\(ObjectIdentifier(affirmativeChild))")
        try c.recordIndex("resolve-success-before-restoration")
        try require(try await c.repository.run(["rev-parse","HEAD"]).stdout==c.originalHead,"Resolve continued or committed the replay")
        // Restore only this private fixture's index/working bytes for the
        // independent late-close case below; no successful user action undone.
        try c.originalIndex.write(to:c.folder.appendingPathComponent(".git/index"),options:.atomic)
        for(path,bytes)in c.originalFiles {
            let file=c.folder.appendingPathComponent(path)
            if try Data(contentsOf:file) != bytes {
                try bytes.write(to:file)
                if let modified=c.originalModified[path] {try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:file.path)}
            }
        }
        try c.assertRestoredIndex("resolve-restoration-immediate")
        model.refreshState();try await wait("Private replay restoration did not refresh"){!model.busy && model.conflicts.count==2}
        try c.assertRestoredIndex("resolve-restoration-after-refresh")
        // Forced close during an actual prepared-entry read retains onClosed
        // and global Quit ownership until that worker acknowledges cancellation.
        _=try await select([c.conflict,c.other],owner,active)
        var readRelease:CheckedContinuation<Void,Never>?,readToken:OperationCancellation?
        c.unblock.append{readRelease?.resume();readRelease=nil}
        root.readConflictEditorEntry={repository,path,token in
            let value=try await repository.conflictEditorEntry(path:path,cancellation:token);readToken=token
            await withCheckedContinuation{readRelease=$0};return value
        }
        model.confirmPrimaryConflictFileActivation={_ in true}
        var closed=0;owner.onClosed={closed += 1}
        try await enter(owner,active);try await wait("Actual replay conflict read did not hold"){readRelease != nil}
        window.close()
        try require(readToken?.isCancelled==true && model.pendingBatchWorkers>0 && closed==0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced replay close released worker/Quit ownership")
        readRelease?.resume();readRelease=nil
        try await wait("Forced replay close did not drain"){closed==1 && !owner.transportBatchWorkPending && !root.hasPendingRepositoryWork}
        try await c.preserved()
        // Column Reset is another actual owned native question. Force its view
        // teardown and require both original parent links before onClosed.
        let resetOwner=RebaseWindowController(repository:c.repository,access:nil,preferences:c.prefs),resetModel=resetOwner.model
        c.own(resetOwner);resetModel.load()
        let resetTable=try await self.table(resetOwner),resetWindow=try Prior.unwrap(resetOwner.window,"Reset source missing")
        resetTable.headerView?.menu?.delegate?.menuNeedsUpdate?(resetTable.headerView!.menu!)
        let resetItem=try Prior.unwrap(resetTable.headerView?.menu?.items.first{$0.title=="Reset columns"},"Native column Reset missing; actual items=\(resetTable.headerView?.menu?.items.map(\.title) ?? [])")
        _=NSApp.sendAction(try Prior.unwrap(resetItem.action,"Reset selector missing"),to:resetItem.target,from:resetItem)
        try await wait("Actual reset sheet absent"){resetWindow.attachedSheet != nil && resetModel.pendingBatchWorkers>0}
        let resetQuestion=try Prior.unwrap(resetWindow.attachedSheet,"Reset question missing")
        var resetClosed=0;resetOwner.onClosed={resetClosed += 1}
        resetWindow.close();resetWindow.contentViewController=nil
        try await wait("Forced reset teardown did not drain original links"){resetClosed==1 && resetModel.pendingBatchWorkers==0 && resetQuestion.sheetParent==nil && resetWindow.attachedSheet !== resetQuestion}
    }
    static func verify(base:URL,git:URL)async throws {
        for cherry in [false,true] {
            trace("COHORT begin git="+git.path+" cherry=\(cherry)")
            let c=try Context(base:base,git:git,cherry:cherry)
            stateWitness={ [weak c] in
                guard let c else{return "context released"}
                let owners=c.owners.compactMap{$0 as? RebaseWindowController}.map{owner in
                    let model=owner.model
                    return "busy=\(model.busy),retired=\(model.retired),tab=\(model.tab),workers=\(model.pendingBatchWorkers),primary=\(model.primaryConflictActivationPending),sheet=\(owner.window?.attachedSheet != nil),error=\(model.error ?? "nil")"
                }
                return "owners=\(owners) roots=\(c.roots.map{$0.hasPendingRepositoryWork}) preparations=\(RebaseWindowModel.activePreparationReads) replay=\(RebaseWindowModel.activeReplayOperations) modal=\(NSApp.modalWindow != nil)"
            }
            defer{stateWitness={""}}
            var featureError:Error?
            do {try await c.setup(cherry:cherry);try await exercise(c)}
            catch {featureError=error;trace("FAILED \(error) "+stateWitness())}
            do {try await c.cleanup()}
            catch {
                if let featureError {try require(false,"Feature failed: \(featureError); cleanup also failed: \(error)")}
                throw error
            }
            if let featureError {throw featureError}
            trace("COHORT complete cherry=\(cherry)")
        }
        print("PASS: Rebase/Cherry Pick native mixed recovery Return, real stage/orientation and working-file intent, menus/check policy, owned Resolve and close/Quit drain")
    }
}
