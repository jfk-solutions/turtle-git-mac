import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncConflictFilesVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line)async throws {
        for _ in 0..<6000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Conflict file table wait at \(line)")
    }
    @MainActor static func views(_ v:NSView)->[NSView] {[v]+v.subviews.flatMap(views)}
    @MainActor static func capture(_ window:NSWindow)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_CONFLICT_CAPTURE"] else {return}
        if #available(macOS 14.4,*) {
            let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:350_000_000)
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
                guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Missing owned Sync window")}
                let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.includeChildWindows=false;config.showsCursor=false
                let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
                try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("sync-conflict-files-"+suffix+".png"))
            };window.alphaValue=0
        }
    }
    @MainActor static func main()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.SyncConflictFiles."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite);NSApp.windows.forEach{$0.close()}}
        _=try await repo.run(["init","--initial-branch=main","--template="])
        for (key,value) in [("user.name","Conflict QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        let names=["conflict 🐢.txt","other.txt"]
        for name in names {try Data("base\n".utf8).write(to:root.appendingPathComponent(name))}
        try await repo.stage(names);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        func blob(_ text:String)async throws->String {String(decoding:try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)}
        let base=try await blob("base\n"),mine=try await blob("mine\n"),theirs=try await blob("theirs\n")
        let input=names.map {name in "0 0000000000000000000000000000000000000000\t"+name+"\n100644 "+base+" 1\t"+name+"\n100644 "+mine+" 2\t"+name+"\n100644 "+theirs+" 3\t"+name+"\n"}.joined()
        _=try await repo.run(["update-index","--index-info"],input:Data(input.utf8))
        let owner=SynchronizationWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,window=owner.window!,actions=owner.model.conflictFileActions
        window.alphaValue=0;window.orderFront(nil);model.tab=6
        try await wait{!model.busy && !actions.busy && actions.files.count==2 && model.conflicts.count==2}
        try await wait{views(window.contentView!).compactMap{$0 as? NSTableView}.contains{$0.tableColumns.count==5}}
        let table=views(window.contentView!).compactMap{$0 as? NSTableView}.first{$0.tableColumns.count==5}!
        try require(table.tableColumns.map{$0.title} == ["Path","Extension","Status","Lines added","Lines removed"],"Source conflict column order")
        let original=try await repo.run(["ls-files","--unmerged"]).stdout
        var routed=[(RepositoryAction,[String])](),opened=[String]()
        model.onConflictAction={routed.append(($0,$1))}
        actions.openWorkingFile={url,_ in opened.append(url.lastPathComponent)}
        actions.openAlternativeEditor={url in opened.append("editor:"+url.lastPathComponent)}
        actions.selection=[names[0]]
        let single=model.conflictMenu([names[0]],mark:names[0])
        try require(single.commands == [.log,.editor,.open,.openWith,.reveal] && single.offersResolve,"Source conflict mask admitted unrelated commands")
        model.performConflict(.editConflict,menu:single);model.performConflict(.resolveMine,menu:single);model.performConflictFile(.log,menu:single)
        try require(routed.map{$0.0} == [.editConflict,.resolveMine,.log] && routed.allSatisfy{$0.1 == [names[0]]},"Single conflict actions used wrong captured file")
        model.performConflictFile(.delete,menu:single);try require(routed.count==3,"Excluded destructive command dispatched")
        model.performConflictFile(.open,menu:single);try await wait{!actions.busy && StatusWindowModel.activeOperations==0}
        model.performConflictFile(.editor,menu:single);try await wait{!actions.busy && StatusWindowModel.activeOperations==0}
        try require(opened == [names[0],"editor:"+names[0]],"Open/editor failed captured path")
        actions.selection=GitPathSet(names);let multiple=model.conflictMenu(Set(names),mark:names[1])
        try require(multiple.commands.isEmpty,"Multi-selection enabled single-file commands")
        model.performConflict(.editConflict,menu:multiple);try require(routed.count==3,"Multi-selection Edit conflict dispatched")
        model.performConflict(.resolveTheirs,menu:multiple);try require(routed.last?.0 == .resolveTheirs && Set(routed.last!.1)==Set(names),"Multi-resolution lost selection")
        let clipboard=NSPasteboard.withUniqueName();defer{clipboard.releaseGlobally()};actions.clipboard=clipboard
        actions.withFileMenu(multiple){actions.copy(Set(names),information:.relativePaths)}
        try require(names.allSatisfy{clipboard.string(forType:.string)?.contains($0)==true},"Private clipboard lost conflict paths")
        actions.selection=[names[0]];actions.selection=GitPathSet(names);let count=routed.count
        model.performConflict(.resolveCurrent,menu:multiple);try require(routed.count==count,"Selection-away/return revived old menu")
        actions.setColumn(.added,visible:false)
        try require(prefs.integer(forKey:"ConflictSyncDlg.FileColumns.Version")==1 && prefs.object(forKey:"WorkingTree.FileColumns.Version")==nil,"Sync customization changed Working Tree profile")
        actions.requestResetColumns(choose:{true},onAccepted:{})
        try await wait{!actions.busy && actions.fileColumns.visible==SynchronizationWindowModel.conflictColumns}
        let ordinary=StatusWindowModel(repository:repo,access:nil,defaults:prefs)
        try require(ordinary.fileColumns.visible==StatusWindowModel.defaultColumns.visible,"Working Tree default columns changed")
        ordinary.invalidate()
        try await capture(window)
        let stale=model.conflictMenu([names[0]],mark:names[0])
        let f5=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:String(UnicodeScalar(NSF5FunctionKey)!),charactersIgnoringModifiers:String(UnicodeScalar(NSF5FunctionKey)!),isARepeat:false,keyCode:96)!
        try require(window.performKeyEquivalent(with:f5),"F5 did not route")
        try await wait{!actions.busy && StatusWindowModel.activeOperations==0}
        model.performConflict(.resolveCurrent,menu:stale);try require(routed.count==count,"Refresh revived old file menu")
        let selected=try await repo.conflicts(paths:[names[0]])
        _=try await repo.resolveConflicts(selected,using:.mine)
        ConflictListRefreshPolicy.perform(preferences:prefs){model.refreshConflictFiles()}
        try await wait{!actions.busy && actions.files.count==1 && model.conflicts.count==1}
        prefs.set(0,forKey:"RefreshFileListAfterResolvingConflict")
        _=try await repo.resolveConflicts(try await repo.conflicts(paths:[names[1]]),using:.theirs)
        ConflictListRefreshPolicy.perform(preferences:prefs){model.refreshConflictFiles()}
        try require(actions.files.count==1,"Disabled refresh callback rebuilt list")
        _=window.performKeyEquivalent(with:f5);try await wait{!actions.busy && actions.files.isEmpty}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"File-list actions moved HEAD")
        // Restore conflict data for an actual owned application chooser, then force-close.
        _=try await repo.run(["update-index","--index-info"],input:Data(input.utf8))
        model.refreshConflictFiles();try await wait{!actions.busy && actions.files.count==2}
        let chooser=model.conflictMenu([names[0]],mark:names[0]);model.performConflictFile(.openWith,menu:chooser)
        try await wait{window.attachedSheet is NSOpenPanel}
        let panel=window.attachedSheet!
        try require(actions.busy && !owner.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Chooser did not retain owner/Quit")
        owner.close();try await wait{StatusWindowModel.activeOperations==0 && panel.sheetParent==nil && !panel.isVisible}
        try require(actions.retired && model.closed && opened.count==2,"Forced chooser close opened a late application")
        let retained=routed.count;model.performConflict(.resolveCurrent,menu:chooser);try require(routed.count==retained,"Retired conflict action dispatched")
        let final=try await repo.run(["ls-files","--unmerged"]).stdout
        try require(final==original,"Chooser or copy changed unresolved stage entries")
        print("PASS Sync conflict files: actual five-column native table, multi-selection source mask, direct Edit/quick Resolve/Log routes, private Copy, captured Open/editor, stale selection/refresh/retirement, isolated column customization/reset, F5, real mine/theirs resolution and refresh policy, actual Open With/forced close/Quit/worker drain and unchanged HEAD")
    }
}
