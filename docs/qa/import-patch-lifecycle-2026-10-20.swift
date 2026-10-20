// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@main struct ImportPatchSafetyVerification {
    struct Failure:Error,CustomStringConvertible,LocalizedError {let description:String;var errorDescription:String?{description}}
    @MainActor static var diagnostic:()->String={""}
    static func require(_ condition:Bool,_ message:String,line:UInt = #line)throws {if !condition{throw Failure(description:"\(line): "+message)}}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Import Patch timeout at \(line): \(message); \(diagnostic())")
    }
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return[root]+root.subviews.flatMap{views($0)}}
    @MainActor static func button(_ title:String,in window:NSWindow?)throws->NSButton {
        try require(window != nil,"Missing button owner")
        guard let button=views(window?.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title})else{throw Failure(description:"Missing actual native "+title+" button")};return button
    }
    @MainActor final class Gate<Value> {
        private var continuation:CheckedContinuation<Value,Error>?,result:Result<Value,Error>?
        var entered=false,token:OperationCancellation?
        func read(_ token:OperationCancellation)async throws->Value {self.token=token;entered=true;if let result{return try result.get()};return try await withCheckedThrowingContinuation{continuation=$0}}
        func finish(_ value:Result<Value,Error>){guard result==nil else{return};result=value;let reply=continuation;continuation=nil;reply?.resume(with:value)}
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),suite:String,prefs:UserDefaults
        var owners:[ImportPatchWindowController]=[],unblock:[()->Void]=[]
        init(){let name="TurtleGit.ImportSafety."+UUID().uuidString;suite=name;prefs=UserDefaults(suiteName:name)!;prefs.set(true,forKey:"HintHierarchicalConfig");prefs.set(false,forKey:"ConfirmKillProcess")}
        func fixture(_ name:String,conflict:Bool=false)async throws->(GitRepository,[URL]) {
            let directory=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let repo=GitRepository(root:directory,executable:git,askpass:nil)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Import lifecycle"),("user.email","import@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            try Data("base\n".utf8).write(to:directory.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Base")
            _=try await repo.run(["switch","-c","patch-source"])
            var patches:[URL]=[]
            for(index,path)in["file","other"].enumerated(){
                try Data("patch content\n".utf8).write(to:directory.appendingPathComponent(path));try await repo.stage([path]);_=try await repo.run(["-c","user.name=Original Author 雪","-c","user.email=original@example.invalid","commit","-m","Imported \(index)"])
                let patch=directory.appendingPathComponent("mail 雪\n\(index).patch");try await repo.run(["format-patch","-1","--stdout","HEAD"]).stdout.write(to:patch);patches.append(patch)
            }
            _=try await repo.run(["switch","main"])
            if conflict{try Data("our conflicting content\n".utf8).write(to:directory.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Conflicting main")}
            return(repo,patches)
        }
        func owner(_ repo:GitRepository)->ImportPatchWindowController {
            let owner=ImportPatchWindowController(repository:repo,access:nil,preferences:prefs);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.window?.orderFront(nil);owners.append(owner)
            diagnostic={"closed=\(owner.model.closed), busy=\(owner.model.busy), closing=\(owner.model.closing), workers=\(ImportPatchWindowModel.activeWorkers), states=\(owner.model.items.map{$0.state.rawValue}), error=\(String(describing:owner.model.error)), identityPending=\(owner.identitySession.hasPendingWork), sheet=\(String(describing:owner.window?.attachedSheet)), output=\(owner.model.output)"}
            return owner
        }
        func cleanup()async {
            unblock.forEach{$0()};unblock=[];owners.forEach{$0.close()}
            for _ in 0..<2500 {if ImportPatchWindowModel.activeWorkers==0 && ImportPatchWindowController.activeReleases==0 && SettingsSheetController.activeSheets==0{break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);diagnostic={""}
        }
    }
    @MainActor static func run(_ body:(Context)async throws->Void)async throws {
        let context=Context();do{try await body(context);await context.cleanup();try require(ImportPatchWindowModel.activeWorkers==0 && ImportPatchWindowController.activeReleases==0,"Import workers/owners did not drain")}catch{await context.cleanup();throw error}
    }
    @MainActor static func main()async throws {
        NSApp.setActivationPolicy(.prohibited)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_IMPORT_SAFETY_CASE"] {
        case "identity":try await identity()
        case "recovery":try await recovery()
        case "lifetime":try await lifetime()
        default:throw Failure(description:"Unknown Import Patch lifecycle case")
        }
        print("PASS: Import Patch lifecycle case completed")
    }
    @MainActor static func identity()async throws {try await run{context in
        let(repo,patches)=try await context.fixture("identity"),owner=context.owner(repo),model=owner.model
        // Three explicit identity fields are populated; missing committer email
        // must still open the shared four-field gate before any git-am mutation.
        for(key,value)in[("user.name",""),("user.email",""),("author.name","Explicit author"),("author.email","explicit@example.invalid"),("committer.name","Explicit committer")] {_=try await repo.run(["config",key,value])}
        model.add(patches);let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        model.apply();try await wait("missing fourth identity field question"){owner.identitySession.question != nil}
        try require(model.busy && model.items.allSatisfy{$0.state == .pending},"Import started before four-field identity gate")
        owner.identitySession.question!.buttons[1].performClick(nil)
        try await wait("identity No drains"){!model.busy && !owner.identitySession.hasPendingWork}
        let denied=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(denied==head && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index && model.error==nil,"Identity No changed Git or reported an import failure")
        model.apply();try await wait("identity preparation Abort question"){owner.identitySession.question != nil}
        model.requestStop();try await wait("Abort cancels identity preparation promptly"){!model.busy && !owner.identitySession.hasPendingWork && owner.window?.attachedSheet==nil}
        let stoppedHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(stoppedHead==head && model.error==nil && model.items.allSatisfy{$0.state == .pending},"Abort during identity imported or failed the patch batch")
        model.apply();try await wait("identity retry question"){owner.identitySession.question != nil}
        let first=owner.identitySession.question!;first.buttons[0].performClick(nil)
        try await wait("actual shared Git Settings"){owner.identitySession.settingsWindow != nil && owner.identitySession.navigation?.selected == .git}
        try require(owner.identitySession.settingsWindow?.alphaValue==0 && model.items.allSatisfy{$0.state == .pending},"Settings child became visible or imported early")
        try button("Cancel",in:owner.identitySession.settingsWindow).performClick(nil)
        try await wait("Settings Cancel rechecks incomplete identity"){owner.identitySession.question != nil && owner.identitySession.question !== first}
        owner.identitySession.question!.buttons[0].performClick(nil)
        try await wait("second actual Git Settings"){owner.identitySession.settingsWindow != nil}
        _=try await repo.run(["config","user.email","repaired@example.invalid"])
        try button("Cancel",in:owner.identitySession.settingsWindow).performClick(nil)
        try await wait("repair reread imports real patches"){!model.busy && model.finished && !owner.identitySession.hasPendingWork}
        let identities=try await repo.run(["log","-2","--format=%an <%ae>|%cn <%ce>"]).text
        try require(identities.components(separatedBy:"Original Author 雪 <original@example.invalid>").count==3 && identities.components(separatedBy:"Explicit committer <repaired@example.invalid>").count==3,"Actual am lost patch authors or repaired committer")
        // Completed Apply becomes OK, but must still pass source identity check.
        _=try await repo.run(["config","user.email",""])
        var closed=0;owner.onClosed={closed += 1};model.apply()
        try await wait("finished OK still requires identity"){owner.identitySession.question != nil}
        owner.identitySession.question!.buttons[1].performClick(nil);try await wait("finished identity No settles"){!model.busy && !model.closing}
        try require(closed==0 && !model.closed && model.finished && !model.accepted,"Finished OK bypassed identity or discarded editor on No")
        _=try await repo.run(["config","user.email","repaired@example.invalid"]);model.apply()
        try await wait("finished accepted OK closes once"){closed==1 && model.closed && ImportPatchWindowModel.activeWorkers==0}
        try require(model.accepted,"Completed OK lost accepted result")
        print("PASS: actual four-field identity gate, No preservation, owned Git Settings Cancel/recheck/repair loop, patch-author preservation and identity before completed OK")
    }}
    @MainActor static func recovery()async throws {try await run{context in
        let(repo,patches)=try await context.fixture("recovery-retry",conflict:true),owner=context.owner(repo),model=owner.model
        // Keep the AppKit controller/owned source questions while preventing a
        // SwiftUI error alert from covering the injected recovery-choice boundary.
        owner.window?.contentViewController=nil
        model.add(patches);model.apply();try await wait("first actual am conflict"){!model.busy && model.items.first?.state == .failed}
        let reviewed=try await repo.mailPatchRecoverySession();try require(reviewed != nil,"Actual conflict did not retain am session")
        var choices=0,captured:[MailPatchRecoverySession]=[]
        model.chooseRecovery={choices += 1;return choices==1 ? .resolved:.skip}
        model.recoverReviewedSession={action,session,token in captured.append(session);return try await repo.recoverMailPatch(action,reviewed:session,cancellation:token)}
        model.apply();try await wait("failed Resolved reoffers recovery then Skip imports next patch"){!model.busy && model.finished}
        let after=try await repo.mailPatchRecoverySession(),subject=try await repo.run(["log","-1","--format=%s"]).text
        try require(choices==2 && captured.count==2 && captured[0]==reviewed && captured[1]==reviewed,"Ordinary recovery error recaptured or replaced the reviewed session")
        try require(after==nil && model.items[0].state == .skipped && model.items[1].state == .success && model.error==nil && subject=="Imported 1\n","Recovery retry lost row ownership or actual next patch import")
        try require(model.output.contains("--resolved") && model.output.contains("--skip"),"Recovery log omitted attempted source choices")
        let(replacementRepo,replacementFiles)=try await context.fixture("replaced-session",conflict:true),replacementOwner=context.owner(replacementRepo),replacement=replacementOwner.model
        replacementOwner.window?.contentViewController=nil;replacement.add(replacementFiles);replacement.apply()
        try await wait("second actual conflict"){!replacement.busy && replacement.items.first?.state == .failed}
        let oldSession=try await replacementRepo.mailPatchRecoverySession(),choice=Gate<MailPatchRecovery?>()
        context.unblock.append{choice.finish(.success(nil))}
        replacement.chooseRecovery={try? await choice.read(replacement.activeCancellation!)}
        replacement.apply();try await wait("captured recovery choice held"){choice.entered}
        _=try await replacementRepo.recoverMailPatch(.abort)
        do{_=try await replacementRepo.importMailPatch(replacementFiles[0]);throw Failure(description:"Expected recreated conflict")}catch is GitFailure{}
        let newSession=try await replacementRepo.mailPatchRecoverySession(),head=try await replacementRepo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:replacementRepo.root.appendingPathComponent(".git/index"))
        try require(oldSession != nil && newSession != nil && oldSession != newSession,"Replacement fixture failed to create a new session incarnation")
        choice.finish(.success(.skip));try await wait("stale choice rejected without automatic retry"){!replacement.busy}
        let retained=try await replacementRepo.mailPatchRecoverySession(),afterHead=try await replacementRepo.run(["rev-parse","HEAD"]).stdout
        try require(retained==newSession && afterHead==head && (try Data(contentsOf:replacementRepo.root.appendingPathComponent(".git/index")))==index && replacement.error != nil && !replacement.finished,"Old recovery choice mutated replacement session or falsely completed row")
        print("PASS: actual failed git-am Resolved retries against captured session, Skip updates matching row/imports next patch; stale choice cannot mutate a recreated session")
    }}
    @MainActor static func lifetime()async throws {try await run{context in
        for phase in ["identity","session","recovery","close-read"] {
            let(repo,patches)=try await context.fixture("held-"+phase,conflict:phase=="recovery"),owner=context.owner(repo),model=owner.model
            owner.window?.contentViewController=nil
            if phase=="recovery" {model.add(patches);model.apply();try await wait("prepare real recovery conflict"){!model.busy && model.items.first?.state == .failed}}
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),session=try await repo.mailPatchRecoverySession()
            let heldIdentity=Gate<ReplayUserIdentity>(),heldSession=Gate<MailPatchRecoverySession?>(),heldRecovery=Gate<Void>(),heldClose=Gate<MailPatchSession>()
            let identity=try await repo.replayUserIdentity()
            context.unblock.append{heldIdentity.finish(.success(identity));heldSession.finish(.success(session));heldRecovery.finish(.success(()));heldClose.finish(.success(.none))}
            switch phase {
            case "identity":owner.identitySession.readIdentity={try await heldIdentity.read($0)}
            case "session":model.readRecoverySession={try await heldSession.read($0)}
            case "recovery":
                model.chooseRecovery={.abort}
                model.recoverReviewedSession={action,reviewed,token in try await heldRecovery.read(token);return try await repo.recoverMailPatch(action,reviewed:reviewed,cancellation:token)}
            default:model.readSession={try await heldClose.read($0)}
            }
            var closed=0,changed=0;owner.onClosed={closed += 1};model.onChanged={_ in changed += 1}
            if phase=="close-read" {model.requestClose()}else {if model.items.isEmpty{model.add(patches)};model.apply()}
            try await wait("held "+phase){heldIdentity.entered || heldSession.entered || heldRecovery.entered || heldClose.entered}
            let token=model.activeCancellation,output=model.output
            owner.close()
            try require(!owner.presentationClosed && model.hasPendingWork && closed==0 && ImportPatchWindowModel.activeWorkers>0 && token?.isCancelled==true,"Forced \(phase) close released pending owned work")
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored retired pending "+phase)
            heldIdentity.finish(.success(identity));heldSession.finish(.success(session));heldRecovery.finish(.success(()));heldClose.finish(.success(.none))
            try await wait("forced "+phase+" drain"){!model.hasPendingWork && closed==1 && ImportPatchWindowModel.activeWorkers==0}
            let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterSession=try await repo.mailPatchRecoverySession()
            try require(owner.presentationClosed && afterHead==head && afterSession==session && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index && changed==0 && model.output==output && model.error==nil && !model.accepted,"Retired \(phase) callback mutated Git or published late state")
            owner.close();try require(closed==1,"Retired owner closed twice")
        }
        print("PASS: identity/session/recovery/close-read held workers retain close/Quit ownership until drain and reject all late callbacks")
        let(repo,patches)=try await context.fixture("stop-after-command"),owner=context.owner(repo),model=owner.model
        let hooks=repo.root.appendingPathComponent(".git/hooks"),hook=hooks.appendingPathComponent("pre-applypatch"),entered=repo.root.appendingPathComponent(".git/hook-entered"),release=repo.root.appendingPathComponent(".git/release-hook")
        try FileManager.default.createDirectory(at:hooks,withIntermediateDirectories:true)
        func quote(_ text:String)->String{"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let script="#!/bin/sh\nprintf '%s\\n' \"$$\" > "+quote(entered.path)+"\nwhile [ ! -f "+quote(release.path)+" ]; do /bin/sleep 0.02; done\nexit 0\n"
        try Data(script.utf8).write(to:hook);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path);_=try await repo.run(["config","core.hooksPath",hooks.path])
        context.unblock.append{try? Data().write(to:release)}
        model.add(patches);model.apply();try await wait("actual current am held in hook"){FileManager.default.fileExists(atPath:entered.path)}
        let hookPID=pid_t(try String(contentsOf:entered).trimmingCharacters(in:.newlines))!
        let token=model.activeCancellation;model.requestStop()
        try require(model.busy && model.stopRequested && token?.isCancelled==false,"Abort cancelled the running Git command")
        try Data().write(to:release);try await wait("current command finishes before batch stop"){!model.busy}
        try await wait("owned pre-applypatch hook reaped"){kill(hookPID,0) == -1 && errno==ESRCH}
        let subject=try await repo.run(["log","-1","--format=%s"]).text
        try require(model.items[0].state == .success && model.items[1].state == .pending && subject=="Imported 0\n" && !FileManager.default.fileExists(atPath:repo.root.appendingPathComponent("other").path),"Abort did not stop after the current real command")
        print("PASS: native Abort lets actual held git-am finish its current patch and leaves the next patch pending")
        let(brokenRepo,brokenPatches)=try await context.fixture("corrupt-close",conflict:true),broken=context.owner(brokenRepo)
        do{_=try await brokenRepo.importMailPatch(brokenPatches[0]);throw Failure(description:"Expected real conflict before corrupt-close case")}catch is GitFailure{}
        let metadata=brokenRepo.root.appendingPathComponent(".git/rebase-apply"),corrupt=Data("not a valid next item\n".utf8)
        try corrupt.write(to:metadata.appendingPathComponent("next"))
        func metadataBytes()throws->[String:Data] {
            var result:[String:Data]=[:]
            guard let files=FileManager.default.enumerator(at:metadata,includingPropertiesForKeys:[.isRegularFileKey])else{throw Failure(description:"Missing actual am metadata")}
            for case let file as URL in files where (try file.resourceValues(forKeys:[.isRegularFileKey])).isRegularFile==true {result[String(file.path.dropFirst(metadata.path.count+1))]=try Data(contentsOf:file)}
            return result
        }
        let brokenHead=try await brokenRepo.run(["rev-parse","HEAD"]).stdout,brokenIndex=try Data(contentsOf:brokenRepo.root.appendingPathComponent(".git/index")),retainedMetadata=try metadataBytes()
        var questions:[NSAlert]=[],brokenClosed=0
        broken.onClosed={brokenClosed += 1}
        broken.presentQuestion={alert,parent,reply in
            questions.append(alert);alert.window.alphaValue=0;alert.window.appearance=parent.effectiveAppearance;alert.window.setFrameOrigin(NSPoint(x:-12000,y:-12000));alert.beginSheetModal(for:parent,completionHandler:reply);return true
        }
        broken.model.requestClose();try await wait("corrupt metadata owned keep-state question"){questions.count==1 && broken.window?.attachedSheet===questions[0].window}
        try require(questions[0].messageText=="Could not check patch import state" && questions[0].buttons.map(\.title)==["Close and keep state","Cancel"] && questions[0].window.alphaValue==0,"Corrupt session offered destructive recovery or lost hidden owned warning")
        questions[0].buttons[1].performClick(nil)
        try await wait("declined corrupt close keeps owner"){!broken.model.closing && !broken.model.hasPendingWork && broken.window?.attachedSheet==nil}
        try require(brokenClosed==0 && !broken.model.closed && !broken.model.accepted && (try metadataBytes())==retainedMetadata,"Declining corrupt-state close discarded owner or mutated am metadata")
        broken.model.requestClose();try await wait("corrupt close retry question"){questions.count==2 && broken.window?.attachedSheet===questions[1].window}
        questions[1].buttons[0].performClick(nil)
        try await wait("accepted keep-state closes exactly once"){brokenClosed==1 && broken.presentationClosed && !broken.model.hasPendingWork}
        let preservedHead=try await brokenRepo.run(["rev-parse","HEAD"]).stdout,preservedSession=try await brokenRepo.mailPatchSession()
        try require(!broken.model.accepted && preservedHead==brokenHead && preservedSession == .applying && (try Data(contentsOf:brokenRepo.root.appendingPathComponent(".git/index")))==brokenIndex && (try metadataBytes())==retainedMetadata && (try Data(contentsOf:metadata.appendingPathComponent("next")))==corrupt,"Keep-state close modified HEAD/index/corrupt bookkeeping or falsely accepted import")
        broken.close();try require(brokenClosed==1,"Corrupt owner closed twice")
        print("PASS: actual corrupt am bookkeeping offers owned non-destructive keep-state close; decline/retry/accept preserve every metadata file, HEAD and index")
    }}
}
