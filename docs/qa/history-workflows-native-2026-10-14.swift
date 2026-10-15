import AppKit
import TurtleGitCore

@main struct HistoryWorkflowsVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws { for _ in 0..<2000 { if ready() { return };try await Task.sleep(nanoseconds:10_000_000) };throw Failure(description:"History workflow timeout at line \(line)") }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("History workflow failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","History QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        for name in ["root","a","b","c"] { try Data((name+"\n").utf8).write(to:root.appendingPathComponent(name));try await repo.stage([name]);_ = try await repo.commit(message:"add "+name) }
        let entries=try await repo.history(),head=entries[0].hash,tree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout
        let suite="TurtleGit.HistoryWorkflows."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(16,forKey:"GitOutputLimitinKiB");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(false,forKey:"EnableGravatar")
        defer { prefs.removePersistentDomain(forName:suite) }
        try await menuOwnership(repository:repo,entries:entries,preferences:prefs)
        try await historyMenuCommands(repository:repo,entries:entries,preferences:prefs,git:git)
        let helper=root.appendingPathComponent("stream-git"),marker=root.appendingPathComponent("ready"),release=root.appendingPathComponent("release"),counter=root.appendingPathComponent("counter")
        let script = #"""
        #!/bin/sh
        if [ "$4" = "$TG_HISTORY_MATCH" ] && { [ -z "$TG_HISTORY_MODE" ] || [ "$5" = "$TG_HISTORY_MODE" ]; }; then
          count=0;[ ! -e "$3/counter" ] || count=$(cat "$3/counter");count=$((count+1));printf '%s' "$count" > "$3/counter"
          printf 'Work: 10%%\rWork: 55%%\r\nUnicode '
          printf '\351\233'; /bin/sleep 0.06;printf '\252\n'
          if [ "$count" = "$TG_HISTORY_OCCURRENCE" ]; then
            if [ "$TG_HISTORY_BIG" = 1 ];then row=0;while [ "$row" -lt 32 ];do printf '%1024s\n' X;row=$((row+1));done;fi
            : > "$3/ready"
            while [ ! -e "$3/release" ];do /bin/sleep 0.05;done
          fi
        fi
        exec "$TG_HISTORY_GIT" "$@"
        """#
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        setenv("TG_HISTORY_GIT",git.path,1)
        defer { for key in ["TG_HISTORY_GIT","TG_HISTORY_MATCH","TG_HISTORY_MODE","TG_HISTORY_OCCURRENCE","TG_HISTORY_BIG"] { unsetenv(key) } }
        let wrapped=GitRepository(root:root,executable:helper)
        @MainActor func gate(_ command:String,mode:String="",occurrence:Int=1,big:Bool=false) { for file in [marker,release,counter] { try? FileManager.default.removeItem(at:file) };setenv("TG_HISTORY_MATCH",command,1);setenv("TG_HISTORY_MODE",mode,1);setenv("TG_HISTORY_OCCURRENCE",String(occurrence),1);setenv("TG_HISTORY_BIG",big ? "1":"0",1) }
        @MainActor func live(_ text:String,_ busy:Bool) throws { try require(busy && text.contains("Unicode 雪") && text.contains("Work: 55%") && !text.contains("Work: 10%"),"Live history output damaged");try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"History worker lacks Quit ownership") }
        // Preserve the first successful MERGE_MSG while cancellation stops a later revision.
        gate("revert",occurrence:2)
        let revertController=HistoryRevertWindowController(repository:wrapped,access:nil,entries:Array(entries.prefix(2)),mainline:nil,preferences:prefs),revert=revertController.model
        defer { revertController.close() }
        revert.ask={title,_,_,_ in title == "Revert the selected commit(s)?"};var raw="";revert.onChanged={raw=$0};revert.start()
        try await wait { FileManager.default.fileExists(atPath:marker.path) && revert.output.contains("Unicode 雪") };try live(revert.output,revert.busy)
        let message=try String(contentsOf:root.appendingPathComponent(".git/MERGE_MSG"),encoding:.utf8);try require(message.contains(entries[0].hash),"First Revert message was lost before next command")
        revertController.window?.contentView?.layoutSubtreeIfNeeded();try await wait { descendants(revertController.window!.contentView!).contains {$0 is SubmoduleProgressTextView} }
        let text=descendants(revertController.window!.contentView!).compactMap {$0 as? SubmoduleProgressTextView}.first!;try await wait { text.string == revert.output }
        let clipboard=NSPasteboard.withUniqueName();defer { clipboard.releaseGlobally() };text.clipboard=clipboard;text.copyAllInformation(nil);try require(clipboard.string(forType:.string) == revert.output && text.outputMenu().items.last?.image != nil,"History copy icons/control missing")
        revert.cancel();try await wait { !revert.busy && HistoryRevertWindowModel.activeOperations == 0 }
        try require(revert.cancelled && revert.completed == 2 && raw.contains("Work: 10%") && !FileManager.default.fileExists(atPath:root.appendingPathComponent("c").path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("b").path),"Cancellation lost original callback/partial Revert state")
        let retained=try String(contentsOf:root.appendingPathComponent(".git/MERGE_MSG"),encoding:.utf8);try require(retained.contains(entries[0].hash),"Cancellation discarded successful Revert message");revertController.close();_ = try await repo.run(["reset","--hard","HEAD"])
        // Skip a root failure, process the next revision, and dispatch Commit only once after close.
        gate("disabled");let skip=HistoryRevertWindowModel(repository:repo,access:nil,entries:[entries.last!,entries[0]],mainline:nil,preferences:prefs)
        var questions:[String]=[],events:[String]=[]
        skip.ask={title,_,_,_ in questions.append(title);return true};skip.close={events.append("close")};skip.onCommit={events.append("commit")};skip.start();try await wait {!skip.busy && HistoryRevertWindowModel.activeOperations == 0}
        try require(skip.success && skip.completed == 2 && questions.count == 3 && events == ["close","commit"],"Skip/Commit handoff was not ordered/once-only")
        _ = try await repo.run(["reset","--hard","HEAD"])
        // Successful Combine uses actual native Commit presets and real amendment/replay.
        let combine=HistoryCombineWindowModel(repository:repo,access:nil,entries:Array(entries[1...2]),firstOffset:1,expectedHead:head,preferences:prefs)
        var combinedRaw="",presets=false
        combine.presentCommit={plan in
            let child=CommitWindowController(repository:repo,access:nil,defaults:prefs);defer {child.close()};child.model.loadHistoryCombine(plan,date:.first)
            try? await wait {!child.model.busy}
            presets=child.model.amend && child.model.setAuthorDate && child.model.message == plan.message && child.model.historyCombine?.originalHead == head
            do {_ = try await repo.run(["commit","--amend","-m",plan.message]);return true} catch {return false}
        }
        combine.onChanged={combinedRaw=$0};combine.start();try await wait {!combine.busy && HistoryCombineWindowModel.activeOperations == 0}
        let finalTree=try await repo.run(["rev-parse","HEAD^{tree}"]).stdout,rows=try await repo.history()
        try require(combine.success && presets && finalTree == tree && rows.count == entries.count-1 && !combinedRaw.isEmpty,"Combine Commit/replay lost final tree or presets")
        _ = try await repo.run(["reset","--hard",head])
        // Retired Combine waits for the injected Commit child, then holds rollback ownership.
        gate("reset",mode:"--hard",big:true)
        let retired=HistoryCombineWindowModel(repository:wrapped,access:nil,entries:Array(entries[1...2]),firstOffset:1,expectedHead:head,preferences:prefs)
        var commitReply:((Bool)->Void)?,callbacks=0
        // Replace with a single explicit continuation; no app or public Git operation is launched by a response.
        retired.presentCommit={_ in await withCheckedContinuation { continuation in commitReply={continuation.resume(returning:$0)} } }
        retired.onChanged={_ in callbacks += 1};gate("disabled");retired.start();try await wait {retired.presentingCommit && commitReply != nil};let frozen=retired.output;retired.invalidate()
        try require(HistoryCombineWindowModel.activeOperations > 0,"Retirement dropped pending Commit ownership")
        gate("reset",mode:"--hard",big:true);commitReply?(false)
        try await wait {FileManager.default.fileExists(atPath:marker.path)};try require(HistoryCombineWindowModel.activeOperations > 0 && retired.recovering,"Rollback not owned")
        retired.cancel();try Data().write(to:release);try await wait {HistoryCombineWindowModel.activeOperations == 0 && LocalGitCommandProgress.activeOperations == 0}
        let restoredHead=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),restoredTree=try await repo.run(["write-tree"]).stdout
        try require(callbacks == 0 && retired.output == frozen && restoredHead == head && restoredTree == tree,"Forced Combine retirement failed rollback or published late callback")
        // Both owner types register and cancel a live ancestry read, keeping Quit blocked until drain.
        for ownerType in ["log","sync"] {
            gate("rev-parse",mode:"--verify")
            let token=OperationCancellation(),log=LogWindowModel(repository:wrapped,access:nil,labelDefaults:prefs),sync=SynchronizationWindowModel(repository:wrapped,access:nil,preferences:prefs)
            let task=Task { () -> Bool in do { if ownerType == "log" {try await log.validateCombineSelection(Array(entries.prefix(2)),offset:0,head:head,token:token)} else {try await sync.validateCombineSelection(Array(entries.prefix(2)),offset:0,head:head,token:token)};return true } catch {return false} }
            try await wait {FileManager.default.fileExists(atPath:marker.path)};try require(HistoryCombineSelectionReader.activeReads > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Combine menu read lacks global ownership")
            if ownerType == "log" {log.invalidate()} else {sync.invalidate()};let accepted=await task.value;try require(!accepted && HistoryCombineSelectionReader.activeReads == 0,"Closed history owner accepted late ancestry")
        }
        print("History workflows: Revert live/copy/original results, preserved partial MERGE_MSG, cancellation, Skip and ordered Commit handoff; real Combine amendment/replay/presets and forced pending-child rollback; Log/Sync ancestry ownership and Quit passed. Private fixtures/preferences/clipboard; owned windows closed.")
    }
    @MainActor static func menuOwnership(repository:GitRepository,entries:[LogEntry],preferences:UserDefaults) async throws {
        let model=LogWindowModel(repository:repository,access:nil,labelDefaults:preferences)
        let coordinator=RevisionTable.Coordinator(model:model),menu=NSMenu()
        let clipboard=NSPasteboard(name:NSPasteboard.Name("TurtleGit.HistoryMenu."+UUID().uuidString));model.clipboard=clipboard
        defer { coordinator.menuDidClose(menu);model.invalidate();clipboard.releaseGlobally() }
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repository.root.appendingPathComponent(".git/index")),refs=try await repository.run(["show-ref"]).stdout
        var shown=entries;shown[1].references=[RevisionReference(name:"refs/heads/menu-captured"),RevisionReference(name:"refs/remotes/origin/menu-captured")]
        model.entries=shown;model.graph=CommitGraph.layout(shown);model.selected=[shown[1].hash];model.currentBranch="main";model.bare=try await repository.isBare()
        var callbacks:[String]=[]
        model.onBrowseRepository={ callbacks.append("browse:"+$0) };model.onExportRevision={ callbacks.append("export:"+$0) }
        model.onCheckout={ callbacks.append("checkout:"+$0) };model.onCreateReference={ callbacks.append(($0 ? "tag:":"branch:")+$1) }
        model.onReset={ callbacks.append("reset:"+$0) };model.onShowContainingReferences={ callbacks.append("refs:"+$0) }
        model.onCherryPick={ callbacks.append("pick:"+$0.joined(separator:",")) };model.onFormatPatch={_ in callbacks.append("patch")}
        model.onCompare={_,_ in callbacks.append("compare")};model.onCommit={ callbacks.append("commit") }
        func leaves(_ menu:NSMenu)->[NSMenuItem] { menu.items.flatMap { item in item.submenu.map{leaves($0)} ?? (item.action == nil ? []:[item]) } }
        func item(_ selector:String) throws ->NSMenuItem {
            guard let found=leaves(menu).first(where:{NSStringFromSelector($0.action!)==selector}) else { throw Failure(description:"Missing revision selector: "+selector+"; available: "+leaves(menu).map{NSStringFromSelector($0.action!)}.joined(separator:",")) };return found
        }
        func send(_ item:NSMenuItem) { _=NSApp.sendAction(item.action!,to:item.target,from:item) }
        func open() { coordinator.menuNeedsUpdate(menu) }
        func sentinel() { clipboard.clearContents();clipboard.setString("untouched",forType:.string) }
        let commands=["browseRepository","exportRevision","checkoutReference:","branchReference:","tagReference:","reset","showContainingReferences","cherryPick","formatPatch","compare"]
        for command in commands {
            open();let action=try item(command),before=callbacks.count
            try require(action.isEnabled && (action.target as? NSObject)?.responds(to:action.action!)==true,"Fresh menu action unavailable: "+command)
            coordinator.menuDidClose(menu);send(action)
            try require(callbacks.count==before+1,"Fresh/closed-menu callback failed: "+command)
        }
        open();let copy=try item("copyHashes");send(copy)
        try require(clipboard.string(forType:.string)==shown[1].hash,"Fresh copied hash changed")
        sentinel();send(copy);try require(clipboard.string(forType:.string)=="untouched","Popup command executed twice")
        // Every menu/submenu leaf has a guarded native selector, including
        // actions with typed reference/parent payloads and async preparation.
        open();let stale=leaves(menu),before=callbacks.count
        try require(stale.count>20 && stale.allSatisfy{($0.target as? NSObject)?.responds(to:$0.action!)==true},"Some revision selectors bypassed or lack the relay")
        model.selected=[shown[2].hash];sentinel()
        for action in stale { send(action) }
        await Task.yield()
        try require(callbacks.count==before && clipboard.string(forType:.string)=="untouched" && model.commandRequest==nil && model.noteRequest==nil && model.error==nil && !model.busy && !model.loadingNote,"Stale menu targeted a later revision or started work")
        model.selected=[shown[1].hash]
        for key in [\LogWindowModel.busy,\.findBlocked,\.orderingBlocked,\.referencePickerBlocked] {
            open();let action=try item("copyHashes");model[keyPath:key]=true;sentinel();send(action)
            try require(clipboard.string(forType:.string)=="untouched","Blocked dialog accepted popup action");model[keyPath:key]=false
        }
        // A same-hash reference change, including canonical-equivalent Unicode
        // names, must retire the old label/command binding without a reload.
        shown[1].references=[RevisionReference(name:"refs/heads/café")];model.entries=shown;open();let changedRefs=try item("copyHashes")
        shown[1].references=[RevisionReference(name:"refs/heads/café")];model.entries=shown;sentinel();send(changedRefs)
        try require(clipboard.string(forType:.string)=="untouched","Reference byte-identity change preserved an old popup")
        // Reloading to the same commit is still a new menu generation.
        open();let beforeReload=try item("browseRepository"),count=callbacks.count
        model.reload();try await wait{!model.busy};model.selected=[entries[1].hash]
        send(beforeReload);try require(callbacks.count==count,"Old popup survived a same-selection reload")
        // Working-tree commands have the same captured ownership contract.
        model.selected=[""];open();let commit=try item("commitWorkingTree")
        model.selected=[entries[1].hash];send(commit);try require(callbacks.count==count,"Working-tree popup opened Commit for another row")
        model.selected=[""];open();send(try item("commitWorkingTree"));try require(callbacks.last=="commit","Fresh working-tree Commit was lost")
        model.selected=[entries[1].hash];open();let retired=try item("browseRepository");model.invalidate();send(retired)
        try require(callbacks.last=="commit" && callbacks.count==count+1,"Retired Log accepted a menu action")
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterRefs=try await repository.run(["show-ref"]).stdout
        try require(afterHead==head && afterRefs==refs && (try? Data(contentsOf:repository.root.appendingPathComponent(".git/index")))==index,"Menu ownership checks modified repository state")
        print("Log popup ownership: original native selectors/icons/payloads, fresh callbacks after menu close, one-shot use, all stale selection leaves, blocked states, Unicode reference bytes, reload generation, working tree and retirement passed; private clipboard/HEAD/index/refs preserved.")
    }

    @MainActor static func historyMenuCommands(repository:GitRepository,entries:[LogEntry],preferences:UserDefaults,git:URL) async throws {
        DialogGeometry.install(preferences:preferences)
        let regexExecutable=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let owner=LogWindowController(repository:repository,access:nil,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,historyRegexExecutable:regexExecutable)
        defer{owner.close()}
        let model=owner.model,window=owner.window!
        owner.showWindow(nil);model.reload();try await wait{!model.busy}
        try await wait{window.contentView.map{descendants($0).contains{$0 is HistoryTableView}}==true}
        let table=descendants(window.contentView!).compactMap{$0 as? HistoryTableView}.first!,coordinator=table.delegate as! RevisionTable.Coordinator,menu=table.menu!
        func leaves(_ menu:NSMenu)->[NSMenuItem] { menu.items.flatMap{$0.submenu.map{leaves($0)} ?? ($0.action == nil ? []:[$0])} }
        func item(_ selector:String)->NSMenuItem? { leaves(menu).first{NSStringFromSelector($0.action!)==selector} }
        func update(extended:Bool=false) { table.contextExtendedMenu=extended;coordinator.menuNeedsUpdate(menu) }
        func send(_ item:NSMenuItem) { _=NSApp.sendAction(item.action!,to:item.target,from:item) }
        func choose(_ hash:String) { let row=model.entries.firstIndex{$0.hash==hash}!;table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);model.select([hash]) }
        var histories:[String]=[],dcommits=0,pushes=0
        model.onShowHistory={histories.append($0)};model.onHistorySVNDCommit={dcommits += 1};model.onHistoryPush={_,_ in pushes += 1}
        choose(entries[0].hash);update()
        try require(item("showHistory:")?.isEnabled==true && item("showHistory:")?.image != nil && item("svnDCommitFromHistory:")==nil,"Ordinary HEAD menu lacks Show log or exposes SVN")
        send(item("showHistory:")!);try require(histories==[entries[0].hash],"Show log did not capture selected SHA")
        let svn=repository.root.appendingPathComponent(".git/svn"),hadSVN=FileManager.default.fileExists(atPath:svn.path)
        try FileManager.default.createDirectory(at:svn,withIntermediateDirectories:true)
        try Data().write(to:svn.appendingPathComponent(".metadata"))
        defer{if !hadSVN{try? FileManager.default.removeItem(at:svn)}}
        model.reload();try await wait{!model.busy};choose(entries[0].hash);update()
        try require(model.hasGitSVN && item("svnDCommitFromHistory:")?.title==RepositoryAction.svnDCommit.title && item("svnDCommitFromHistory:")?.image != nil,"Git-SVN menu command/icon absent: svn=\(model.hasGitSVN), bare=\(model.bare), error=\(model.error ?? "none"), title=\(item("svnDCommitFromHistory:")?.title ?? "missing")")
        let svnItem=item("svnDCommitFromHistory:")!;send(svnItem);send(svnItem)
        try require(dcommits==1,"SVN command was lost or dispatched twice")
        choose(entries[1].hash);update()
        try require(item("showHistory:")==nil && item("pushCaptured:")==nil && item("svnDCommitFromHistory:")==nil,"Unreferenced row exposed normal extended commands")
        update(extended:true);let extendedLog=item("showHistory:")!
        table.contextExtendedMenu=false;send(extendedLog)
        try require(histories.last==entries[1].hash,"Releasing Shift redirected/removed captured Show log")
        update(extended:true);let extendedSVN=item("svnDCommitFromHistory:")!
        table.contextExtendedMenu=false;send(extendedSVN);model.svnDCommitFromHistory(extended:false)
        try require(dcommits==2,"Captured extended SVN gate was lost or normal gate bypassed")
        update(extended:true);let stale=item("showHistory:")!;choose(entries[2].hash);send(stale)
        try require(histories.count==2,"Stale Show log opened a later selection")
        let row=model.entries.firstIndex{$0.hash==entries[2].hash}!
        model.entries[row].references=[RevisionReference(name:"refs/stash")];choose(entries[2].hash);update()
        try require(item("showHistory:")==nil && item("svnDCommitFromHistory:")==nil,"Normal stash exposed transport/history")
        update(extended:true);try require(item("showHistory:") != nil && item("svnDCommitFromHistory:") != nil,"Extended stash lost source commands")
        model.entries[row].references=[];model.bare=true;update(extended:true)
        try require(item("svnDCommitFromHistory:")==nil,"Bare menu exposed SVN DCommit");model.bare=false
        choose(entries[1].hash)
        var popups=0,anchor=NSPoint.zero,popupTitles:[String]=[]
        table.presentContextMenu={popup,point,_ in coordinator.menuNeedsUpdate(popup);popups += 1;anchor=point;popupTitles=leaves(popup).map(\.title)}
        table.contextReference=(row:table.selectedRow,name:"refs/heads/not-a-keyboard-target")
        let f10=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.shift,.function],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{f70d}",charactersIgnoringModifiers:"\u{f70d}",isARepeat:false,keyCode:109)!
        try require(table.performKeyEquivalent(with:f10) && popups==1 && table.contextReference==nil && table.contextExtendedMenu && table.row(at:anchor)==table.selectedRow && popupTitles.contains("Show log…"),"Shift-F10 menu anchor/mode/target failed")
        try require(table.accessibilityPerformShowMenu() && popups==2 && !table.contextExtendedMenu && !popupTitles.contains("Show log…"),"Accessibility context menu inherited Shift or label hit")
        for key in [\LogWindowModel.busy,\.findBlocked,\.orderingBlocked,\.referencePickerBlocked] {
            model[keyPath:key]=true;try require(!table.showKeyboardContextMenu() && !table.accessibilityPerformShowMenu(),"Blocked owner opened keyboard context menu");model[keyPath:key]=false
        }
        table.deselectAll(nil);try require(!table.showKeyboardContextMenu(),"Empty selection opened keyboard menu");choose(entries[1].hash)
        var comparisons:[(ComparisonRevision,ComparisonRevision)]=[]
        model.onCompare={comparisons.append(($0,$1))}
        let oldDouble=preferences.object(forKey:"DiffByDoubleClickInLog")
        defer{if let oldDouble{preferences.set(oldDouble,forKey:"DiffByDoubleClickInLog")}else{preferences.removeObject(forKey:"DiffByDoubleClickInLog")}}
        preferences.set(false,forKey:"DiffByDoubleClickInLog");try require(table.onReturn?()==false,"Disabled Return diff was consumed")
        preferences.set(true,forKey:"DiffByDoubleClickInLog")
        let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        window.makeFirstResponder(table)
        try require(window.performKeyEquivalent(with:enter),"Log window default button consumed Return before revision diff")
        try require(comparisons.count==1 && comparisons[0].0 == .revision(entries[1].parents[0]) && comparisons[0].1 == .revision(entries[1].hash),"Return did not follow source double-click diff preference")
        owner.close();try require(!table.showKeyboardContextMenu() && table.onReturn?() != true,"Retired native table accepted keyboard action")
        // Exercise repository-bound handlers through the actual workspace factory.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},comparisonMarks:WorkingComparisonMarkStore(storageURL:repository.root.appendingPathComponent("private-comparison-mark.json")))
        let clipboard=NSPasteboard(name:NSPasteboard.Name("TurtleGit.HistoryMenus."+UUID().uuidString))
        var logs:[LogWindowController]=[],leases:[RepositoryAccessLease?]=[],svnWindows:[SVNWindowController]=[],svnRoots:[URL]=[]
        defer{logs.forEach{$0.close()};svnWindows.forEach{$0.close()};workspace.closeRepository();workspace.stopMonitoringForTermination();clipboard.releaseGlobally()}
        workspace.logWindowFactory={repo,access in
            let log=LogWindowController(repository:repo,access:access,labelDefaults:preferences,savesColumnLayout:false,savesGeometry:false,historyRegexExecutable:regexExecutable);log.model.clipboard=clipboard;logs.append(log);leases.append(access);return log
        }
        workspace.svnWindowFactory={repo,access,operation in let child=SVNWindowController(repository:repo,access:access,operation:operation,preferences:preferences,clipboard:clipboard);svnWindows.append(child);return child}
        workspace.svnPresentation={child in svnRoots.append(child.model.repository.root);child.close()}
        workspace.open(repository.root);try await wait{!workspace.busy && workspace.root != nil};workspace.activate(.log)
        try await wait{logs.count==1 && !logs[0].model.busy}
        let parent=logs[0],hash=entries[1].hash
        parent.model.select([hash]);parent.model.showHistory(extended:true)
        try await wait{logs.count==2 && !logs[1].model.busy && logs[1].model.selected==[hash]}
        let child=logs[1]
        try require(child !== parent && child.model.endRevision==hash && child.model.repository.root==parent.model.repository.root && leases[0] === leases[1] && parent.model.endRevision==nil,"Show log changed parent scope or lost repository/grant")
        child.model.select([hash]);child.model.showHistory(extended:true);try await wait{!child.model.busy}
        try require(logs.count==2,"Same scoped history did not reuse its child")
        parent.model.select([entries[0].hash]);parent.model.svnDCommitFromHistory(extended:false)
        try require(svnRoots.count==1 && svnRoots[0]==parent.model.repository.root && svnWindows[0].model.operation == .dcommit,"History SVN command lost its captured repository")
        workspace.closeRepository();parent.close()
        try require(!child.model.isInvalidated && child.window?.isVisible==true,"Closing parent/workspace retired independent scoped history")
        child.close()
        print("Log source menu family: normal/extended/ref/stash/bare Show log and SVN DCommit, original icons, Shift snapshot and stale guards, selected-row Shift-F10/AX routes, Return diff preference, scoped child reuse/selection/grant and captured SVN repository passed. No SVN transport submitted; owned windows closed.")
    }

}
