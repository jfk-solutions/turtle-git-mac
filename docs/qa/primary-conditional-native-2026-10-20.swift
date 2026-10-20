// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct PrimaryConditionalVerification {
    struct Failure:Error,CustomStringConvertible,LocalizedError {let description:String;var errorDescription:String?{description}}
    @MainActor final class Gate {
        var continuation:CheckedContinuation<Void,Never>?, token:OperationCancellation?
        var entered=false
        func pause() async {entered=true;await withCheckedContinuation{continuation=$0}}
        func release(){let reply=continuation;continuation=nil;reply?.resume()}
    }
    @MainActor static var owners:[NSWindowController]=[], gates:[Gate]=[], releaseFiles:[URL]=[]
    static func require(_ value:Bool,_ message:String)throws {if !value{throw Failure(description:message)}}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1200 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Conditional UI timeout at \(line)")
    }
    @MainActor static func own(_ controller:NSWindowController){owners.append(controller);if let w=controller.window{w.alphaValue=0;w.setFrameOrigin(NSPoint(x:-24000,y:-24000));w.orderFront(nil)}}
    @MainActor static func cleanup()async ->Bool {
        for gate in gates{gate.release()};for path in releaseFiles{try? FileManager.default.removeItem(at:path)}
        for owner in owners.reversed(){if let w=owner.window{if let child=w.attachedSheet{w.endSheet(child,returnCode:.abort);child.close()};w.close()}}
        for window in NSApp.windows{window.orderOut(nil);window.close()}
        for _ in 0..<1000 {
            if CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0 && LogWindowModel.activeHistoryLoads==0 && StatusWindowModel.activeOperations==0{return true}
            try? await Task.sleep(nanoseconds:10_000_000)
        }
        return false
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_CONDITIONAL_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:200_000_000)
            let content=try await SCShareableContent.currentProcess
            let owned=try XCT(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try XCT(NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]),"Native capture encoding")
            let filename=name+"-"+suffix+".png";try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(filename))
            print("Owned native capture: "+filename+" "+String(pixels.width)+"x"+String(pixels.height))
        }
    }
    @MainActor static func main()async {
        NSApp.setActivationPolicy(.prohibited)
        var failure:Error?
        do {
            let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
            for name in CommandLine.arguments.dropFirst(3) {
                let root=base.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let repo=GitRepository(root:root,executable:git),suite="TurtleGit.PrimaryConditional."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
                defer{prefs.removePersistentDomain(forName:suite)}
                prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"AddBeforeCommit");prefs.set(true,forKey:"ShowListBackgroundImage")
                try await fixture(repo)
                switch name {case "commit":try await commit(repo,prefs);case "log":try await log(repo,prefs);case "status":try await status(repo,prefs);default:throw Failure(description:"Unknown case")}
                print("PASS primary conditional case: "+name)
            }
        }catch{failure=error}
        let drained=await cleanup()
        if !drained && failure==nil{failure=Failure(description:"Owned primary workers did not drain")}
        if let failure{fputs("Primary conditional controls failed: \(failure)\n",stderr);exit(1)}
        print("PASS primary conditional controls: native source actions, date menus/loading, fresh scoped status/cancellation/watermark; all owned windows closed")
    }
    static func fixture(_ repo:GitRepository)async throws {
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Conditional QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try FileManager.default.createDirectory(at:repo.root.appendingPathComponent("scoped"),withIntermediateDirectories:true)
        for (day,path) in [(1,"scoped/inside.txt"),(2,"outside.txt"),(3,"third.txt")] {
            try Data("base \(day)\n".utf8).write(to:repo.root.appendingPathComponent(path));try await repo.stage([path])
            _ = try await repo.run(["commit","-m","history \(day)"],environmentOverrides:["GIT_AUTHOR_DATE":"2020-01-0\(day)T12:00:00+00:00","GIT_COMMITTER_DATE":"2020-01-0\(day)T12:00:00+00:00"])
        }
    }
    @MainActor static func commit(_ repo:GitRepository,_ prefs:UserDefaults)async throws {
        prefs.set(2,forKey:"CommitLastAction")
        try Data("modified\n".utf8).write(to:repo.root.appendingPathComponent("outside.txt"))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs);own(owner);owner.model.reload()
        try await wait(owner.window){!owner.model.busy && !owner.model.entries.isEmpty}
        let model=owner.model;model.message="Private native control attempt";model.checked=GitPathSet(["outside.txt"])
        try await wait(owner.window){model.canCommit && views(owner.window?.contentView).compactMap{$0 as? CommitNativeActionControl}.first?.isEnabled==true}
        let control=try XCT(views(owner.window?.contentView).compactMap{$0 as? CommitNativeActionControl}.first,"Missing native Commit split")
        try require(control.segmentCount==2 && control.label(forSegment:0)=="Commit & Push" && control.isEnabled,"Remembered primary action/split disabled")
        let menu=try XCT(control.menu(forSegment:1),"Missing Commit menu")
        try require(menu.items.map(\.title)==["Commit","ReCommit","Commit & Push"] && menu.items[2].state == .on && menu.items.allSatisfy{$0.image != nil},"Source action order/checks/icons")
        try await capture(owner.window!,"commit-conditional")
        var attempts=0;model.captureCommitBackend={attempts += 1;return GitLibGit2Configuration.load(from:prefs)}
        menu.delegate?.menuWillOpen?(menu)
        model.message += " changed while menu open"
        if let action=menu.items[0].action{_ = NSApp.sendAction(action,to:menu.items[0].target,from:menu.items[0])}
        try require(attempts==0 && model.currentCompletionAction == .push,"Stale Commit menu changed/executed action")
        menu.delegate?.menuWillOpen?(menu)
        if let action=menu.items[1].action{_ = NSApp.sendAction(action,to:menu.items[1].target,from:menu.items[1])}
        try require(attempts==1 && model.currentCompletionAction == .recommit,"Fresh native action not accepted")
        if let action=menu.items[0].action{_ = NSApp.sendAction(action,to:menu.items[0].target,from:menu.items[0])}
        try require(attempts==1,"Commit menu receipt reused")
        owner.window?.close()
        try await wait{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0}
        prefs.set(0,forKey:"CommitLastAction")
        let keyboard=CommitWindowController(repository:repo,access:nil,defaults:prefs);own(keyboard);keyboard.model.reload()
        try await wait(keyboard.window){!keyboard.model.busy && !keyboard.model.entries.isEmpty}
        keyboard.model.message="Keyboard native attempt";keyboard.model.checked=GitPathSet(["outside.txt"])
        try await wait(keyboard.window){keyboard.model.canCommit && views(keyboard.window?.contentView).compactMap{$0 as? CommitNativeActionControl}.first?.isEnabled==true}
        let keyControl=try XCT(views(keyboard.window?.contentView).compactMap{$0 as? CommitNativeActionControl}.first,"Missing keyboard split")
        keyboard.model.captureCommitBackend={attempts += 1;return GitLibGit2Configuration.load(from:prefs)}
        let event=try XCT(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:keyboard.window!.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49),"Keyboard event")
        keyControl.keyDown(with:event);try require(attempts==2,"Focused Space did not invoke primary action")
        keyboard.window?.close();try await wait{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0}
        keyControl.keyDown(with:event);try require(attempts==2 && keyControl.lifetime.retired,"Retired native action accepted keyboard")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after==head,"Cancelled control attempts mutated HEAD")
    }
    static func XCT<T>(_ value:T?,_ message:String)throws->T {guard let value else{throw Failure(description:message)};return value}
    @MainActor static func log(_ repo:GitRepository,_ prefs:UserDefaults)async throws {
        let hold=repo.root.appendingPathComponent("hold-log"),entered=repo.root.appendingPathComponent("entered-log"),wrapper=repo.root.appendingPathComponent("held-git")
        func quote(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="""
        #!/bin/sh
        for argument do
          if [ "$argument" = log ] && [ -f \(quote(hold.path)) ]; then
            : > \(quote(entered.path))
            while [ -f \(quote(hold.path)) ]; do /bin/sleep 0.02; done
            break
          fi
        done
        exec \(quote(repo.executable.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        try Data().write(to:hold);releaseFiles.append(hold)
        let held=GitRepository(root:repo.root,executable:wrapper)
        let owner=LogWindowController(repository:held,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false);own(owner)
        let model=owner.model;model.reload()
        try await wait(owner.window){FileManager.default.fileExists(atPath:entered.path) && model.loadingHistory && views(owner.window?.contentView).compactMap{$0 as? LogDateControl}.count==2 && !views(owner.window?.contentView).compactMap{$0 as? LogControlButton}.contains{$0.identifier?.rawValue=="Log.Control.walk"}}
        try require(!model.canShowStatistics && !model.canJump(up:true),"Loading Log commands remained active")
        try require(!views(owner.window?.contentView).compactMap{$0 as? LogControlButton}.contains{$0.identifier?.rawValue=="Log.Control.view"},"History load left native View controls visible")
        try FileManager.default.removeItem(at:hold)
        try await wait(owner.window){!model.busy && model.entries.count==3 && views(owner.window?.contentView).compactMap{$0 as? LogDateControl}.count==2}
        let dates=views(owner.window?.contentView).compactMap{$0 as? LogDateControl}
        let from=try XCT(dates.first{$0.identifier?.rawValue=="Log.Date.From"},"Native From date missing")
        let to=try XCT(dates.first{$0.identifier?.rawValue=="Log.Date.To"},"Native To date missing")
        var gregorian=Calendar(identifier:.gregorian);gregorian.timeZone = .current
        let sourceMaximum=gregorian.date(from:DateComponents(year:2100,month:1,day:2,hour:23,minute:59,second:59))!
        try require(from.isEnabled && to.isEnabled && from.minDate==Date(timeIntervalSince1970:0) && from.maxDate==sourceMaximum && to.maxDate==sourceMaximum,"Native Gregorian source date bounds")
        let limit=LogControlMenus.make(model:model,kind:.limit)
        try require(limit.items.first?.title=="No limitation" && limit.items.last?.title=="Configure default" && limit.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Source limit menu order/icons")
        try require(from.buildMenu?()?.items.map(\.title)==limit.items.map(\.title),"From context menu differs from source limitation button")
        try require(model.canShowStatistics,"Commit-bearing Log disabled Statistics")
        try await capture(owner.window!,"log-conditional")
        let oldGeneration=model.contextMenuGeneration
        model.select([model.entries.last!.hash])
        limit.performActionForItem(at:0)
        try require(model.contextMenuGeneration==oldGeneration,"Stale From menu replaced history")
        let chosen=gregorian.date(from:DateComponents(year:2020,month:1,day:2))!
        from.dateValue=chosen
        if let action=from.action{_ = NSApp.sendAction(action,to:from.target,from:from)}
        try await wait(owner.window){!model.busy && model.historyLimit.scale == .selectedDate && model.entries.count==2}
        let once=model.contextMenuGeneration
        from.dateValue=chosen;if let action=from.action{_ = NSApp.sendAction(action,to:from.target,from:from)}
        try require(model.contextMenuGeneration==once,"Identical date caused another history acquisition")
        let menu=LogControlMenus.make(model:model,kind:.limit);menu.performActionForItem(at:0)
        try await wait(owner.window){!model.busy && model.entries.count==3}
        let table=views(owner.window?.contentView).compactMap{$0 as? HistoryTableView}.first
        try require(table?.tableColumns.first?.identifier.rawValue=="graph","Graph no longer precedes revision list")
        // Actual source Cancel exists in ordinary (non-picker) Log too.
        // Hidden SwiftUI hosts publish no virtual AX children on this SDK.
        // Exercise the actual Cancel shortcut; source button presence is covered
        // by the owned compositor capture, not inferred from NSButton subclasses.
        let logWindow=try XCT(owner.window as? LogHistoryWindow,"Native Log window missing")
        logWindow.makeFirstResponder(nil);logWindow.commandKeyWindow={ [weak logWindow] in logWindow }
        let escape=try XCT(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:logWindow.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53),"Log Cancel key")
        try require(logWindow.performKeyEquivalent(with:escape),"Actual Log Cancel shortcut was not handled")
        try await wait{model.isInvalidated}
        // The source jump coordinates include the synthetic first row. The
        // newest real commit is therefore index one and can jump to its parent.
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges")
        try Data("private working change\n".utf8).write(to:repo.root.appendingPathComponent("third.txt"))
        let withWorking=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false,loadsImmediately:false);own(withWorking)
        let navigation=withWorking.model;navigation.reload()
        try await wait(withWorking.window){!navigation.busy && navigation.entries.count==4 && navigation.entries.first?.hash==""}
        let newest=try XCT(navigation.entries.first{!$0.hash.isEmpty},"Missing newest real commit")
        let parent=try XCT(newest.parents.first,"Missing actual parent")
        navigation.select([newest.hash]);navigation.chooseJumpKind(.parent1)
        try require(navigation.canJump(up:false),"Newest real commit with synthetic row disabled parent jump")
        navigation.jump(up:false)
        try await wait(withWorking.window){!navigation.jumping && navigation.selected==[parent]}
        try require(navigation.scrollRevision==parent,"Parent jump used filtered rather than displayed row indices")
        navigation.select([""])
        try require(!navigation.canJump(up:false),"Synthetic working-tree selection enabled parent jump")
        navigation.jump(up:false)
        try require(!navigation.jumping && navigation.selected==[""],"Synthetic working-tree jump changed selection")
        withWorking.window?.close()
    }
    @MainActor static func status(_ repo:GitRepository,_ prefs:UserDefaults)async throws {
        prefs.set(false,forKey:"ChangedFilesIncludeStaged")
        try Data("inside modified\n".utf8).write(to:repo.root.appendingPathComponent("scoped/inside.txt"))
        let owner=StatusWindowController(repository:repo,access:nil,defaults:prefs);own(owner)
        let model=owner.model
        var reads=0
        model.readStatus={token in reads += 1;return try await repo.workingTreeStatus(cancellation:token)}
        model.setScope(["scoped"])
        try await wait(owner.window){!model.busy && model.hasStatusSnapshot}
        try require(Set(model.visibleFiles.map(\.entry.path))==["scoped/inside.txt"],"Scoped initial CFM rows")
        try Data("outside fresh\n".utf8).write(to:repo.root.appendingPathComponent("outside.txt"))
        var filter=model.filter;filter.wholeProject=true;let beforeWhole=reads;model.setFilter(filter)
        try await wait(owner.window){!model.busy && reads>beforeWhole}
        try require(model.visibleFiles.contains{$0.entry.path=="outside.txt"},"Whole Project only repainted stale cache")
        filter=model.filter;filter.wholeProject=false;model.setFilter(filter);try await wait(owner.window){!model.busy}
        try await repo.stage(["outside.txt"])
        filter=model.filter;filter.showAllStaged=true;let beforeStaged=reads;model.setFilter(filter)
        try await wait(owner.window){!model.busy && reads>beforeStaged}
        try require(model.visibleFiles.contains{$0.entry.path=="outside.txt" && $0.entry.staged},"Show all staged did not acquire fresh outside-scope index state")
        let acquired=reads;filter=model.filter;filter.showUnversioned.toggle();model.setFilter(filter)
        try await wait{!model.fileListRefresh.hasPendingPosition}
        try require(reads==acquired,"Loaded-category toggle unnecessarily acquired another Git snapshot")
        try await wait(owner.window){views(owner.window?.contentView).contains{$0 is FileListWatermark}}
        let watermark=try XCT(views(owner.window?.contentView).compactMap{$0 as? FileListWatermark}.first,"CFM watermark missing")
        try require(watermark.icon == .statusBackdrop && watermark.image != nil && watermark.artworkRect != nil,"CFM uses wrong/missing source background artwork")
        try await capture(owner.window!,"status-conditional")
        let oldPaths=model.files.map(\.entry.path),gate=Gate();gates.append(gate)
        model.readStatus={token in gate.token=token;await gate.pause();try token.check();return try await repo.workingTreeStatus(cancellation:token)}
        model.reload();try await wait(owner.window){gate.entered && model.refreshing && model.primaryActionEnabled}
        try require(model.primaryActionTitle=="Cancel" && model.controlsBlocked,"Refresh disabled its default Cancel or left form active")
        try await capture(owner.window!,"status-refresh-conditional")
        let statusWindow=try XCT(owner.window as? StatusNativeWindow,"Native status window missing")
        statusWindow.makeFirstResponder(nil);owner.commandKeyWindow={ [weak statusWindow] in statusWindow }
        let enter=try XCT(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:statusWindow.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"Status default Return")
        try require(statusWindow.performKeyEquivalent(with:enter),"Actual status default Return was not handled")
        try require(gate.token?.isCancelled==true && model.busy && !model.primaryActionEnabled,"Cancel released read ownership before receipt")
        gate.release();try await wait(owner.window){!model.busy && model.refreshCancelled}
        try require(model.files.map(\.entry.path)==oldPaths && model.refreshNotice != nil && model.primaryActionTitle=="OK","Cancelled refresh lost prior results/notice")
        model.readStatus={_ in throw Failure(description:"Private status read failure")};model.reload()
        try await wait(owner.window){!model.busy && model.refreshFailure != nil}
        try require(model.files.map(\.entry.path)==oldPaths && model.refreshNotice?.contains("Private status read failure")==true,"Failed refresh silently replaced prior snapshot")
        model.error=nil
        try await wait(owner.window){owner.window?.attachedSheet==nil}
        model.readStatus={try await repo.workingTreeStatus(cancellation:$0)};model.reload()
        try await wait(owner.window){!model.busy && model.refreshFailure==nil && !model.refreshCancelled}
        try require(model.refreshNotice==nil,"Successful refresh retained obsolete failure")
        owner.window?.close()
    }
}
