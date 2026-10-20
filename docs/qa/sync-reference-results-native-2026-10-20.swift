// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncReferenceResultsVerification {
    struct Failure:Error,LocalizedError,CustomStringConvertible {let description:String;var errorDescription:String?{description}}
    @MainActor final class Gate {
        var continuation:CheckedContinuation<Void,Never>?,token:OperationCancellation?,entered=false
        func pause()async {entered=true;await withCheckedContinuation{continuation=$0}}
        func release(){let reply=continuation;continuation=nil;reply?.resume()}
    }
    @MainActor static var owners:[NSWindowController]=[],gates:[Gate]=[]
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?=nil,line:Int = #line,_ condition:()->Bool)async throws {
        for _ in 0..<1200 {window?.contentView?.layoutSubtreeIfNeeded();if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Sync results timeout at \(line)")
    }
    @MainActor static func own(_ controller:NSWindowController){owners.append(controller);if let window=controller.window{window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.orderFront(nil)}}
    static func fixture(_ root:URL,_ git:URL)async throws->(GitRepository,String,String,URL) {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Result QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false"),("core.abbrev","12")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"base result")
        let old=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try await repo.run(["tag","same",old]);_ = try await repo.run(["tag","-a","annotated","-m","annotated tag",old]);_ = try await repo.run(["tag","different",old]);_ = try await repo.run(["tag","v2",old]);_ = try await repo.run(["tag","v10",old])
        let remote=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-remote.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path])
        _ = try await repo.run(["remote","add","origin",remote.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["branch","--set-upstream-to=origin/main","main"])
        try Data("new\n".utf8).write(to:root.appendingPathComponent("file.txt"));try await repo.stage(["file.txt"]);_ = try await repo.commit(message:"new\tresult\u{2028}subject\n\nBody retained")
        let new=String(decoding:try await repo.run(["rev-parse","HEAD"]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        _ = try await repo.run(["push","origin","HEAD:refs/heads/main"])
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",old])
        _ = try await repo.run(["tag","-f","different",new]);_ = try await repo.run(["tag","local-only",new])
        _ = try await repo.run(["--git-dir",remote.path,"update-ref","refs/tags/remote-only",old])
        return(repo,old,new,remote)
    }
    @MainActor static func prepared(_ repo:GitRepository,_ prefs:UserDefaults)async throws->SynchronizationWindowController {
        let owner=SynchronizationWindowController(repository:repo,access:nil,preferences:prefs);own(owner);owner.model.sshSettings.enabled=false
        try await wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && owner.model.outgoing != nil}
        return owner
    }
    @MainActor static func invoke(_ menu:NSMenu,_ id:String)throws {
        func find(_ menu:NSMenu)->NSMenuItem? {for item in menu.items {if item.identifier?.rawValue==id{return item};if let child=item.submenu,let result=find(child){return result}};return nil}
        let item=try unwrap(find(menu),"Result menu action missing: "+id)
        try require(item.isEnabled,"Result menu action disabled: "+id)
        if let action=item.action {_ = NSApp.sendAction(action,to:item.target,from:item)} else {throw Failure(description:"Missing native result selector")}
    }
    @MainActor static func table(_ owner:SynchronizationWindowController,_ tags:Bool)async throws->(SynchronizationResultTable,SynchronizationReferenceResults.Coordinator) {
        let id=tags ? "TurtleGit.Sync.TagResults":"TurtleGit.Sync.ReferenceResults"
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? SynchronizationResultTable}.contains{$0.identifier?.rawValue==id}}
        let table=try unwrap(views(owner.window?.contentView).compactMap{$0 as? SynchronizationResultTable}.first{$0.identifier?.rawValue==id},"Native result table missing")
        return(table,try unwrap(table.dataSource as? SynchronizationReferenceResults.Coordinator,"Native result data source missing"))
    }
    @MainActor static func references(_ repo:GitRepository,_ old:String,_ new:String,_ prefs:UserDefaults)async throws {
        prefs.set(true,forKey:"LogFontForFileListCtrl");prefs.set(27,forKey:"LogFontSize");prefs.set(false,forKey:"RefCompareHideUnchanged")
        let store=try RepositoryAccessStore(storageURL:repo.root.deletingLastPathComponent().appendingPathComponent("result-routing-access.json"))
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:repo.executable)},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
        workspace.fileComparisonPreferences=prefs
        let host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
        defer{workspace.stopMonitoringForTermination();host.close()}
        var syncs:[SynchronizationWindowController]=[],logs:[LogWindowController]=[],comparisons:[RevisionComparisonWindowController]=[],reflogs:[ReferenceLogWindowController]=[]
        workspace.synchronizationWindowPresentation={syncs.append($0);own($0)}
        workspace.logWindowPresentation={logs.append($0);own($0)}
        workspace.revisionComparisonWindowPresentation={comparisons.append($0);own($0)}
        workspace.referenceLogWindowPresentation={reflogs.append($0);own($0)}
        workspace.open(repo.root);try await wait(host){!workspace.busy && workspace.root?.path==repo.root.path}
        workspace.showSynchronization()
        try await wait{syncs.count==1 && !syncs[0].model.busy && syncs[0].model.outgoing != nil}
        let owner=syncs[0],model=owner.model
        let replacementSuite="TurtleGit.ResultReplacement."+UUID().uuidString,replacement=UserDefaults(suiteName:replacementSuite)!
        defer{replacement.removePersistentDomain(forName:replacementSuite)}
        workspace.fileComparisonPreferences=replacement
        model.fetch()
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.referenceChanges.contains{$0.name.rawValue=="refs/remotes/origin/main" && $0.oldHash==old && $0.newHash==new}}
        model.tab=3
        let (native,coordinator)=try await table(owner,false)
        try await wait(owner.window){!coordinator.referenceRows.isEmpty}
        try require(native.tableColumns.map{$0.identifier.rawValue}==["0","1","2","3","4","5","6"],"Source RefList seven columns changed")
        try require(native.doubleAction==nil,"RefList invented doubleclick action")
        try require(abs(native.tableColumns[0].width-130)<1,"Source RefList initial reference width changed")
        let defaultNames=coordinator.referenceRows.map{$0.name.rawValue}
        try require(coordinator.referenceRows.map(\.kind.rawValue)==coordinator.referenceRows.map(\.kind.rawValue).sorted(),"RefList default change-kind grouping changed")
        try require(!defaultNames.isEmpty,"RefList default source rows missing")
        let row=try unwrap(coordinator.referenceRows.firstIndex{$0.name.rawValue=="refs/remotes/origin/main"},"Actual fetched ref row missing")
        native.scrollRowToVisible(row);native.layoutSubtreeIfNeeded()
        for (column,hash) in [(3,old),(5,new)] {
            let cell=try unwrap(native.view(atColumn:column,row:row,makeIfNecessary:true) as? NSTableCellView,"Reference hash cell missing")
            let label=try unwrap(cell.textField,"Reference hash label missing")
            try require(label.stringValue==String(hash.prefix(8)) && label.toolTip==hash,"RefList hash display ignored source8/full tooltip")
            try require(label.font?.pointSize != 27,"RefList incorrectly used optional Log font")
            try require(label.frame.height<=native.rowHeight+0.5 && label.fittingSize.height<=native.rowHeight+0.5,"RefList label overlaps neighboring row")
        }
        let messageCell=try unwrap(native.view(atColumn:6,row:row,makeIfNecessary:true) as? NSTableCellView,"Reference message cell missing")
        let messageLabel=try unwrap(messageCell.textField,"Reference message label missing")
        try require(messageLabel.stringValue.contains("⇥") && messageLabel.stringValue.contains("↵") && messageLabel.toolTip?.contains("\t")==true && messageLabel.toolTip?.contains("\u{2028}")==true,"Single-line reference presentation lost literal message tooltip")
        try require(messageLabel.frame.height<=native.rowHeight+0.5 && messageLabel.fittingSize.height<=native.rowHeight+0.5,"Reference message overlaps neighboring row")
        let first=try unwrap(native.view(atColumn:0,row:row,makeIfNecessary:true) as? NSTableCellView,"Reference name cell missing")
        try require(views(first).contains{$0 is NSImageView},"Source remote ref type icon missing")
        let sourceIDs=["Sync.Results.log.old","Sync.Results.log.new","Sync.Results.compare","Sync.Results.reflog"]
        let menu=try unwrap(coordinator.rowMenu(row),"Actual RefList row menu missing")
        try require(menu.items.filter{!$0.isSeparatorItem}.compactMap{$0.identifier?.rawValue}==sourceIDs,"RefList source action order changed")
        try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"RefList source action icon missing")
        native.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        native.keyOwnerQuery={ [weak window=owner.window] candidate in candidate === window }
        try require(owner.window?.makeFirstResponder(native)==true,"RefList native context focus missing")
        var keyboardMenu:NSMenu?
        native.presentContextMenu={menu,_,_ in keyboardMenu=menu}
        try require(native.showKeyboardContextMenu() && keyboardMenu?.items.count==menu.items.count,"Native keyboard result menu lost selected row/source actions")
        keyboardMenu=nil
        let keyboardEvent=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.shift,timestamp:0,windowNumber:try unwrap(owner.window,"Keyboard result owner").windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:109),"ShiftF10 result event")
        native.keyDown(with:keyboardEvent)
        try require(keyboardMenu?.items.count==menu.items.count,"Actual ShiftF10 did not open selected result menu")
        let blankPoint=native.convert(NSPoint(x:4,y:-30),to:nil)
        let blankEvent=try unwrap(NSEvent.mouseEvent(with:.rightMouseDown,location:blankPoint,modifierFlags:[],timestamp:0,windowNumber:try unwrap(owner.window,"Blank result owner").windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),"Blank-space context event")
        try require(native.menu(for:blankEvent)?.items.count==menu.items.count && native.selectedRow==row,"Blank-space context menu discarded captured selected row")
        try invoke(try unwrap(coordinator.rowMenu(row),"Old Log selected menu"),"Sync.Results.log.old")
        try await wait{logs.count==1 && !logs[0].model.busy && logs[0].model.selected.contains(old)}
        try require(logs[0].model.endRevision==old && logs[0].model.colorPreferences===prefs && logs[0].model.repository.root.path==repo.root.path && logs[0].window?.alphaValue==0,"Actual old Log lost end+selected/repository/preferences/hidden ownership")
        try invoke(try unwrap(coordinator.rowMenu(row),"New Log menu"),"Sync.Results.log.new")
        try await wait{logs.count==2 && !logs[1].model.busy && logs[1].model.selected.contains(new)}
        try require(logs[1].model.endRevision==new && logs[1].model.colorPreferences===prefs,"Actual new Log lost end+selected/preferences")
        try ComparisonToolInvocation.$alternate.withValue(true){try invoke(try unwrap(coordinator.rowMenu(row),"Compare menu"),"Sync.Results.compare")}
        try await wait{comparisons.count==1 && !comparisons[0].model.busy && comparisons[0].model.snapshot != nil}
        try require(comparisons[0].model.from==old && comparisons[0].model.to==new && comparisons[0].model.alternateTool==true && comparisons[0].model.preferences===prefs && comparisons[0].model.repository.root.path==repo.root.path && comparisons[0].window?.alphaValue==0,"Actual comparison lost captured old/new/alternate/preferences/hidden owner")
        try invoke(try unwrap(coordinator.rowMenu(row),"Reflog menu"),"Sync.Results.reflog")
        try await wait{reflogs.count==1 && !reflogs[0].model.busy}
        try require(reflogs[0].model.reference=="refs/remotes/origin/main" && reflogs[0].model.preferences===prefs && reflogs[0].window?.alphaValue==0,"Actual Reflog lost full reference/preferences/hidden owner")
        let retainedReference=try unwrap(coordinator.rowMenu(row),"Pre-filter reference menu missing")
        let header=coordinator.headerMenu()
        try require(header.items.filter{!$0.isSeparatorItem}.count==1,"RefList invented header commands")
        let count=coordinator.referenceRows.count
        try invoke(header,"Sync.Results.hideUnchanged")
        try await wait(owner.window){coordinator.referenceRows.count != count}
        try invoke(retainedReference,"Sync.Results.compare")
        try require(comparisons.count==1,"Retained RefList row menu crossed filter snapshot")
        try require(model.hideUnchangedReferences && !prefs.bool(forKey:"RefCompareHideUnchanged"),"RefList filter improperly persisted window-local toggle")
        let fresh=try await prepared(repo,prefs)
        try require(!fresh.model.hideUnchangedReferences,"New RefList owner inherited previous window-only filter")
        fresh.window?.close()
        native.sortDescriptors=[NSSortDescriptor(key:"0",ascending:false)]
        coordinator.reload()
        try await capture(try unwrap(owner.window,"Ref capture owner"),"sync-reference-results")
    }
    @MainActor static func answer(_ owner:SynchronizationWindowController,_ title:String)async throws {
        try await wait(owner.window){views(owner.window?.attachedSheet?.contentView).compactMap{$0 as? NSButton}.contains{$0.title==title}}
        let sheet=try unwrap(owner.window?.attachedSheet,"Owned tag question missing")
        let button=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==title},"Owned tag response button missing")
        button.performClick(nil);try await wait{sheet.sheetParent==nil}
    }
    @MainActor static func loadTags(_ owner:SynchronizationWindowController)async throws {
        owner.model.compareTags()
        try await wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && owner.model.tagSnapshot != nil}
    }
    @MainActor static func tags(_ repo:GitRepository,_ old:String,_ new:String,_ remote:URL,_ prefs:UserDefaults)async throws {
        prefs.set(false,forKey:"TagCompareHideEqual");prefs.set(true,forKey:"SortTagsReversed")
        let owner=try await prepared(repo,prefs),model=owner.model
        var actions:[(SynchronizationTagAction,String,String)]=[],errors:[String]=[]
        model.performTagOperation={operation,token in
            do {
                switch operation {
                case .tags(let selected):return .success(.tags(try await repo.synchronizationTags(remote:selected,cancellation:token)))
                case .tag(let action,let row,let snapshot,_):
                    actions.append((action,row.tag.rawValue,snapshot.remote))
                    return .failure(Failure(description:"private injected transport failure"))
                default:return .failure(Failure(description:"Unexpected tag workflow operation"))
                }
            }catch{return .failure(error)}
        }
        model.presentTagError={errors.append($0)}
        try await loadTags(owner)
        let (native,coordinator)=try await table(owner,true)
        try require(native.tableColumns.map{$0.identifier.rawValue}==["0","1","2","3","4","5"],"Compare Tags source six columns changed")
        try require(native.doubleAction==nil,"Compare Tags invented doubleclick action")
        native.tableColumns[0].width=30;coordinator.reload()
        try require(native.tableColumns[0].width>30,"Compare Tags did not auto-size columns on each Show")
        try await wait(owner.window){coordinator.tagRows.contains{$0.name.rawValue=="different"}}
        let v2=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="v2"},"Logical v2 row missing"),v10=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="v10"},"Logical v10 row missing")
        try require(v10<v2,"Source reversed logical tag order ignored")
        native.sortDescriptors=[NSSortDescriptor(key:"0",ascending:true)];coordinator.reload()
        try require(coordinator.tagRows.firstIndex{$0.name.rawValue=="v2"}! < coordinator.tagRows.firstIndex{$0.name.rawValue=="v10"}!,"Actual native Tag header lost numeric logical sort")
        let row=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="different"},"Differing tag row missing")
        for (column,hash) in [(2,new),(4,old)] {
            let cell=try unwrap(native.view(atColumn:column,row:row,makeIfNecessary:true) as? NSTableCellView,"Tag hash cell missing")
            let label=try unwrap(cell.textField,"Tag hash label missing")
            try require(label.stringValue==String(hash.prefix(8)) && label.toolTip==hash,"Tag hash display ignored source8/full tooltip")
        }
        let nameCell=try unwrap(native.view(atColumn:0,row:row,makeIfNecessary:true) as? NSTableCellView,"Tag name cell missing")
        try require(!views(nameCell).contains{$0 is NSImageView},"Compare Tags invented row icons")
        let menu=try unwrap(coordinator.rowMenu(row),"Differing tag source menu missing")
        let expected=["log.local","log.remote","compare","fetch","push","deleteLocal","deleteRemote"].map{"Sync.Results."+$0}
        try require(menu.items.filter{!$0.isSeparatorItem}.compactMap{$0.identifier?.rawValue}==expected,"Compare Tags source action order changed")
        try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Compare Tags source action icon missing")
        var logged:[String]=[],compared:[(String,String,Bool)]=[]
        model.onTagLog={logged.append($0)};model.onReferenceCompare={compared.append(($0,$1,ComparisonToolInvocation.capture))}
        try invoke(menu,"Sync.Results.log.local")
        try invoke(try unwrap(coordinator.rowMenu(row),"Remote tag Log menu"),"Sync.Results.log.remote")
        try require(logged==[new,old],"Tag Log lost captured selected revision")
        try ComparisonToolInvocation.$alternate.withValue(true){try invoke(try unwrap(coordinator.rowMenu(row),"Tag Compare menu"),"Sync.Results.compare")}
        try require(compared.count==1 && compared[0].0==new && compared[0].1==old && compared[0].2,"Tag comparison lost local/remote/Shift")
        for (id,expectedAction) in [("fetch",SynchronizationTagAction.fetch),("push",.push)] {
            let current=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="different"},"Refilled differing tag missing")
            try invoke(try unwrap(coordinator.rowMenu(current),"Tag transport menu"),"Sync.Results."+id)
            try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.tagSnapshot != nil}
            try require(actions.last?.0==expectedAction && actions.last?.1=="different" && actions.last?.2=="origin","Tag transport lost captured action/name/remote")
            try require(model.error?.contains("private injected transport failure")==true,"Failed tag transport diagnostic disappeared after refill")
        }
        try require(errors.isEmpty,"Fetch/Push invented an extra remote-delete error dialog")
        for accepted in [false,true] {
            let current=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="local-only"},"Local-only tag missing")
            try invoke(try unwrap(coordinator.rowMenu(current),"Tag delete menu"),"Sync.Results.deleteLocal")
            try await answer(owner,accepted ? "Yes":"No")
            try await wait(owner.window){!model.busy && !model.hasPendingInlineWork}
            let exists=try await repo.run(["rev-parse","--verify","--quiet","--end-of-options","refs/tags/local-only"],successfulExitCodes:0...1).exitCode==0
            try require(exists != accepted,"Tag delete confirmation did not control actual private ref outcome")
        }
        let remoteRow=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="remote-only"},"Remote-only tag missing")
        try invoke(try unwrap(coordinator.rowMenu(remoteRow),"Remote delete menu"),"Sync.Results.deleteRemote")
        try await answer(owner,"Yes")
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork}
        try require(actions.last?.0 == .deleteRemote && actions.last?.1=="remote-only" && actions.last?.2=="origin" && errors.count==1,"Remote tag delete lost captured scope/error")
        let header=coordinator.headerMenu();try require(header.items.filter{!$0.isSeparatorItem}.count==1,"Compare Tags invented header operations")
        try invoke(header,"Sync.Results.hideUnchanged")
        coordinator.reload()
        try require(model.hideEqualTags && !prefs.bool(forKey:"TagCompareHideEqual"),"Tag filter improperly persisted window-local toggle")
        let fresh=try await prepared(repo,prefs)
        try require(!fresh.model.hideEqualTags,"New Compare Tags owner inherited previous window-only filter")
        fresh.window?.close()
        native.sortDescriptors=[NSSortDescriptor(key:"0",ascending:false)]
        coordinator.reload()
        try await capture(try unwrap(owner.window,"Tag capture owner"),"sync-tag-results")
    }
    @MainActor static func ownership(_ repo:GitRepository,_ old:String,_ new:String,_ remote:URL,_ prefs:UserDefaults)async throws {
        let owner=try await prepared(repo,prefs),model=owner.model
        model.performTagOperation={operation,token in
            if case .tags(let remote)=operation {do{return .success(.tags(try await repo.synchronizationTags(remote:remote,cancellation:token)))}catch{return .failure(error)}}
            return .failure(Failure(description:"private refused transport"))
        }
        model.presentTagError={_ in}
        try await loadTags(owner)
        let (native,coordinator)=try await table(owner,true)
        let current=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="different"},"Owned tag menu source missing")
        native.selectRowIndexes(IndexSet(integer:current),byExtendingSelection:false)
        var compared=0;model.onReferenceCompare={_,_ in compared += 1}
        let staleSelection=try unwrap(coordinator.rowMenu(current),"Captured selection menu missing")
        let other=try unwrap(coordinator.tagRows.firstIndex{$0.name.rawValue=="same"},"Alternate tag row missing")
        native.selectRowIndexes(IndexSet(integer:other),byExtendingSelection:false)
        try invoke(staleSelection,"Sync.Results.compare");try require(compared==0,"Retained result menu followed changed selection")
        native.selectRowIndexes(IndexSet(integer:current),byExtendingSelection:false)
        let staleHeader=coordinator.headerMenu(),hidden=model.hideEqualTags
        let staleTab=try unwrap(coordinator.rowMenu(current),"Captured tab menu missing")
        model.tab=2;model.tab=7
        try invoke(staleTab,"Sync.Results.compare");try invoke(staleHeader,"Sync.Results.hideUnchanged")
        try require(compared==0 && model.hideEqualTags==hidden,"Retained result row/header crossed tab generation")
        let staleRead=try unwrap(coordinator.rowMenu(current),"Captured read menu missing")
        model.compareTags()
        try invoke(staleRead,"Sync.Results.compare")
        try require(compared==0,"Busy tag refresh admitted captured row action")
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && model.tagSnapshot != nil}
        let (active,latest)=try await table(owner,true)
        let index=try unwrap(latest.tagRows.firstIndex{$0.name.rawValue=="different"},"Refreshed tag source missing")
        active.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
        let quit=try unwrap(latest.rowMenu(index),"Quit menu missing")
        model.confirmingQuit=true;try invoke(quit,"Sync.Results.compare");try require(compared==0,"Quit-owned tag menu accepted")
        model.confirmingQuit=false
        let sheetMenu=try unwrap(latest.rowMenu(index),"Sheet menu missing")
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:180,height:90),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        owner.window?.beginSheet(sheet,completionHandler:nil);try invoke(sheetMenu,"Sync.Results.compare")
        try require(compared==0,"Owned sheet admitted background tag menu")
        owner.window?.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait{sheet.sheetParent==nil}
        let staleRemote=try unwrap(latest.rowMenu(index),"Remote menu missing")
        model.remote=remote.path
        try invoke(staleRemote,"Sync.Results.compare");try require(compared==0,"Changed remote admitted stale tag menu")
        model.remote="origin"
        let gate=Gate();gates.append(gate)
        model.performTagOperation={operation,token in
            if case .tag=operation {gate.token=token;await gate.pause();return .failure(OperationCancellationFailure.cancelled)}
            if case .tags(let remote)=operation {do{return .success(.tags(try await repo.synchronizationTags(remote:remote,cancellation:token)))}catch{return .failure(error)}}
            return .failure(Failure(description:"Unexpected held tag operation"))
        }
        try await loadTags(owner)
        let (_,heldCoordinator)=try await table(owner,true)
        let heldIndex=try unwrap(heldCoordinator.tagRows.firstIndex{$0.name.rawValue=="different"},"Held tag source missing")
        try invoke(try unwrap(heldCoordinator.rowMenu(heldIndex),"Held fetch menu"),"Sync.Results.fetch")
        try await wait(owner.window){gate.entered && model.busy}
        owner.window?.close()
        try require(gate.token?.isCancelled==true && model.hasPendingInlineWork,"Forced close dropped live tag worker/token before drain")
        gate.release();try await wait{!model.hasPendingInlineWork}
        try require(compared==0,"Retired callback opened comparison")
        // A real owned native deletion question must abort on owner closure.
        let questionOwner=try await prepared(repo,prefs),questionModel=questionOwner.model
        questionModel.performTagOperation={operation,token in
            if case .tags(let selected)=operation {do{return .success(.tags(try await repo.synchronizationTags(remote:selected,cancellation:token)))}catch{return .failure(error)}}
            return .failure(Failure(description:"private error receipt"))
        }
        try await loadTags(questionOwner)
        let (_,questions)=try await table(questionOwner,true)
        let local=try unwrap(questions.tagRows.firstIndex{$0.name.rawValue=="local-only"},"Owned delete source missing")
        try invoke(try unwrap(questions.rowMenu(local),"Owned delete menu"),"Sync.Results.deleteLocal")
        try await wait(questionOwner.window){questionOwner.window?.attachedSheet != nil}
        let actualQuestion=questionOwner.window?.attachedSheet
        questionOwner.window?.close()
        try await wait{!questionModel.hasPendingInlineWork && actualQuestion?.sheetParent==nil}
        let localRef=try await repo.run(["rev-parse","--verify","--quiet","--end-of-options","refs/tags/local-only"],successfulExitCodes:0...1)
        try require(localRef.exitCode==0,"Owner close accepted late deletion confirmation")
        // Default error presenter remains a real owned AppKit sheet until close.
        let errorOwner=try await prepared(repo,prefs),errorModel=errorOwner.model
        errorModel.performTagOperation=questionModel.performTagOperation
        errorModel.confirmTagDeletion={_,_,_ in true}
        try await loadTags(errorOwner)
        let (_,errors)=try await table(errorOwner,true)
        let remoteIndex=try unwrap(errors.tagRows.firstIndex{$0.name.rawValue=="remote-only"},"Owned error source missing")
        try invoke(try unwrap(errors.rowMenu(remoteIndex),"Owned error menu"),"Sync.Results.deleteRemote")
        try await wait(errorOwner.window){views(errorOwner.window?.attachedSheet?.contentView).compactMap{$0 as? NSButton}.contains{$0.title=="OK"}}
        let errorSheet=errorOwner.window?.attachedSheet
        try require(errorModel.busy && errorModel.hasPendingInlineWork,"Native error presentation released active tag request too early")
        errorOwner.window?.close()
        try await wait{!errorModel.hasPendingInlineWork && errorSheet?.sheetParent==nil}
        let loadingOwner=try await prepared(repo,prefs),loadingModel=loadingOwner.model,loadingGate=Gate();gates.append(loadingGate)
        loadingModel.performTagOperation={_,token in loadingGate.token=token;await loadingGate.pause();return .failure(OperationCancellationFailure.cancelled)}
        loadingModel.compareTags()
        try await wait(loadingOwner.window){loadingGate.entered && views(loadingOwner.window?.contentView).compactMap{$0 as? NSTextField}.contains{$0.stringValue=="Please wait…"}}
        loadingOwner.window?.close()
        try require(loadingGate.token?.isCancelled==true && loadingModel.hasPendingInlineWork,"Loading table close dropped active receipt")
        loadingGate.release();try await wait{!loadingModel.hasPendingInlineWork}
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_RESULT_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]),"Capture encoding")
            let filename=name+"-"+suffix+".png";try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(filename));print("Owned capture: \(filename) \(pixels.width)x\(pixels.height)")
        }
    }
    @MainActor static func cleanup()async->Bool {
        for gate in gates{gate.release()}
        for owner in owners.reversed(){if let window=owner.window{if let child=window.attachedSheet{window.endSheet(child,returnCode:.abort);child.close()};window.close()}}
        for window in NSApp.windows{window.orderOut(nil);window.close()}
        for _ in 0..<1200 {if SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowModel.activePushWorkflows==0 && SynchronizationWindowController.activeInlineReleases==0 && LogWindowModel.activeHistoryLoads==0 && ReferenceLogWindowModel.activeOwnedOperations==0 && ReferenceLogWindowModel.activeRevisionReads==0 && RevisionComparisonWindowModel.activeFileOperations==0 && owners.compactMap{$0 as? RevisionComparisonWindowController}.allSatisfy({!$0.model.hasOwnedPreparation}){return true};try? await Task.sleep(nanoseconds:10_000_000)}
        return false
    }
    @MainActor static func main()async {
        NSApp.setActivationPolicy(.prohibited);var failure:Error?
        do {
            let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
            for name in CommandLine.arguments.dropFirst(3) {
                let (repo,old,new,remote)=try await fixture(base.appendingPathComponent(name),git)
                let suite="TurtleGit.SyncResults."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
                defer{prefs.removePersistentDomain(forName:suite)}
                prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TGitAutoLoadSSHKey")
                switch name {case "references":try await references(repo,old,new,prefs);case "tags":try await tags(repo,old,new,remote,prefs);case "ownership":try await ownership(repo,old,new,remote,prefs);default:throw Failure(description:"Unknown Sync result case")}
                print("PASS Sync reference result case: "+name)
            }
        } catch{failure=error}
        if !(await cleanup()),failure==nil{failure=Failure(description:"Owned Sync result workers did not drain")}
        if let failure{fputs("Sync reference results failed: \(failure)\n",stderr);exit(1)}
        print("PASS Sync reference results: "+CommandLine.arguments.dropFirst(3).joined(separator:", ")+"; all owned windows/workers closed")
    }
}
