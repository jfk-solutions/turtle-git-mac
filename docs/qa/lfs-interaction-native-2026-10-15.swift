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
        try await wait { views(owner.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let probe=views(owner.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        guard let capturedColumn=probe.captureColumnCopy?(["1","2"],.lfsOwner) else { throw Failure(description:"Missing captured column hook") }
        capturedColumn();try require(copied.last=="QA\nOther user\n","Actual table column hook copy")
        await model.refresh();let oldCount=copied.count;capturedColumn();try require(copied.count==oldCount,"Old native column capture survived refresh")
        model.selectAll(true);try await capture(owner.window!,name:"lfs-locks")
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
        preferences.set(false,forKey:"ShowAppContextMenuIcons");table.menu!.delegate?.menuNeedsUpdate?(table.menu!);try require(table.menu!.items.first?.image==nil,"Private progress icon preference")
        preferences.set(true,forKey:"ShowAppContextMenuIcons");try await capture(sheet,name:"lfs-unlock-progress")
        model.selection=[];model.checked=[];await model.unlock(forceRetry:true)
        let afterForce=copied.count;_=NSApp.sendAction(staleProgressCopy.action!,to:staleProgressCopy.target,from:staleProgressCopy)
        try require(copied.count==afterForce && model.results.map(\.path)==paths && model.results.allSatisfy(\.success),"Retry retargeted or old progress menu survived")
        model.finishProgress();try await wait { !model.busy && !model.showingProgress && owner.window!.attachedSheet==nil }
        try require(model.locks.isEmpty,"Force result review did not refresh final state")
        let calls=try String(contentsOf:root.appendingPathComponent(".git/lfs-calls.jsonl"),encoding:.utf8).split(separator:"\n").map { try JSONDecoder().decode([String].self,from:Data($0.utf8)) }
        let unlocks=calls.filter{$0.count>1 && $0[1]=="unlock"}
        try require(unlocks.map{$0.last!}==paths+paths && unlocks.suffix(2).allSatisfy{$0.contains("--force")},"Force commands lost captured targets")
        let saved=try log.read();try require(saved.components(separatedBy:"Command\tUnlock").count-1==2 && saved.contains("owned by another user"),"Per-attempt action log missing/duplicated")
        let late=model.menuTarget(["1"]);try require(late==nil,"Removed lock still produced menu")
        owner.close();try require(TurtleGitHelp.context(owner.window) == .overview,"Closed LFS help context retained")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"LFS UI changed local index/config")
        let finalHead=try await actual.run(["rev-parse","HEAD"]).stdout;try require(finalHead==head,"LFS UI changed HEAD")
        print("PASS: LFS selected checkboxes, captured menus/columns, literal live begin/result rows, source progress table/artwork/copy, Force targets, per-attempt logs and review refresh")
    }
}
