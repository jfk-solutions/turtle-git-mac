// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func turtleGitDiffBackendOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000))
        turtleGitDiffBackendOrder(place,relativeTo:number)
    }
}
@MainActor @main enum DiffBackendVerification {
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
        let root:URL,git:URL,repo:GitRepository,prefs:UserDefaults,suite:String,lease:RepositoryAccessLease,probe:URL
        var windows:[NSWindowController]=[],releases:[URL]=[]
        var base="",next=""
        let path="file 雪.txt"
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]);git=URL(fileURLWithPath:CommandLine.arguments[2]);probe=root.appendingPathComponent("helper.calls")
            suite="TurtleGit.DiffBackend."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!;lease=RepositoryAccessLease(url:root)
            prefs.set(true,forKey:"UseLibgit2");prefs.set((1<<4)|(1<<15),forKey:"UseLibgit2_mask");prefs.set(false,forKey:"ShowWCRevision");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"UseRegexFilter")
            let actual=try GitLibGit2Configuration(mask:1<<4,helperURL:ProcessInfo.processInfo.environment["TURTLEGIT_DIFF_BACKEND_HELPER"].map{URL(fileURLWithPath:$0)}).executor(for:.diff)!
            let wrapper=root.appendingPathComponent("probe helper")
            let script="#!/bin/sh\nprintf '%s\\n' \"$*\" >> "+DiffBackendVerification.quote(probe.path)+"\nexec "+DiffBackendVerification.quote(actual.path)+" \"$@\"\n"
            try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:wrapper.path)
            repo=GitRepository(root:root.appendingPathComponent("repository 雪"),executable:git,libgit2Configuration:.init(mask:0,helperURL:wrapper))
            DialogGeometry.install(preferences:prefs)
        }
        func prepare()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Diff QA"),("user.email","diff@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try Data("alpha\nbeta\n".utf8).write(to:repo.root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"base")
            base=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
            try Data("alpha\nchanged\n".utf8).write(to:repo.root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"next")
            next=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        }
        func calls()->String {(try? String(contentsOf:probe,encoding:.utf8)) ?? ""}
        func count(_ verb:String)->Int {calls().split(separator:"\n").filter{$0.contains(verb)}.count}
        func log()async throws->LogWindowController {
            let owner=LogWindowController(repository:repo,access:lease,labelDefaults:prefs,historyFileCache:HistoryFileCache(root:root.appendingPathComponent("history cache")),loadsImmediately:false)
            windows.append(owner);owner.showWindow(nil);owner.model.reload();try await DiffBackendVerification.wait{!owner.model.busy && owner.model.entries.contains{$0.hash==self.next}}
            owner.model.select([next]);try await DiffBackendVerification.wait{owner.model.files.contains{$0.path==self.path}}
            return owner
        }
        func cleanup()async throws {
            for url in releases{try? Data().write(to:url)}
            for owner in windows{owner.close()}
            for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.close()}
            try await DiffBackendVerification.wait{LogWindowModel.activeActionReads==0 && RevisionGraphFindController.activeOperations==0 && PatchWindowModel.activeOperations==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}}
            prefs.removePersistentDomain(forName:suite);prefs.synchronize()
        }
    }
    static func verifyLog(_ f:Fixture)async throws {
        let owner=try await f.log(),model=owner.model
        try require(f.count("turtlegit-history-diff")>0,"Log selected15 changed files bypassed helper")
        let selected=model.files.first{$0.path==f.path}!
        try require(selected.action=="M" && selected.added==1 && selected.removed==1,"Log selected15 file action/statistics differ")
        var displayed:Data?
        model.onUnifiedDiff={bytes,_ in displayed=bytes};model.diff();try await wait{!model.busy && displayed != nil}
        try require(f.count("turtlegit-unified-diff")>0 && String(decoding:displayed!,as:UTF8.self).contains("+changed"),"Log selected4 unified output missing")
        model.setPatchPreview(true);try await wait{!model.patchPreviewLoading && !model.patchPreviewData.isEmpty}
        try require(String(decoding:model.patchPreviewData,as:UTF8.self).contains("+changed"),"Log preview lost selected diff bytes")
        try await wait{LogWindowModel.activeActionReads==0}
        let before=f.count("turtlegit-history-diff")
        f.prefs.set(0,forKey:"UseLibgit2_mask");model.select([f.base]);try await wait{model.files.contains{$0.path==f.path}}
        model.select([f.next]);try await wait{model.files.contains{$0.path==f.path} && !model.patchPreviewLoading}
        try require(f.count("turtlegit-history-diff")==before,"Disabled15 reused helper rather than CLI/cache context")
        f.prefs.set((1<<4)|(1<<15),forKey:"UseLibgit2_mask")
        owner.showFind();guard let find=owner.find else{throw Failure(description:"Actual Log Find missing")}
        try await wait{!find.loadingReferences};find.searchBox.stringValue=f.path;find.findNext();try await wait{!find.busy && RevisionGraphFindController.activeOperations==0}
        try require(!find.acknowledgingFailure,"Log Find selected15 path read failed")
    }
    static func verifyWorking(_ f:Fixture)async throws {
        try Data("alpha\nworking\n".utf8).write(to:f.repo.root.appendingPathComponent(f.path))
        let owner=StatusWindowController(repository:f.repo,access:f.lease,defaults:f.prefs);f.windows.append(owner);owner.showWindow(nil);owner.model.reload();try await wait{!owner.model.busy && !owner.model.files.isEmpty}
        var patch:Data?;owner.model.onUnifiedDiff={bytes,_ in patch=bytes};let before=f.count("turtlegit-unified-diff")
        owner.model.unifiedDiff([f.path],alternate:false);try await wait{!owner.model.busy && patch != nil}
        try require(f.count("turtlegit-unified-diff")>before && String(decoding:patch!,as:UTF8.self).contains("+working"),"Status unified lost captured4 backend/output")
        let view=PatchWindowController(repository:f.repo,access:f.lease,preferences:f.prefs);f.windows.append(view);view.showWindow(nil)
        let count=f.count("turtlegit-unified-diff");view.model.reload(paths:[f.path],staged:false);try await wait{!view.model.busy && !view.model.document.text.isEmpty}
        try require(f.count("turtlegit-unified-diff")==count && view.model.document.text.contains("+working"),"Editable staging patch was incorrectly routed to selected4")
        let comparison=RevisionComparisonWindowController(repository:f.repo,access:f.lease,from:.revision(f.base),to:.revision(f.next),preferences:f.prefs);f.windows.append(comparison);comparison.showWindow(nil);comparison.model.load();try await wait{!comparison.model.busy && comparison.model.snapshot != nil}
        comparison.model.selection=[f.path];comparison.model.togglePatch();try await wait{comparison.model.patchWindow?.model.document.text.contains("+changed")==true}
        try require(comparison.model.patchWindow?.model.appearancePreferences===f.prefs,"Revision patch viewer lost owning preferences")
        let commit=CommitWindowController(repository:f.repo,access:f.lease,defaults:f.prefs);f.windows.append(commit);commit.showWindow(nil);commit.model.reload();try await wait{!commit.model.busy && commit.model.entries.contains{$0.path==f.path}}
        var commitBytes:Data?;commit.model.onUnifiedDiff={bytes,_ in commitBytes=bytes}
        let beforeCommit=f.count("turtlegit-unified-diff");commit.model.diff(paths:[f.path]);try await wait{!commit.model.busy && commitBytes != nil}
        try require(f.count("turtlegit-unified-diff")>beforeCommit && String(decoding:commitBytes!,as:UTF8.self).contains("+working"),"Commit display-only diff bypassed captured4")

    }
    static func verifyLifecycle(_ f:Fixture)async throws {
        let owner=try await f.log(),model=owner.model
        model.setPatchPreview(false)
        let actual=try f.repo.libgit2Configuration!.executor(for:.diff) ?? f.repo.libgit2Configuration!.helperURL!
        let helper=f.root.appendingPathComponent("held diff"),marker=f.root.appendingPathComponent("held.ready"),release=f.root.appendingPathComponent("held.release");f.releases.append(release)
        let script="#!/bin/sh\ncase \" $* \" in *turtlegit-unified-diff*) echo $$ > "+quote(marker.path)+"; while [ ! -e "+quote(release.path)+" ]; do sleep 0.05; done;; esac\nexec "+quote(actual.path)+" \"$@\"\n"
        try Data(script.utf8).write(to:helper);try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let capturedRepo=GitRepository(root:f.repo.root,executable:f.git,libgit2Configuration:.init(mask:0,helperURL:helper)),held=LogWindowController(repository:capturedRepo,access:f.lease,labelDefaults:f.prefs,historyFileCache:HistoryFileCache(root:f.root.appendingPathComponent("held cache")),loadsImmediately:false)
        f.windows.append(held);held.showWindow(nil);held.model.reload();try await wait{!held.model.busy && held.model.entries.contains{$0.hash==f.next}}
        held.model.select([f.next]);try await wait{!held.model.files.isEmpty}
        var delivered=0;held.model.onUnifiedDiff={_,_ in delivered+=1};held.model.diff();try await wait{FileManager.default.fileExists(atPath:marker.path)}
        f.prefs.set(0,forKey:"UseLibgit2_mask");held.model.invalidate();try Data().write(to:release)
        try await wait{!held.model.unifiedViewerBusy};try require(delivered==0,"Retired unified read delivered late output")
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitDiffBackendOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let f=try Fixture()
        do {try await f.prepare();switch ProcessInfo.processInfo.environment["TURTLEGIT_DIFF_BACKEND_CASE"]! {case "log":try await verifyLog(f);case "working":try await verifyWorking(f);case "lifecycle":try await verifyLifecycle(f);default:throw Failure(description:"Unknown diff backend case")};try await f.cleanup()}
        catch{let original=error;do{try await f.cleanup()}catch{throw Failure(description:"\(original); cleanup: \(error)")};throw original}
        print("PASS: diff backend native case completed")
    }
}
