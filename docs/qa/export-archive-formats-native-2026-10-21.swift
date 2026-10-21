// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func turtleExportFormatsOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-18000,y:-18000));turtleExportFormatsOrder(place,relativeTo:number)
    }
}
@MainActor enum ExportArchiveFormatsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String,line:Int = #line)throws{if !condition{throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Export formats timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func capture(_ window:NSWindow?,_ name:String)async throws{
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_EXPORT_FORMATS_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*)else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance;defer{window.alphaValue=alpha;window.appearance=appearance}
        window.orderFront(nil);window.alphaValue=1
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess,owned=try unwrap(content.windows.first{$0.windowID==CGWindowID(window.windowNumber)},"Owned capture window missing")
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            let bytes=try unwrap(NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]),"Capture encoding failed")
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ExportFormats."+UUID().uuidString,prefs:UserDefaults,clipboard=NSPasteboard.withUniqueName()
        var owners:[ExportWindowController]=[],progress:[ExportProgressWindowController]=[],release:[()->Void]=[],hashes:[String]=[],oracles:[[String:Any]]=[]
        var repository:GitRepository {GitRepository(root:root.appendingPathComponent("repo"),executable:git)}
        var outputs:URL {root.appendingPathComponent("outputs")}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(true,forKey:"ShowAppContextMenuIcons")}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repository.root.appendingPathComponent("sub"),withIntermediateDirectories:true);try FileManager.default.createDirectory(at:outputs,withIntermediateDirectories:true)
            let repo=repository;_=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Export QA"),("user.email","export@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tar.bundle.command","gzip")] {_=try await repo.run(["config",key,value])}
            for n in 0..<2 {
                try Data("root \(n)\n".utf8).write(to:repo.root.appendingPathComponent("root.txt"));try Data("scoped \(n)\n".utf8).write(to:repo.root.appendingPathComponent("sub/file 雪.txt"))
                try await repo.stage(["root.txt","sub/file 雪.txt"]);_=try await repo.commit(message:"export \(n)")
                hashes.append(try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines))
            }
        }
        func owner(_ repo:GitRepository?=nil,revision:String="HEAD",directory:String="")->ExportWindowController {
            let result=ExportWindowController(repository:repo ?? repository,access:RepositoryAccessLease(url:root),revision:revision,directory:directory,preferences:prefs)
            owners.append(result);result.window?.alphaValue=0;result.window?.setFrameOrigin(.init(x:-18000,y:-18000));result.window?.orderFront(nil)
            let original=result.model.onProgress
            result.model.onProgress={ [self,weak result] model in model.outputClipboard=clipboard;original?(model);if let child=result?.progressController{progress.append(child)}}
            return result
        }
        func record(_ url:URL,version:Int,scoped:Bool){oracles.append(["path":url.path,"members":scoped ? ["file 雪.txt":"scoped \(version)\n"]:["root.txt":"root \(version)\n","sub/file 雪.txt":"scoped \(version)\n"]])}
        func saveOracles()throws{try JSONSerialization.data(withJSONObject:oracles,options:[.sortedKeys]).write(to:root.appendingPathComponent("archive-oracles.json"))}
        func cleanup()async {
            release.forEach{$0()};release=[];owners.forEach{$0.close()};progress.forEach{$0.closeForOwnerRetirement()}
            for window in NSApp.windows{window.orderOut(nil);window.close()}
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()
        }
        func drained()->Bool {ExportWindowModel.activeReads==0 && ExportWindowModel.activeOperations==0 && ExportProgressWindowModel.activeOperations==0 && ExportProgressWindowController.activeReleases==0 && owners.allSatisfy{!$0.hasPendingWork} && progress.allSatisfy{!$0.model.hasPendingWork}}
    }
    static func exported(_ c:Context,_ owner:ExportWindowController)async throws->ExportProgressWindowController {
        let model=owner.model;try await wait{!model.busy && model.progress==nil}
        model.export();try await wait{owner.progressController != nil && owner.progressController?.model.busy==false && owner.progressController?.model.hasPendingWork==false}
        let result=try unwrap(owner.progressController,"Actual Export progress missing")
        try require(result.model.success && result.model.commandSucceeded,"Actual Export failed: "+result.model.output)
        return result
    }
    static func formats(_ c:Context)async throws {
        let repo=c.repository,head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        for (name,version,scope) in [("native.zip",1,false),("native.tar",0,true),("native.tar.gz",1,true),("custom.bundle",0,false),("fallback.unknown",1,false),("default-name",1,false)] {
            let owner=c.owner(revision:c.hashes[version],directory:scope ? "sub":""),model=owner.model
            try await wait{!model.busy && model.error==nil};model.destination=c.outputs.appendingPathComponent(name).path
            let result=try await exported(c,owner),actual=result.model.destination
            try require(actual.lastPathComponent==(name=="default-name" ? "default-name.zip":name),"Native format filename/default suffix changed: "+actual.path)
            c.record(actual,version:version,scoped:scope)
            if name=="native.zip" {
                var events:[String]=[];owner.onClosed={events.append("options closed")};let previous=result.onClosed;result.onClosed={previous();events.append("progress closed")}
                result.model.showInFinder={url in
                    if url.path==actual.path && owner.window?.attachedSheet==nil && result.window?.sheetParent==nil && !result.model.hasPendingWork {events.append("reveal")}else{events.append("invalid reveal")}
                }
                try await wait{views(result.window?.contentView).compactMap{$0 as? ExportNativeCompletionControl}.contains{$0.isEnabled}}
                let control=try unwrap(views(result.window?.contentView).compactMap{$0 as? ExportNativeCompletionControl}.first{$0.isEnabled},"Actual Export result split missing")
                let menu=try unwrap(control.menu(forSegment:1),"Export result menu missing");menu.delegate?.menuWillOpen?(menu)
                try require(menu.items.map(\.title)==["Show in Finder"] && menu.items.allSatisfy{$0.image != nil && $0.isEnabled},"Actual result menu source action/icon missing")
                result.model.confirmingQuit=true;result.model.confirmingQuit=false;menu.performActionForItem(at:0);await Task.yield();try require(!events.contains("reveal"),"Retained result menu revived after Quit")
                try await wait{control.isEnabled && result.model.canExplore && control.menu(forSegment:1) !== menu};try await capture(result.window,"export-archive-result")
                let event=try unwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:result.window!.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49),"Export result Space event missing")
                control.keyDown(with:event);result.model.explore();try await wait{events.contains("reveal")}
                try require(events.filter{$0=="reveal"}.count==1 && events.last=="reveal" && !events.contains("invalid reveal"),"Export reveal was not captured one-shot after actual owner detach")
            }else{result.model.close();try await wait{owner.progressController==nil}}
        }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        try require(afterHead==head && afterIndex==index,"Export mutated source HEAD/index")
        try c.saveOracles()
    }
    final class FinalizationGate:@unchecked Sendable {
        private let condition=NSCondition();private var entered=false,released=false,temporary:URL?
        var waiting:Bool{condition.lock();defer{condition.unlock()};return entered && !released}
        var output:URL?{condition.lock();defer{condition.unlock()};return temporary}
        func command(_ invocation:GitCommandInvocation){condition.lock();defer{condition.unlock()};if let argument=invocation.arguments.first(where:{$0.hasPrefix("--output=")}){temporary=URL(fileURLWithPath:String(argument.dropFirst(9)))}}
        func hold(){condition.lock();entered=true;condition.broadcast();while !released{condition.wait()};condition.unlock()}
        func release(){condition.lock();released=true;condition.broadcast();condition.unlock()}
    }
    static func ownership(_ c:Context)async throws {
        for forced in [false,true] {
            let destination=c.outputs.appendingPathComponent(forced ? "retired.tar.gz":"cancelled.tar.gz"),original=Data("existing destination sentinel\n".utf8)
            try original.write(to:destination)
            let model=ExportProgressWindowModel(repository:c.repository,access:RepositoryAccessLease(url:c.root),outputAccess:RepositoryAccessLease(url:destination),revision:c.hashes[0],directory:"sub",destination:destination,preferences:c.prefs),gate=FinalizationGate()
            model.outputClipboard=c.clipboard
            model.runArchive={token,output,command,finished in
                try await c.repository.archiveRevision(c.hashes[0],directory:"sub",to:destination,cancellation:token,onOutput:output,onCommand:{invocation in gate.command(invocation);command(invocation)},onCommandFinished:finished,beforeFinalization:{gate.hold()})
            }
            c.release.append{gate.release()}
            let owner=ExportProgressWindowController(model:model);c.progress.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil)
            var closed=false,revealed=0;owner.onClosed={closed=true};model.showInFinder={_ in revealed += 1}
            model.start();try await wait{gate.waiting && model.commandFinished}
            let temporary=try unwrap(gate.output,"Actual Git archive staging filename not observed")
            try require(temporary.lastPathComponent==destination.lastPathComponent && FileManager.default.fileExists(atPath:temporary.path) && model.commandSucceeded && model.hasPendingWork && (try Data(contentsOf:destination))==original,"Actual command receipt or same-basename staging/finalization lost")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held archive finalization escaped Quit")
            model.explore();try require(revealed==0,"Reveal escaped held finalization")
            if forced {owner.closeForOwnerRetirement();try require(!closed && model.hasPendingWork,"Owner released actual pending archive finalizer")}
            else {model.confirmingQuit=true;model.explore();model.confirmingQuit=false;try require(revealed==0,"Quit transition escaped pending result")}
            gate.release();try await wait{!model.hasPendingWork && !model.busy}
            try require(!FileManager.default.fileExists(atPath:temporary.path) && !FileManager.default.fileExists(atPath:temporary.deletingLastPathComponent().path),"Owned archive staging workspace leaked")
            if forced {try await wait{closed};try require((try Data(contentsOf:destination))==original && !model.success && revealed==0,"Retired archive replaced old destination or revealed late")}
            else {try require(model.success,"Live held finalization failed: "+model.output);c.record(destination,version:0,scoped:true);model.close();try await wait{closed}}
        }
        try await reentrantPresentation(c)
        try await routingRetirement(c)
        try await metadataOwnership(c)
        try await actualCancellation(c)
        try c.saveOracles()
    }
    static func actualCancellation(_ c:Context)async throws {
        let wrapper=c.root.appendingPathComponent("archive-git"),marker=c.root.appendingPathComponent("archive-pids"),destination=c.outputs.appendingPathComponent("actual-cancel.tar")
        func q(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let script="""
        #!/bin/sh
        case " $* " in *' archive '*)
          /bin/sleep 30 &
          turtle_child=$!
          trap 'kill "$turtle_child" 2>/dev/null;wait "$turtle_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$turtle_child" > \(q(marker.path))
          wait "$turtle_child"
          ;;
        esac
        exec \(q(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let original=Data("preserved actual command cancellation\n".utf8);try original.write(to:destination)
        let repo=GitRepository(root:c.repository.root,executable:wrapper),model=ExportProgressWindowModel(repository:repo,access:RepositoryAccessLease(url:c.root),outputAccess:RepositoryAccessLease(url:destination),revision:c.hashes[1],directory:"",destination:destination,preferences:c.prefs),receipt=FinalizationGate()
        model.outputClipboard=c.clipboard
        model.runArchive={token,output,command,finished in try await repo.archiveRevision(c.hashes[1],to:destination,cancellation:token,onOutput:output,onCommand:{invocation in receipt.command(invocation);command(invocation)},onCommandFinished:finished)}
        let owner=ExportProgressWindowController(model:model);c.progress.append(owner);owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        c.prefs.set(true,forKey:"ConfirmKillProcess");var answer:((NSApplication.ModalResponse)->Void)?
        owner.presentCancellation={_,_,reply in answer=reply};model.start();try await wait{FileManager.default.fileExists(atPath:marker.path)}
        let pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};try require(pids.count==2,"Archive subprocess ownership receipt missing")
        model.cancel();try await wait{answer != nil};model.confirmingQuit=true;model.confirmingQuit=false;answer?(.alertFirstButtonReturn);answer=nil
        try await wait{!model.confirmingCancellation && owner.questionWindow==nil};try require(pids.allSatisfy{kill($0,0)==0},"Retired cancellation reply killed actual archive after Quit")
        model.cancel();try await wait{answer != nil};answer?(.alertFirstButtonReturn);answer=nil
        try await wait{!model.hasPendingWork && !model.busy};try require(model.cancelled && !model.success && !model.commandSucceeded && (try Data(contentsOf:destination))==original,"Cancelled actual command replaced destination or claimed success")
        for pid in pids{try require(kill(pid,0) == -1 && errno==ESRCH,"Owned archive subprocess was not reaped")}
        if let temporary=receipt.output{try require(!FileManager.default.fileExists(atPath:temporary.deletingLastPathComponent().path),"Cancelled archive leaked owned replacement workspace")}
        model.close();c.prefs.set(false,forKey:"ConfirmKillProcess")
    }
    static func reentrantPresentation(_ c:Context)async throws {
        let head=try await c.repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        for commit in [false,true] {
            let owner=c.owner();try await wait{owner.model.canEditForm};var child:NSWindowController?,closed=false
            owner.onClosed={closed=true}
            if commit {
                owner.model.target = .commit
                owner.configureCommitPicker={_ in child=owner.commitPicker;owner.close()}
            }else{
                owner.model.target = .branch
                owner.configureReferencePicker={_ in child=owner.referencePicker;owner.close()}
            }
            owner.model.onBrowsePicker?(commit ? .commit:.branch)
            try await wait{closed && !owner.hasPendingWork}
            try require(child != nil && owner.model.retired && owner.referencePicker==nil && owner.commitPicker==nil && owner.window?.attachedSheet==nil && child?.window?.sheetParent==nil && child?.window?.isVisible != true,"Reentrant picker configuration attached/reopened a child after Export retirement")
            if let log=child as? LogWindowController{try require(log.model.isInvalidated && log.model.pendingHistoryLoads==0,"Retired commit picker retained actual work")}
            if let reference=child as? ReferenceBrowserWindowController{try require(reference.model.closed && reference.model.pendingReferenceReads==0,"Retired reference picker retained actual work")}
        }
        let owner=c.owner();try await wait{owner.model.canEditForm};let destination=c.outputs.appendingPathComponent("retired-handoff.tar.gz");owner.model.destination=destination.path
        let original=owner.model.onProgress;var captured:ExportProgressWindowModel?,closed=false
        owner.onClosed={closed=true};owner.model.onProgress={result in captured=result;owner.close();original?(result)}
        owner.model.export();try await wait{closed && !owner.hasPendingWork && captured != nil}
        let result=try unwrap(captured,"Reentrant progress callback missing")
        try require(owner.model.retired && owner.progressController==nil && owner.window?.attachedSheet==nil && !result.active && !result.hasPendingWork && !result.commandFinished && !FileManager.default.fileExists(atPath:destination.path),"Reentrant result handoff created a child or launched Git after retiring Export")
        let after=try await c.repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:c.repository.root.appendingPathComponent(".git/index"))
        try require(after==head && afterIndex==index,"Reentrant retired presentation changed source HEAD/index")
    }
    static func routingRetirement(_ c:Context)async throws {
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:c.git)},snapshotWriter:{_ in true},comparisonMarks:WorkingComparisonMarkStore(storageURL:c.root.appendingPathComponent("private-marks.json")))
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=c.prefs;workspace.notifyFinder={};workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:c.root)}
        workspace.exportWindowPresentation={owner in owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.window?.orderFront(nil)}
        defer{workspace.stopMonitoringForTermination()}
        let existing=Set(c.owners.map(ObjectIdentifier.init))
        func routed()->[ExportWindowController]{NSApp.windows.compactMap{$0.delegate as? ExportWindowController}.filter{!existing.contains(ObjectIdentifier($0))}}
        func invoke(){workspace.handleCommandLine(arguments:["--command=export"],currentDirectory:c.repository.root.path)}
        invoke();try await wait{!workspace.busy && routed().contains{$0.model.canEditForm}}
        let owner=try unwrap(routed().first{$0.model.canEditForm},"Actual routed Export missing");c.owners.append(owner)
        let destination=c.outputs.appendingPathComponent("routed.tar"),original=Data("routed existing archive\n".utf8);try original.write(to:destination);owner.model.destination=destination.path
        var answer:CheckedContinuation<Bool,Never>?,closed=false
        owner.model.confirmOverwrite={_ in await withCheckedContinuation{answer=$0}};c.release.append{answer?.resume(returning:false);answer=nil}
        let previous=owner.onClosed;owner.onClosed={previous();closed=true};owner.model.export();try await wait{answer != nil};owner.close()
        try require(!owner.canReuse && owner.hasPendingWork && !closed,"Retired routed Export did not retain actual pending overwrite work")
        workspace.error=nil;invoke();try await wait{!workspace.busy && workspace.error != nil}
        try require(workspace.error=="The previous Export window is still closing. Wait for it to finish." && !owner.canReuse && routed().allSatisfy{$0 === owner},"Cached retired Export was reopened or replaced before drain")
        answer?.resume(returning:false);answer=nil;try await wait{closed && !owner.hasPendingWork}
        try require((try Data(contentsOf:destination))==original,"Retired cached overwrite replaced original destination")
        workspace.error=nil;invoke();try await wait{!workspace.busy && routed().contains{$0 !== owner && $0.model.canEditForm}}
        let fresh=try unwrap(routed().first{$0 !== owner && $0.model.canEditForm},"Fresh Export owner missing after retirement");c.owners.append(fresh)
        try require(fresh.canReuse && fresh.model.presentationPreferences === c.prefs,"Fresh Export cache lost captured private preferences")
        for controller in [owner,fresh]{if let window=controller.window{try require(!window.isVisible || window.alphaValue==0 || !NSScreen.screens.contains{$0.frame.intersects(window.frame)},"Routed Export escaped private presentation: alpha=\(window.alphaValue) frame=\(window.frame)")}}
    }
    static func metadataOwnership(_ c:Context)async throws {
        let wrapper=c.root.appendingPathComponent("metadata-git"),marker=c.root.appendingPathComponent("metadata-pids")
        func q(_ value:String)->String{"'"+value.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        let script="""
        #!/bin/sh
        case " $* " in *' for-each-ref '*)
          /bin/sleep 30 &
          turtle_child=$!
          trap 'kill "$turtle_child" 2>/dev/null;wait "$turtle_child" 2>/dev/null;exit 143' TERM INT
          printf '%s %s\\n' "$$" "$turtle_child" > \(q(marker.path))
          wait "$turtle_child"
          ;;
        esac
        exec \(q(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let repo=GitRepository(root:c.repository.root,executable:wrapper),owner=c.owner(repo),model=owner.model;var closed=false;owner.onClosed={closed=true}
        try await wait{FileManager.default.fileExists(atPath:marker.path)}
        try require(owner.hasPendingWork && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Export metadata read escaped owner/Quit")
        owner.close();try require(!closed,"Export metadata owner released before real query cancellation/drain")
        try await wait{closed && !owner.hasPendingWork}
        let pids=try String(contentsOf:marker).split(whereSeparator:{$0.isWhitespace}).compactMap{Int32($0)};try require(pids.count==2,"Metadata worker receipt missing")
        for pid in pids{try require(kill(pid,0) == -1 && errno==ESRCH,"Metadata worker was not reaped")}
        try require(model.references.isEmpty && model.error==nil && model.exported==nil,"Late metadata callback published into closed Export")
    }
    static func chooser(_ c:Context)async throws {
        for (index,name,expected) in [(0,"chosen","chosen.zip"),(1,"chosen","chosen.tar"),(2,"chosen","chosen.tar.gz"),(3,"custom.bundle","custom.bundle"),(3,"noextension","noextension.zip")] {
            let owner=c.owner(),model=owner.model;try await wait{model.canEditForm}
            var panel:NSSavePanel?,answer:((NSApplication.ModalResponse)->Void)?
            owner.presentSavePanel={value,_,reply in panel=value;answer=reply};owner.selectedSaveURL={_ in c.outputs.appendingPathComponent(name)}
            model.chooseDestination();try await wait{panel != nil && owner.archiveFormatPopup != nil}
            let nativePanel=try unwrap(panel,"Actual save chooser missing"),popup=try unwrap(owner.archiveFormatPopup,"Actual archive format control missing")
            try require(popup.itemTitles==["ZIP archive (*.zip)","TAR archive (*.tar)","TAR GZIP archive (*.tar.gz)","All Files (*.*)"] && nativePanel.allowsOtherFileTypes,"Save chooser source formats/custom filename option missing")
            if index==1 {nativePanel.nameFieldStringValue="generated.zip"}
            popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target)
            if index==1 {try require(nativePanel.nameFieldStringValue=="generated.tar","Changing native filter did not update recognized ZIP suffix")}

            if index==3 {try require(nativePanel.allowedContentTypes.isEmpty,"All Files retained a restrictive native content type")}
            else {try require(!nativePanel.allowedContentTypes.isEmpty,"Archive type failed to constrain native chooser")}
            try require(owner.panel(nativePanel,userEnteredFilename:"bare-name",confirmed:true)==(index==1 ? "bare-name.tar":index==2 ? "bare-name.tar.gz":"bare-name.zip"),"Save default suffix did not follow selected native type")
            for literal in ["custom.bundle",".profile","trailing."]{try require(owner.panel(nativePanel,userEnteredFilename:literal,confirmed:true)==literal,"Native delegate changed explicit/custom suffix: "+literal)}
            answer?(.OK);answer=nil;try await wait{owner.savePanel==nil && !owner.hasPendingWork}
            try require(model.destination==c.outputs.appendingPathComponent(expected).path && model.outputAccess?.url.path==model.destination,"Accepted chooser lost captured path/file grant: "+model.destination)
            try require(c.prefs.string(forKey:"Export.LastDirectory")==c.outputs.path && !FileManager.default.fileExists(atPath:model.destination),"Save chooser forgot source directory or exported before acceptance")
            if index==0 {try await capture(owner.window,"export-archive-options")}
            owner.close()
        }
        for (name,index) in [("prefilled.tar.gz",2),("prefilled.bundle",3)] {
            let owner=c.owner();try await wait{owner.model.canEditForm};owner.model.destination=c.outputs.appendingPathComponent(name).path
            var answer:((NSApplication.ModalResponse)->Void)?;owner.presentSavePanel={_,_,reply in answer=reply};owner.model.chooseDestination();try await wait{answer != nil}
            try require(owner.archiveFormatPopup?.indexOfSelectedItem==index && owner.savePanel?.nameFieldStringValue==name,"Prefilled suffix did not select matching native save filter: "+name)
            answer?(.cancel);try await wait{!owner.hasPendingWork};owner.close()
        }
        let owner=c.owner(),model=owner.model;try await wait{model.canEditForm};model.destination=c.outputs.appendingPathComponent("original.zip").path
        var reply:((NSApplication.ModalResponse)->Void)?;owner.presentSavePanel={_,_,answer in reply=answer};owner.selectedSaveURL={_ in c.outputs.appendingPathComponent("late.tar")}
        model.chooseDestination();try await wait{reply != nil};let old=model.destination
        model.confirmingQuit=true;model.confirmingQuit=false;reply?(.OK);reply=nil;try await wait{owner.savePanel==nil}
        try require(model.destination==old && model.outputAccess==nil,"Late save reply accepted a path/grant after Quit retired capture")
        model.chooseDestination();try await wait{reply != nil};var closed=false;owner.onClosed={closed=true};owner.close();reply?(.OK);reply=nil
        try await wait{closed && !owner.hasPendingWork};try require(model.destination==old && model.outputAccess==nil,"Late save reply retargeted retired Export")
        let overwrite=c.owner(revision:c.hashes[0],directory:"sub");try await wait{overwrite.model.canEditForm}
        let path=c.outputs.appendingPathComponent("overwrite.tar"),sentinel=Data("captured original archive\n".utf8);try sentinel.write(to:path);overwrite.model.destination=path.path
        var question:NSAlert?,questionReply:((NSApplication.ModalResponse)->Void)?
        overwrite.presentOverwrite={alert,_,answer in question=alert;questionReply=answer};overwrite.model.export();try await wait{question != nil}
        try require(question?.informativeText==path.path && overwrite.hasPendingWork,"Overwrite question did not capture exact selected destination/owner")
        overwrite.model.confirmingQuit=true;overwrite.model.confirmingQuit=false;questionReply?(.alertSecondButtonReturn);questionReply=nil
        try await wait{!overwrite.model.hasPendingWork && overwrite.overwriteAlert==nil};try require((try Data(contentsOf:path))==sentinel && overwrite.progressController==nil,"Late overwrite Replace escaped Quit capture")
        overwrite.model.export();try await wait{questionReply != nil};questionReply?(.alertSecondButtonReturn);questionReply=nil
        try await wait{overwrite.progressController?.model.success==true && overwrite.progressController?.model.hasPendingWork==false}
        c.record(path,version:0,scoped:true);overwrite.progressController?.model.close();try await wait{!overwrite.hasPendingWork};try c.saveOracles()
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleExportFormatsOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let context=Context(),which=CommandLine.arguments[3]
        do{try await context.seed();switch which{case "formats":try await formats(context);case "chooser":try await chooser(context);default:try await ownership(context)};await context.cleanup();try require(context.drained(),"Export owned work/native releases did not drain");print("PASS: Export formats "+which)}catch{await context.cleanup();fputs("Export formats failed: \(error)\n",stderr);exit(1)}
    }
}
@main struct ExportFormatsMain{static func main()async{await ExportArchiveFormatsVerification.main()}}
