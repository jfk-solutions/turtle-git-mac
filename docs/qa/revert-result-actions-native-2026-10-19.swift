// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

@MainActor enum RevertResultActionsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    // Reconstruct the immutable value snapshot without changing the real
    // coordinator, state object, owner callbacks or presentation policy.
    static func availabilitySnapshot(_ value:FileOperationProgressTable,available:Bool,keyboardAvailable:Bool)->FileOperationProgressTable {
        FileOperationProgressTable(state:value.state,icon:value.icon,available:available,repository:value.repository,
            keyboardAvailable:keyboardAvailable,fileRowIcons:value.fileRowIcons,backgroundIcon:value.backgroundIcon,
            actionAvailability:value.actionAvailability,keyboardAvailability:value.keyboardAvailability,
            performRow:value.performRow,perform:value.perform)
    }
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Revert result timeout at \(line)")
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return[view]+view.subviews.flatMap{views($0)}}
    static func drain()async throws {
        try await wait {
            RevertProgressWindowModel.activeOperations==0 && RevertProgressWindowController.activeReleases==0 &&
            RevertWindowModel.activeOperations==0 && LogWindowModel.activeHistoryLoads==0 &&
            NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
        }
    }
    static func table(_ owner:RevertProgressWindowController)async throws->FileOperationProgressNativeTable {
        try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return views(owner.window?.contentView).contains{$0 is FileOperationProgressNativeTable}}
        return views(owner.window?.contentView).compactMap{$0 as? FileOperationProgressNativeTable}.first!
    }
    static func coordinator(_ table:FileOperationProgressNativeTable)throws->FileOperationProgressTable.Coordinator {
        guard let value=NativeListSelection.originalDelegate(of:table) as? FileOperationProgressTable.Coordinator else {throw Failure(description:"Actual shared Revert table coordinator missing")};return value
    }
    static func select(_ table:FileOperationProgressNativeTable,path:String)async throws {
        let source=try coordinator(table)
        try await wait {table.numberOfRows==source.rows.count && source.rows.contains{$0.kind == .file && GitReferenceName.equal($0.path,path)}}
        let index=source.rows.firstIndex{$0.kind == .file && GitReferenceName.equal($0.path,path)}!
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
    }
    static func menu(_ table:FileOperationProgressNativeTable,line:Int = #line)throws->NSMenu {guard let menu=table.makeMenu() else {let source=try coordinator(table);throw Failure(description:"Native completed Revert popup missing at \(line); selected=\(table.selectedRowIndexes) available=\(source.parent.available) dynamic=\(String(describing:source.parent.actionAvailability?())) rows=\(source.rows.count)")};return menu}
    static func item(_ menu:NSMenu,_ title:String)throws->NSMenuItem {guard let item=menu.items.first(where:{$0.title==title}) else{throw Failure(description:"Missing Revert result action "+title)};return item}
    static func invoke(_ item:NSMenuItem) {if let action=item.action {_ = NSApp.sendAction(action,to:item.target,from:item)}}
    static func key(_ window:NSWindow,_ text:String)->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:text=="c" ? 8:0)!}
    static func doubleClick(_ table:FileOperationProgressNativeTable,row:Int)throws {
        guard let action=table.doubleAction,let target=table.target,
              let getter=class_getInstanceMethod(NSTableView.self,#selector(getter:NSTableView.clickedRow)) else {throw Failure(description:"Native result double action missing")}
        // Offscreen windows cannot receive a physical mouse sequence. Inject
        // its captured row while dispatching the actual AppKit target/action.
        let original=method_getImplementation(getter)
        let implementation=imp_implementationWithBlock(unsafeBitCast({ (_:AnyObject)->Int in row } as @convention(block)(AnyObject)->Int,to:AnyObject.self))
        method_setImplementation(getter,implementation)
        defer{method_setImplementation(getter,original);imp_removeBlock(implementation)}
        try require(NSApp.sendAction(action,to:target,from:table),"Native result double action did not dispatch")
    }
    static func capture(_ window:NSWindow)async throws {
        guard let value=ProcessInfo.processInfo.environment["TURTLEGIT_REVERT_RESULT_CAPTURES"],let view=window.contentView else{return}
        let directory=URL(fileURLWithPath:value);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let old=window.appearance;defer{window.appearance=old}
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);view.needsDisplay=true;view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Missing actual Revert content bitmap")}
            window.effectiveAppearance.performAsCurrentDrawingAppearance {view.cacheDisplay(in:view.bounds,to:bitmap)}
            guard let original=bitmap.cgImage,let context=CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,bytesPerRow:original.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw Failure(description:"Missing opaque Revert capture surface")}
            var background=NSColor.windowBackgroundColor
            window.effectiveAppearance.performAsCurrentDrawingAppearance {background=NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor}
            context.setFillColor(background.cgColor);context.fill(CGRect(x:0,y:0,width:original.width,height:original.height));context.setBlendMode(.normal);context.draw(original,in:CGRect(x:0,y:0,width:original.width,height:original.height))
            guard let image=context.makeImage(),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw Failure(description:"Missing actual Revert PNG")}
            try png.write(to:directory.appendingPathComponent("revert-completed-results-"+name+".png"))
        }
    }
    static func verify()async throws {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),root=folder.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Revert result QA"),("user.email","results@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let first="file 雪 [*].txt",second="z-other.txt"
        for path in [first,second] {try Data(("base "+path+"\n").utf8).write(to:root.appendingPathComponent(path))}
        try await repo.stage([first,second]);_ = try await repo.commit(message:"baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["ls-files","--stage","-z"]).stdout
        let suite="TurtleGit.RevertResults."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(true,forKey:"ShowContextMenuIcons")
        ProgressActionLog.install(store:ActionLogStore(storageURL:folder.appendingPathComponent("actions.log")),preferences:prefs);DialogGeometry.install(preferences:prefs)
        var parents:[RevertWindowController]=[],owners:[RevertProgressWindowController]=[],auxiliaryWindows:[NSWindow]=[]
        var readReleases:[URL]=[]
        var heldOpen:CheckedContinuation<Void,Error>?,heldPanelReply:((NSApplication.ModalResponse)->Void)?,heldPanel:NSOpenPanel?
        func cleanup()async throws {
            for release in readReleases {try? Data().write(to:release)}
            heldOpen?.resume(throwing:OperationCancellationFailure.cancelled);heldOpen=nil
            heldPanelReply?(.cancel);heldPanelReply=nil;heldPanel?.cancel(nil);heldPanel=nil
            for owner in owners {owner.close()};for parent in parents {parent.close()};for window in auxiliaryWindows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
            try await drain()
            for owner in owners {for copy in owner.model.trashedFiles {try? FileManager.default.removeItem(at:copy)}}
        }
        func gitlinkResult(_ name:String)async throws->(RevertProgressWindowController,String) {
            let location=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
            let repository=GitRepository(root:location,executable:git);_ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Gitlink result QA"),("user.email","gitlink@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repository.run(["config",key,value])}
            try Data("one\n".utf8).write(to:location.appendingPathComponent("anchor"));try await repository.stage(["anchor"]);_ = try await repository.commit(message:"first")
            let firstHash=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try Data("two\n".utf8).write(to:location.appendingPathComponent("anchor"));try await repository.stage(["anchor"]);_ = try await repository.commit(message:"second")
            let secondHash=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            _ = try await repository.run(["update-index","--add","--cacheinfo","160000,"+firstHash+",module"]);_ = try await repository.commit(message:"gitlink baseline")
            let revision=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            _ = try await repository.run(["update-index","--cacheinfo","160000,"+secondHash+",module"])
            try FileManager.default.createDirectory(at:location.appendingPathComponent("module"),withIntermediateDirectories:true)
            let selected=try await repository.status().filter{$0.path=="module"}
            try require(selected.count==1,"Private gitlink changed status missing")
            let owner=RevertProgressWindowController(repository:repository,access:nil,entries:selected,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs);owners.append(owner);owner.showWindow(nil);owner.model.start()
            try await wait {!owner.model.busy && owner.model.submodulePaths==["module"]}
            try require(!owner.model.failed,"Actual gitlink Revert failed")
            return(owner,revision)
        }
        defer{clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        do {
            for path in [first,second] {try Data(("draft "+path+"\n").utf8).write(to:root.appendingPathComponent(path))}
            let parent=RevertWindowController(repository:repo,access:nil,preferences:prefs);parents.append(parent);parent.window?.alphaValue=0;parent.showWindow(nil);parent.model.setScope([first,second])
            try await wait {!parent.model.busy && parent.model.entries.count==2}
            var logs:[String]=[];parent.model.onFileLog={logs.append($0)}
            parent.model.onRevert(parent.model.entries)
            try await wait {parent.revertProgress != nil && parent.revertProgress?.model.busy==false}
            let owner=parent.revertProgress!;owners.append(owner);let model=owner.model,native=try await table(owner),source=try coordinator(native)
            try require(!model.failed && !model.cancelled && model.preferences === prefs && model.progress.preferences === prefs,"Completed Revert lost success/private preferences")
            for path in [first,second] {try require(Data(contentsOf:root.appendingPathComponent(path))==Data(("base "+path+"\n").utf8),"Actual Revert failed to restore "+path)}
            try require(native.tableColumns.map(\.title)==["Action","Path"],"Revert notification columns diverged")
            model.progress.publishClipboard={text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            try await select(native,path:first)
            // Freeze only the representable's value snapshots at the previous
            // busy state, reproducing the hosted SDK's delayed updateNSView.
            // All commands still traverse the actual native table/coordinator
            // and the real model's live admission; no asynchronous wait hides
            // stale-false or stale-true behavior.
            let valueSnapshot=source.parent
            source.parent=availabilitySnapshot(source.parent,available:false,keyboardAvailable:false)
            let liveMenu=try menu(native),retainedBlocked=try item(liveMenu,"Show Log")
            invoke(try item(liveMenu,"Copy to Clipboard"))
            try require(clipboard.string(forType:.string)==first,"Live completed popup was blocked by an old busy snapshot")
            native.keyDown(with:key(owner.window!,"c"))
            let liveRow=source.rows[native.selectedRow]
            try require(clipboard.string(forType:.string)==liveRow.action+": "+first+"  \r\n","Live keyboard Copy was blocked by an old busy snapshot")
            source.parent=availabilitySnapshot(source.parent,available:true,keyboardAvailable:true)
            model.confirmingQuit=true
            try require(native.makeMenu()==nil,"Stale enabled snapshot admitted a Quit-blocked popup")
            clipboard.clearContents();clipboard.setString("blocked-copy-witness",forType:.string)
            native.keyDown(with:key(owner.window!,"c"));invoke(retainedBlocked)
            try require(clipboard.string(forType:.string)=="blocked-copy-witness" && logs.isEmpty,"Stale enabled snapshot dispatched a blocked command")
            model.confirmingQuit=false;invoke(retainedBlocked)
            try require(logs.isEmpty,"Rejected once-only popup revived after Quit cancellation")
            // Static-only consumers retain their independent keyboard policy:
            // running output may be copied while file actions stay disabled.
            source.parent.actionAvailability=nil;source.parent.keyboardAvailability=nil
            source.parent=availabilitySnapshot(source.parent,available:false,keyboardAvailable:true)
            try require(native.makeMenu()==nil,"Static disabled action fallback was ignored")
            native.keyDown(with:key(owner.window!,"c"))
            try require(clipboard.string(forType:.string)==liveRow.action+": "+first+"  \r\n","Independent static keyboard fallback was lost")
            source.parent=availabilitySnapshot(source.parent,available:true,keyboardAvailable:false)
            try require(native.makeMenu() != nil,"Static enabled action fallback was ignored")
            clipboard.clearContents();clipboard.setString("static-keyboard-witness",forType:.string)
            native.keyDown(with:key(owner.window!,"c"))
            try require(clipboard.string(forType:.string)=="static-keyboard-witness","Static disabled keyboard fallback was ignored")
            source.parent=valueSnapshot
            let firstMenu=try menu(native),captions=firstMenu.items.filter{!$0.isSeparatorItem}.map(\.title)
            try require(captions==["Show Log","Open","Open With","Explore to","Copy to Clipboard"],"Completed Revert file popup differs: \(captions)")
            try require(firstMenu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Revert result source icons missing")
            try await capture(owner.window!)
            let copy=try item(firstMenu,"Copy to Clipboard");invoke(copy);try require(clipboard.string(forType:.string)==first,"Context copy included action/output or lost literal path")
            let log=try item(firstMenu,"Show Log");invoke(log);invoke(log);try require(logs==[first],"Actual Revert-owner Log wiring lost one-shot captured path")
            let selected=source.rows[native.selectedRow],commandText=selected.action+": "+first+"  \r\n"
            native.keyDown(with:key(owner.window!,"c"));try require(clipboard.string(forType:.string)==commandText,"Keyboard Copy lost source Action: Path format")
            model.copyOutput();try require(clipboard.string(forType:.string)==model.clipboardOutput,"Whole-output Copy was replaced by selected-row Copy")
            native.keyDown(with:key(owner.window!,"a"));try require(native.selectedRowIndexes.count==source.rows.count,"Command-A did not select actual notification rows")
            try await select(native,path:first)
            var opened:[URL]=[],revealed:[[URL]]=[]
            owner.progressFiles.open={url,_ in opened.append(url)};owner.progressFiles.reveal={revealed.append($0)}
            let openItem=try item(try menu(native),"Open");invoke(openItem);try await wait {!owner.progressFiles.busy && opened.count==1}
            try require(opened[0].path==root.appendingPathComponent(first).path,"Open used display text instead of captured path")
            invoke(try item(try menu(native),"Explore to"));try await wait {!owner.progressFiles.busy && !revealed.isEmpty};try require(revealed.last?.map(\.path)==[root.appendingPathComponent(first).path],"Explore lost exact working file")
            let openCount=opened.count
            try doubleClick(native,row:native.selectedRow);try await wait {!owner.progressFiles.busy && opened.count==openCount+1}
            // Source sorting is disabled while running and orders completed file
            // rows; Copy follows the actual sorted selection, not model indices.
            native.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)];source.tableView(native,sortDescriptorsDidChange:[])
            let displayed=source.rows.filter{$0.kind == .file}.map(\.path)
            try require(displayed==displayed.sorted(by:{$0.compare($1,options:.literal) == .orderedDescending}),"Completed Revert Path sort ignored")
            let fileIndices=IndexSet(source.rows.indices.filter{source.rows[$0].kind == .file});native.selectRowIndexes(fileIndices,byExtendingSelection:false)
            let multi=try menu(native);try require(multi.items.filter{!$0.isSeparatorItem}.map(\.title)==["Copy to Clipboard"],"Multi-result popup exposed single-file launch")
            invoke(try item(multi,"Copy to Clipboard"));try require(clipboard.string(forType:.string)==displayed.joined(separator:"\r\n"),"Sorted selected-path Copy changed source order")
            // A popup captured before selection-away/return cannot act on a
            // different result. A busy/quit owner also cannot dispatch it.
            try await select(native,path:first);let staleSelection=try item(try menu(native),"Show Log")
            try await select(native,path:second);try await select(native,path:first);invoke(staleSelection);try require(logs==[first],"Selection replacement revived old result action")
            let staleBusy=try item(try menu(native),"Open");model.confirmingQuit=true;invoke(staleBusy);try require(opened.count==openCount+1,"Quit-deferred result dispatched Open");model.confirmingQuit=false
            // Completed notifications can outlive their disk items. Directory
            // Open reveals that directory; missing Explore opens an existing
            // parent, while explicit Open must never silently open the parent.
            let directory=root.appendingPathComponent("nested");try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            model.progress.append("Revert","nested",kind:.file);try await select(native,path:"nested")
            let directoryMenu=try menu(native)
            try require(directoryMenu.items.filter{!$0.isSeparatorItem}.map(\.title)==["Show Log","Explore to","Copy to Clipboard"],"Directory result exposed file application commands")
            let revealCount=revealed.count;try doubleClick(native,row:native.selectedRow);try await wait {!owner.progressFiles.busy && revealed.count==revealCount+1}
            try require(revealed.last?.map(\.path)==[directory.path],"Directory double-click did not reveal directory")
            let missing="nested/vanished/file.txt";model.progress.append("Revert",missing,kind:.file);try await select(native,path:missing)
            var errors:[String]=[];let originalError=owner.progressFiles.onError;owner.progressFiles.onError={errors.append($0);originalError($0)}
            let beforeMissingOpen=opened.count;invoke(try item(try menu(native),"Open"));try await wait {!owner.progressFiles.busy && !errors.isEmpty}
            try require(opened.count==beforeMissingOpen,"Missing file Open silently launched a parent directory")
            invoke(try item(try menu(native),"Explore to"));try await wait {!owner.progressFiles.busy && opened.count==beforeMissingOpen+1}
            try require(opened.last?.path==directory.path,"Missing Explore lost nearest existing parent")
            // A leaf symlink retains its selected Git spelling and may open its
            // regular target. Escaping parent symlinks cannot authorize paths.
            let outside=folder.appendingPathComponent("outside");try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
            let externalFile=outside.appendingPathComponent("target.txt");try Data("external target\n".utf8).write(to:externalFile)
            let leaf=root.appendingPathComponent("leaf-link");try FileManager.default.createSymbolicLink(at:leaf,withDestinationURL:externalFile)
            model.progress.append("Revert","leaf-link",kind:.file);try await select(native,path:"leaf-link")
            let beforeLeaf=opened.count;invoke(try item(try menu(native),"Open"));try await wait {!owner.progressFiles.busy && opened.count==beforeLeaf+1}
            try require(opened.last?.path==leaf.path,"Leaf symlink Open discarded literal selected path")
            let escape=root.appendingPathComponent("escape");try FileManager.default.createSymbolicLink(at:escape,withDestinationURL:outside)
            model.progress.append("Revert","escape/target.txt",kind:.file);try await select(native,path:"escape/target.txt")
            let beforeEscape=opened.count,errorCount=errors.count
            invoke(try item(try menu(native),"Open"));try await wait {!owner.progressFiles.busy && errors.count==errorCount+1}
            try require(opened.count==beforeEscape,"Escaping parent symlink launched external path")
            let beforeEscapeReveal=revealed.count;invoke(try item(try menu(native),"Explore to"));try await wait {!owner.progressFiles.busy && errors.count==errorCount+2}
            try require(revealed.count==beforeEscapeReveal,"Escaping parent symlink was revealed")
            try await select(native,path:first)
            // Actual Open With sheet is owned, blocks close and drains on Cancel.
            owner.progressFiles.chooseApplication={panel,window,reply in heldPanel=panel;heldPanelReply=reply;window.beginSheet(panel,completionHandler:reply)}
            invoke(try item(try menu(native),"Open With"));try await wait {heldPanel != nil && owner.progressFiles.busy && owner.window?.attachedSheet === heldPanel}
            try require(!owner.windowShouldClose(owner.window!),"Pending application picker allowed result closure")
            owner.window?.endSheet(heldPanel!,returnCode:.cancel);try await wait {!owner.progressFiles.busy && owner.window?.attachedSheet==nil};heldPanelReply=nil;heldPanel=nil
            let afterPathActions=opened.count
            try require(afterPathActions==beforeEscape,"Cancelled Open With launched a file")
            // Accepting a picker after another process replaces the disk item
            // must reject the stale target rather than launch different bytes.
            let application=folder.appendingPathComponent("Private Viewer.app");try FileManager.default.createDirectory(at:application,withIntermediateDirectories:true)
            owner.progressFiles.selectedApplication={_ in application}
            invoke(try item(try menu(native),"Open With"));try await wait {heldPanel != nil && owner.progressFiles.busy}
            let displaced=root.appendingPathComponent("displaced-original");try FileManager.default.moveItem(at:root.appendingPathComponent(first),to:displaced)
            try Data("replacement target\n".utf8).write(to:root.appendingPathComponent(first))
            let beforeReplacementError=errors.count
            owner.window?.endSheet(heldPanel!,returnCode:.OK);try await wait {!owner.progressFiles.busy && errors.count==beforeReplacementError+1};heldPanelReply=nil;heldPanel=nil
            try require(opened.count==afterPathActions,"Open With accepted a replaced target")
            try FileManager.default.removeItem(at:root.appendingPathComponent(first));try FileManager.default.moveItem(at:displaced,to:root.appendingPathComponent(first))
            let retired=try item(try menu(native),"Show Log");owner.close();try await wait {model.retired && RevertProgressWindowController.activeReleases==0};invoke(retired);try require(logs==[first],"Retired result popup opened Log")
            parent.close()
            // Failed-attempt receipts cannot survive a fresh real Retry. The
            // foreign lock prevents side effects before the result is replaced.
            try Data("another draft\n".utf8).write(to:root.appendingPathComponent(first))
            let selection=try await repo.status().filter{$0.path==first},retry=RevertProgressWindowController(repository:repo,access:nil,entries:selection,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs)
            owners.append(retry);retry.showWindow(nil)
            let lock=root.appendingPathComponent(".git/index.lock");try Data("foreign".utf8).write(to:lock);retry.model.start();try await wait {!retry.model.busy}
            try require(retry.model.failed,"Foreign lock did not produce retained failed result")
            let retryTable=try await table(retry);retry.model.progress.append("Revert",first,kind:.file);try await select(retryTable,path:first)
            var retryLogs:[String]=[];retry.onProgressLog={retryLogs.append($0)}
            let oldAttempt=try item(try menu(retryTable),"Show Log")
            retryTable.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)]
            try FileManager.default.removeItem(at:lock);retry.model.retry();try await wait {!retry.model.busy && !retry.model.failed};invoke(oldAttempt)
            try require(retryLogs.isEmpty,"Fresh Retry revived an earlier result action")
            try await wait {retryTable.sortDescriptors.isEmpty};try require(retryTable.selectedRowIndexes.isEmpty,"Fresh Retry retained previous result selection")
            try await select(retryTable,path:first)
            // Outstanding async file launch retains the owner, blocks Quit and
            // is drained even when forced retirement precedes its completion.
            retry.progressFiles.open={_,_ in try await withCheckedThrowingContinuation{heldOpen=$0}}
            invoke(try item(try menu(retryTable),"Open"));try await wait {heldOpen != nil && retry.model.fileActionBusy}
            try require(!retry.windowShouldClose(retry.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Async result launch lost close/Quit ownership")
            retry.close();try require(retry.model.retired && RevertProgressWindowController.activeReleases>0,"Forced close lost outstanding launch lifetime")
            heldOpen?.resume(returning:());heldOpen=nil;try await wait {RevertProgressWindowController.activeReleases==0 && !retry.progressFiles.busy}
            // A real held Core preflight cannot create a late Open With sheet
            // after its owner retires. Releasing the owned Git wrapper is part
            // of cleanup on both success and failure.
            let wrapper=folder.appendingPathComponent("held-preflight-git"),readMarker=root.appendingPathComponent(".git/read-ready"),readRelease=root.appendingPathComponent(".git/read-release"),readGate=root.appendingPathComponent(".git/hold-read")
            readReleases.append(readRelease)
            let script=#"""
            #!/bin/sh
            if [ "$4" = rev-parse ] && [ "$5" = --is-bare-repository ] && [ -f "$3/.git/hold-read" ];then
              : > "$3/.git/read-ready"
              while [ ! -f "$3/.git/read-release" ];do /bin/sleep 0.02;done
            fi
            exec "$TURTLEGIT_REVERT_RESULT_GIT" "$@"
            """#
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            setenv("TURTLEGIT_REVERT_RESULT_GIT",git.path,1);defer{unsetenv("TURTLEGIT_REVERT_RESULT_GIT")}
            let heldRepository=GitRepository(root:root,executable:wrapper)
            let clean=try await heldRepository.workingFileRevertSelection(selection)
            let heldOwner=RevertProgressWindowController(repository:heldRepository,access:nil,entries:clean,amend:false,againstHead:false,autoCloseSuccess:false,preferences:prefs);owners.append(heldOwner);heldOwner.showWindow(nil);heldOwner.model.start()
            try await wait {!heldOwner.model.busy};try require(!heldOwner.model.failed,"Private held-preflight baseline Revert failed")
            let heldTable=try await table(heldOwner);try await select(heldTable,path:first)
            var latePickers=0,lateLaunches=0;heldOwner.progressFiles.chooseApplication={_,_,reply in latePickers += 1;reply(.cancel)};heldOwner.progressFiles.open={_,_ in lateLaunches += 1}
            try Data().write(to:readGate);invoke(try item(try menu(heldTable),"Open With"))
            try await wait {FileManager.default.fileExists(atPath:readMarker.path) && heldOwner.progressFiles.busy}
            try require(!heldOwner.windowShouldClose(heldOwner.window!),"Held Core preflight allowed ordinary closure")
            heldOwner.close();try require(heldOwner.model.retired && RevertProgressWindowController.activeReleases>0,"Retirement dropped pending preflight ownership")
            try Data().write(to:readRelease);try await wait {!heldOwner.progressFiles.busy && RevertProgressWindowController.activeReleases==0}
            try require(latePickers==0 && lateLaunches==0 && heldOwner.window?.attachedSheet==nil,"Retired preflight opened a late application picker/launch")
            try FileManager.default.removeItem(at:readGate)
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try await repo.run(["ls-files","--stage","-z"]).stdout
            try require(finalHead==head && finalIndex==index,"Result interactions or Revert changed HEAD/index entries")
            // Actual gitlink results keep the source post-action but drain
            // their owning sheet before invoking it, once, with captured refs.
            let (handoff,revision)=try await gitlinkResult("gitlink-handoff")
            let host=NSWindow(contentRect:.init(x:-12000,y:-12000,width:700,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;auxiliaryWindows.append(host);host.orderFront(nil)
            handoff.window!.orderOut(nil);host.beginSheet(handoff.window!,completionHandler:nil)
            var handoffs:[(String,[String])]=[],closed=0,drained=false
            handoff.onClosed={closed += 1};handoff.model.onHandleSubmodules={hash,paths in handoffs.append((hash,paths));drained=closed==1 && handoff.window?.sheetParent==nil && host.attachedSheet==nil && handoff.window?.isVisible != true}
            handoff.model.handleSubmodules();handoff.model.handleSubmodules()
            try await wait {handoffs.count==1 && RevertProgressWindowController.activeReleases==0}
            try require(handoffs[0].0==revision && handoffs[0].1==["module"] && drained,"Gitlink post-action lost captured refs or ran before owner detach")
            let (blocked,_)=try await gitlinkResult("gitlink-blocked"),sheet=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:[.titled],backing:.buffered,defer:false)
            sheet.isReleasedWhenClosed=false;auxiliaryWindows.append(sheet);blocked.window!.beginSheet(sheet,completionHandler:nil)
            var blockedCallbacks=0;blocked.model.onHandleSubmodules={_,_ in blockedCallbacks += 1}
            blocked.model.handleSubmodules();try require(blockedCallbacks==0 && !blocked.model.retired,"Attached sheet allowed gitlink handoff")
            blocked.window!.endSheet(sheet,returnCode:.cancel);sheet.close();try await wait {blocked.window?.attachedSheet==nil && sheet.sheetParent==nil}
            blocked.model.confirmingQuit=true;blocked.model.handleSubmodules();try require(blockedCallbacks==0 && !blocked.model.retired,"Deferred Quit allowed gitlink handoff")
            blocked.model.confirmingQuit=false;blocked.close();blocked.model.handleSubmodules();try await wait {RevertProgressWindowController.activeReleases==0}
            try require(blockedCallbacks==0,"Forced-close gitlink result dispatched stale post-action")
            let (lateQuit,_)=try await gitlinkResult("gitlink-late-quit");var lateCallbacks=0;lateQuit.model.onHandleSubmodules={_,_ in lateCallbacks += 1}
            lateQuit.model.handleSubmodules();lateQuit.model.confirmingQuit=true
            try await wait {RevertProgressWindowController.activeReleases==0}
            try require(lateCallbacks==0,"Quit deferred during sheet drain revived gitlink handoff")
            try await cleanup()
        } catch {
            let failure=error
            do {try await cleanup()} catch {throw Failure(description:"\(failure); cleanup also failed: \(error)")}
            throw failure
        }
    }
}
