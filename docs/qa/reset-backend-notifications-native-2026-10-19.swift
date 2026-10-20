// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitResetBackendOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitResetBackendOrder(place,relativeTo:number)
    }
}
@MainActor @main enum ResetBackendNotificationsVerification {
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
        try await wait {guard let source=NativeListSelection.originalDelegate(of:result) as? FileOperationProgressTable.Coordinator else{return false};return result.numberOfRows==source.rows.count}
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
        guard let value=NativeListSelection.originalDelegate(of:table) as? FileOperationProgressTable.Coordinator else {throw Failure(description:"Actual notification coordinator missing")};return value
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
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_RESET_BACKEND_CAPTURES"],let view=window.contentView else{return}
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
        let root:URL,git:URL,repo:GitRepository,preferences:UserDefaults,suite:String,lease:RepositoryAccessLease
        let clipboard=NSPasteboard.withUniqueName()
        var resets:[ResetProgressWindowController]=[],reverts:[HistoryRevertWindowController]=[]
        var base="",next=""
        var pending:CheckedContinuation<Void,Error>?
        var releases:[URL]=[]
        let paths=["file 雪.txt","second.txt","tab\tname.txt"]
        var backend:GitLibGit2Configuration {.init(mask:(1<<5)|(1<<6),helperURL:ProcessInfo.processInfo.environment["TURTLEGIT_RESET_BACKEND_HELPER"].map{URL(fileURLWithPath:$0)})}
        init(root:URL,git:URL)throws {
            self.root=root;self.git=git;repo=GitRepository(root:root.appendingPathComponent("repository 雪"),executable:git)
            suite="TurtleGit.ResetBackend."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!;lease=RepositoryAccessLease(url:root)
            preferences.set(0,forKey:"AutoCloseGitProgress");preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(true,forKey:"ShowContextMenuIcons");preferences.set(false,forKey:"RevertWithRecycleBin")
            ProgressActionLog.install(store:ActionLogStore(storageURL:root.appendingPathComponent("actions.log")),preferences:preferences);DialogGeometry.install(preferences:preferences)
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Reset backend QA"),("user.email","reset@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try await commit("base");base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try await commit("next");next=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        }
        func commit(_ text:String)async throws {for path in paths {try Data((text+" "+path+"\n").utf8).write(to:repo.root.appendingPathComponent(path))};try await repo.stage(paths);_ = try await repo.commit(message:text)}
        func reset(_ revision:String,mode:ResetMode = .hard,backend:GitLibGit2Configuration?=nil)async throws->ResetProgressWindowController {
            let plan=try await repo.prepareReset(to:revision,mode:mode),model=ResetProgressWindowModel(repository:repo,plan:plan,preferences:preferences,access:lease,backend:backend ?? self.backend)
            model.notifications.publishClipboard={ [clipboard] text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
            let owner=ResetProgressWindowController(model:model);resets.append(owner);owner.showWindow(nil);model.start();return owner
        }
        func cleanup()async throws {
            for url in releases {try? Data().write(to:url)}
            pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil
            for owner in resets{owner.close()};for owner in reverts{owner.close()}
            for window in NSApp.windows {if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.close()}
            try await ResetBackendNotificationsVerification.wait{ResetProgressWindowModel.activeOperations==0 && HistoryRevertWindowModel.activeOperations==0 && ResetWindowController.activeChildReleases==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
            preferences.removePersistentDomain(forName:suite);preferences.synchronize();clipboard.releaseGlobally()
        }
    }
    static func verifyReset(_ f:Fixture)async throws {
        let owner=try await f.reset(f.base)
        f.preferences.set(true,forKey:"RevertWithRecycleBin");f.preferences.set(0,forKey:"UseLibgit2_mask")
        try await wait{!owner.model.busy && !owner.model.hasPendingWork}
        f.preferences.set(false,forKey:"RevertWithRecycleBin")
        try require(owner.model.success && owner.model.showsNotifications && !owner.model.recycle,"Captured selected Reset backend/recycle policy differs")
        let table=try await Self.table(owner.window!),source=try coordinator(table)
        try verifyViewport(table,minimumRows:4)
        let files=owner.model.notifications.rows.filter{$0.kind == .file}
        try require(Set(files.compactMap(\.filePath))==Set(f.paths) && files.allSatisfy{$0.action=="Checkout"},"Reset omitted typed UPDATED paths")
        try require(source.rows.first?.kind == .command && source.rows.last?.kind == .finished,"Reset command/footer missing")
        try await capture(owner.window!,name:"reset-checkout-results")
        let row=try select(table){$0.filePath=="file 雪.txt"}
        var logs:[(String,[String])]=[],opened:[URL]=[]
        owner.model.onNotificationLog={repo,grant,paths,_,_ in if grant===f.lease{logs.append((repo.root.path,paths))}}
        owner.notificationFiles.configure={files in files.open={url,_ in opened.append(url)};files.reveal={opened += $0}}
        let menu=try Self.menu(table);try require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Reset menu lost source icons")
        invoke(try item(menu,"Show Log"));try require(logs.count==1 && logs[0].0==f.repo.root.path && logs[0].1==[row.filePath!],"Reset Log lost captured repository/grant/path")
        invoke(try item(try Self.menu(table),"Open"));try await wait{!owner.notificationFiles.busy};try require(opened.last?.path==f.repo.root.appendingPathComponent(row.filePath!).path,"Reset Open lost file path")
        invoke(try item(try Self.menu(table),"Copy to Clipboard"));try require(f.clipboard.string(forType:.string)==row.path,"Reset selected context Copy differs")
        table.copySelection();try require(f.clipboard.string(forType:.string)==row.action+": "+row.path+"  \r\n","Reset keyboard Copy differs")
        table.sortDescriptors=[NSSortDescriptor(key:"path",ascending:false)];try require(source.rows[table.selectedRow].id==row.id,"Reset sorting lost selection identity")
        let held=try item(try Self.menu(table),"Show Log");owner.model.confirmingQuit=true;invoke(held);try require(logs.count==1,"Reset stale menu escaped deferred Quit");owner.model.confirmingQuit=false
        table.selectAll(nil);try require(try Self.menu(table).items.filter{!$0.isSeparatorItem}.map(\.title)==["Copy to Clipboard"],"Reset multi-selection offers single-file action")
        owner.model.saveActionLog();let saved=try ActionLogStore(storageURL:f.root.appendingPathComponent("actions.log")).read();try require(saved.contains("Checkout") && saved.contains(row.path),"Reset saved log omits typed paths")
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);try require(head==f.base,"Reset did not move HEAD")
        for path in f.paths {try require(try String(contentsOf:f.repo.root.appendingPathComponent(path),encoding:.utf8)=="base "+path+"\n","Reset working bytes differ")}
        let cli=try await f.reset(f.next,backend:.init());try await wait{!cli.model.busy && !cli.model.hasPendingWork}
        try require(cli.model.success && !cli.model.showsNotifications && !cli.model.notifications.rows.contains{$0.kind == .file},"Default CLI fabricated typed Reset rows")
        try require(!views(cli.window?.contentView).contains{$0 is FileOperationProgressNativeTable},"Default CLI layout changed into result table")
        for mode in [ResetMode.soft,.mixed] {
            let plain=try await f.reset(mode == .soft ? f.base:f.next,mode:mode);try await wait{!plain.model.busy && !plain.model.hasPendingWork}
            try require(plain.model.success && !plain.model.notifications.rows.contains{$0.kind == .file},"Soft/mixed Reset fabricated checkout rows")
        }
    }
    static func verifyRevert(_ f:Fixture)async throws {
        let entries=try await f.repo.log(),owner=HistoryRevertWindowController(repository:f.repo,access:f.lease,entries:[entries[0]],mainline:nil,preferences:f.preferences)
        f.reverts.append(owner);owner.showWindow(nil)
        var captured=0,questions:[String]=[],commit=0
        owner.model.captureBackend={captured+=1;return f.backend}
        owner.model.ask={title,_,_,_ in questions.append(title);if questions.count==1 {return true};return false}
        owner.model.onCommit={commit+=1};owner.model.start();try await wait{!owner.model.busy && HistoryRevertWindowModel.activeOperations==0}
        try require(captured==1 && owner.model.backend?.requests(.revert)==true && owner.model.success && owner.model.completed==1 && questions.count==2 && commit==0,"Log revert lost captured backend/confirmation/Commit review")
        try require(!views(owner.window?.contentView).contains{$0 is FileOperationProgressNativeTable},"Log commit revert invented per-file result table")
        let head=try await f.repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines);try require(head==f.next,"Log revert unexpectedly committed")
        for path in f.paths {try require(try String(contentsOf:f.repo.root.appendingPathComponent(path),encoding:.utf8)=="base "+path+"\n","Log revert working bytes differ")}
        let mergeMessage=try await f.repo.run(["rev-parse","--git-path","MERGE_MSG"]).text.trimmingCharacters(in:.newlines)
        let url=mergeMessage.hasPrefix("/") ? URL(fileURLWithPath:mergeMessage):f.repo.root.appendingPathComponent(mergeMessage)
        try require(try String(contentsOf:url,encoding:.utf8).contains("Revert"),"Log revert lost MERGE_MSG")
        let missing=LogEntry(hash:String(repeating:"f",count:40),author:"QA",date:"",subject:"missing revision")
        for skip in [true,false] {
            _ = try await f.repo.run(["reset","--hard",f.next])
            let batch=HistoryRevertWindowController(repository:f.repo,access:f.lease,entries:[missing,entries[0]],mainline:nil,preferences:f.preferences)
            f.reverts.append(batch);batch.showWindow(nil)
            var calls=0,captures=0
            batch.model.captureBackend={captures+=1;return f.backend}
            batch.model.ask={title,_,accept,reject in
                calls+=1
                if calls==1{return true}
                if title=="Revert failed" {f.preferences.set(0,forKey:"UseLibgit2_mask");return skip}
                return false
            }
            batch.model.start();try await wait{!batch.model.busy && HistoryRevertWindowModel.activeOperations==0}
            try require(captures==1 && batch.model.completed==(skip ? 2:1) && batch.model.success==skip && calls==(skip ? 3:2),"Log multi-revert Skip/Abort or backend capture differs")
        }
        _ = try await f.repo.run(["reset","--hard",f.next]);try await f.commit("third")
        let conflicted=HistoryRevertWindowController(repository:f.repo,access:f.lease,entries:[entries[0]],mainline:nil,preferences:f.preferences)
        f.reverts.append(conflicted);conflicted.showWindow(nil);var conflictQuestions=0
        conflicted.model.captureBackend={f.backend};conflicted.model.ask={_,_,_,_ in conflictQuestions+=1;return conflictQuestions==1}
        conflicted.model.start();try await wait{!conflicted.model.busy && HistoryRevertWindowModel.activeOperations==0}
        let status=try await f.repo.status(refreshIndex:false)
        try require(conflicted.model.success && conflictQuestions==2 && status.contains{$0.state == .conflicted},"Library revert zero outcome lost conflict stages or source Commit review")
    }
    static func verifyLifecycle(_ f:Fixture)async throws {
        let actual=try f.backend.executor(for:.reset)!,helper=f.root.appendingPathComponent("held helper"),marker=f.root.appendingPathComponent("held.ready"),release=f.root.appendingPathComponent("held.release")
        f.releases.append(release)
        let script="#!/bin/sh\ncase \" $* \" in *' reset '*) echo $$ > "+quote(marker.path)+"; while [ ! -e "+quote(release.path)+" ]; do sleep 0.05; done;; esac\nexec "+quote(actual.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let owner=try await f.reset(f.base,backend:.init(mask:1<<5,helperURL:helper));try await wait{FileManager.default.fileExists(atPath:marker.path)}
        let table=try await Self.table(owner.window!);table.selectAll(nil);table.copySelection()
        try require(f.clipboard.string(forType:.string)?.contains("Command: Reset")==true && table.makeMenu()==nil,"Running Reset keyboard/context ownership differs")
        try require(!owner.windowShouldClose(owner.window!),"Running Reset close escaped owned helper")
        try await wait{!owner.model.busy && !owner.model.hasPendingWork}
        try require(owner.model.cancelled && !owner.model.success && owner.model.postActions==[.retry],"Cancelled Reset lost Retry")
        let generation=owner.model.notifications.generation
        try Data().write(to:release);owner.model.perform(.retry);try await wait{!owner.model.busy && !owner.model.hasPendingWork}
        try require(owner.model.success && owner.model.notifications.generation != generation && owner.model.notifications.rows.contains{$0.kind == .file},"Reset Retry lost captured backend/attempt rows")
        _ = try select(table){$0.kind == .file}
        owner.notificationFiles.configure={files in files.open={_,_ in try await withCheckedThrowingContinuation{f.pending=$0}}}
        invoke(try item(try Self.menu(table),"Open"));try await wait{f.pending != nil}
        try require(owner.model.fileActionBusy && !owner.windowShouldClose(owner.window!),"Reset closed while file launch retained ownership")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped Reset file action ownership")
        owner.close();try require(owner.notificationFiles.busy,"Forced Reset close dropped pending file action")
        f.pending?.resume(returning:());f.pending=nil;try await wait{!owner.notificationFiles.busy && ResetWindowController.activeChildReleases==0}
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitResetBackendOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let f=try Fixture(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]))
        do {
            try await f.prepare()
            switch ProcessInfo.processInfo.environment["TURTLEGIT_RESET_BACKEND_CASE"]! {
            case "reset":try await verifyReset(f)
            case "revert":try await verifyRevert(f)
            case "lifecycle":try await verifyLifecycle(f)
            default:throw Failure(description:"Unknown reset backend case")
            }
            try await f.cleanup()
        }catch{let failure=error;do{try await f.cleanup()}catch{throw Failure(description:"\(failure); cleanup: \(error)")};throw failure}
        print("PASS: reset backend native case completed")
    }
}
