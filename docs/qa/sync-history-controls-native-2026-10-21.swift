// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncHistoryControlsVerification {
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
        throw Failure(description:"Sync history controls timeout at \(line)")
    }
    @MainActor static func own(_ controller:NSWindowController){owners.append(controller);if let window=controller.window{window.alphaValue=0;window.setFrameOrigin(.init(x:-24000,y:-24000));window.orderFront(nil)}}
    static func hash(_ repo:GitRepository,_ name:String="HEAD")async throws->String {String(decoding:try await repo.run(["rev-parse","--verify",name]).stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)}
    static func fixture(_ root:URL,_ git:URL,svn:Bool)async throws->(GitRepository,String,String) {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","History Controls QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("root\n".utf8).write(to:root.appendingPathComponent("root.txt"));try await repo.stage(["root.txt"])
        _ = try await repo.commit(message:"Root\n\ngit-svn-id: https://example.invalid/repo/trunk@314 12345678-1234-1234-1234-123456789abc")
        let first=try await hash(repo)
        _ = try await repo.run(["branch","side"])
        try Data("main\n".utf8).write(to:root.appendingPathComponent("main.txt"));try await repo.stage(["main.txt"]);_ = try await repo.commit(message:"Main parent")
        _ = try await repo.run(["switch","side"])
        try Data("side\n".utf8).write(to:root.appendingPathComponent("side.txt"));try await repo.stage(["side.txt"]);_ = try await repo.commit(message:"Side parent")
        _ = try await repo.run(["switch","main"]);_ = try await repo.run(["merge","--no-ff","side","-m","Merge parent choices"])
        try Data("latest\n".utf8).write(to:root.appendingPathComponent("latest.txt"));try await repo.stage(["latest.txt"]);_ = try await repo.commit(message:"Latest\tmessage\u{2028}single-line\n\ngit-svn-id: https://example.invalid/repo/trunk@315 12345678-1234-1234-1234-123456789abc")
        _ = try await repo.run(["checkout","--orphan","baseline"]);_ = try await repo.run(["rm","-rf","--","."])
        try Data("unrelated\n".utf8).write(to:root.appendingPathComponent("baseline.txt"));try await repo.stage(["baseline.txt"]);_ = try await repo.commit(message:"Remote baseline")
        let baseline=try await hash(repo)
        _ = try await repo.run(["switch","main"])
        let remote=root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-origin.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path]);_ = try await repo.run(["remote","add","origin",remote.path]);_ = try await repo.run(["fetch","origin"])
        _ = try await repo.run(["config","branch.main.remote","origin"]);_ = try await repo.run(["config","branch.main.merge","refs/heads/baseline"])
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/svn"),withIntermediateDirectories:true)
        if svn {try Data().write(to:root.appendingPathComponent(".git/svn/.metadata"))}
        return(repo,first,baseline)
    }
    @MainActor static func prepared(_ repo:GitRepository,_ baseline:String,_ prefs:UserDefaults)async throws->SynchronizationWindowController {
        let owner=SynchronizationWindowController(repository:repo,access:nil,preferences:prefs);own(owner);owner.model.sshSettings.enabled=false;owner.model.historyRegexExecutable=try regex();owner.model.reload(initial:true)
        try await wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && owner.model.outgoing != nil}
        owner.model.force=true;owner.model.reload()
        try await wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && (owner.model.outgoing?.commits.count ?? 0)>=5}
        owner.model.finishPatchImport(oldHead:try await hash(repo,"HEAD~2"))
        try await wait(owner.window){!owner.model.busy && !owner.model.hasPendingInlineWork && (owner.model.incomingCommits?.count ?? 0)>=3}
        return owner
    }
    @MainActor static func nativeTable(_ owner:SynchronizationWindowController,_ incoming:Bool)async throws->(HistoryTableView,SynchronizationHistoryTable.Coordinator) {
        owner.model.tab=incoming ? 4:0
        let source=incoming ? 4:0
        try await wait(owner.window){views(owner.window?.contentView).compactMap{$0 as? HistoryTableView}.contains{($0.dataSource as? SynchronizationHistoryTable.Coordinator)?.sourceTab==source}}
        let native=try unwrap(views(owner.window?.contentView).compactMap{$0 as? HistoryTableView}.first{($0.dataSource as? SynchronizationHistoryTable.Coordinator)?.sourceTab==source},"Native history table missing")
        return(native,try unwrap(native.dataSource as? SynchronizationHistoryTable.Coordinator,"Native history data source missing"))
    }
    static func regex()throws->URL {
        let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try IssueRegexRuntime.executable(bundle:try unwrap(Bundle(url:project.appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app")),"Packaged regex bundle missing"))
    }
    @MainActor static func find(_ menu:NSMenu,_ title:String)->NSMenuItem? {
        for item in menu.items {if item.title==title{return item};if let sub=item.submenu,let result=find(sub,title){return result}};return nil
    }
    @MainActor static func invoke(_ menu:NSMenu,_ title:String)throws {
        let item=try unwrap(find(menu,title),"Native history command missing: "+title)
        try require(item.isEnabled,"Native history command disabled: "+title)
        let selector=try unwrap(item.action,"Native history selector missing: "+title)
        _ = NSApp.sendAction(selector,to:item.target,from:item)
    }
    @MainActor static func rowMenu(_ native:HistoryTableView,_ coordinator:SynchronizationHistoryTable.Coordinator,_ rows:IndexSet)throws->NSMenu {
        native.selectRowIndexes(rows,byExtendingSelection:false)
        let menu=try unwrap(native.menu,"Native history menu missing")
        coordinator.menuNeedsUpdate(menu);return menu
    }
    @MainActor static func answer(_ owner:SynchronizationWindowController,_ title:String)async throws {
        try await wait(owner.window){views(owner.window?.attachedSheet?.contentView).compactMap{$0 as? NSButton}.contains{$0.title==title}}
        let sheet=try unwrap(owner.window?.attachedSheet,"Owned history question missing")
        let button=try unwrap(views(sheet.contentView).compactMap{$0 as? NSButton}.first{$0.title==title},"Owned history response missing")
        button.performClick(nil);try await wait{sheet.sheetParent==nil}
    }
    @MainActor static func key(_ window:NSWindow,_ flags:NSEvent.ModifierFlags=[])throws->NSEvent {
        try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"History Return event")
    }
    @MainActor static func controls(_ repo:GitRepository,_ first:String,_ baseline:String,_ prefs:UserDefaults)async throws {
        prefs.set(true,forKey:"LogFontForLogCtrl");prefs.set("Menlo",forKey:"LogFontName");prefs.set(24,forKey:"LogFontSize");prefs.set(true,forKey:"DiffByDoubleClickInLog")
        let runtime=try regex(),store=try RepositoryAccessStore(storageURL:repo.root.deletingLastPathComponent().appendingPathComponent("history-access.json"))
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:repo.executable)},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
        workspace.fileComparisonPreferences=prefs
        let host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
        defer{workspace.stopMonitoringForTermination();host.close()}
        var syncs:[SynchronizationWindowController]=[],comparisons:[RevisionComparisonWindowController]=[]
        workspace.synchronizationWindowPresentation={child in own(child);syncs.append(child);child.model.historyRegexExecutable=runtime;child.model.reload(initial:true)}
        workspace.revisionComparisonWindowPresentation={own($0);comparisons.append($0)}
        workspace.open(repo.root);try await wait(host){!workspace.busy && workspace.root?.path==repo.root.path}
        workspace.showSynchronization();try await wait{syncs.count==1 && !syncs[0].model.busy && !syncs[0].model.hasPendingInlineWork && syncs[0].model.outgoing != nil}
        let owner=syncs[0],model=owner.model
        model.force=true;model.reload();try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && (model.outgoing?.commits.count ?? 0)>=5}
        model.finishPatchImport(oldHead:try await hash(repo,"HEAD~2"));try await wait(owner.window){!model.busy && !model.hasPendingInlineWork && (model.incomingCommits?.count ?? 0)>=3}
        let sourceEntries=try unwrap(model.outgoing?.commits,"Actual outgoing SVN source entries missing")
        let sourceMessages=sourceEntries.map{$0.historySubject+"\n"+$0.historyBody}
        let sourceSVN=try await Task.detached {try IssueRegexRuntime.svnRevisions(sourceMessages,executable:runtime)}.value
        let expectedSVN=Dictionary(uniqueKeysWithValues:zip(sourceEntries.map(\.hash),sourceSVN))
        // Preserve FindSVNRev's whole-message anchors and GetSubjectBody's
        // subject + newline + body composition: an ordinary commit trailer
        // deliberately yields no revision, unlike a directly anchored message.
        let anchored=try await Task.detached {try IssueRegexRuntime.svnRevisions([
            "git-svn-id: https://example.invalid/repo/trunk@314 12345678-1234-1234-1234-123456789abc",
            "git-svn-id: https://example.invalid/repo/trunk@315 12345678-1234-1234-1234-123456789abc"
        ],executable:runtime)}.value
        try require(anchored==["314","315"],"Actual pinned SVN parser lost anchored positive cases")
        try require(model.hasGitSVN && expectedSVN[first]=="" && model.historySVNRevisions[first]==expectedSVN[first],"Pinned SVN marker/parser differed from source-composed root message")
        let replacementSuite="TurtleGit.HistoryReplacement."+UUID().uuidString,replacement=UserDefaults(suiteName:replacementSuite)!
        defer{replacement.removePersistentDomain(forName:replacementSuite)}
        workspace.fileComparisonPreferences=replacement
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};model.historyPasteboard=board
        let head=try await hash(repo),parent=try await hash(repo,"HEAD^")
        for incoming in [false,true] {
            let (native,coordinator)=try await nativeTable(owner,incoming)
            try require(coordinator.sourceTab==(incoming ? 4:0),"History coordinator changed captured source tab")
            let header=coordinator.headerMenu()
            try require(find(header,"Graph")==nil && find(header,"SVN Rev") != nil,"Source header Graph/SVN conditional policy changed")
            let svn=try unwrap(native.tableColumn(withIdentifier:.init("svn")),"Native SVN column missing")
            try require(svn.title=="SVN Rev" && !svn.isHidden,"SVN metadata column not visible")
            let latest=try unwrap(model.historyEntries.firstIndex{$0.hash==head},"Actual latest history row missing")
            native.scrollRowToVisible(latest);native.layoutSubtreeIfNeeded()
            let svnCell=try unwrap(native.view(atColumn:native.column(withIdentifier:.init("svn")),row:latest,makeIfNecessary:true) as? NSTableCellView,"Actual SVN cell missing")
            try require(expectedSVN[head]=="" && model.historySVNRevisions[head]==expectedSVN[head] && svnCell.textField?.stringValue==expectedSVN[head],"Native SVN cell did not preserve pinned whole-message parser result")
            let message=try unwrap(native.view(atColumn:native.column(withIdentifier:.init("message")),row:latest,makeIfNecessary:true) as? NSTableCellView,"Actual history message cell missing")
            let text=try unwrap(message.textField,"Native history message missing"),font=try unwrap(message.textField?.font,"Native history font missing")
            message.layoutSubtreeIfNeeded()
            try require(abs(font.pointSize-24)<0.5 && native.rowHeight>=ceil(font.ascender-font.descender+font.leading)+5,"Large source Log font clipped by fixed row height")
            try require(text.frame.height<=native.rowHeight+0.5 && text.fittingSize.height<=native.rowHeight+0.5 && text.toolTip?.contains("\u{2028}")==true,"History message wrapped/clipped or lost raw tooltip")
            let copy=try rowMenu(native,coordinator,IndexSet(integer:latest))
            try require(find(copy,"Copy to clipboard")?.image != nil && find(copy,"Compare with working tree")?.image != nil,"Source history menu/icon mask missing")
            try invoke(copy,"Hashes");try require(board.string(forType:.string)==head,"Native history Hash clipboard changed revision")
            native.selectRowIndexes(IndexSet(integer:latest),byExtendingSelection:false);try require(owner.window?.makeFirstResponder(native)==true,"History list did not take native responder focus")
            let before=comparisons.count
            try require(native.performKeyEquivalent(with:key(try unwrap(owner.window,"History compare owner"),.shift)),"Actual Shift Return was not handled")
            try await wait(owner.window){comparisons.count==before+1 && !comparisons.last!.model.busy && comparisons.last!.model.snapshot != nil}
            let child=try unwrap(comparisons.last,"Configured history comparison missing")
            try require(child.model.from==parent && child.model.to==head && child.model.alternateTool==true && child.model.preferences===prefs && child.window?.alphaValue==0,"Actual history comparison lost parent/selected/Shift/captured preferences/hidden ownership")
            // Incoming excludes one merge parent: lazy caption reads must not
            // invalidate the visible menu's otherwise current action receipt.
            if incoming {
                let merge=try unwrap(model.historyEntries.firstIndex{$0.parents.count>1},"Actual merge row missing")
                let entry=model.historyEntries[merge],menu=try rowMenu(native,coordinator,IndexSet(integer:merge))
                let submenu=try unwrap(find(menu,"Compare with previous revision")?.submenu,"Merge parent choices missing")
                await model.loadHistoryParentSubjects(entry)
                try await wait(owner.window){model.historyParentSubjects[entry.parents[0]] != nil}
                let item=try unwrap(submenu.items.first,"Parent comparison item missing")
                let count=comparisons.count
                _ = NSApp.sendAction(try unwrap(item.action,"Parent selector missing"),to:item.target,from:item)
                try await wait{comparisons.count==count+1 && !comparisons.last!.model.busy}
                try require(comparisons.last!.model.from==entry.parents[0] && comparisons.last!.model.to==entry.hash,"Lazy caption publication retired actionable parent menu")
            }
            // Source reset asks before changing this list's private layout.
            try invoke(coordinator.headerMenu(),"SHA-1")
            let messageColumn=try unwrap(native.tableColumn(withIdentifier:.init("message")),"Native message column missing")
            messageColumn.width=373;coordinator.tableViewColumnDidResize(Notification(name:NSTableView.columnDidResizeNotification,object:native))
            let author=try unwrap(native.tableColumns.firstIndex{$0.identifier.rawValue=="author"},"Author column missing")
            native.moveColumn(author,toColumn:1)
            let order=native.tableColumns.map{$0.identifier.rawValue}
            try invoke(coordinator.headerMenu(),"Reset columns");try await answer(owner,"No");try await wait{!coordinator.hasPendingQuestion}
            try require(native.tableColumns.map{$0.identifier.rawValue}==order && !native.tableColumn(withIdentifier:.init("hash"))!.isHidden,"Reset No replaced captured column layout")
            try invoke(coordinator.headerMenu(),"Reset columns");try await answer(owner,"Yes");try await wait{!coordinator.hasPendingQuestion}
            try require(native.tableColumns.first?.identifier.rawValue=="graph" && native.tableColumn(withIdentifier:.init("hash"))!.isHidden && abs(messageColumn.width-373)>1,"Reset Yes did not restore source list defaults")
            let longestMessage=model.historyEntries.map{(SynchronizationResultPresentation.singleLine($0.logLine(fullMessage:false)) as NSString).size(withAttributes:[.font:font]).width}.max() ?? 0
            try require(messageColumn.width>=ceil(longestMessage)+13,"Reset message width did not measure actual source row text")
            let dateColumn=try unwrap(native.tableColumn(withIdentifier:.init("date")),"Date column missing after reset")
            let dateWidth=model.historyEntries.indices.compactMap{index in (coordinator.tableView(native,viewFor:dateColumn,row:index) as? NSTableCellView)?.textField?.attributedStringValue.size().width}.max() ?? 0
            try require(dateColumn.width>=ceil(dateWidth)+13,"Reset date width did not measure actual formatted row text")
            messageColumn.width=incoming ? 421:411;coordinator.tableViewColumnDidResize(Notification(name:NSTableView.columnDidResizeNotification,object:native))
            try require((prefs.dictionary(forKey:coordinator.layoutKey)?["widths"] as? [String:Double])?["message"]==(incoming ? 421:411),"Private scoped column width did not persist")
            if !incoming {
                let root=try unwrap(model.historyEntries.firstIndex{$0.hash==first},"Root history row missing")
                native.selectRowIndexes(IndexSet(integer:root),byExtendingSelection:false);_ = owner.window?.makeFirstResponder(native)
                let count=comparisons.count
                _ = native.performKeyEquivalent(with:try key(try unwrap(owner.window,"Root history owner")))
                try await wait(owner.window){coordinator.hasPendingQuestion}
                try await answer(owner,"OK");try await wait{!coordinator.hasPendingQuestion}
                try require(comparisons.count==count,"Root warning opened an invented previous revision")
            }
            try await capture(try unwrap(owner.window,"History capture owner"),incoming ? "sync-incoming-commits":"sync-outgoing-commits")
        }
        let reopened=try await prepared(repo,baseline,prefs)
        for incoming in [false,true] {
            let (native,_)=try await nativeTable(reopened,incoming)
            try require(abs(native.tableColumn(withIdentifier:.init("message"))!.width-(incoming ? 421:411))<1,"Scoped native column width failed actual reopen")
        }
    }
    @MainActor static func ownership(_ repo:GitRepository,_ first:String,_ baseline:String,_ prefs:UserDefaults)async throws {
        prefs.set(true,forKey:"DiffByDoubleClickInLog")
        let owner=try await prepared(repo,baseline,prefs),model=owner.model
        var (native,coordinator)=try await nativeTable(owner,false)
        try require(!model.hasGitSVN && native.tableColumn(withIdentifier:.init("svn"))?.isHidden==true && find(coordinator.headerMenu(),"SVN Rev")==nil,"Bare svn directory without .metadata exposed SVN column")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};model.historyPasteboard=board
        let head=try await hash(repo)
        let latest=try unwrap(model.historyEntries.firstIndex{$0.hash==head},"Owned latest history row missing")
        let root=try unwrap(model.historyEntries.firstIndex{$0.hash==first},"Owned root history row missing")
        func captureCopy()throws->(NSMenuItem,AnyObject?) {
            let menu=try rowMenu(native,coordinator,IndexSet(integer:latest)),item=try unwrap(find(menu,"Hashes"),"Captured Hash clipboard action missing")
            return(item,item.target as AnyObject?)
        }
        func refused(_ receipt:(NSMenuItem,AnyObject?),_ message:String)throws {
            board.clearContents();board.setString("private unchanged",forType:.string)
            _ = NSApp.sendAction(try unwrap(receipt.0.action,"Retained history action missing"),to:receipt.1,from:receipt.0)
            try require(board.string(forType:.string)=="private unchanged",message)
        }
        let selection=try captureCopy()
        native.selectRowIndexes(IndexSet(integer:root),byExtendingSelection:false);native.selectRowIndexes(IndexSet(integer:latest),byExtendingSelection:false)
        try refused(selection,"History selection away/back resurrected retained menu")
        let oldHeader=coordinator.headerMenu(),headerItem=try unwrap(find(oldHeader,"SHA-1"),"Captured header Hash missing"),headerTarget=headerItem.target
        let tab=try captureCopy()
        _ = try await nativeTable(owner,true)
        (native,coordinator)=try await nativeTable(owner,false)
        try refused(tab,"Dismantled source-tab row changed clipboard")
        _ = NSApp.sendAction(try unwrap(headerItem.action,"Retained header selector"),to:headerTarget,from:headerItem)
        try require(prefs.object(forKey:SynchronizationHistoryColumns.key(incoming:false,id:"hash"))==nil && prefs.object(forKey:SynchronizationHistoryColumns.key(incoming:true,id:"hash"))==nil,"Retired header callback wrote a different pane's preferences")
        let busy=try captureCopy();model.reload();try require(model.busy,"History busy regression did not start actual read")
        try refused(busy,"Actual history read admitted stale clipboard")
        try await wait(owner.window){!model.busy && !model.hasPendingInlineWork}
        (native,coordinator)=try await nativeTable(owner,false)
        let quit=try captureCopy();model.confirmingQuit=true;try refused(quit,"Quit-owned history menu accepted")
        model.confirmingQuit=false
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:180,height:90),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        let behindSheet=try captureCopy()
        owner.window?.beginSheet(sheet,completionHandler:nil);try refused(behindSheet,"Owned sheet admitted background history clipboard")
        owner.window?.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait{sheet.sheetParent==nil}
        let close=try captureCopy()
        native.selectRowIndexes(IndexSet(integer:root),byExtendingSelection:false);_ = owner.window?.makeFirstResponder(native)
        _ = native.performKeyEquivalent(with:try key(try unwrap(owner.window,"Root warning owner")))
        try await wait(owner.window){coordinator.hasPendingQuestion && owner.window?.attachedSheet != nil}
        let warning=owner.window?.attachedSheet
        try require(model.hasPendingInlineWork,"Owned root warning did not participate in Quit accounting")
        owner.window?.close()
        try refused(close,"Closed history owner retained executable clipboard")
        try await wait{!coordinator.hasPendingQuestion && !model.hasPendingInlineWork && warning?.sheetParent==nil}
        try require(coordinator.retired && native.onReturn==nil && native.menu==nil,"History dismantle retained keyboard/menu callbacks")
        // A reset callback arriving after forced close cannot write any layout.
        let resetOwner=try await prepared(repo,baseline,prefs)
        let (_,resetCoordinator)=try await nativeTable(resetOwner,false)
        var reply:((NSApplication.ModalResponse)->Void)?
        resetCoordinator.presentQuestion={_,alert,completion in alert.window.alphaValue=0;reply=completion}
        try invoke(resetCoordinator.headerMenu(),"Reset columns")
        try await wait{reply != nil && resetCoordinator.hasPendingQuestion}
        resetOwner.window?.close()
        let afterClose=prefs.dictionary(forKey:resetCoordinator.layoutKey) as NSDictionary?
        reply?(.alertFirstButtonReturn);reply=nil
        try await wait{!resetCoordinator.hasPendingQuestion && !resetOwner.model.hasPendingInlineWork}
        try require((prefs.dictionary(forKey:resetCoordinator.layoutKey) as NSDictionary?)==afterClose,"Late reset answer rewrote retired pane layout")
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_HISTORY_CAPTURES"] else{return}
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
        for _ in 0..<1600 {
            if SynchronizationWindowModel.activeInlineOperations==0 && SynchronizationWindowModel.activePushWorkflows==0 && SynchronizationWindowController.activeInlineReleases==0 && RevisionComparisonWindowModel.activeFileOperations==0 && owners.compactMap{$0 as? SynchronizationWindowController}.allSatisfy({!$0.model.hasPendingInlineWork}) && owners.compactMap{$0 as? RevisionComparisonWindowController}.allSatisfy({!$0.model.hasOwnedPreparation}) {return true}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        return false
    }
    @MainActor static func main()async {
        NSApp.setActivationPolicy(.prohibited);var failure:Error?
        do {
            let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
            for name in CommandLine.arguments.dropFirst(3) {
                let (repo,first,baseline)=try await fixture(base.appendingPathComponent(name),git,svn:name=="controls")
                let suite="TurtleGit.SyncHistoryControls."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
                defer{prefs.removePersistentDomain(forName:suite)}
                prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TGitAutoLoadSSHKey")
                switch name {case "controls":try await controls(repo,first,baseline,prefs);case "ownership":try await ownership(repo,first,baseline,prefs);default:throw Failure(description:"Unknown Sync history case")}
                print("PASS Sync history case: "+name)
            }
        } catch{failure=error}
        if !(await cleanup()),failure==nil{failure=Failure(description:"Owned Sync history workers did not drain")}
        if let failure{fputs("Sync history controls failed: \(failure)\n",stderr);exit(1)}
        print("PASS Sync history controls: "+CommandLine.arguments.dropFirst(3).joined(separator:", ")+"; all owned windows/workers closed")
    }
}
