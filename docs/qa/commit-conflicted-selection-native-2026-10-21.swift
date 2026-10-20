// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum ConflictedCommitVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ predicate:()->Bool)async throws{for _ in 0..<3000{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Conflicted Commit timeout at \(line)")}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func ready(_ model:CommitWindowModel)async throws{try await wait{!model.busy && model.commitIdentityPrepared && model.changelistsLoaded && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.loadingAmendMessage && !model.mergeHintVisible && !model.stagingHintVisible}}
    static func drained()->Bool{CommitWindowModel.activeCommitPreflights==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0}
    @MainActor final class Context {
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ConflictedCommit."+UUID().uuidString
        let prefs:UserDefaults
        var owners:[CommitWindowController]=[],releases:[()->Void]=[]
        let first="checked 雪\n[*]",second="second",missing="missing"
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation"]{prefs.set(true,forKey:key)};prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"AddBeforeCommit");prefs.set(false,forKey:"SelectFilesForCommit");prefs.set(0,forKey:"AutoCloseGitProgress")}
        func fixture(_ name:String,staging:Bool=false)async throws->GitRepository {
            let root=folder.appendingPathComponent(name);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            let repo=GitRepository(root:root,executable:git,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Native conflict QA"),("user.email","conflict@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport",staging ? "true":"false")] {_=try await repo.run(["config",key,value])}
            for path in [first,second,missing]{try Data("base\n".utf8).write(to:root.appendingPathComponent(path))};try await repo.stage([first,second,missing]);_=try await repo.commit(message:"base")
            _=try await repo.run(["checkout","-b","side"])
            for path in [first,second,missing]{try Data("side\n".utf8).write(to:root.appendingPathComponent(path))};try await repo.stage([first,second,missing]);_=try await repo.commit(message:"side")
            _=try await repo.run(["checkout","main"])
            for path in [first,second,missing]{try Data("main\n".utf8).write(to:root.appendingPathComponent(path))};try await repo.stage([first,second,missing]);_=try await repo.commit(message:"main")
            do{_=try await repo.run(["merge","--no-ff","side"]);throw Failure(description:"Expected actual merge conflict")}catch is GitFailure{}
            return repo
        }
        func owner(_ repo:GitRepository)->CommitWindowController{
            let value=CommitWindowController(repository:repo,access:nil,defaults:prefs);owners.append(value)
            value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-14000,y:-14000));value.window?.orderFront(nil)
            value.presentConflictQuestion={_,alert,reply in DispatchQueue.main.async{reply(.alertFirstButtonReturn)};return true}
            value.model.onCommitProgress={progress in progress.dismissWithoutWindow=true}
            value.model.reload(paths:["."]);return value
        }
        func cleanup()async{releases.forEach{$0()};releases=[];owners.forEach{$0.close()};for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};owners.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite)}
    }
    static func capture(_ window:NSWindow?,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_CONFLICT_CAPTURES"],let window else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned compositor capture unavailable")}
        let alpha=window.alphaValue,appearance=window.appearance
        defer{window.alphaValue=alpha;window.appearance=appearance;window.orderOut(nil)}
        window.alphaValue=1;window.orderFront(nil)
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:150_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)})else{throw Failure(description:"Owned capture window missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])else{throw Failure(description:"Owned capture encoding failed")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func selection(_ c:Context)async throws{
        let repo=try await c.fixture("selection"),owner=c.owner(repo),model=owner.model;try await ready(model)
        let rows=model.entries.filter{$0.state == .conflicted};try require(rows.count==3,"Actual conflicted rows missing")
        try require(rows.allSatisfy{!model.checked.contains($0.id)},"Fresh default selection checked conflicts")
        let first=try rows.first(where:{$0.path==c.first}).unwrap("Literal conflict missing")
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()=="Include "+c.first && $0.isEnabled}}
        let checkbox=try views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Include "+c.first}.unwrap("Native conflict checkbox missing")
        checkbox.performClick(nil)
        try require(model.checked.contains(first.id),"Actual manual conflict checkbox ignored")
        model.setFileChecked(first,files:rows,highlighted:rows.map(\.id),checked:true)
        try require(rows.allSatisfy{model.checked.contains($0.id)},"Highlighted checkbox did not include conflicts")
        model.setGroupChecked(rows,checked:false);try require(rows.allSatisfy{!model.checked.contains($0.id)},"Uncheck group retained conflicts")
        model.setGroupChecked(rows,checked:true);try require(rows.allSatisfy{model.checked.contains($0.id)},"Check group omitted conflicts")
        model.checkAll(false);try require(rows.allSatisfy{!model.checked.contains($0.id)},"None retained conflict choices")
        model.checkAll(true);try require(rows.allSatisfy{model.checked.contains($0.id)},"All omitted manually selectable conflicts")
        try await capture(owner.window,"commit-conflicted-selection")
        let stale=model.fileCheckReceipt;model.reload();try await ready(model);let unchanged=model.checked;model.setGroupChecked(rows,checked:true,receipt:stale);try require(model.checked==unchanged,"Old checkbox receipt survived actual reload")
        let before=model.checked;model.confirmingQuit=true;model.setFileChecked(first,files:rows,highlighted:[first.id],checked:false);try require(model.checked==before,"Quit accepted checkbox change");model.confirmingQuit=false
        let unmerged=try await repo.run(["ls-files","--unmerged","-z"]).stdout;try require(!unmerged.isEmpty,"Checkbox selection alone modified index")
        c.prefs.set(true,forKey:"SelectFilesForCommit");let automatic=c.owner(repo);try await ready(automatic.model)
        try require(automatic.model.entries.filter{$0.state == .conflicted}.allSatisfy{automatic.model.checked.contains($0.id)},"Source automatic selection omitted conflicts")
    }
    static func staging(_ c:Context)async throws{
        let repo=try await c.fixture("staging",staging:true),owner=c.owner(repo),model=owner.model;try await ready(model)
        try require(model.stagingEnabled,"Actual staging config not applied")
        try Data("chosen current bytes\n".utf8).write(to:repo.root.appendingPathComponent(c.first));try FileManager.default.removeItem(at:repo.root.appendingPathComponent(c.missing))
        let before=try await repo.run(["ls-files","--unmerged","-z","--",c.second]).stdout
        try await wait{views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.accessibilityLabel()=="Stage "+c.first && $0.isEnabled}}
        let checkbox=try views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.accessibilityLabel()=="Stage "+c.first}.unwrap("Native staging conflict checkbox missing")
        checkbox.performClick(nil);try await ready(model)
        model.moveToStage([c.missing],staged:true);try await ready(model)
        let chosen=try await repo.run(["show",":"+c.first]).text,missing=try await repo.run(["ls-files","--stage","-z","--",c.missing]).stdout,other=try await repo.run(["ls-files","--unmerged","-z","--",c.second]).stdout
        try require(chosen=="chosen current bytes\n" && missing.isEmpty && other==before,"Staging failed current content/deletion or touched unrelated conflict")
        try require(model.entries.contains{$0.path==c.first && model.isStaged($0)},"Actual stage completion did not publish staged checkbox state")
        try await capture(owner.window,"commit-conflicted-staging")
    }
    static func warning(_ c:Context)async throws{
        let repo=try await c.fixture("warning"),owner=c.owner(repo),model=owner.model;var mergeAlerts=0
        owner.presentConflictQuestion={_,alert,reply in
            if alert.messageText.contains("merge") || alert.informativeText.contains("merge") {mergeAlerts += 1;alert.suppressionButton?.state = .on}
            DispatchQueue.main.async{reply(.alertFirstButtonReturn)};return true
        }
        try await ready(model);try await wait{mergeAlerts==1 && !model.mergeHintVisible}
        try require(mergeAlerts==1,"Unsuppressed merge owner did not show owned source hint")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        var conflicts=0
        owner.presentConflictQuestion={_,alert,reply in conflicts += 1;alert.suppressionButton?.state = .on;DispatchQueue.main.async{reply(.alertFirstButtonReturn)};return true}
        model.message="Do not proceed";model.checked=[c.first];try await wait{model.canCommit};model.commit();try await wait{!model.busy && CommitWindowModel.activeCommitPreflights==0}
        try require(conflicts==1 && c.prefs.integer(forKey:"CommitWarnOnUnresolved")==1,"Owned warning OK suppression not recorded")
        let stopped=try await repo.run(["rev-parse","HEAD"]).stdout;try require(stopped==head && Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Warning OK mutated repository")
        SavedDataStore(preferences:c.prefs).clear(.storedDecisions)
        try require(c.prefs.object(forKey:"CommitWarnOnUnresolved")==nil && c.prefs.object(forKey:"CommitMergeHint")==nil,"Stored decisions clear retained conflict/merge warnings")
        let savedWorking=try Data(contentsOf:repo.root.appendingPathComponent(c.first))
        model.withFileMenu(model.fileMenu([c.first])){model.markForRestore([c.first])};try await ready(model)
        try require(model.restoreCopies[c.first] != nil,"Conflict working-copy recovery receipt missing")
        try Data("accepted chosen working bytes\n".utf8).write(to:repo.root.appendingPathComponent(c.first));model.reload();try await ready(model);model.checked=[c.first]
        owner.presentConflictQuestion={_,alert,reply in conflicts += 1;alert.suppressionButton?.state = .on;DispatchQueue.main.async{reply(.alertSecondButtonReturn)};return true}
        model.message="Explicitly accept working conflict bytes";model.commit();try await wait{!model.busy && CommitWindowModel.activeCommitPreflights==0}
        try require(conflicts==2 && c.prefs.integer(forKey:"CommitWarnOnUnresolved")==2,"Owned Ignore suppression not recorded")
        let committed=try await repo.run(["show","HEAD:"+c.first]).stdout;try require(committed==Data("accepted chosen working bytes\n".utf8) && Data(contentsOf:repo.root.appendingPathComponent(c.first))==savedWorking && model.restoreCopies.isEmpty,"Ignore lost actual chosen bytes or saved working-copy recovery")
    }
    static func ownership(_ c:Context)async throws{
        let repo=try await c.fixture("ownership"),owner=c.owner(repo),model=owner.model;try await ready(model)
        var reply:((NSApplication.ModalResponse)->Void)?,closed=false
        owner.presentConflictQuestion={_,_,answer in reply=answer;return true};owner.onClosed={closed=true}
        model.message="Retired warning must not commit";model.checked=[c.first];try await wait{model.canCommit}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        model.commit();try await wait{reply != nil};owner.close();try await wait{drained() && closed}
        reply?(.alertSecondButtonReturn);for _ in 0..<10{await Task.yield()}
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after==head && Data(contentsOf:repo.root.appendingPathComponent(".git/index"))==index,"Late Ignore after owner close mutated repository")
        try require(c.prefs.object(forKey:"CommitWarnOnUnresolved")==nil,"Retired warning saved suppression")
        let stageRepo=try await c.fixture("owned-stage",staging:true),wrapper=stageRepo.root.appendingPathComponent(".git/held-git"),marker=stageRepo.root.appendingPathComponent(".git/stage-entered")
        func q(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\"'\"'")+"'"}
        try Data(("#!/bin/sh\nfor a in \"$@\"; do if [ \"$a\" = add ]; then /usr/bin/touch "+q(marker.path)+"; while :; do /bin/sleep 1; done; fi; done\nexec "+q(c.git.path)+" \"$@\"\n").utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let held=GitRepository(root:stageRepo.root,executable:wrapper,libgit2Configuration:.init(enabled:false)),stageOwner=c.owner(held);try await ready(stageOwner.model)
        let original=try await stageRepo.run(["ls-files","--stage","-z"]).stdout
        stageOwner.model.moveToStage([c.first],staged:true);try await wait{FileManager.default.fileExists(atPath:marker.path)}
        try require(stageOwner.model.busy && CommitWindowModel.activeFileOperations>0,"Actual held staging worker lost owner/Quit accounting")
        try require(stageOwner.model.cancelFileOperation(),"Actual staging cancellation unavailable");try await ready(stageOwner.model)
        let retained=try await stageRepo.run(["ls-files","--stage","-z"]).stdout;try require(retained==original,"Cancelled pre-write staging changed conflict stages")
        stageOwner.model.error=nil;try await wait{stageOwner.window?.attachedSheet==nil}
    }
    static func main()async{
        NSApplication.shared.setActivationPolicy(.prohibited);let context=Context(),which=CommandLine.arguments[3]
        do{switch which{case "selection":try await selection(context);case "warning":try await warning(context);case "staging":try await staging(context);default:try await ownership(context)};await context.cleanup();try require(drained(),"Workers failed to drain");print("PASS: conflicted Commit "+which)}catch{await context.cleanup();fputs("Conflicted Commit failed: \(error)\n",stderr);exit(1)}
    }
}
private extension Optional {func unwrap(_ message:String)throws->Wrapped{guard let self else{throw ConflictedCommitVerification.Failure(description:message)};return self}}
@main struct ConflictedCommitMain {static func main()async{await ConflictedCommitVerification.main()}}
