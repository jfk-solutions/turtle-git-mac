// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitRemoteNotificationOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitRemoteNotificationOrder(place,relativeTo:number)
    }
}
@MainActor @main enum RemoteProgressNotificationsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Remote notification timeout at \(line)")
    }
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func table(_ window:NSWindow)async throws->FileOperationProgressNativeTable {
        try await wait {window.contentView?.layoutSubtreeIfNeeded();return views(window.contentView).contains{$0 is FileOperationProgressNativeTable}}
        let result=views(window.contentView).compactMap{$0 as? FileOperationProgressNativeTable}.first!
        try await wait {guard let source=result.delegate as? FileOperationProgressTable.Coordinator else{return false};return result.numberOfRows==source.rows.count}
        return result
    }
    static func verifyViewport(_ table:FileOperationProgressNativeTable,minimumRows:Int)throws {
        guard let scroll=table.enclosingScrollView else {throw Failure(description:"Notification scroll view missing")}
        scroll.window?.contentView?.layoutSubtreeIfNeeded()
        try require(scroll.contentView.bounds.height >= table.rowHeight*CGFloat(minimumRows),"Notification viewport hides result rows: \(scroll.contentView.bounds.height)")
        try require(scroll.contentView.bounds.width >= 500,"Notification viewport is too narrow for Action/Path")
        try require(table.backdropRect(in:NSRect(x:0,y:0,width:500,height:80)) == nil,"Short list clips artwork through header")
        try require(table.backdropRect(in:NSRect(x:20,y:70,width:500,height:240)) == NSRect(x:392,y:182,width:128,height:128),"Full-size list watermark lost viewport anchoring")
    }
    static func coordinator(_ table:FileOperationProgressNativeTable)throws->FileOperationProgressTable.Coordinator {
        guard let value=table.delegate as? FileOperationProgressTable.Coordinator else {throw Failure(description:"Actual notification coordinator missing")};return value
    }
    static func select(_ table:FileOperationProgressNativeTable,_ predicate:(FileOperationProgressRow)->Bool)throws->FileOperationProgressRow {
        let source=try coordinator(table),rows=source.rows
        guard let index=rows.firstIndex(where:predicate) else {throw Failure(description:"Expected typed notification row missing")}
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);return rows[index]
    }
    static func menu(_ table:FileOperationProgressNativeTable)throws->NSMenu {guard let value=table.makeMenu() else {throw Failure(description:"Completed notification menu missing")};return value}
    static func item(_ menu:NSMenu,_ title:String)throws->NSMenuItem {guard let value=menu.items.first(where:{$0.title==title}) else {throw Failure(description:"Missing notification action "+title)};return value}
    static func invoke(_ item:NSMenuItem) {if let action=item.action {_ = NSApp.sendAction(action,to:item.target,from:item)}}
    static func doubleClick(_ table:FileOperationProgressNativeTable,row:Int)throws {
        guard let action=table.doubleAction,let target=table.target,let getter=class_getInstanceMethod(NSTableView.self,#selector(getter:NSTableView.clickedRow)) else {throw Failure(description:"Double-click target missing")}
        let original=method_getImplementation(getter)
        let replacement=imp_implementationWithBlock(unsafeBitCast({(_:AnyObject)->Int in row} as @convention(block)(AnyObject)->Int,to:AnyObject.self))
        method_setImplementation(getter,replacement);defer {method_setImplementation(getter,original);imp_removeBlock(replacement)}
        try require(NSApp.sendAction(action,to:target,from:table),"Double-click dispatch failed")
    }
    static func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
    static func capture(_ window:NSWindow,name:String)async throws {
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_NOTIFICATION_CAPTURES"],let view=window.contentView else{return}
        let folder=URL(fileURLWithPath:directory);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let previous=window.appearance;defer{window.appearance=previous}
        try await Task.sleep(nanoseconds:600_000_000)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);view.needsDisplay=true;view.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw Failure(description:"Missing actual remote notification bitmap")}
            window.effectiveAppearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
            guard let original=bitmap.cgImage,let context=CGContext(data:nil,width:original.width,height:original.height,bitsPerComponent:8,bytesPerRow:original.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else {throw Failure(description:"Missing opaque notification capture")}
            var background=NSColor.windowBackgroundColor
            window.effectiveAppearance.performAsCurrentDrawingAppearance{background=NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .windowBackgroundColor}
            context.setFillColor(background.cgColor);context.fill(CGRect(x:0,y:0,width:original.width,height:original.height));context.setBlendMode(.normal);context.draw(original,in:CGRect(x:0,y:0,width:original.width,height:original.height))
            guard let image=context.makeImage(),let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw Failure(description:"Notification PNG unavailable")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor final class Fixture {
        let root:URL,git:URL,source:GitRepository,preferences:UserDefaults,suite:String,lease:RepositoryAccessLease
        let clipboard=NSPasteboard.withUniqueName()
        var clones:[CloneProgressWindowController]=[],fetches:[FetchProgressWindowController]=[]
        var releases:[URL]=[]
        var replies:[(NSApplication.ModalResponse)->Void]=[]
        var pendingLaunch:CheckedContinuation<Void,Error>?
        var backend:GitLibGit2Configuration {.init(mask:6,helperURL:ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_NOTIFICATION_HELPER"].map{URL(fileURLWithPath:$0)})}
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;source=GitRepository(root:root.appendingPathComponent("source 雪"),executable:git)
            suite="TurtleGit.RemoteNotifications."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!;lease=RepositoryAccessLease(url:root)
            preferences.set(0,forKey:"AutoCloseGitProgress");preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(true,forKey:"ShowContextMenuIcons")
            ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("actions.log")),preferences:preferences);DialogGeometry.install(preferences:preferences)
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:source.root,withIntermediateDirectories:true)
            _ = try await source.run(["init","-b","main"])
            for (key,value) in [("user.name","Remote notification QA"),("user.email","notifications@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await source.run(["config",key,value])}
            try await commit("base")
        }
        func commit(_ text:String)async throws {try Data((text+"\n").utf8).write(to:source.root.appendingPathComponent("file 雪.txt"));try await source.stage(["file 雪.txt"]);_ = try await source.commit(message:text)}
        func clone(_ name:String,backend:GitLibGit2Configuration,recursive:Bool=false)->CloneProgressWindowController {
            var options=CloneOptions();options.source=source.root.path;options.recursive=recursive
            let model=CloneProgressWindowModel(options:options,destination:root.appendingPathComponent(name),executable:git,destinationAccess:lease,sourceAccess:lease,keyAccess:nil,preferences:preferences,backend:backend)
            model.notifications.publishClipboard={ [clipboard] text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            let owner=CloneProgressWindowController(model:model);clones.append(owner);owner.showWindow(nil);model.start();return owner
        }
        func fetch(_ repo:GitRepository,options:FetchOptions,backend:GitLibGit2Configuration)->FetchProgressWindowController {
            let model=FetchProgressWindowModel(repository:repo,access:lease,options:options,preferences:preferences,backend:backend)
            model.notifications.publishClipboard={ [clipboard] text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            let owner=FetchProgressWindowController(model:model);fetches.append(owner);owner.showWindow(nil);model.start();return owner
        }
        func cleanup()async throws {
            for release in releases {try? Data().write(to:release)}
            pendingLaunch?.resume(throwing:OperationCancellationFailure.cancelled);pendingLaunch=nil
            for reply in replies {reply(.cancel)};replies=[]
            for owner in clones {owner.window?.close()};for owner in fetches {owner.window?.close()}
            for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.close()}
            try await RemoteProgressNotificationsVerification.wait {
                CloneProgressWindowModel.activeOperations==0 && CloneProgressWindowController.activeReleases==0 && FetchProgressWindowModel.activeOperations==0 && FetchWindowController.activeProgressReleases==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}
            }
            preferences.removePersistentDomain(forName:suite);preferences.synchronize();clipboard.releaseGlobally()
        }
    }
    static func verifyClone(_ f:Fixture)async throws {
        let backend=f.backend
        let child=f.root.appendingPathComponent("child"),childRepo=GitRepository(root:child,executable:f.git)
        try FileManager.default.createDirectory(at:child,withIntermediateDirectories:true);_ = try await childRepo.run(["init","-b","main"])
        for (key,value) in [("user.name","Child QA"),("user.email","child@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await childRepo.run(["config",key,value])}
        try Data("child bytes\n".utf8).write(to:child.appendingPathComponent("file 雪.txt"));try await childRepo.stage(["file 雪.txt"]);_ = try await childRepo.commit(message:"child")
        _ = try await f.source.run(["-c","protocol.file.allow=always","submodule","add","--",child.path,"module 雪"]);_ = try await f.source.commit(message:"submodule")
        let beforeHead=try await f.source.run(["rev-parse","HEAD"]).stdout,beforeIndex=try Data(contentsOf:f.source.root.appendingPathComponent(".git/index"))
        let owner=f.clone("recursive clone",backend:backend,recursive:true);try await wait {!owner.model.busy && !owner.model.hasPendingWork}
        try require(owner.model.success && owner.model.showsNotifications,"Opt-in Clone did not use notification family")
        let table=try await Self.table(owner.window!),source=try coordinator(table)
        try verifyViewport(table,minimumRows:6)
        try await capture(owner.window!,name:"clone-reference-checkout-results")
        let childRow=try select(table){$0.kind == .file && $0.repositoryPath=="module 雪" && $0.filePath=="file 雪.txt"}
        var logs:[(String,[String],String?,String?)]=[],opened:[URL]=[]
        owner.model.onNotificationLog={repo,_,paths,old,new in logs.append((repo.root.path,paths,old,new))}
        owner.notificationFiles.configure={files in files.open={url,_ in opened.append(url)};files.reveal={opened += $0}}
        let menu=try Self.menu(table);try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Notification menu icons missing")
        invoke(try item(menu,"Show Log"));try require(logs.count==1 && logs[0].0==owner.model.destination.appendingPathComponent("module 雪").path && logs[0].1==["file 雪.txt"],"Recursive checkout Log lost producing repository/path")
        invoke(try item(try Self.menu(table),"Open"));try await wait {!owner.notificationFiles.busy}
        try require(opened.last?.path==owner.model.destination.appendingPathComponent("module 雪/file 雪.txt").path,"Recursive checkout Open targeted superproject")
        invoke(try item(try Self.menu(table),"Copy to Clipboard"));try require(f.clipboard.string(forType:.string)==childRow.path,"Context Copy did not use displayed path")
        table.copySelection();try require(f.clipboard.string(forType:.string)==childRow.action+": "+childRow.path+"  \r\n","Keyboard Copy lost action/path")
        table.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)]
        try require(source.rows[table.selectedRow].id==childRow.id,"Sorting lost selected row identity")
        table.selectAll(nil);try require(try Self.menu(table).items.filter{!$0.isSeparatorItem}.map(\.title)==["Copy to Clipboard"],"Multi-selection offered a single-row action")
        try require(source.rows.first?.kind == .command && source.rows.last?.kind == .finished,"Sorting moved auxiliary rows")
        let cli=f.clone("default CLI",backend:.init());try await wait {!cli.model.busy && !cli.model.hasPendingWork}
        try require(cli.model.success && !cli.model.showsNotifications && !cli.model.notifications.rows.contains{[.reference,.file].contains($0.kind)},"Default CLI fabricated typed notifications")
        owner.model.saveActionLog();let saved=try ActionLogStore(storageURL:f.root.appendingPathComponent("actions.log")).read()
        try require(saved.contains(childRow.path) && saved.contains("Checkout"),"Saved Clone action log omitted checkout notifications")
        let afterHead=try await f.source.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:f.source.root.appendingPathComponent(".git/index"))
        try require(beforeHead==afterHead && beforeIndex==afterIndex,"Clone mutated source repository")
    }
    static func verifyFetch(_ f:Fixture)async throws {
        let clone=f.clone("client",backend:f.backend);try await wait {!clone.model.busy && !clone.model.hasPendingWork}
        try require(clone.model.success,"Fetch setup clone failed")
        let repo=GitRepository(root:clone.model.destination,executable:f.git),old=try await repo.run(["rev-parse","refs/remotes/origin/main"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),bytes=try Data(contentsOf:repo.root.appendingPathComponent("file 雪.txt"))
        try await f.commit("next");let new=try await f.source.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.whitespacesAndNewlines)
        var options=FetchOptions();options.remote="origin"
        let owner=f.fetch(repo,options:options,backend:f.backend);try await wait {!owner.model.busy}
        try require(owner.model.success && owner.model.showsNotifications,"Opt-in Fetch failed")
        let table=try await Self.table(owner.window!),source=try coordinator(table)
        try verifyViewport(table,minimumRows:3)
        try await capture(owner.window!,name:"fetch-reference-results")
        let row=try select(table){$0.kind == .reference && $0.reference?.oldHash==old && $0.reference?.newHash==new}
        owner.model.saveActionLog();let saved=try ActionLogStore(storageURL:f.root.appendingPathComponent("actions.log")).read()
        try require(saved.contains(row.path) && saved.contains("Update ref"),"Saved Fetch action log omitted reference notifications")
        var logs:[(String?,String?)]=[]
        owner.model.onNotificationLog={_,_,_,old,new in logs.append((old,new))}
        let referenceMenu=try Self.menu(table)
        try require(referenceMenu.items.filter{!$0.isSeparatorItem}.map(\.title)==["Show Log","Copy to Clipboard"],"Reference menu contains file actions")
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",old])
        invoke(try item(referenceMenu,"Show Log"));try require(logs.count==1 && logs[0].0==old && logs[0].1==new,"Reference Log resolved mutable reference instead of captured full range")
        try doubleClick(table,row:source.rows.firstIndex{$0.id==row.id}!);try require(logs.count==1,"Reference double-click unexpectedly opened Log")
        let stale=try item(try Self.menu(table),"Show Log");owner.model.confirmingQuit=true;invoke(stale);try require(logs.count==1,"Deferred Quit dispatched stale reference menu");owner.model.confirmingQuit=false
        _ = try await repo.run(["update-ref","refs/remotes/origin/main",new])
        let same=f.fetch(repo,options:options,backend:f.backend);try await wait {!same.model.busy}
        try require(same.model.success && same.model.notifications.rows.contains{$0.reference?.oldHash==new && $0.reference?.newHash==new},"Unchanged fetch did not report Same notification")
        try await f.commit("partial");_ = try await repo.run(["remote","rename","origin","aa-good"]);_ = try await repo.run(["remote","add","zz-bad",f.root.appendingPathComponent("missing").path])
        options.allRemotes=true;let partial=f.fetch(repo,options:options,backend:f.backend);try await wait {!partial.model.busy}
        try require(!partial.model.success && partial.model.notifications.rows.contains{$0.kind == .reference},"Partial Fetch failure lost completed references")
        let partialTable=try await Self.table(partial.window!),partialSource=try coordinator(partialTable)
        _ = try select(partialTable){$0.kind == .reference};let previousGeneration=partial.model.notifications.generation,oldMenu=try item(try Self.menu(partialTable),"Show Log")
        var partialLogs=0;partial.model.onNotificationLog={_,_,_,_,_ in partialLogs += 1}
        _ = try await repo.run(["remote","set-url","zz-bad",f.source.root.path]);partial.model.perform(.retry);try await wait {!partial.model.busy}
        try await wait {partialSource.generation==partial.model.notifications.generation}
        invoke(oldMenu);try require(partial.model.success && partial.model.notifications.generation != previousGeneration && partialLogs==0 && partialTable.selectedRowIndexes.isEmpty && partialTable.sortDescriptors.isEmpty,"Retry retained old attempt action/selection")
        try require(partialSource.rows.last?.kind == .finished,"Retry missing completed footer")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),afterBytes=try Data(contentsOf:repo.root.appendingPathComponent("file 雪.txt"))
        try require(head==afterHead && index==afterIndex && bytes==afterBytes,"Fetch changed current HEAD/index/working bytes")
    }
    static func verifyLifecycle(_ f:Fixture)async throws {
        let actual=try f.backend.executor(for:.clone)!
        let helper=f.root.appendingPathComponent("held helper"),marker=f.root.appendingPathComponent("held helper.ready"),release=f.root.appendingPathComponent("held helper.release")
        f.releases.append(release)
        let script="#!/bin/sh\n"+quote(actual.path)+" \"$@\"\nturtle_status=$?\n: > "+quote(marker.path)+"\nwhile [ ! -f "+quote(release.path)+" ]; do /bin/sleep 0.05; done\nexit \"$turtle_status\"\n"
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let held=f.clone("running clone",backend:.init(mask:6,helperURL:helper))
        try await wait {FileManager.default.fileExists(atPath:marker.path) && held.model.notifications.rows.contains{$0.kind == .file}}
        let runningTable=try await Self.table(held.window!),runningSource=try coordinator(runningTable)
        let runningRow=try select(runningTable){$0.kind == .file}
        try require(held.model.busy && runningTable.makeMenu()==nil,"Running worker offered completed-result file menu")
        runningTable.copySelection();try require(f.clipboard.string(forType:.string)==runningRow.action+": "+runningRow.path+"  \r\n","Running worker disabled source keyboard Copy")
        let selectAll=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:held.window!.windowNumber,context:nil,characters:"a",charactersIgnoringModifiers:"a",isARepeat:false,keyCode:0)!
        _ = runningTable.performKeyEquivalent(with:selectAll);try require(runningTable.selectedRowIndexes.count==runningSource.rows.count,"Running worker disabled source Select All")
        held.model.cancel();try await wait {!held.model.busy && !held.model.hasPendingWork}
        try require(held.model.cancelled && held.model.notifications.rows.contains{$0.kind == .file},"Cancelled transfer discarded already delivered checkout results")
        let owner=f.clone("lifecycle",backend:f.backend);try await wait {!owner.model.busy && !owner.model.hasPendingWork}
        try require(owner.model.success,"Lifecycle setup Clone failed")
        let table=try await Self.table(owner.window!);_ = try select(table){$0.kind == .file && $0.filePath=="file 雪.txt"}
        var launches=0,chooser:NSOpenPanel?,answer:((NSApplication.ModalResponse)->Void)?
        owner.notificationFiles.configure={files in
            files.open={_,_ in launches += 1}
            files.chooseApplication={panel,window,reply in chooser=panel;answer=reply;f.replies.append(reply);window.beginSheet(panel)}
        }
        invoke(try item(try Self.menu(table),"Open With"));try await wait {chooser != nil && owner.notificationFiles.busy}
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit accepted while chooser owns target access")
        try require(!owner.windowShouldClose(owner.window!),"Normal Close accepted during owned chooser")
        owner.window?.close();try await wait {!owner.notificationFiles.busy && owner.window?.attachedSheet==nil && CloneProgressWindowController.activeReleases==0}
        answer?(.OK);try require(launches==0,"Late Open With answer launched after owner retirement")
        let second=f.clone("held launch",backend:f.backend);try await wait {!second.model.busy && !second.model.hasPendingWork}
        let secondTable=try await Self.table(second.window!);_ = try select(secondTable){$0.kind == .file && $0.filePath=="file 雪.txt"}
        second.notificationFiles.configure={files in files.open={_,_ in try await withCheckedThrowingContinuation{f.pendingLaunch=$0}}}
        invoke(try item(try Self.menu(secondTable),"Open"));try await wait {f.pendingLaunch != nil}
        second.window?.close();try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit accepted while launch callback pending")
        f.pendingLaunch?.resume();f.pendingLaunch=nil;try await wait {!second.notificationFiles.busy && CloneProgressWindowController.activeReleases==0}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitRemoteNotificationOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let f=try Fixture(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {
            try await f.prepare()
            switch ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_NOTIFICATION_CASE"]! {
            case "clone":try await verifyClone(f)
            case "fetch":try await verifyFetch(f)
            case "lifecycle":try await verifyLifecycle(f)
            default:throw Failure(description:"Unknown notification case")
            }
            try await f.cleanup()
        } catch {let failure=error;do {try await f.cleanup()} catch {throw Failure(description:"\(failure); cleanup: \(error)")};throw failure}
        print("PASS: remote notification native case completed")
    }
}
