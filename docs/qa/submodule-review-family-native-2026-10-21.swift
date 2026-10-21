// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum SubmoduleReviewVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws{if !value{throw Failure(description:"\(line): "+text)}}
    static func unwrap<T>(_ value:T?,_ text:String)throws->T{guard let value else{throw Failure(description:text)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Submodule review timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func own(_ value:NSWindowController){value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-16000,y:-16000));value.window?.orderFront(nil)}
    static func capture(_ window:NSWindow?,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_SUBMODULE_REVIEW_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*)else{throw Failure(description:"Owned window capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance;defer{window.alphaValue=alpha;window.appearance=appearance}
        window.alphaValue=1;window.orderFront(nil)
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture encoding failed")
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func drained(_ owners:[NSWindowController])->Bool {
        guard SubmoduleDiffWindowModel.activeReads==0,SubmoduleDiffWindowController.activeReleases==0,
              SubmoduleUpdateWindowModel.activeReads==0,SubmoduleUpdateProgressWindowModel.activeOperations==0,
              ConflictReviewOperation.activeOperations==0,ResetWindowModel.activeReads==0,ResetProgressWindowModel.activeOperations==0,
              ResetWindowController.activeChildReleases==0,FinderFilesystemWorkflowRelease.activeRetirements==0 else{return false}
        return owners.allSatisfy {owner in
            if let value=owner as? SubmoduleDiffWindowController{return !value.hasPendingWork}
            if let value=owner as? SubmoduleConflictWindowController{return !value.hasPendingWork}
            if let value=owner as? ResetWindowController{return !value.transportBatchWorkPending}
            if let value=owner as? LogWindowController{return value.model.pendingHistoryLoads==0}
            return true
        }
    }
    struct Fixture {let parent:GitRepository,child:GitRepository,path:String,old:String,next:String,other:String,parentOld:String}
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.SubmoduleReview."+UUID().uuidString
        let prefs:UserDefaults,otherPrefs:UserDefaults
        var owners:[NSWindowController]=[],release:[()->Void]=[],workspaces:[RepositoryModel]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;otherPrefs=UserDefaults(suiteName:suite+".other")!;for domain in [prefs,otherPrefs]{domain.set(false,forKey:"EnableGravatar");domain.set(false,forKey:"TGitAutoLoadSSHKey");domain.set(false,forKey:"ConfirmKillProcess");domain.set(0,forKey:"AutoCloseGitProgress")}}
        func keep<T:NSWindowController>(_ value:T)->T{owners.append(value);own(value);return value}
        func fixture(_ name:String,conflict:Bool=false)async throws->Fixture {
            let folder=root.appendingPathComponent(name),path="child 雪\nmodule",location=folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:location,withIntermediateDirectories:true)
            let parent=GitRepository(root:folder,executable:git),child=GitRepository(root:location,executable:git)
            for repo in [parent,child]{_=try await repo.run(["init","-b","main"]);for(key,value)in[("user.name","Submodule review QA"),("user.email","submodule@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}}
            try Data("base\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_=try await child.commit(message:"base")
            let old=try await child.rebaseCommit("HEAD").hash
            _=try await parent.run(["update-index","--add","--cacheinfo","160000,"+old+","+path]);_=try await parent.commit(message:"attach")
            let parentOld=try await parent.rebaseCommit("HEAD").hash
            try Data("main next\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_=try await child.commit(message:"main next")
            let next=try await child.rebaseCommit("HEAD").hash
            _=try await child.run(["checkout","-b","side",old]);try Data("other branch\n".utf8).write(to:location.appendingPathComponent("file"));try await child.stage(["file"]);_=try await child.commit(message:"side revision")
            let other=try await child.rebaseCommit("HEAD").hash;_=try await child.run(["checkout","main"])
            if conflict {
                _=try await parent.run(["checkout","-b","side"]);_=try await parent.run(["update-index","--cacheinfo","160000,"+other+","+path]);_=try await parent.commit(message:"side gitlink")
                _=try await parent.run(["checkout","main"]);_=try await parent.run(["update-index","--cacheinfo","160000,"+next+","+path]);_=try await parent.commit(message:"main gitlink")
                do{_=try await parent.run(["merge","--no-ff","side"]);throw Failure(description:"Expected actual gitlink merge conflict")}catch is GitFailure{}
            }else{try Data("dirty child\n".utf8).write(to:location.appendingPathComponent("file"))}
            return Fixture(parent:parent,child:child,path:path,old:old,next:next,other:other,parentOld:parentOld)
        }
        func cleanup()async {
            release.forEach{$0()};release=[]
            for owner in owners.reversed(){owner.close()}
            workspaces.forEach{$0.stopMonitoringForTermination()}
            for window in NSApp.windows{window.orderOut(nil);window.close()}
            for _ in 0..<3000{if drained(owners){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);otherPrefs.removePersistentDomain(forName:suite+".other")
        }
    }
    static func actions(_ c:Context)async throws {
        let f=try await c.fixture("actions"),owner=c.keep(SubmoduleDiffWindowController(repository:f.parent,access:nil,path:f.path,from:"HEAD",preferences:c.prefs)),model=owner.model
        model.load();try await wait{!model.busy && model.details != nil}
        let details=try unwrap(model.details,"Comparison missing")
        try require(details.dirty && details.from.revision==f.old && details.to.revision==f.next,"Real dirty comparison endpoints missing")
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.contains{$0.identifier?.rawValue=="Submodule comparison action"}}
        let control=try unwrap(views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.first{$0.identifier?.rawValue=="Submodule comparison action"},"Native split control missing")
        var calls:[(ComparisonRevision,ComparisonRevision,Bool)]=[],logs:[String]=[]
        model.onCompare={child,from,to in if child.root.path==f.child.root.path{calls.append((from,to,ComparisonToolInvocation.capture))}}
        model.onLog={_,hash in logs.append(hash)}
        func menu()throws->NSMenu{let value=try unwrap(control.menu(forSegment:1),"Actual split dropdown missing");value.delegate?.menuWillOpen?(value);return value}
        let initial=try menu();try require(initial.items.map(\.title)==["Show diff","Compare"] && initial.items.allSatisfy{$0.image != nil},"Source dropdown order/icons changed")
        initial.performActionForItem(at:1);try await wait{!model.busy && calls.count==1}
        try require(calls[0].0 == .revision(f.old) && calls[0].1 == .workingTree && !calls[0].2 && model.selectedComparisonAction == .compare,"Compare menu did not capture actual working-tree action")
        try await wait{control.label(forSegment:0)=="Compare"}
        let current=try menu();try require(current.items[1].state == .on,"Sticky menu choice has no check")
        control.selectedSegment=0;control.performClick(nil);try await wait{!model.busy && calls.count==2}
        try require(calls[1].1 == .workingTree,"Main split button forgot selected Compare action")
        let stale=try menu();owner.commandKeyWindow={owner.window}
        let refresh=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:String(UnicodeScalar(NSF5FunctionKey)!),charactersIgnoringModifiers:String(UnicodeScalar(NSF5FunctionKey)!),isARepeat:false,keyCode:96),"F5 event missing")
        try require(owner.window!.performKeyEquivalent(with:refresh),"Owned F5 was not consumed");try await wait{!model.busy};stale.performActionForItem(at:0);for _ in 0..<5{await Task.yield()};try require(calls.count==2,"Old menu acted after F5-equivalent source refresh")
        let native=try unwrap(control as? SubmoduleDiffNativeActionControl,"Actual native split subclass missing");native.captureAlternate={true}
        let alternate=try menu();alternate.performActionForItem(at:0);try await wait{!model.busy && calls.count==3};native.captureAlternate={false}
        try require(calls[2].1 == .revision(f.next) && calls[2].2,"Pinned revisions or alternate tool lost during actual preparation")
        model.log(details.from,receipt:model.actionReceipt);try await wait{!model.busy};model.log(details.to,receipt:model.actionReceipt);try await wait{!model.busy}
        try require(logs==[f.old,f.next],"From/To Log callbacks lost exact hashes")
        let quit=try menu();model.confirmingQuit=true;quit.performActionForItem(at:0);model.confirmingQuit=false;quit.performActionForItem(at:0);for _ in 0..<5{await Task.yield()};try require(calls.count==3,"Quit transition resurrected retained dropdown")
        let close=try menu();try await capture(owner.window,"submodule-comparison");owner.close();close.performActionForItem(at:0);for _ in 0..<5{await Task.yield()};try require(calls.count==3,"Retired native control dispatched comparison")
    }
    static func diffOwnership(_ c:Context)async throws {
        let f=try await c.fixture("diff-ownership"),value=try await f.parent.submoduleComparison(path:f.path,from:"HEAD")
        let owner=SubmoduleDiffWindowController(repository:f.parent,access:nil,path:f.path,from:"HEAD",preferences:c.prefs);var continuation:CheckedContinuation<SubmoduleComparison,Error>?,token:OperationCancellation?,closed=false
        owner.model.readDetails={request in token=request;return try await withCheckedThrowingContinuation{continuation=$0}}
        c.release.append{if let held=continuation{continuation=nil;held.resume(returning:value)}}
        owner.onClosed={closed=true};_ = c.keep(owner);owner.model.load();try await wait{continuation != nil}
        owner.close();try require(token?.isCancelled==true && owner.hasPendingWork && !closed,"Forced close released actual pending comparison producer")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pending producer escaped Quit")
        continuation?.resume(returning:value);continuation=nil;try await wait{closed && !owner.hasPendingWork}
        try require(owner.model.details==nil,"Retired read republished comparison")
        let conflict=SubmoduleDiffWindowController(repository:f.parent,access:nil,path:f.path,from:"HEAD",preferences:c.prefs);var handoff=false,pendingAtHandoff:Int?
        conflict.model.readDetails={_ in throw SubmoduleComparisonFailure.conflicted}
        conflict.model.onConflict={pendingAtHandoff=conflict.model.pendingReads;conflict.closeForConflict{handoff=true}}
        _ = c.keep(conflict);conflict.model.load();try await wait{handoff};try require(pendingAtHandoff==0,"Conflict handoff ran before failed reader drained");try require(!conflict.hasPendingWork,"Conflict handoff retained old reader/owner")
        // Hold a real child options read through the private Git executable.
        let wrapper=f.parent.root.appendingPathComponent(".git/held-git"),armed=f.parent.root.appendingPathComponent(".git/hold-options"),entered=f.parent.root.appendingPathComponent(".git/options-entered")
        func q(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        try Data(("#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = ls-files ] && [ -f "+q(armed.path)+" ]; then /usr/bin/touch "+q(entered.path)+"; while [ -f "+q(armed.path)+" ]; do /bin/sleep 1; done; fi; done\nexec "+q(c.git.path)+" \"$@\"\n").utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        c.release.append{try? FileManager.default.removeItem(at:armed)}
        let held=GitRepository(root:f.parent.root,executable:wrapper),update=c.keep(SubmoduleDiffWindowController(repository:held,access:nil,path:f.path,from:"HEAD",preferences:c.prefs));update.model.load();try await wait{!update.model.busy && update.model.details != nil}
        try Data().write(to:armed);update.model.update();try await wait{FileManager.default.fileExists(atPath:entered.path) && update.updateOptions != nil}
        let child=try unwrap(update.updateOptions,"Actual options sheet missing");try require(child.window?.sheetParent===update.window,"Update options is not owned")
        var updateClosed=false;update.onClosed={updateClosed=true};update.close();try require(!updateClosed && update.hasPendingWork,"Parent released pending Update sheet/reader")
        try? FileManager.default.removeItem(at:armed);try await wait{updateClosed && !update.hasPendingWork && child.model.pendingReads==0}
        let writeArmed=f.parent.root.appendingPathComponent(".git/hold-update"),writeEntered=f.parent.root.appendingPathComponent(".git/update-entered")
        try Data(("#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = update ] && [ -f "+q(writeArmed.path)+" ]; then /usr/bin/touch "+q(writeEntered.path)+"; while [ -f "+q(writeArmed.path)+" ]; do /bin/sleep 1; done; fi; done\nexec "+q(c.git.path)+" \"$@\"\n").utf8).write(to:wrapper)
        c.release.append{try? FileManager.default.removeItem(at:writeArmed)}
        let writing=c.keep(SubmoduleDiffWindowController(repository:held,access:nil,path:f.path,from:"HEAD",preferences:c.prefs));writing.model.load();try await wait{!writing.model.busy && writing.model.details != nil};writing.model.update()
        try await wait{writing.updateOptions != nil && writing.updateOptions?.model.canApply==true}
        try Data().write(to:writeArmed);writing.updateOptions?.model.options.noFetch=true;writing.updateOptions?.model.apply()
        try await wait{writing.updateProgress != nil && FileManager.default.fileExists(atPath:writeEntered.path)}
        let progress=try unwrap(writing.updateProgress,"Owned Update progress missing");try require(progress.window?.sheetParent===writing.window,"Update progress detached from comparison owner")
        var writeClosed=false;writing.onClosed={writeClosed=true};writing.close()
        try require(!writeClosed && writing.hasPendingWork,"Comparison released actual Update progress worker")
        try? FileManager.default.removeItem(at:writeArmed);try await wait{writeClosed && !writing.hasPendingWork && progress.model.pendingOperations==0}
    }
    static func routing(_ c:Context)async throws {
        let f=try await c.fixture("routing",conflict:true)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git)},snapshotWriter:{_ in true});c.workspaces.append(workspace);workspace.requiresRepositoryScope=false
        var conflicts:[SubmoduleConflictWindowController]=[],logs:[LogWindowController]=[],resets:[ResetWindowController]=[]
        workspace.conflictWindowPresentation={value in if let owner=value as? SubmoduleConflictWindowController{conflicts.append(c.keep(owner))}}
        workspace.logWindowPresentation={logs.append(c.keep($0))};workspace.resetWindowPresentation={value in value.model.load();resets.append(c.keep(value))}
        workspace.showConflictEditor(repository:f.parent,access:nil,path:f.path,preferences:c.prefs)
        try await wait{conflicts.count==1 && conflicts[0].model.details != nil && !conflicts[0].model.busy}
        workspace.showConflictEditor(repository:f.parent,access:nil,path:f.path,preferences:c.otherPrefs)
        try await wait{conflicts.count==2 && conflicts[1].model.details != nil && !conflicts[1].model.busy}
        let first=conflicts[0],second=conflicts[1],details=try unwrap(first.model.details,"Conflict details missing")
        try require(first !== second && first.model.operation.preferences === c.prefs && second.model.operation.preferences === c.otherPrefs,"Conflict cache merged independent origin preference domains")
        first.model.log(details.mine);try await wait{logs.count==1 && !first.model.busy && !logs[0].model.busy}
        try require(logs[0].model.repository.root.path==f.child.root.path && logs[0].model.endRevision==details.mine.revision && logs[0].model.selected.contains(details.mine.revision ?? "") && logs[0].model.colorPreferences === c.prefs,"Actual conflict child Log lost origin, end or selected hash")
        logs[0].close()
        let other=try unwrap(second.model.details,"Second conflict details missing");second.model.log(other.theirs);try await wait{logs.count==2 && !second.model.busy && !logs[1].model.busy}
        try require(logs[1].model.colorPreferences === c.otherPrefs && logs[1].model.endRevision==other.theirs.revision && logs[1].model.selected.contains(other.theirs.revision ?? ""),"Second origin reused wrong Log presentation")
        logs[1].close()
        var retiredRead:CheckedContinuation<SubmoduleConflictDetails,Error>?
        second.model.readDetails={_ in try await withCheckedThrowingContinuation{retiredRead=$0}}
        c.release.append{if let held=retiredRead{retiredRead=nil;held.resume(returning:other)}}
        second.model.load();try await wait{retiredRead != nil};second.close()
        workspace.showConflictEditor(repository:f.parent,access:nil,path:f.path,preferences:c.otherPrefs)
        try await wait{conflicts.count==3 && conflicts[2].model.details != nil && !conflicts[2].model.busy}
        try require(conflicts[2] !== second && conflicts[2].model.operation.preferences === c.otherPrefs,"Retired cache owner blocked independent replacement")
        retiredRead?.resume(returning:other);retiredRead=nil;try await wait{!second.hasPendingWork}
        workspace.showConflictEditor(repository:f.parent,access:nil,path:f.path,preferences:c.otherPrefs);try await wait{conflicts.count==4}
        try require(conflicts[3] === conflicts[2],"Old owner close callback removed replacement cache entry")
        try await capture(first.window,"submodule-conflict")
        var confirmations=0,sourceButtons=false
        first.sheets.present={_,alert,reply in confirmations += 1;sourceButtons=alert.buttons.map(\.title)==["Yes","No"];DispatchQueue.main.async{reply(.alertFirstButtonReturn)};return true}
        let index=try Data(contentsOf:f.parent.root.appendingPathComponent(".git/index")),childHead=try await f.child.run(["rev-parse","HEAD"]).stdout
        first.model.choose(details.theirs);try await wait{resets.count==1 && resets[0].model.chooser.revision==f.other && resets[0].model.canEditForm && !resets[0].model.busy && !resets[0].model.chooser.busy}
        try require(confirmations==1 && sourceButtons && resets[0].model.presentationPreferences === c.prefs && first.model.operation.hasChild,"Actual Reset handoff lost captured preferences/child ownership")
        resets[0].close();try await wait{!first.model.hasPendingWork && !first.model.operation.hasChild && first.model.canInteract}
        try require(try Data(contentsOf:f.parent.root.appendingPathComponent(".git/index"))==index,"Cancelling Reset resolved parent conflict")
        let after=try await f.child.run(["rev-parse","HEAD"]).stdout;try require(after==childHead,"Cancelling Reset moved submodule HEAD")
        let retry=try unwrap(first.model.details,"Conflict did not reload after cancelled Reset")
        first.model.choose(retry.theirs);try await wait{resets.count==2 && resets[1].model.chooser.revision==f.other && resets[1].model.canEditForm && !resets[1].model.busy && !resets[1].model.chooser.busy}
        let reset=resets[1];try require(reset.model.presentationPreferences === c.prefs,"Retry Reset changed origin preferences")
        reset.model.mode = .soft;reset.model.reset()
        do {try await wait{reset.progressController != nil && reset.progressController?.model.busy==false}}
        catch {throw Failure(description:"Reset progress readiness failed: target=\(reset.model.chooser.revision) expected=\(f.other) modelBusy=\(reset.model.busy) chooserBusy=\(reset.model.chooser.busy) canEdit=\(reset.model.canEditForm) modelError=\(reset.model.error ?? "nil") chooserError=\(reset.model.chooser.error ?? "nil") progress=\(reset.model.progress != nil) controller=\(reset.progressController != nil) progressBusy=\(String(describing:reset.progressController?.model.busy)) progressOutput=\(reset.progressController?.model.output ?? "nil") sheet=\(reset.window?.attachedSheet?.title ?? "nil") pending=\(reset.transportBatchWorkPending)")}

        let progress=try unwrap(reset.progressController,"Actual Reset progress missing");try require(progress.model.success,"Actual submodule Reset failed: "+progress.model.output)
        progress.model.close();try await wait{!first.hasPendingWork && !first.canReuse}
        let resolved=try await f.parent.run(["ls-files","--stage","-z","--",f.path]).stdout,unmerged=try await f.parent.run(["ls-files","--unmerged","-z","--",f.path]).stdout
        try require(resolved==Data(("160000 "+f.other+" 0\t"+f.path+"\0").utf8) && unmerged.isEmpty,"Successful Reset did not resume captured exact gitlink resolution")
        let resetHead=try await f.child.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(resetHead==f.other && FileManager.default.fileExists(atPath:f.parent.root.appendingPathComponent(".git/MERGE_HEAD").path),"Reset/resolution lost chosen child target or continued merge automatically")
    }
    static func conflictOwnership(_ c:Context)async throws {
        let f=try await c.fixture("conflict-ownership",conflict:true),details=try await f.parent.submoduleConflictDetails(path:f.path)
        let owner=c.keep(SubmoduleConflictWindowController(repository:f.parent,access:nil,path:f.path,preferences:c.prefs));owner.model.load();try await wait{owner.model.details != nil && !owner.model.busy}
        var reply:((NSApplication.ModalResponse)->Void)?,resolveCalls=0
        owner.sheets.present={_,_,answer in reply=answer;return true}
        let stale=owner.model.displayGeneration;owner.model.load();try await wait{!owner.model.busy && owner.model.details != nil}
        var staleLogs=0;owner.model.onLog={_,_ in staleLogs += 1};owner.model.choose(details.mine,display:stale);owner.model.log(details.mine,display:stale)
        try require(reply==nil && owner.model.pendingActions==0 && staleLogs==0,"Old conflict control receipt survived refresh")
        owner.model.resolveEntry={entry,choice,token,emit in resolveCalls += 1;return try await f.parent.resolveConflicts([entry],using:choice,cancellation:token,onOutput:emit)}
        let index=try Data(contentsOf:f.parent.root.appendingPathComponent(".git/index"))
        owner.model.choose(details.mine);try await wait{reply != nil}
        try require(owner.model.pendingActions>0 && owner.hasPendingWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned confirmation escaped Busy/Quit")
        owner.model.confirmingQuit=true;owner.model.confirmingQuit=false;reply?(.alertFirstButtonReturn);reply=nil
        try await wait{!owner.model.hasPendingWork && owner.model.canInteract}
        try require(resolveCalls==0 && Data(contentsOf:f.parent.root.appendingPathComponent(".git/index"))==index,"Late affirmative survived Quit transition")
        // A forced owner close drains a producer that deliberately ignores cancellation.
        var pending:CheckedContinuation<SubmoduleConflictDetails,Error>?,readToken:OperationCancellation?,closed=false
        owner.model.readDetails={token in readToken=token;return try await withCheckedThrowingContinuation{pending=$0}}
        c.release.append{if let held=pending{pending=nil;held.resume(returning:details)}}
        owner.onClosed={closed=true};owner.model.load();try await wait{pending != nil};owner.close()
        try require(readToken?.isCancelled==true && owner.hasPendingWork && !closed,"Conflict owner released live details producer")
        pending?.resume(returning:details);pending=nil;try await wait{closed && !owner.hasPendingWork}
        // Actual resolution receipt held after Git changed the index: close may
        // cancel publication but cannot imply that the completed write rolled back.
        let writing=c.keep(SubmoduleConflictWindowController(repository:f.parent,access:nil,path:f.path,preferences:c.prefs));writing.model.load();try await wait{writing.model.details != nil && !writing.model.busy}
        var receipt:CheckedContinuation<String,Error>?,writeToken:OperationCancellation?,writeClosed=false
        writing.model.confirmChoice={true}
        writing.model.resolveEntry={entry,choice,token,emit in writeToken=token;_ = try await f.parent.resolveConflicts([entry],using:choice,cancellation:token,onOutput:emit);return try await withCheckedThrowingContinuation{receipt=$0}}
        c.release.append{if let held=receipt{receipt=nil;held.resume(returning:"resolved before owner close")}}
        writing.onClosed={writeClosed=true};writing.model.choose(try unwrap(writing.model.details,"Write details missing").mine);try await wait{receipt != nil}
        let published=try await f.parent.run(["ls-files","--unmerged","-z","--",f.path]).stdout;try require(published.isEmpty,"Held worker did not complete actual chosen Git write")
        writing.close();try require(writeToken?.isCancelled==true && !writeClosed && writing.hasPendingWork,"Owner discarded held actual resolution worker")
        receipt?.resume(returning:"resolved before owner close");receipt=nil;try await wait{writeClosed && !writing.hasPendingWork}
        let after=try await f.parent.run(["ls-files","--unmerged","-z","--",f.path]).stdout;try require(after.isEmpty,"Close rolled back already-completed Git resolution")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited);let context=Context(),which=CommandLine.arguments[3]
        do{switch which{case "actions":try await actions(context);case "diff-ownership":try await diffOwnership(context);case "routing":try await routing(context);default:try await conflictOwnership(context)};await context.cleanup();try require(drained(context.owners),"Owned review workers, native sheets or deferred releases failed to drain");print("PASS: submodule review "+which)}catch{await context.cleanup();fputs("Submodule review failed: \(error)\n",stderr);exit(1)}
    }
}
@main struct SubmoduleReviewMain {static func main()async{await SubmoduleReviewVerification.main()}}
