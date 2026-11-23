// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Real private porcelain states mounted in the production native Log report.
/// Root comparison presentation is injected; Git preparation/owner admission is real.
@MainActor enum LogWorkingRowAffordanceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Log working rows \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ label:String,window:NSWindow?=nil,_ ready:()->Bool)async throws {
        for _ in 0..<3500 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log working rows timeout: "+label)
    }
    @MainActor final class Gate {
        var reply:CheckedContinuation<Bool,Never>?
        func read()async->Bool {await withCheckedContinuation{reply=$0}}
        func finish(_ value:Bool){let held=reply;reply=nil;held?.resume(returning:value)}
    }
    static func verify(base:URL,git:URL)async throws {
        let base=base.standardizedFileURL,root=base.appendingPathComponent("repository"),suite="TurtleGit.LogWorkingRows."+UUID().uuidString
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let preferences=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        for key in ["UseLibgit2","EnableLogCache","EnableGravatar"] {preferences.set(false,forKey:key)}
        preferences.set(true,forKey:"LogIncludeWorkingTreeChanges");preferences.set(3,forKey:"NumDiffWarning")
        try MergeToolPreferences.load(from:preferences).save(to:preferences)
        let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
        let missing="a-missing 雪.txt",removed="b-removed.txt",retained="c-retained.txt",modified="d-modified.txt",added="e-added-missing.txt",renameSource="f-before.txt",renamed="f-renamed-missing.txt",unknown="g-untracked.txt",historicalDeleted="z-historical-deleted.txt"
        _=try await repository.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Log working QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repository.run(["config",key,value])}
        for path in [missing,removed,retained,modified,renameSource,historicalDeleted] {try Data((path+"\nbase\n").utf8).write(to:root.appendingPathComponent(path))}
        try await repository.stage(["."]);_=try await repository.commit(message:"Base")
        _=try await repository.run(["rm","--",historicalDeleted]);_=try await repository.commit(message:"Historical deletion")
        let head=try await repository.rebaseCommit("HEAD").hash
        try FileManager.default.removeItem(at:root.appendingPathComponent(missing))
        _=try await repository.run(["rm","--",removed]);_=try await repository.run(["rm","--cached","--",retained])
        try Data("added then missing\n".utf8).write(to:root.appendingPathComponent(added));try await repository.stage([added]);try FileManager.default.removeItem(at:root.appendingPathComponent(added))
        _=try await repository.run(["mv","--",renameSource,renamed]);try FileManager.default.removeItem(at:root.appendingPathComponent(renamed))
        try Data("modified working content\n".utf8).write(to:root.appendingPathComponent(modified));try Data("untracked working content\n".utf8).write(to:root.appendingPathComponent(unknown))
        let baselineIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),baselineHead=try await repository.run(["rev-parse","HEAD"]).stdout
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,snapshotStore:FinderSnapshotStore(url:base.appendingPathComponent("finder.json")),savedAccessStore:try RepositoryAccessStore(storageURL:base.appendingPathComponent("access.json")),comparisonMarks:WorkingComparisonMarkStore(storageURL:base.appendingPathComponent("marks.json")),cachePersistenceDefaults:preferences)
        var owner:LogWindowController?,plans:[LogFilePrimaryActivation]=[],delivered:[(ComparisonRevision,ComparisonRevision,String)]=[],warnings:[Int]=[],saved:[String]=[],exported:[[String]]=[],opened:[URL]=[],baseRequests:[[String]]=[],gate:Gate?
        workspace.fileComparisonPreferences=preferences
        workspace.logWindowPresentation={controller in owner=controller;controller.window?.alphaValue=0;controller.window?.setFrameOrigin(.init(x:-24000,y:-24000));controller.showWindow(nil);(controller.window as? LogHistoryWindow)?.commandKeyWindow={[weak controller]in controller?.window}}
        workspace.fileComparisonPresentation={snapshot,file in delivered.append((snapshot.from,snapshot.to,file.path))}
        @MainActor func cleanup()async throws {
            gate?.finish(false);workspace.cancelConflictEditorPreparations();owner?.model.cancelFileNavigationRead();owner?.close();workspace.stopMonitoringForTermination()
            try await wait("owned Log/Root drain"){LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeHistoryProjectionWorkers==0 && LogWindowModel.activeActionReads==0 && LogWindowModel.activeFileNavigationActivities==0 && LogWindowModel.activeFileOpenReads==0 && FileListComparisonSession.activeOperations==0 && owner?.window?.isVisible != true && owner?.window?.attachedSheet==nil}
            owner=nil;clipboard.clearContents();preferences.removePersistentDomain(forName:suite)
        }
        do {
            workspace.showLog(repository:repository,access:RepositoryAccessLease(url:root),paths:[],preferences:preferences)
            try await wait("Root working history"){owner != nil && owner?.model.busy==false && owner?.model.workingTreeSnapshot != nil}
            let controller=try unwrap(owner,"Root Log missing"),model=controller.model,window=try unwrap(controller.window,"Native Log window missing")
            model.clipboard=clipboard;model.select([""])
            let paths=GitPathSet([missing,removed,retained,modified,added,renamed,unknown])
            try await wait("accepted working metadata",window:window){!model.busy && paths.isSubset(of:GitPathSet(model.visibleFiles.map(\.path))) && views(window.contentView).contains{$0 is LogChangedFileNativeTable}}
            let table=try unwrap(views(window.contentView).compactMap{$0 as? LogChangedFileNativeTable}.first,"Native report missing")
            let accepted=Dictionary(uniqueKeysWithValues:model.workingIndexFiles.map{($0.id,$0.entry)})
            try require(accepted[added]?.index=="A" && accepted[added]?.worktree=="D" && accepted[renamed]?.index=="R" && accepted[renamed]?.worktree=="D","Private Git fixture did not produce real AD/RD missing states")
            try require(accepted[retained]?.index=="D" && accepted[retained]?.hasUnversionedCopy==true,"Private Git fixture lost retained-copy metadata")
            let launch=try unwrap(model.onPrimaryFileActivation,"Root primary dispatcher missing")
            model.onPrimaryFileActivation={plan,token in plans.append(plan);try await launch(plan,token)}
            model.confirmPrimaryFileActivation={count in warnings.append(count);if let gate{return await gate.read()};return true}
            model.presentWorkingSave={saved.append($0)};model.presentWorkingExport={exported.append($0)};model.presentWorkingOpen={url,_ in opened.append(url)}
            model.onFileCompare={_,_,paths in baseRequests.append(paths)};model.onFileComparisons={baseRequests.append($0.flatMap{$0.2})}
            @MainActor func select(_ selected:GitPathSet)async throws {
                try await wait("settled native rows",window:window){!model.busy && table.numberOfRows==model.fileTableRows.count}
                let rows=model.fileTableRows,indexes=IndexSet(rows.indices.filter{rows[$0].file != nil && selected.contains(rows[$0].rawID)})
                try require(indexes.count==selected.count,"Raw native identity missing")
                table.selectRowIndexes(indexes,byExtendingSelection:false)
                try await wait("native selection",window:window){model.selectedFiles==selected};window.makeFirstResponder(table)
            }
            func row(_ path:String)throws->CommitFile {try unwrap(model.visibleFiles.first{GitReferenceName.equal($0.path,path)},"Row missing: "+path)}
            func menu(_ ids:GitPathSet)->NSMenu {LogChangedFileMenus.make(model:model,ids:ids,column:.status,shift:true)}
            func item(_ menu:NSMenu,_ title:String)->NSMenuItem? {menu.items.first{$0.title==NSLocalizedString(title,comment:"")}}
            func invoke(_ value:NSMenuItem)throws {let action=try unwrap(value.action,"Native menu action missing");try require(NSApp.sendAction(action,to:value.target,from:value),"Native menu dispatch rejected")}
            for (path,caption,compare,readable) in [(missing,"Missing",true,false),(removed,"Deleted",true,false),(retained,"Deleted",false,true),(added,"Added",false,false),(renamed,"Missing",false,false),(modified,"Modified",true,true),(unknown,"Unversioned",false,true)] {
                try await select(GitPathSet([path]));let file=try row(path),nativeMenu=menu(GitPathSet([file.id]))
                try require(model.fileStatus(file)==caption,"Caption lost raw XY: "+path)
                if path==added {try require(model.fileStatusTextRole(file) == .added,"AD row used Deleted color instead of source Added role")}
                if path==renamed || path==missing {try require(model.fileStatusTextRole(file) == .deleted,"Missing row lost combined Deleted/Missing color role")}
                try require(model.canCompareFileWithBase(file)==compare,"Base policy lost raw XY: "+path)
                try require(model.canReadFileContents(file)==readable && model.canReadChangedFile([file.id])==readable && model.canExportChangedFiles([file.id])==readable && model.canRevealChangedFile([file.id])==readable,"Physical metadata gate mismatch: "+path)
                try require((item(nativeMenu,"Compare with base") != nil)==compare && (item(nativeMenu,"Show changes as unified diff") != nil)==compare,"Native comparison visibility mismatch: "+path)
                for title in ["Open","Open With…","Export…","Reveal in Finder","Mark for comparison"] {try require((item(nativeMenu,title)?.isEnabled==true)==readable,"Native physical action mismatch: "+title+" "+path)}
                try require(nativeMenu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil || $0.submenu != nil},"Native row menu lost action icons")
            }
            // Shared copied/renamed/added raw missing policy is also checked
            // directly: Git porcelain does not necessarily discover copies.
            for xy in ["AD","RD","CD"] {let raw=StatusEntry.parse(Data((xy+" copied\0"+(xy=="AD" ? "":"before\0")).utf8));try require(raw.count==1 && !raw[0].canCompareWithBaseFromStatusList,"Shared missing eligibility lost "+xy)}
            try require(StatusEntry.parse(Data(" D plain\0MD modified\0".utf8)).allSatisfy(\.canCompareWithBaseFromStatusList),"Plain D|Missing stopped comparing")
            // One retained identity remains useful with ordinary unversioned
            // rows hidden. Source commands own fresh leaf validation later.
            model.showUnversionedFiles=false;model.updateWorkingFiles()
            try await wait("hidden unversioned report",window:window){!model.visibleFiles.contains{$0.path==unknown} && model.visibleFiles.contains{$0.path==retained} && table.numberOfRows==model.fileTableRows.count}
            try await select(GitPathSet([retained]))
            // Each popup owns one accepted invocation. Save, Export and Open
            // are separate user gestures, not three actions on one receipt.
            try invoke(try unwrap(item(menu(GitPathSet([retained])),"Save As…"),"Retained Save missing"))
            try invoke(try unwrap(item(menu(GitPathSet([retained])),"Export…"),"Retained Export missing"))
            try invoke(try unwrap(item(menu(GitPathSet([retained])),"Open"),"Retained Open missing"))
            try await wait("retained working open"){!model.busy && opened.count==1}
            try require(saved==[retained] && exported==[[retained]] && opened[0].standardizedFileURL==root.appendingPathComponent(retained).standardizedFileURL,"Retained copy read/saved another path")
            model.markForComparison([retained]);try require(model.comparisonMark?.path==retained && model.comparisonMark?.revision=="","Retained working mark lost empty current version")
            // This callback is still unused: only source-selection retirement,
            // rather than an earlier invocation, may reject it below.
            let staleOpen=try unwrap(item(menu(GitPathSet([retained])),"Open"),"Fresh retained Open missing")
            try await select(GitPathSet([missing]));try invoke(staleOpen);try require(opened.count==1,"Stale retained menu read after selection changed")
            model.saveHistoricalFile([missing]);model.openHistoricalFile([missing],action:.open);model.chooseHistoricalExport([missing]);model.markForComparison([missing]);try require(saved==[retained] && exported==[[retained]] && model.comparisonMark?.path==retained,"Missing direct action bypassed metadata guards")
            model.compareFiles([added]);try require(baseRequests.isEmpty,"Suppressed missing base action bypassed handler gate")
            model.showUnversionedFiles=true;model.updateWorkingFiles();try await select(paths)
            model.chooseHistoricalExport(paths)
            try require(GitPathSet(exported.last ?? [])==GitPathSet([retained,modified,unknown]),"Mixed Export included a missing disk leaf")
            let order=model.fileTableRows.compactMap(\.file).filter{paths.contains($0.id)},expected=order.filter{!GitPathSet([added,renamed]).contains($0.path)}.map(\.path)
            let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
            ComparisonToolInvocation.$alternate.withValue(true){table.keyDown(with:event)}
            try await wait("mixed primary drain"){!model.busy && !model.fileNavigationReadPending && plans.count==1 && FileListComparisonSession.activeOperations==0}
            let plan=try unwrap(plans.first,"Mixed owned plan missing")
            try require(warnings==[order.count] && plan.selectedCount==order.count && plan.actions.map{$0.file.path}==expected,"Missing skip changed order/count or repeated warning")
            try require(plan.repository.root==root && plan.preferences===preferences && plan.alternateTool,"Mixed activation lost captured producer intent")
            for action in plan.actions {if case .workingFile(let file,let currentVersion)=action {try require([retained,unknown].contains(file.path) && currentVersion == .workingTree,"Working preview substituted HEAD")}}
            try require(GitPathSet(delivered.map{$0.2})==GitPathSet(expected) && delivered.count==expected.count && model.error==nil,"Root skipped a valid leaf or tried a missing added/renamed leaf")
            for item in delivered where [retained,unknown].contains(item.2) {try require(item.0 == .workingTree && item.1 == .workingTree,"Actual Root preview changed currentVersion to HEAD")}
            // Existing owned-warning retirement remains intact when the source
            // selection is replaced while its injected question is pending.
            gate=Gate();let previousPlans=plans.count;try await select(paths);table.keyDown(with:event)
            try await wait("held mixed warning"){gate?.reply != nil}
            model.selectedFiles=GitPathSet([modified]);gate?.finish(true);gate=nil
            try await wait("retired warning drain"){!model.busy && !model.fileNavigationReadPending && FileListComparisonSession.activeOperations==0}
            try require(plans.count==previousPlans,"Selection-retired primary request was dispatched")
            // Historical D retains revision comparison while physical/historical
            // leaf readers remain unavailable, independently of working XY.
            model.select([head]);try await wait("historical deleted row",window:window){!model.busy && model.visibleFiles.contains{$0.path==historicalDeleted}}
            let historical=try row(historicalDeleted);try require(historical.action.hasPrefix("D") && model.canCompareFileWithBase(historical) && !model.canReadFileContents(historical),"Historical D policy was retargeted by working metadata")
            try await select(GitPathSet([historical.id]));try require(item(menu(GitPathSet([historical.id])),"Compare with base")?.isEnabled==true,"Historical D lost native base comparison")
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==baselineHead && Data(contentsOf:root.appendingPathComponent(".git/index"))==baselineIndex,"Read affordances mutated HEAD/index")
            print("PASS: Log working-row raw XY captions; Missing/add/rename/copy comparison guards; retained copy reads/mark; native ordered mixed Return with one warning and captured current-version preview; owned stale-menu/question rejection; historical D preserved. Private/hidden adapters only; no physical Finder, external application, signed access or separate-row directory parity claim.")
        } catch {let original=error;do{try await cleanup()}catch{throw Failure(description:String(describing:original)+"; cleanup: "+String(describing:error))};throw original}
        try await cleanup()
    }
}
