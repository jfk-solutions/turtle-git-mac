// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

private struct FileProgressScopes:RepositoryBookmarkProvider {
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {.init(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {true}
    func stopAccessing(_ url:URL) {}
}
@MainActor enum AddResolveProgressVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Add/Resolve progress timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return[root]+root.subviews.flatMap{views($0)}}
    static func capture(_ owner:NSWindowController,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_PROGRESS_CAPTURES"],let window=owner.window,let view=window.contentView else{return}
        let appearance=window.appearance
        defer{window.appearance=appearance;view.needsDisplay=true}
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);view.needsDisplay=true;view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:60_000_000)
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Native content bitmap unavailable for "+name)}
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else{throw Failure(description:"Native content PNG unavailable for "+name)}
            let directory=URL(fileURLWithPath:folder);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try png.write(to:directory.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func key(_ window:NSWindow,_ code:UInt16,_ characters:String,_ flags:NSEvent.ModifierFlags = .command)->NSEvent {
        NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code)!
    }
    static func verify()async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (name,value) in [("user.name","File progress QA"),("user.email","file-progress@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",name,value])}
        let path="new 雪\n[*].txt",tracked=root.appendingPathComponent("tracked")
        try Data("base\n".utf8).write(to:tracked);try await repo.stage(["tracked"]);_ = try await repo.commit(message:"baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        try Data("new original\n".utf8).write(to:root.appendingPathComponent(path))
        let suite="TurtleGit.FileProgress."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,otherSuite=suite+".other",otherPrefs=UserDefaults(suiteName:otherSuite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ShowGitexeTimings");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(true,forKey:"ShowContextMenuIcons");prefs.set(0x228844,forKey:"Colors.Added");prefs.set(0x993322,forKey:"Colors.Cmd")
        ProgressActionLog.install(store:ActionLogStore(storageURL:folder.appendingPathComponent("private-actions.log")),preferences:prefs);DialogGeometry.install(preferences:prefs)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false})
        workspace.repositoryBookmarkProvider=FileProgressScopes();workspace.requiresRepositoryScope=true;workspace.fileComparisonPreferences=prefs
        let host=NSWindow(contentRect:.init(x:-12000,y:-12000,width:700,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;host.alphaValue=0;host.appearance=NSAppearance(named:.darkAqua);host.orderFront(nil);workspace.workspaceWindow=host
        var adds:[AddProgressWindowController]=[],resolves:[ResolveWindowController]=[],commits:[CommitWindowController]=[],otherOwners:[NSWindowController]=[]
        var addGrant:RepositoryAccessLease?,heldAdd:CheckedContinuation<String,Error>?,heldMode:CheckedContinuation<Void,Error>?,heldResolve:CheckedContinuation<String,Error>?
        workspace.addProgressWindowFactory={repository,access,paths,mode,preferences,backend,preservePathOrder in
            let value=AddProgressWindowController(repository:repository,access:access,paths:paths,mode:mode,preferences:preferences,backend:backend,preservePathOrder:preservePathOrder);addGrant=access;adds.append(value);return value
        }
        workspace.addProgressWindowPresentation={owner in owner.window?.alphaValue=0;owner.window?.appearance=host.appearance;owner.showWindow(nil)}
        workspace.resolveWindowPresentation={owner in owner.window?.alphaValue=0;owner.window?.appearance=host.appearance;resolves.append(owner);owner.showWindow(nil)}
        func liveCommits()->[CommitWindowController] {NSApp.windows.compactMap{$0.delegate as? CommitWindowController}.filter{owner in owner.window?.isVisible==true && !commits.contains{$0 === owner}}}
        func cleanup()async {
            heldAdd?.resume(throwing:OperationCancellationFailure.cancelled);heldAdd=nil
            heldMode?.resume(throwing:OperationCancellationFailure.cancelled);heldMode=nil
            heldResolve?.resume(throwing:OperationCancellationFailure.cancelled);heldResolve=nil
            adds.forEach{$0.close()};resolves.forEach{$0.close()};commits.forEach{$0.close()};otherOwners.forEach{$0.close()}
            workspace.stopMonitoringForTermination();workspace.closeRepository();host.close()
            for _ in 0..<3000 {
                if AddProgressWindowModel.activeOperations==0 && AddProgressWindowController.activeReleases==0 && ResolveWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && !workspace.hasPendingRepositoryWork {break}
                try? await Task.sleep(nanoseconds:10_000_000)
            }
            prefs.removePersistentDomain(forName:suite);otherPrefs.removePersistentDomain(forName:otherSuite);DialogGeometry.install(preferences:.standard)
        }
        func fileTable(_ owner:NSWindowController)async throws->FileOperationProgressNativeTable {
            try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).contains{$0 is FileOperationProgressNativeTable}}
            return views(owner.window?.contentView).compactMap{$0 as? FileOperationProgressNativeTable}.first!
        }
        func checkFooter(_ text:String,_ range:NSRange?,_ rows:[FileOperationProgressRow])throws {
            guard let range,NSMaxRange(range)<=(text as NSString).length else {throw Failure(description:"File-list progress source footer missing")}
            try require((text as NSString).substring(with:range).contains(" ms @ "),"File-list footer obeyed unrelated Gitexe timing preference")
            try require(rows.first?.kind == .command && rows.last?.kind == .finished && rows.last?.path.contains(" ms @ ")==true,"Source Action/Path command/Finished notifications missing")
        }
        do {
            workspace.open(root);try await wait {workspace.root?.path==root.path && !workspace.busy}
            workspace.activate(.add,paths:[path]);try await wait {adds.count==1 && !adds[0].model.busy}
            let add=adds[0],model=add.model
            try require(model.success && model.percentage==100 && model.currentWork=="Success" && model.preferences === prefs && model.progress.preferences === prefs,"Add completed metadata/captured prefs lost")
            try checkFooter(model.information,model.completionRange,model.progress.rows)
            try require(model.progress.rows.filter{$0.kind == .file}.map(\.path)==[path],"Add file notifications replaced captured paths")
            let table=try await fileTable(add)
            try await wait {table.numberOfRows==model.progress.rows.count}
            try require(table.tableColumns.map(\.title)==["Action","Path"],"Actual Add table lost source columns")
            try await capture(add,"add-completed")
            guard let row=model.progress.rows.firstIndex(where:{$0.kind == .file}),let action=table.delegate?.tableView?(table,viewFor:table.tableColumns[0],row:row) as? NSTextField else {throw Failure(description:"Add native source Action cell missing")}
            try require(action.stringValue=="Added" && action.toolTip==path,"Actual Add notification row lost action/path")
            var privateColorMatches=true
            for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                let theme=NSAppearance(named:appearance)!
                theme.performAsCurrentDrawingAppearance {
                    let actual=action.textColor?.usingColorSpace(.sRGB),expected=StatusTextPalette.text(.added,preferences:prefs).usingColorSpace(.sRGB)
                    if let actual,let expected {privateColorMatches = privateColorMatches && abs(actual.redComponent-expected.redComponent)<0.01 && abs(actual.greenComponent-expected.greenComponent)<0.01 && abs(actual.blueComponent-expected.blueComponent)<0.01} else {privateColorMatches=false}
                }
            }
            try require(privateColorMatches,"Private Added color not honored in both appearances")
            var clipboard:[String]=[],logs:[String]=[];model.progress.publishClipboard={clipboard.append($0)};add.onProgressLog={logs.append($0)}
            table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
            guard let menu=table.makeMenu(),let copy=menu.items.first(where:{$0.title=="Copy to Clipboard"}),let log=menu.items.first(where:{$0.title=="Show Log"}) else {throw Failure(description:"Source file notification menu missing")}
            try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Progress source icons missing")
            _ = NSApp.sendAction(copy.action!,to:copy.target,from:copy);_ = NSApp.sendAction(log.action!,to:log.target,from:log)
            try require(clipboard==[path] && logs==[path],"Progress context Copy/Log lost source path")
            table.keyDown(with:key(add.window!,8,"c"))
            try require(clipboard.last=="Added: "+path+"  \r\n","Progress keyboard Copy lost source Action: Path layout")
            // Mode post-actions are real index changes; stale popup actions from
            // the previous attempt cannot act on the newly generated rows.
            await model.changeMode(.executable)
            try require(model.success && model.progress.rows.contains{$0.kind == .file && $0.path==path},"Executable mode post-action lost notification/result")
            let stage=try await repo.run(["ls-files","--stage","-z"]).stdout
            try require(String(decoding:stage,as:UTF8.self).contains("100755"),"Add mode post-action did not update real index")
            let oldClipboard=clipboard.count;_ = NSApp.sendAction(copy.action!,to:copy.target,from:copy)
            try require(clipboard.count==oldClipboard,"Old progress popup copied a replaced attempt")
            // Actual Root wiring must retain original prefs/grants after this
            // progress owner closes, even if the workspace preferences change.
            workspace.fileComparisonPreferences=otherPrefs
            var closed=0,postActions=0,drained=false
            let oldClosed=add.onClosed,oldCommit=model.onCommit
            add.onClosed={closed += 1;oldClosed()}
            model.onCommit={postActions += 1;drained=closed==1 && add.window?.isVisible != true && add.window?.sheetParent==nil && host.attachedSheet==nil;oldCommit()}
            add.window!.orderOut(nil);host.beginSheet(add.window!,completionHandler:nil)
            model.confirmingQuit=true;model.commit();try require(postActions==0,"Deferred Quit allowed Add Commit")
            model.confirmingQuit=false;model.commit();model.commit()
            try await wait {postActions==1 && closed==1 && !liveCommits().isEmpty}
            let commit=liveCommits()[0];commits.append(commit)
            try require(drained && commit.presentationPreferences === prefs && commit.model.access === addGrant && commit.model.access?.permits(root.appendingPathComponent(".git/index"))==true,"Add Commit preceded close or lost original prefs/source scope")
            try require(commit.window?.alphaValue==0 && commit.window?.effectiveAppearance.bestMatch(from:[.darkAqua,.aqua]) == .darkAqua,"Add Commit lost hidden/dark appearance")
            commit.close();try await wait {commit.window?.isVisible != true}
            workspace.fileComparisonPreferences=prefs
            // Completed failures retain real source rows and cannot dispatch
            // Commit; a noncooperative killed worker retains its actual lease.
            let failure=AddProgressWindowController(repository:repo,access:nil,paths:["missing"],preferences:prefs);otherOwners.append(failure)
            failure.model.execute={_ in throw Failure(description:"controlled add failure")};await failure.model.run()
            try require(!failure.model.success && failure.model.percentage==100 && failure.model.progress.rows.contains{$0.kind == .error} && !failure.model.progress.rows.contains{$0.kind == .file},"Failed Add invented successful file rows")
            var erroneousCommit=0;failure.model.onCommit={erroneousCommit += 1};failure.model.commit();try require(erroneousCommit==0,"Failed Add dispatched Commit")
            let held=AddProgressWindowController(repository:repo,access:nil,paths:["held"],preferences:prefs);otherOwners.append(held)
            var token:OperationCancellation?
            held.window?.alphaValue=0;held.showWindow(nil)
            held.model.execute={request in token=request;return try await withCheckedThrowingContinuation{heldAdd=$0}};held.model.start();try await wait {heldAdd != nil}
            let liveTable=try await fileTable(held);var runningCopy:[String]=[];held.model.progress.publishClipboard={runningCopy.append($0)}
            liveTable.keyDown(with:key(held.window!,0,"a"));liveTable.keyDown(with:key(held.window!,8,"c"))
            try require(runningCopy==["Command: Add  \r\n"] && liveTable.makeMenu()==nil,"Running progress keyboard SelectAll/Copy or idle-only context gate diverged from source")
            prefs.set(true,forKey:"ConfirmKillProcess");var answer:((Bool)->Void)?;held.model.confirmCancellation={answer=$0};held.model.cancel()
            try require(held.model.confirmingCancellation && !held.model.cancelling,"Add Kill question not owned")
            answer?(false);held.model.cancel();answer?(true);answer?(true)
            try require(token?.isCancelled==true && AddProgressWindowModel.activeOperations>0,"Add Kill reply lost held producer")
            held.close();try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed held Add lost Quit fence")
            heldAdd?.resume(throwing:OperationCancellationFailure.cancelled);heldAdd=nil;try await wait {AddProgressWindowModel.activeOperations==0 && AddProgressWindowController.activeReleases==0}
            try require(held.model.retired && !held.model.success,"Retired Add published late success")
            prefs.set(false,forKey:"ConfirmKillProcess")
            let changing=AddProgressWindowController(repository:repo,access:nil,paths:["held-mode"],preferences:prefs);otherOwners.append(changing)
            changing.model.execute={_ in "controlled initial stage"};await changing.model.run()
            var modeToken:OperationCancellation?
            changing.model.executeMode={_,request in modeToken=request;try await withCheckedThrowingContinuation{heldMode=$0}}
            let modeWork=Task{await changing.model.changeMode(.executable)};try await wait {heldMode != nil}
            changing.close();try require(modeToken?.isCancelled==true && AddProgressWindowModel.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired mode post-action released actual worker/Quit ownership")
            heldMode?.resume(throwing:OperationCancellationFailure.cancelled);heldMode=nil;await modeWork.value
            try await wait {AddProgressWindowModel.activeOperations==0 && AddProgressWindowController.activeReleases==0}
            try require(changing.model.retired && !changing.model.success,"Late mode result escaped retired owner")
            // Auto-close snapshots its policy at the actual attempt start.
            prefs.set(2,forKey:"AutoCloseGitProgress")
            let automatic=AddProgressWindowController(repository:repo,access:nil,paths:["controlled"],preferences:prefs);otherOwners.append(automatic)
            automatic.model.execute={_ in try await withCheckedThrowingContinuation{heldAdd=$0}};var autoClosed=0;automatic.model.close={autoClosed += 1};automatic.model.start();try await wait {heldAdd != nil}
            prefs.set(0,forKey:"AutoCloseGitProgress");heldAdd?.resume(returning:"controlled completion");heldAdd=nil;try await wait {!automatic.model.busy}
            try require(autoClosed==1 && automatic.model.success,"Add auto-close policy was not captured for its attempt")
            // A separate real conflicted repository supplies Resolve file rows
            // and Root-owned Commit continuation through the same source list.
            let conflictRoot=folder.appendingPathComponent("conflict");try FileManager.default.createDirectory(at:conflictRoot,withIntermediateDirectories:true)
            let conflictRepo=GitRepository(root:conflictRoot,executable:git),conflictFile=conflictRoot.appendingPathComponent("file")
            _ = try await conflictRepo.run(["init","-b","main"])
            for (name,value) in [("user.name","Resolve progress"),("user.email","resolve@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await conflictRepo.run(["config",name,value])}
            try Data("base\n".utf8).write(to:conflictFile);try await conflictRepo.stage(["file"]);_ = try await conflictRepo.commit(message:"base")
            _ = try await conflictRepo.run(["switch","-c","side"]);try Data("theirs\n".utf8).write(to:conflictFile);try await conflictRepo.stage(["file"]);_ = try await conflictRepo.commit(message:"theirs")
            _ = try await conflictRepo.run(["switch","main"]);try Data("mine\n".utf8).write(to:conflictFile);try await conflictRepo.stage(["file"]);_ = try await conflictRepo.commit(message:"mine")
            do {_ = try await conflictRepo.run(["merge","--no-edit","side"]);throw Failure(description:"Expected resolution conflict")}catch is GitFailure {}
            let conflictHead=try await conflictRepo.run(["rev-parse","HEAD"]).stdout,conflictBytes=try Data(contentsOf:conflictFile)
            workspace.open(conflictRoot);try await wait {workspace.root?.path==conflictRoot.path && !workspace.busy}
            workspace.activate(.resolve);try await wait {resolves.count==1 && !resolves[0].model.busy && resolves[0].model.entries.count==1}
            let resolve=resolves[0],resolved=resolve.model
            resolved.checked=GitPathSet(["file"]);resolved.resolveChecked();try await wait {!resolved.busy && resolved.success}
            try checkFooter(resolved.output,resolved.completionRange,resolved.progress.rows)
            try require(resolved.percentage==100 && resolved.progress.rows.contains{$0.kind == .file && $0.path=="file"},"Resolve lost completed notification")
            let resolveTable=try await fileTable(resolve);try await wait {resolveTable.numberOfRows==resolved.progress.rows.count}
            try require(resolveTable.tableColumns.map(\.title)==["Action","Path"],"Resolve native source progress table absent")
            try await capture(resolve,"resolve-completed")
            workspace.fileComparisonPreferences=otherPrefs
            var resolveClosed=0,resolveCommit=0,resolveDrained=false
            let priorClosed=resolve.onClosed,priorCommit=resolve.onCommit
            resolve.onClosed={resolveClosed += 1;priorClosed()};resolve.onCommit={resolveCommit += 1;resolveDrained=resolveClosed==1 && resolve.window?.sheetParent==nil && resolve.window?.isVisible != true && host.attachedSheet==nil;priorCommit()}
            resolve.window!.orderOut(nil);host.beginSheet(resolve.window!,completionHandler:nil)
            resolved.confirmingQuit=true;resolve.commit();try require(resolveCommit==0,"Deferred Quit allowed Resolve Commit")
            resolved.confirmingQuit=false;resolve.commit();resolve.commit();try await wait {resolveCommit==1 && resolveClosed==1 && !liveCommits().isEmpty}
            let resolvedCommit=liveCommits()[0];commits.append(resolvedCommit)
            try require(resolveDrained && resolvedCommit.presentationPreferences === prefs && resolvedCommit.model.access?.contains(conflictRoot)==true && resolvedCommit.model.access?.hasSecurityScope==true,"Resolve Commit preceded close or lost prefs/source grant")
            try require((try await conflictRepo.run(["rev-parse","HEAD"])).stdout==conflictHead && (try Data(contentsOf:conflictFile))==conflictBytes,"Resolve progress/Commit presentation committed or replaced current working contents")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && (try Data(contentsOf:root.appendingPathComponent(path)))==Data("new original\n".utf8),"Add progress/Commit presentation changed source HEAD/working bytes")
            await cleanup()
            try require(AddProgressWindowModel.activeOperations==0 && AddProgressWindowController.activeReleases==0 && ResolveWindowModel.activeOperations==0 && ResolveWindowController.activeReleases==0 && adds.allSatisfy{$0.window?.sheetParent==nil && $0.window?.attachedSheet==nil && $0.window?.isVisible != true},"File progress owners survived cleanup")
            print("PASS: Add/Resolve source Action/Path notifications, private colors/clipboard/icons, generation fences, real mode changes, Kill/autoclose policies, actual-close-before-Commit once with Root-captured preferences/scopes/appearance and owned worker/Quit drain")
        } catch {await cleanup();throw error}
    }
}
