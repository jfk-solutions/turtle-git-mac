// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietStatusPrimaryOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));quietStatusPrimaryOrder(mode,relativeTo:number)}
    @objc func quietStatusPrimarySheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));quietStatusPrimarySheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main struct StatusPrimaryActivationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func wait(_ message:String,_ predicate:()->Bool)async throws {for _ in 0..<2000 {if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:message)}
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && StatusWindowModel.activeOperations==0 && RevertWindowModel.activeOperations==0 && ResolveWindowModel.activeOperations==0 && FileListComparisonSession.activeOperations==0}
    @MainActor final class Context {
        let root:URL,git:URL,repository:GitRepository,prefs:UserDefaults,suite:String
        let conflict="conflict 雪.txt",other="other-conflict.txt",normal="ordinary.txt"
        var owners:[NSWindowController]=[],index=Data(),head=Data(),bytes:[String:Data]=[:]
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]);git=URL(fileURLWithPath:CommandLine.arguments[2]);repository=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            suite="TurtleGit.StatusPrimary."+UUID().uuidString;prefs=try unwrap(UserDefaults(suiteName:suite),"No private defaults")
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation","AddBeforeCommit"] {prefs.set(true,forKey:key)}
            for key in ["TurtleGit.Commit.GitGuiInterface","SelectFilesForCommit","UseLibgit2","EnableGravatar"] {prefs.set(false,forKey:key)}
        }
        func setup()async throws {
            _=try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Primary QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
            for path in [conflict,other,normal] {try Data("base\n".utf8).write(to:root.appendingPathComponent(path))}
            try await repository.stage(["."]);_=try await repository.commit(message:"Primary fixture")
            let base=try await repository.run(["rev-parse","HEAD:"+normal]).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let mine=try await repository.run(["hash-object","-w","--stdin"],input:Data("mine\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            let theirs=try await repository.run(["hash-object","-w","--stdin"],input:Data("theirs\n".utf8)).text.trimmingCharacters(in:.whitespacesAndNewlines)
            var records=""
            for path in [conflict,other] {
                records += "0 "+String(repeating:"0",count:40)+"\t"+path+"\0"+"100644 \(base) 1\t\(path)\0"+"100644 \(mine) 2\t\(path)\0"+"100644 \(theirs) 3\t\(path)\0"
                try Data("<<<<<<< mine\nmine\n=======\ntheirs\n>>>>>>> theirs\n".utf8).write(to:root.appendingPathComponent(path))
            }
            _=try await repository.run(["update-index","-z","--index-info"],input:Data(records.utf8))
            try Data("ordinary work\n".utf8).write(to:root.appendingPathComponent(normal))
            head=try await repository.run(["rev-parse","HEAD"]).stdout
            for path in [conflict,other,normal] {bytes[path]=try Data(contentsOf:root.appendingPathComponent(path))}
        }
        func preserved()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==head,"Activation changed HEAD")
            try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Activation changed index")
            for(path,value)in bytes {try require(try Data(contentsOf:root.appendingPathComponent(path))==value,"Activation changed working bytes")}
        }
        func clean()async {
            owners.forEach{$0.close()}
            for _ in 0..<2000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func bridge(_ owner:NSWindowController)async throws->StatusListPrimaryActionBridge.Probe {
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait("Primary row bridge not mounted"){views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}.contains{$0.active && !$0.rows.isEmpty}}
        return try unwrap(views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}.first{$0.active && !$0.rows.isEmpty},"No live primary bridge")
    }
    static func table(_ owner:NSWindowController)throws->NSTableView {try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSTableView}.first{$0.headerView != nil},"No native source report")}
    static func select(_ owner:NSWindowController,paths:[String],accepted:()->Bool)async throws {
        let probe=try await bridge(owner),table=try table(owner),wanted=GitPathSet(paths)
        try await wait("Native rows not ready"){table.numberOfRows==probe.rows.count}
        owner.window?.makeFirstResponder(table)
        CommitFileInteraction.replaceSelection(in:table,with:IndexSet(probe.rows.indices.filter{probe.rows[$0].map{wanted.contains($0)} ?? false}))
        try await wait("Native multi-selection not projected"){accepted()}
    }
    static func click(_ owner:NSWindowController,path:String,shift:Bool=false,column:Int?=nil)async throws {
        let probe=try await bridge(owner),table=try table(owner)
        let row=try unwrap(probe.rows.firstIndex(where:{candidate in candidate.map{GitReferenceName.equal($0,path)} ?? false}),"Clicked row absent")
        table.scrollRowToVisible(row);owner.window?.contentView?.layoutSubtreeIfNeeded()
        let col=column ?? probe.checkboxColumns
        let cell=table.frameOfCell(atColumn:col,row:row),point=table.convert(.init(x:cell.midX,y:cell.midY),to:nil)
        let event=try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:shift ? .shift:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:owner.window!.windowNumber,context:nil,eventNumber:1,clickCount:2,pressure:1),"No native double-click event")
        let observed=probe.observe(event)
        if col<probe.checkboxColumns {try require(observed === event,"Checkbox event was swallowed by row activation adapter")}
        else {try require(observed==nil,"Source default double-click was not consumed by actual row adapter")}
    }
    static func checkbox(_ owner:NSWindowController,path:String,value:()->Bool)async throws {
        let before=value()
        try await click(owner,path:path,column:0)
        @MainActor func button()throws->NSButton {
            let probe=try unwrap(views(owner.window?.contentView).compactMap{$0 as? StatusListPrimaryActionBridge.Probe}.first{$0.active},"Checkbox bridge retired")
            let row=try unwrap(probe.rows.firstIndex(where:{candidate in candidate.map{GitReferenceName.equal($0,path)} ?? false}),"Checkbox row missing")
            let table=try Self.table(owner)
            return try unwrap(views(table.view(atColumn:0,row:row,makeIfNecessary:true)).compactMap{$0 as? NSButton}.first,"No mounted native checkbox")
        }
        try button().performClick(nil)
        try await wait("Native checkbox did not toggle"){value() != before}
        try await wait("Native checkbox presentation did not follow action"){(try? button().state) == (before ? .off:.on)}
        try button().performClick(nil)
        try await wait("Native checkbox did not restore"){value() == before}
    }
    static func verify(_ c:Context)async throws {
        let commit=CommitWindowController(repository:c.repository,access:nil,defaults:c.prefs);c.owners.append(commit);commit.showWindow(nil);commit.model.reload(paths:["."])
        try await wait("Commit not ready"){commit.model.fileListAvailable && !commit.model.busy && commit.model.commitIdentityPrepared && commit.model.changelistsLoaded && !commit.model.loadingFileMetadata && !commit.model.fileWorkPending && !commit.model.savingPreferences}
        var commitActions:[(String,[String],Bool)]=[]
        commit.model.onCompare={paths,_ in commitActions.append(("diff",paths,ComparisonToolInvocation.capture))}
        commit.model.onResolve={_,paths in commitActions.append(("edit",paths,ComparisonToolInvocation.capture))}
        try await select(commit,paths:[c.conflict,c.normal]){commit.model.selection==GitPathSet([c.conflict,c.normal])}
        let commitSelection=commit.model.selection
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await click(commit,path:c.conflict,shift:true)
        try require(commitActions.count==1 && commitActions[0].0=="edit" && commitActions[0].1==[c.conflict] && commitActions[0].2 && commit.model.selection==commitSelection,"Classic double-click did not isolate clicked conflict/Shift and retain highlight")
        try await click(commit,path:c.normal)
        try require(commitActions.count==2 && commitActions[1].0=="diff" && commitActions[1].1==[c.normal] && !commitActions[1].2 && commit.model.selection==commitSelection,"Classic ordinary double-click compared whole selection")
        try await click(commit,path:c.conflict,column:0);try require(commitActions.count==2,"Checkbox double-click launched file")
        try await checkbox(commit,path:c.normal){commit.model.checked.contains(c.normal)}
        try require(commitActions.count==2 && commit.model.selection==commitSelection,"Native checkbox action launched viewer or changed highlighted selection")
        let beforeSort=StatusListPrimaryActionReceipt(path:c.normal,revision:commit.model.fileReportRevision,alternate:false)
        commit.model.fileSortOrder=[CommitFileSort(column:.path,order:.reverse)]
        commit.model.activatePrimaryFile(beforeSort);try require(commitActions.count==2,"Classic sort retained old native row receipt")
        commit.model.fileSortOrder=[CommitFileSort(column:.path)]
        commit.model.changelists=GitChangelists(assignments:[c.normal:"Primary QA"])
        let grouped=try await bridge(commit)
        try await wait("Classic changelist group not mounted"){grouped.rows.contains{$0==nil}}
        let groupTable=try table(commit),groupRow=try unwrap(grouped.rows.firstIndex(where:{$0==nil}),"No actual group row")
        groupTable.scrollRowToVisible(groupRow)
        let groupCell=groupTable.frameOfCell(atColumn:1,row:groupRow),groupPoint=groupTable.convert(.init(x:groupCell.midX,y:groupCell.midY),to:nil)
        let groupEvent=try unwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:groupPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:commit.window!.windowNumber,context:nil,eventNumber:2,clickCount:2,pressure:1),"No group event")
        try require(grouped.observe(groupEvent)==nil && commitActions.count==2,"Group row activated highlighted file")
        commit.model.changelists=GitChangelists()
        try await c.preserved()
        let oldCommit=StatusListPrimaryActionReceipt(path:c.normal,revision:commit.model.fileReportRevision,alternate:false)
        commit.model.reload(paths:["."]);try await wait("Commit reload not ready"){commit.model.fileListAvailable && !commit.model.busy && !commit.model.savingPreferences}
        commit.model.activatePrimaryFile(oldCommit);try require(commitActions.count==2,"Reload accepted stale clicked-row receipt")
        let keyboardRows=try await bridge(commit).rows
        let keyboard=try unwrap(StatusListPrimaryActionReceipt.focused([c.conflict,c.normal],focus:c.conflict,rows:keyboardRows,revision:commit.model.fileReportRevision),"No focused keyboard row")
        commit.model.activatePrimaryFile(keyboard);try require(commitActions.count==3 && commitActions.last!.1==[c.conflict],"Keyboard primary action lost focused conflict")
        commit.close();commit.model.activatePrimaryFile(keyboard);try require(commitActions.count==3,"Closed Commit accepted row activation")

        let status=StatusWindowController(repository:c.repository,access:nil,defaults:c.prefs);c.owners.append(status);status.showWindow(nil);status.model.reload()
        try await wait("Working Tree not ready"){!status.model.busy && status.model.hasStatusSnapshot}
        var statusActions:[(RepositoryAction,[String],Bool)]=[];status.model.onAction={action,paths in statusActions.append((action,paths,ComparisonToolInvocation.capture))}
        try await select(status,paths:[c.conflict,c.normal]){status.model.selection==GitPathSet([c.conflict,c.normal])}
        let statusSelection=status.model.selection
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await click(status,path:c.conflict,shift:true);try await click(status,path:c.normal)
        try require(statusActions.count==2 && statusActions[0].0 == .editConflict && statusActions[0].1==[c.conflict] && statusActions[0].2 && statusActions[1].0 == .diff && statusActions[1].1==[c.normal] && status.model.selection==statusSelection,"Working Tree primary routing changed selection or selected-set intent")
        try await c.preserved()
        let oldStatus=StatusListPrimaryActionReceipt(path:c.normal,revision:status.model.primaryActionRevision,alternate:false)
        status.model.reload();try await wait("Working Tree reload not ready"){!status.model.busy && status.model.hasStatusSnapshot}
        status.model.activatePrimaryFile(oldStatus);try require(statusActions.count==2,"Working Tree accepted stale row")
        status.close();status.model.activatePrimaryFile(oldStatus);try require(statusActions.count==2,"Closed Working Tree activated")

        let revert=RevertWindowController(repository:c.repository,access:nil,preferences:c.prefs);c.owners.append(revert);revert.showWindow(nil);revert.model.setScope(["."])
        try await wait("Revert not ready"){revert.model.canInteract && revert.model.entries.count>=3}
        var revertActions:[(String,[String],Bool)]=[]
        revert.model.onAction={_,paths in revertActions.append(("edit",paths,ComparisonToolInvocation.capture))};revert.model.onCompare={paths in revertActions.append(("diff",paths,ComparisonToolInvocation.capture))}
        try await select(revert,paths:[c.conflict,c.normal]){revert.model.highlighted==GitPathSet([c.conflict,c.normal])}
        let revertSelection=revert.model.highlighted
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await click(revert,path:c.conflict,shift:true);try await click(revert,path:c.normal)
        try require(revertActions.count==2 && revertActions[0].0=="edit" && revertActions[0].1==[c.conflict] && revertActions[0].2 && revertActions[1].0=="diff" && revertActions[1].1==[c.normal] && revert.model.highlighted==revertSelection,"Revert primary action used selected-set or lost captured intent")
        try await click(revert,path:c.normal,column:0);try require(revertActions.count==2,"Revert checkbox launched viewer")
        try await checkbox(revert,path:c.normal){revert.model.checked.contains(c.normal)}
        try require(revertActions.count==2,"Native Revert checkbox action launched viewer")
        try await c.preserved()
        revert.close()

        let resolve=ResolveWindowController(repository:c.repository,access:nil,paths:[c.conflict,c.other],preferences:c.prefs);c.owners.append(resolve);resolve.showWindow(nil)
        try await wait("Resolve not ready"){resolve.model.canInteract && resolve.model.entries.count==2}
        var resolveActions:[(String,Bool)]=[];resolve.model.onEdit={path in resolveActions.append((path,ComparisonToolInvocation.capture))}
        try await select(resolve,paths:[c.conflict,c.other]){resolve.model.selection==GitPathSet([c.conflict,c.other])}
        let resolveSelection=resolve.model.selection
        c.index=try Data(contentsOf:c.root.appendingPathComponent(".git/index"))
        try await click(resolve,path:c.other,shift:true)
        try require(resolveActions.count==1 && resolveActions[0].0==c.other && resolveActions[0].1 && resolve.model.selection==resolveSelection,"Resolve multi-selection did not edit only clicked conflict")
        try await click(resolve,path:c.conflict,column:0);try require(resolveActions.count==1,"Resolve checkbox launched editor")
        try await checkbox(resolve,path:c.conflict){resolve.model.checked.contains(c.conflict)}
        try require(resolveActions.count==1,"Native Resolve checkbox action launched editor")
        let oldResolve=StatusListPrimaryActionReceipt(path:c.conflict,revision:resolve.model.primaryActionRevision,alternate:false)
        resolve.close();resolve.model.activatePrimaryFile(oldResolve);try require(resolveActions.count==1,"Closed Resolve activated old row")
        try await wait("Source owners did not drain"){drained()}
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let order=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,quiet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietStatusPrimaryOrder(_:relativeTo:)))!
        let sheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,quietSheet=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietStatusPrimarySheet(_:completionHandler:)))!
        method_exchangeImplementations(order,quiet);method_exchangeImplementations(sheet,quietSheet)
        defer{method_exchangeImplementations(sheet,quietSheet);method_exchangeImplementations(order,quiet)}
        let c=try Context()
        do {try await c.setup();try await verify(c);await c.clean()}catch{await c.clean();throw error}
        try require(drained() && c.owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Primary activation left owned windows/workers")
        print("PASS: Source status primary activation, actual native row events, multi-selection conflict intent, Shift capture, checkbox native-action roundtrip, group exclusion, stale/sorted/closed ownership and drain")
    }
}
