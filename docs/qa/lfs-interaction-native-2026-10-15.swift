// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct LFSInteractionVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2500 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"LFS interaction wait at line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ window:NSWindow, name:String) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_LFS_INTERACTION_CAPTURE"] else { return }
        guard #available(macOS 14.4,*) else { throw Failure(description:"Compositor capture unavailable") }
        window.alphaValue=1;window.orderFront(nil);defer { window.alphaValue=0 }
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else { throw Failure(description:"Missing owned LFS capture window") }
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*window.backingScaleFactor);config.height=Int(window.frame.height*window.backingScaleFactor);config.showsCursor=false;config.ignoreShadowsSingleWindow=true
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.accessory)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), engine=URL(fileURLWithPath:CommandLine.arguments[2])
        let actual=GitRepository(root:root,executable:engine)
        _ = try await actual.run(["init","-b","main"])
        for (key,value) in [("user.name","LFS QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await actual.run(["config",key,value]) }
        let paths=["asset a.bin","雪\t🦎.bin"]
        for path in paths { try Data("base\n".utf8).write(to:root.appendingPathComponent(path)) }
        try await actual.stage(paths);_ = try await actual.commit(message:"base")
        try FileManager.default.createDirectory(at:root.appendingPathComponent(".git/lfs"),withIntermediateDirectories:true)
        let settings:[String:Any]=["engine":engine.path,"paths":paths]
        try JSONSerialization.data(withJSONObject:settings).write(to:root.appendingPathComponent(".git/lfs-simulation.json"))
        let state=paths.enumerated().map { ["id":String($0.offset+1),"path":$0.element,"owner":["name":$0.offset==0 ? "QA":"Other user"]] as [String:Any] }
        try JSONSerialization.data(withJSONObject:state).write(to:root.appendingPathComponent(".git/lfs-state.json"))
        let wrapper=root.appendingPathComponent(".git/lfs-test-git")
        let script = #"""
        #!/usr/bin/python3
        import os,sys,json,time,pathlib
        args=sys.argv[1:];i=args.index('-C');root=pathlib.Path(args[i+1]);cmd=args[i+2:]
        config=json.loads((root/'.git/lfs-simulation.json').read_text())
        if not cmd or cmd[0]!='lfs':os.execv(config['engine'],[config['engine']]+args)
        with (root/'.git/lfs-calls.jsonl').open('a') as out:out.write(json.dumps(cmd)+'\n')
        state=root/'.git/lfs-state.json'
        if cmd==['lfs','locks','--json']:print(state.read_text());sys.exit(0)
        path=cmd[-1]
        if path==config['paths'][0] and '--force' not in cmd:
            deadline=time.monotonic()+20
            while not (root/'.git/lfs-release').exists() and time.monotonic()<deadline:time.sleep(.01)
            if not (root/'.git/lfs-release').exists():print('fixture release timed out',file=sys.stderr);sys.exit(70)
        if path==config['paths'][1] and '--force' not in cmd:print('owned by another user\npermission detail',file=sys.stderr);sys.exit(1)
        records=json.loads(state.read_text());state.write_text(json.dumps([r for r in records if r['path']!=path]))
        print('Unlocked '+path)
        """#
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
        let repository=GitRepository(root:root,executable:wrapper)
        let head=try await actual.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite="TurtleGit.LFSInteraction.QA."+UUID().uuidString, preferences=UserDefaults(suiteName:suite)!
        preferences.set(false,forKey:"ShowGitexeTimings")
        defer { preferences.removePersistentDomain(forName:suite) }
        let log=ActionLogStore(storageURL:root.appendingPathComponent(".git/qa-action-log.txt"))
        ProgressActionLog.install(store:log,preferences:preferences)
        let owner=LFSLocksWindowController(repository:repository,access:nil,defaults:preferences),model=owner.model
        defer { owner.close() }
        owner.window!.alphaValue=0;owner.window!.orderFront(nil)
        var copied:[String]=[];model.publishClipboard={copied.append($0)}
        await model.refresh();try require(model.locks.count==2 && model.hasLFS,"Real simulated lock query")
        model.selection=["1","2"];model.checkClicked("1",value:false);try require(model.checked.isEmpty,"Selected checkbox did not propagate")
        model.selection=["1"];model.checkClicked("2",value:true);try require(model.checked==["2"],"Unselected checkbox changed highlighted row")
        model.selection=["1","2"];model.checkClicked("1",value:true);try require(model.checked==["1","2"],"Selected checkbox enable did not propagate")
        let target=model.menuTarget(["1","2"])!, capturedPaths=target.rows.map(\.path)
        model.selection=["2"];model.setSortOrder([LFSFileSort(column:.path,order:.reverse)])
        model.copy(target,information:.relativePaths);try require(copied.last==capturedPaths.joined(separator:"\n")+"\n","Captured menu followed later selection/sort")
        let stale=model.menuTarget(["1"])!;await model.refresh();let count=copied.count
        model.copy(stale,information:.relativePaths);await model.setSelectionLocked(stale,locked:false);try require(copied.count==count && !model.showingProgress,"Refreshed menu target executed")
        let beforeColumn=model.menuTarget(["1"])!;model.setColumn(.lfsOwner,visible:false);try require(!model.accepts(beforeColumn) && model.lfsActions(["1"])==[.lock,.unlock],"Column policy did not retire menu")
        model.setColumn(.lfsOwner,visible:true);model.setSortOrder([LFSFileSort(column:.path)])
        try await wait { views(owner.window!.contentView!).contains { $0 is LFSLocksNativeTable } }
        let lockedTable = views(owner.window!.contentView!).compactMap { $0 as? LFSLocksNativeTable }.first!
        let nativeList = NativeListSelection.originalDelegate(of:lockedTable) as! LFSLocksTable.Coordinator
        try require((lockedTable.headerView?.frame.height ?? 0) > 0,"Native list header has no visible height")
        try require(lockedTable.watermarkImage != nil && lockedTable.backdropRect(in:NSRect(x:0,y:0,width:500,height:300)) != nil,"Native lock-list watermark missing")
        model.selection = ["1","2"];nativeList.contextColumn = .lfsOwner
        lockedTable.menu!.delegate?.menuNeedsUpdate?(lockedTable.menu!)
        guard let columnItem = lockedTable.menu!.item(withTitle:"Copy to Clipboard")?.submenu?.item(withTitle:"column '\(StatusListColumn.lfsOwner.rawValue)'") else { throw Failure(description:"Missing native captured column menu") }
        let capturedColumn = { _ = NSApp.sendAction(columnItem.action!,to:columnItem.target,from:columnItem) }
        capturedColumn();try require(copied.last=="QA\nOther user\n","Actual table column hook copy")
        await model.refresh();let oldCount=copied.count;capturedColumn();try require(copied.count==oldCount,"Old native column capture survived refresh")
        model.selectAll(true);model.selection = ["1","2"];nativeList.refresh()
        let rowCheck = lockedTable.view(atColumn:0,row:0,makeIfNecessary:true) as! NSButton
        rowCheck.performClick(nil);try require(model.checked.isEmpty && model.selection == ["1","2"],"Native checkbox did not propagate selected rows")
        lockedTable.toggleChecks();try require(model.checked == ["1","2"],"Native Space handler lost selected checks")
        lockedTable.copyRows(false);try require(copied.last == paths.joined(separator:"\n")+"\n","Native keyboard copy lost selected paths")
        preferences.set(false,forKey:"ShowListBackgroundImage");try require(lockedTable.backdropRect(in:NSRect(x:0,y:0,width:500,height:300)) == nil,"Private watermark preference ignored")
        preferences.set(true,forKey:"ShowListBackgroundImage")
        try await capture(owner.window!,name:"lfs-locks")
        let operation=Task { await model.unlock() }
        try await wait { model.currentPath==paths[0] && model.busy && owner.window!.attachedSheet != nil }
        owner.window!.attachedSheet?.alphaValue=0
        try require(model.notifications.map(\.action)==["Command","Unlock"] && model.results.isEmpty,"File-begin event did not precede command settlement")
        try require(LFSLocksWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Streaming LFS Quit ownership")
        let beforeBusy=copied.count;model.copy(target,information:.all);try require(copied.count==beforeBusy,"Busy menu copied")
        try Data().write(to:root.appendingPathComponent(".git/lfs-release"));await operation.value
        try require(model.results.map(\.success)==[true,false] && model.notifications.map(\.action)==["Command","Unlock","Unlock","Error","Error","Finished!"],"Source progress row order or multiline error")
        try require(model.notifications.filter{$0.kind == .file}.map(\.text)==paths,"Progress lost literal Unicode/tab paths")
        let sheet=owner.window!.attachedSheet!
        try await wait { views(sheet.contentView!).compactMap{$0 as? NSTableView}.contains{$0.tableColumns.map(\.title)==["Action","Path"] && $0.numberOfRows==model.notifications.count} }
        let table=views(sheet.contentView!).compactMap{$0 as? NativeWatermarkTable}.first!
        try require(table.watermarkImage != nil,"Original unlock watermark missing")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);table.menu!.delegate?.menuNeedsUpdate?(table.menu!)
        let copy=table.menu!.item(withTitle:"Copy to Clipboard")!;_=NSApp.sendAction(copy.action!,to:copy.target,from:copy)
        try require(copied.last==paths[0] && copy.image != nil,"Native progress selected copy/artwork")
        let staleProgressCopy=copy
        let menuTitles = table.menu!.items.filter { !$0.isSeparatorItem }.map(\.title)
        try require(menuTitles == ["Show log","Open","Open With…","Explore to","LFS Lock","LFS Unlock","Copy to Clipboard"], "Source single-file progress actions/order")
        var commands: [(LFSProgressCommand,String)] = []
        model.progressActionHandler = { commands.append(($0,$1)) }
        for command in LFSProgressCommand.allCases {
            let item = table.menu!.item(withTitle: command.rawValue)!
            try require(item.image != nil, "Source action artwork missing")
            let expectedCount = commands.count + 1
            _ = NSApp.sendAction(item.action!,to:item.target,from:item)
            try await wait { commands.count == expectedCount && !model.progressActionBusy }
            try require(commands.last!.0 == command && commands.last!.1 == paths[0], "Progress action changed captured path")
        }
        let targetBeforeSort = model.progressTarget([model.notifications[1]])!
        let staleProgressOpen = table.menu!.item(withTitle:"Open")!
        await model.progressDoubleClick(model.notifications[1])
        try require(commands.last!.0 == .open, "File double-click did not open")
        let beforeAux = commands.count
        await model.progressDoubleClick(model.notifications[0])
        try require(commands.count == beforeAux, "Auxiliary row double-click launched")
        table.selectRowIndexes(IndexSet([1,2]),byExtendingSelection:false);table.menu!.delegate?.menuNeedsUpdate?(table.menu!)
        try require(table.menu!.items.map(\.title) == ["Copy to Clipboard"], "Multi-selection exposed single-file actions")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);table.menu!.delegate?.menuNeedsUpdate?(table.menu!)
        try require(table.menu!.items.map(\.title) == ["Copy to Clipboard"], "Auxiliary row exposed file actions")
        table.selectRowIndexes(IndexSet([1,2]),byExtendingSelection:false)
        let event = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
        try require(table.performKeyEquivalent(with:event) && copied.last == "Unlock: \(paths[0])  \nUnlock: \(paths[1])  \n", "Keyboard clipboard differs from source Action: Path format")
        let selectAll = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:sheet.windowNumber,context:nil,characters:"a",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0)!
        _ = table.performKeyEquivalent(with:selectAll);try require(table.selectedRowIndexes.count == model.notifications.count,"Command-A did not select notifications")
        let pathColumn = table.tableColumns[1]
        table.delegate?.tableView?(table,didClick:pathColumn);table.delegate?.tableView?(table,didClick:pathColumn)
        let displayedPath = (table.delegate?.tableView?(table,viewFor:pathColumn,row:1) as? NSTextField)?.stringValue
        try require(displayedPath == paths[1] && table.selectedRowIndexes.count == model.notifications.count, "Header descending sort or selected identity")
        await model.progressCommand(.log,target:targetBeforeSort)
        try require(commands.last!.1 == paths[0],"Sorting retargeted old file action")
        // Auxiliary error rows split independent sortable file blocks.
        let sample = [LFSProgressRow(id:"cmd",action:"Command",text:"Unlock",kind:.command),LFSProgressRow(id:"b",action:"Unlock",text:"b",kind:.file),LFSProgressRow(id:"a",action:"Unlock",text:"a",kind:.file),LFSProgressRow(id:"err",action:"Error",text:"failure",kind:.error),LFSProgressRow(id:"d",action:"Unlock",text:"d",kind:.file),LFSProgressRow(id:"c",action:"Unlock",text:"c",kind:.file)]
        try require(LFSProgressRow.sorted(sample,column:"path",ascending:true).map(\.id) == ["cmd","a","b","err","c","d"],"Sort crossed auxiliary boundary")
        let spaced = LFSProgressRow(id:"s",action:"Unlock",text:" leading path ",kind:.file)
        try require(LFSProgressRow.clipboard([spaced],keyboard:false) == " leading path", "Menu clipboard trimmed leading whitespace")
        try require(LFSProgressRow.completion(success:true,elapsed:1.234,date:Date(timeIntervalSince1970:0)).hasPrefix("Success (1234 ms @ ") && model.notifications.last!.text.hasPrefix("Fail ("),"Source completion ignores timing checkbox and uses source wording")
        let directoryPath = root.appendingPathComponent(paths[0])
        try FileManager.default.removeItem(at:directoryPath);try FileManager.default.createDirectory(at:directoryPath,withIntermediateDirectories:false)
        table.selectRowIndexes(IndexSet(integer:2),byExtendingSelection:false);table.menu!.delegate?.menuNeedsUpdate?(table.menu!)
        try require(table.menu!.item(withTitle:"Open") == nil && table.menu!.item(withTitle:"Open With…") == nil && table.menu!.item(withTitle:"Explore to") != nil,"Directory progress menu exposed file opening")
        await model.progressDoubleClick(model.notifications[1]);try require(commands.last!.0 == .explore,"Directory double-click did not explore")
        try FileManager.default.removeItem(at:directoryPath);try Data("base\n".utf8).write(to:directoryPath)
        model.progressActionHandler = nil
        var launched: [(URL,URL?)] = [], revealed: [URL] = []
        model.progressActions.launch = { launched.append(($0,$1)) };model.progressActions.reveal = { revealed.append($0) }
        model.progressActions.chooseApplication = { URL(fileURLWithPath:"/Applications/QA.app") }
        await model.progressCommand(.open,target:targetBeforeSort);await model.progressCommand(.openWith,target:targetBeforeSort);await model.progressCommand(.explore,target:targetBeforeSort)
        try require(launched.count == 2 && launched.allSatisfy{$0.0 == root.appendingPathComponent(paths[0])} && launched[1].1?.lastPathComponent == "QA.app" && revealed == [root.appendingPathComponent(paths[0])],"Actual native host lost file/application routing")
        var routedLog: String?
        model.onProgressLog = { routedLog = $0 }
        await model.progressCommand(.log,target:targetBeforeSort)
        try require(routedLog == paths[0] && model.progressActions.logs.isEmpty,"Application history route was bypassed")
        model.onProgressLog = nil
        // Production history/child progress controllers, with only presentation hidden.
        model.progressActions.presentLog = { $0.window!.alphaValue = 0;$0.window!.orderFront(nil) }
        model.progressActions.presentOperation = { $0.alphaValue = 0;$0.orderFront(nil) }
        await model.progressCommand(.log,target:targetBeforeSort)
        try require(model.progressActions.logs.count == 1 && model.progressActions.logs.values.first!.model.historyPaths == [paths[0]],"Source Show log did not open scoped native history")
        model.progressActions.logs.values.first!.close()
        await model.progressCommand(.unlock,target:targetBeforeSort)
        try await wait { model.progressActions.operations.values.first?.model.results.count == 1 && model.progressActions.operations.values.first?.model.busy == false }
        let child = model.progressActions.operations.values.first!
        try require(child.model.results.first?.path == paths[0],"LFS progress child retargeted")
        child.model.finishProgress();try require(model.progressActions.operations.isEmpty,"Child progress ownership leaked")
        // An application chooser owns Quit/review until completion and is fenced after retirement.
        let lateModel = LFSLocksWindowModel(repository:repository,access:nil,defaults:preferences)
        lateModel.refreshLocksAfterOperation = false;lateModel.change = { paths,_,_,_ in LFSBatchResult(files:paths.map{LFSFileResult(path:$0,success:true,output:"")},cancelled:false) }
        await lateModel.perform(paths:[paths[0]],locked:false)
        var chooseReply: CheckedContinuation<URL?,Never>?, lateLaunch = false
        lateModel.progressActions.chooseApplication = { await withCheckedContinuation { chooseReply = $0 } }
        lateModel.progressActions.launch = { _,_ in lateLaunch = true }
        let lateTarget = lateModel.progressTarget([lateModel.notifications[1]])!
        let pendingOpen = Task { await lateModel.progressCommand(.openWith,target:lateTarget) }
        try await wait { chooseReply != nil }
        try require(lateModel.progressActionBusy && LFSLocksWindowModel.activeOperations == 1,"Chooser lost operation/Quit ownership")
        lateModel.finishProgress();try require(lateModel.showingProgress,"Review closed while chooser owned operation")
        lateModel.retire();chooseReply!.resume(returning:URL(fileURLWithPath:"/Applications/QA.app"));await pendingOpen.value
        try require(!lateLaunch && LFSLocksWindowModel.activeOperations == 0,"Late application chooser launched or leaked ownership")
        table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);table.menu!.delegate?.menuNeedsUpdate?(table.menu!)
        preferences.set(false,forKey:"ShowAppContextMenuIcons");table.menu!.delegate?.menuNeedsUpdate?(table.menu!);try require(table.menu!.items.first?.image==nil,"Private progress icon preference")
        preferences.set(true,forKey:"ShowAppContextMenuIcons");try await capture(sheet,name:"lfs-unlock-progress")
        model.selection=[];model.checked=[];await model.unlock(forceRetry:true)
        let beforeStaleOpen = launched.count
        _ = NSApp.sendAction(staleProgressOpen.action!,to:staleProgressOpen.target,from:staleProgressOpen)
        await Task.yield();try require(launched.count == beforeStaleOpen,"Old progress Open survived Force generation")
        let afterForce=copied.count;_=NSApp.sendAction(staleProgressCopy.action!,to:staleProgressCopy.target,from:staleProgressCopy)
        try require(copied.count==afterForce && model.results.map(\.path)==paths && model.results.allSatisfy(\.success),"Retry retargeted or old progress menu survived")
        model.finishProgress();try await wait { !model.busy && !model.showingProgress && owner.window!.attachedSheet==nil }
        try require(model.locks.isEmpty,"Force result review did not refresh final state")
        let calls=try String(contentsOf:root.appendingPathComponent(".git/lfs-calls.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode([String].self,from:Data($0.utf8)) }
        let unlocks=calls.filter{$0.count>1 && $0[1]=="unlock"}
        try require(unlocks.map{$0.last!}==paths+[paths[0]]+paths && unlocks.suffix(2).allSatisfy{$0.contains("--force")},"Force commands lost captured targets")
        let saved=try log.read();try require(saved.components(separatedBy:"Command\tUnlock").count-1==4 && saved.contains("owned by another user"),"Per-attempt action log missing/duplicated")
        let late=model.menuTarget(["1"]);try require(late==nil,"Removed lock still produced menu")
        owner.close();try require(TurtleGitHelp.context(owner.window) == .overview,"Closed LFS help context retained")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"LFS UI changed local index/config")
        let finalHead=try await actual.run(["rev-parse","HEAD"]).stdout;try require(finalHead==head,"LFS UI changed HEAD")
        print("PASS: LFS selected checkboxes, captured menus/columns, literal live begin/result rows, source progress table/artwork/copy, Force targets, per-attempt logs and review refresh")
    }
}
